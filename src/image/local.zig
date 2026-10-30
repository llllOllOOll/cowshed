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

pub const Version = union(enum) {
    version: []const u8,
    not_a_repository,
    uncommitted,
};

/// The short commit. Uncommitted work, with `dirty`, gets the time too: two tests
/// are different things.
pub fn version(arena: Allocator, io: Io, dirty: bool) Version {
    const commit = output(arena, io, &.{ "git", "rev-parse", "--short", "HEAD" }) orelse return .not_a_repository;
    const clean = process.run(arena, io, &.{ "git", "diff", "--quiet", "HEAD", "--", "." }, null) catch return .not_a_repository;
    if (clean.exitCode() == 0) return .{ .version = commit };
    if (!dirty) return .uncommitted;
    const time = output(arena, io, &.{ "date", "+%s" }) orelse "0";
    return .{ .version = std.fmt.allocPrint(arena, "{s}-dirty-{s}", .{ commit, time }) catch return .not_a_repository };
}

pub fn who(arena: Allocator, io: Io, environ: *const std.process.Environ.Map) []const u8 {
    return output(arena, io, &.{ "git", "config", "user.name" }) orelse environ.get("USER") orelse "unknown";
}

/// The project's own build step, watched as it runs, knowing the version.
pub fn runBefore(arena: Allocator, io: Io, command: []const u8, image_version: []const u8) !bool {
    const variable = try std.fmt.allocPrint(arena, "COWSHED_VERSION={s}", .{image_version});
    const term = try process.runInherit(io, &.{ "env", variable, "sh", "-c", command });
    return term == .exited and term.exited == 0;
}

pub fn build(arena: Allocator, io: Io, builder: Config.Builder, service: []const u8, tag: []const u8) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "docker", "build", "-t", tag, "--label", try std.fmt.allocPrint(arena, "service={s}", .{service}), "-f", builder.dockerfile });
    if (builder.arch) |arch| {
        try argv.appendSlice(arena, &.{ "--platform", try std.fmt.allocPrint(arena, "linux/{s}", .{arch}) });
    }
    try argv.append(arena, builder.context);
    const term = try process.runInherit(io, argv.items);
    return term == .exited and term.exited == 0;
}

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
