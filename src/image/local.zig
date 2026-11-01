//! What a deploy does on this machine: the version, the build, the image saved,
//! the secrets' commands, and asking the app's URL from outside.

const std = @import("std");
const Config = @import("../config/Config.zig");
const process = @import("../remote/process.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How long the outside check waits: a first certificate takes a moment.
const OUTSIDE_TRIES = "6";
const OUTSIDE_DELAY_S = "5";

fn output(arena: Allocator, io: Io, argv: []const []const u8) ?[]const u8 {
    const result = process.run(arena, io, argv, null) catch return null;
    if (result.exitCode() != 0) return null;
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

/// `--dirty`: the short commit, and the time if anything differs, new files included:
/// two tests are different things. Null with no commit.
pub fn dirtyVersion(arena: Allocator, io: Io) ?[]const u8 {
    const commit = output(arena, io, &.{ "git", "rev-parse", "--short", "HEAD" }) orelse return null;
    const status = output(arena, io, &.{ "git", "status", "--porcelain", "--", "." }) orelse return null;
    if (status.len == 0) return commit;
    const time = output(arena, io, &.{ "date", "+%s" }) orelse "0";
    return std.fmt.allocPrint(arena, "{s}-dirty-{s}", .{ commit, time }) catch null;
}

pub fn who(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) []const u8 {
    return output(arena, io, &.{ "git", "config", "user.name" }) orelse environ.get("USER") orelse "unknown";
}

/// The project's own build step, watched as it runs, knowing the version.
pub fn runBefore(arena: Allocator, io: Io, command: []const u8, image_version: []const u8, cwd: ?[]const u8) !bool {
    const variable = try std.fmt.allocPrint(arena, "COWSHED_VERSION={s}", .{image_version});
    const term = try process.runInherit(io, &.{ "env", variable, "sh", "-c", command }, cwd);
    return term == .exited and term.exited == 0;
}

pub fn build(arena: Allocator, io: Io, builder: Config.Builder, service: []const u8, tag: []const u8, cwd: ?[]const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "docker", "build", "-t", tag, "--label", try std.fmt.allocPrint(arena, "service={s}", .{service}), "-f", builder.dockerfile });
    if (builder.arch) |arch| {
        try argv.appendSlice(arena, &.{ "--platform", try std.fmt.allocPrint(arena, "linux/{s}", .{arch}) });
    }
    try argv.append(arena, builder.context);
    const term = try process.runInherit(io, argv.items, cwd);
    return term == .exited and term.exited == 0;
}

/// `~/` as the user's home, for a path written in the config.
pub fn expandHome(arena: Allocator, environ: *const std.process.Environ.Map, path: []const u8) Allocator.Error![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const home = environ.get("HOME") orelse return path;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, path[2..] });
}

/// What a shell file sets, as `NAME=value` joined by NUL, for this command alone. What
/// the file prints or says on failing is dropped: it may hold values. Null if it fails.
pub fn loadEnvFile(arena: Allocator, io: Io, path: []const u8) !?[]const u8 {
    // `.` searches the PATH for a bare name.
    const script = "set -a; . \"$1\" >/dev/null 2>&1 && env -0";
    const where = if (std.mem.indexOfScalar(u8, path, '/') == null) try std.fmt.allocPrint(arena, "./{s}", .{path}) else path;
    const result = process.run(arena, io, &.{ "sh", "-c", script, "sh", where }, null) catch return null;
    if (result.exitCode() != 0) return null;
    return result.stdout;
}

pub const Source = struct {
    /// Its folder's name.
    name: []const u8,
    /// Its repository's folder, and where in it this source is.
    top: []const u8,
    prefix: []const u8,
    /// The whole commit that will be built, short for showing.
    commit: []const u8,
    short: []const u8,
    /// The last commit that touched this source's own folder.
    touched: []const u8,
    /// Files in the folder that differ from what will be built.
    uncommitted: usize,
    /// Those git does not know yet, by name: `git commit -a` leaves them out too.
    untracked: []const []const u8 = &.{},
};

/// The new files in `git status --porcelain`; a whole new folder is one entry.
fn untrackedIn(arena: Allocator, status: []const u8) Allocator.Error![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "?? ")) try found.append(arena, line[3..]);
    }
    return found.items;
}

pub const SourcesResult = union(enum) {
    sources: []const Source,
    /// Why they cannot be read.
    failed: []const u8,
};

fn git(arena: Allocator, io: Io, folder: []const u8, args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(arena, &.{ "git", "-C", folder }) catch return null;
    argv.appendSlice(arena, args) catch return null;
    return output(arena, io, argv.items);
}

/// The first is the project itself: `.` if the config does not list it.
pub fn readSources(arena: Allocator, io: Io, listed: []const []const u8, branch: ?[]const u8) !SourcesResult {
    var folders: std.ArrayList([]const u8) = .empty;
    try folders.append(arena, ".");
    for (listed) |folder| {
        if (!std.mem.eql(u8, folder, ".")) try folders.append(arena, folder);
    }
    var sources: std.ArrayList(Source) = .empty;
    for (folders.items) |folder| {
        const top = git(arena, io, folder, &.{ "rev-parse", "--show-toplevel" }) orelse {
            return .{ .failed = try std.fmt.allocPrint(arena, "`{s}` is not in a git repository", .{folder}) };
        };
        const prefix = git(arena, io, folder, &.{ "rev-parse", "--show-prefix" }) orelse "";
        const ref = branch orelse "HEAD";
        const commit = git(arena, io, folder, &.{ "rev-parse", "--verify", try std.fmt.allocPrint(arena, "{s}^{{commit}}", .{ref}) }) orelse {
            if (branch == null) return .{ .failed = try std.fmt.allocPrint(arena, "`{s}` has no commit yet: a deploy is made from one", .{folder}) };
            return .{ .failed = try std.fmt.allocPrint(arena, "`{s}` has no branch `{s}`", .{ folder, ref }) };
        };
        const touched = git(arena, io, folder, &.{ "log", "-1", "--format=%h", commit, "--", "." }) orelse "";
        const status = git(arena, io, folder, &.{ "status", "--porcelain", "--", "." }) orelse "";
        var changed: usize = 0;
        var lines = std.mem.tokenizeScalar(u8, status, '\n');
        while (lines.next()) |_| changed += 1;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ top, std.mem.trimEnd(u8, prefix, "/") });
        try sources.append(arena, .{
            .name = std.fs.path.basename(std.mem.trimEnd(u8, full, "/")),
            .top = top,
            .prefix = prefix,
            .commit = commit,
            .short = commit[0..@min(commit.len, SHORT_COMMIT)],
            .touched = touched,
            .uncommitted = changed,
            .untracked = try untrackedIn(arena, status),
        });
    }
    return .{ .sources = sources.items };
}

/// `arena@abc,engine@def`: the same when nothing that makes up the project changed.
pub fn fingerprint(arena: Allocator, sources: []const Source) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (sources, 0..) |source, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, source.name);
        try out.append(arena, '@');
        try out.appendSlice(arena, source.touched);
    }
    return out.items;
}

/// Where the repositories keep their places relative to each other, so a path
/// like `../../engine` still holds. Kept between deploys: what git ignores, such
/// as a build's downloads, need not come again.
pub fn prepareCopies(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, service: []const u8, sources: []const Source) !?[]const u8 {
    const cache = if (environ.get("XDG_CACHE_HOME")) |dir| dir else try std.fmt.allocPrint(arena, "{s}/.cache", .{environ.get("HOME") orelse return null});
    const root = try std.fmt.allocPrint(arena, "{s}/cowshed/clones/{s}", .{ cache, service });

    var common: []const u8 = std.fs.path.dirname(sources[0].top) orelse "/";
    for (sources) |source| {
        while (!std.mem.startsWith(u8, source.top, common)) common = std.fs.path.dirname(common) orelse "/";
    }
    for (sources) |source| {
        const place = try std.fs.path.join(arena, &.{ root, source.top[common.len..] });
        const has_copy = output(arena, io, &.{ "git", "-C", place, "rev-parse", "--is-inside-work-tree" }) != null and
            std.mem.eql(u8, output(arena, io, &.{ "git", "-C", place, "rev-parse", "--show-toplevel" }) orelse "", place);
        if (!has_copy) {
            _ = process.run(arena, io, &.{ "rm", "-rf", place }, null) catch return null;
            _ = process.run(arena, io, &.{ "mkdir", "-p", std.fs.path.dirname(place) orelse "/" }, null) catch return null;
            if (output(arena, io, &.{ "git", "clone", "--quiet", "--no-checkout", source.top, place }) == null) return null;
        }
        if (git(arena, io, place, &.{ "fetch", "--quiet", "origin", source.commit }) == null) return null;
        if (git(arena, io, place, &.{ "checkout", "--quiet", "--force", "--detach", source.commit }) == null) return null;
        // What git ignores stays: downloads and caches, which the build needs fast.
        if (git(arena, io, place, &.{ "clean", "-fdq" }) == null) return null;
    }
    const project = sources[0];
    return try std.fs.path.join(arena, &.{ root, project.top[common.len..], project.prefix });
}

const SHORT_COMMIT = 7;

const SAVE =
    \\d=$(mktemp -d) && docker save -o "$d/image.tar" "$1" && tar -xf "$d/image.tar" -C "$d" && rm "$d/image.tar" && printf %s "$d"
;

/// A temporary folder with the image's OCI layout, or null.
pub fn save(arena: Allocator, io: Io, tag: []const u8) ?[]const u8 {
    return output(arena, io, &.{ "sh", "-c", SAVE, "sh", tag });
}

pub fn removeFolder(arena: Allocator, io: Io, path: []const u8) void {
    _ = process.run(arena, io, &.{ "rm", "-rf", path }, null) catch {};
}

/// Its stdout, or an error: for `$(...)` in the secrets file. Its stderr is not
/// kept: it could hold a value.
pub fn shell(arena: Allocator, io: Io, command: []const u8) ![]const u8 {
    const result = try process.run(arena, io, &.{ "sh", "-c", command }, null);
    if (result.exitCode() != 0) return error.CommandFailed;
    return result.stdout;
}

/// The status code seen from here, or null if it never answered.
pub fn askOutside(arena: Allocator, io: Io, url: []const u8) ?[]const u8 {
    return output(arena, io, &.{ "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--retry", OUTSIDE_TRIES, "--retry-delay", OUTSIDE_DELAY_S, "--retry-connrefused", "--max-time", "60", url });
}

const testing = std.testing;

test "a command's stdout, and its failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("value\n", try shell(a, testing.io, "echo value"));
    try testing.expectError(error.CommandFailed, shell(a, testing.io, "exit 3"));
}

test "only what git does not know counts as new, a new folder as one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const found = try untrackedIn(arena_state.allocator(), " M app.py\nA  added.py\n?? logo.svg\n?? public/brand/\n");
    try std.testing.expectEqual(2, found.len);
    try std.testing.expectEqualStrings("logo.svg", found[0]);
    try std.testing.expectEqualStrings("public/brand/", found[1]);
    try std.testing.expectEqual(0, (try untrackedIn(arena_state.allocator(), "")).len);
}

test "an env file: what it sets, and nothing it prints or says" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/env", .{tmp.sub_path});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "env", .data = "PLAIN=one\nexport DONE=two\necho noise\n" });
    const loaded = (try loadEnvFile(a, std.testing.io, path)).?;
    try std.testing.expect(std.mem.indexOf(u8, loaded, "PLAIN=one\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded, "DONE=two\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded, "noise") == null);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad", .data = "exit 1\n" });
    try std.testing.expect(try loadEnvFile(a, std.testing.io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/bad", .{tmp.sub_path})) == null);
}

test "a fingerprint names each source and what last touched it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base: Source = .{ .name = "", .top = "", .prefix = "", .commit = "", .short = "", .touched = "", .uncommitted = 0 };
    var a = base;
    a.name = "game";
    a.touched = "abc";
    var b = base;
    b.name = "engine";
    b.touched = "def";
    try testing.expectEqualStrings("game@abc,engine@def", try fingerprint(arena.allocator(), &.{ a, b }));
}
