//! `cowshed update`: replaces this binary with the newest release on GitHub. It
//! changes nothing until the download matches the release's SHA256SUMS, and then
//! swaps the file in one rename, so a failure leaves the old binary as it was.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const REPOSITORY = "llllOllOOll/cowshed";
const LATEST_URL = "https://api.github.com/repos/" ++ REPOSITORY ++ "/releases/latest";
const DOWNLOAD_URL = "https://github.com/" ++ REPOSITORY ++ "/releases/download";
const SUMS_NAME = "SHA256SUMS";
const MAX_BINARY_BYTES = 64 * 1024 * 1024;
const MAX_TEXT_BYTES = 1024 * 1024;

/// The release file for this system, such as `cowshed-linux-x86_64`; null on a
/// system with no release.
pub fn assetName(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "cowshed-linux-x86_64",
            .aarch64 => "cowshed-linux-aarch64",
            else => null,
        },
        .macos => switch (arch) {
            .x86_64 => "cowshed-macos-x86_64",
            .aarch64 => "cowshed-macos-aarch64",
            else => null,
        },
        else => null,
    };
}

/// The version in a tag such as `v1.2.3`; null when it is not one.
pub fn tagVersion(tag: []const u8) ?[]const u8 {
    if (tag.len < 2 or tag[0] != 'v') return null;
    const version = tag[1..];
    _ = std.SemanticVersion.parse(version) catch return null;
    return version;
}

/// The tag in GitHub's answer for the latest release.
fn latestTag(arena: Allocator, json: []const u8) ?[]const u8 {
    const Release = struct { tag_name: []const u8 };
    const release = std.json.parseFromSliceLeaky(Release, arena, json, .{ .ignore_unknown_fields = true }) catch return null;
    return release.tag_name;
}

/// Whether `latest` comes after `current`. A build of this machine (`-dev`)
/// comes before the release of the same number.
pub fn isNewer(current: []const u8, latest: []const u8) bool {
    const a = std.SemanticVersion.parse(current) catch return true;
    const b = std.SemanticVersion.parse(latest) catch return false;
    return a.order(b) == .lt;
}

/// The hex SHA-256 that a SHA256SUMS file gives for `name`.
pub fn expectedSum(sums: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const sum = words.next() orelse continue;
        var file = words.next() orelse continue;
        // `sha256sum -b` marks the name with `*`.
        if (file[0] == '*') file = file[1..];
        if (words.next() != null) continue;
        if (sum.len == 64 and std.mem.eql(u8, file, name)) return sum;
    }
    return null;
}

pub fn matchesSum(bytes: []const u8, expected_hex: []const u8) bool {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    return std.ascii.eqlIgnoreCase(&actual, expected_hex);
}

/// False when something is wrong; what is wrong has been written to `out`.
pub fn run(arena: Allocator, io: std.Io, out: *std.Io.Writer) !bool {
    const name = assetName(builtin.os.tag, builtin.cpu.arch) orelse {
        try out.writeAll("stopped: there is no release for this system; build it from the source\n");
        return false;
    };

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    try out.writeAll("asking GitHub for the latest release\n");
    const answer = get(arena, &client, LATEST_URL, MAX_TEXT_BYTES) catch |err| {
        if (err == error.NotFound) {
            try out.writeAll("stopped: GitHub has no release of " ++ REPOSITORY ++ "; nothing was changed\n");
        } else {
            try out.print("stopped: could not reach GitHub ({s}); nothing was changed\n", .{@errorName(err)});
        }
        return false;
    };
    const tag = latestTag(arena, answer) orelse {
        try out.writeAll("stopped: GitHub's answer names no release; nothing was changed\n");
        return false;
    };
    const latest = tagVersion(tag) orelse {
        try out.print("stopped: the latest release, `{s}`, is not a version tag such as v1.2.3; nothing was changed\n", .{tag});
        return false;
    };
    if (!isNewer(cli.VERSION, latest)) {
        try out.print("already the latest: {s}\n", .{cli.VERSION});
        return true;
    }

    try out.print("downloading {s} {s}\n", .{ name, latest });
    const sums_url = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ DOWNLOAD_URL, tag, SUMS_NAME });
    const sums = get(arena, &client, sums_url, MAX_TEXT_BYTES) catch |err| {
        try out.print("stopped: could not download {s} ({s}); nothing was changed\n", .{ SUMS_NAME, @errorName(err) });
        return false;
    };
    const expected = expectedSum(sums, name) orelse {
        try out.print("stopped: {s} of {s} has no line for {s}; nothing was changed\n", .{ SUMS_NAME, tag, name });
        return false;
    };
    const binary_url = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ DOWNLOAD_URL, tag, name });
    const binary = get(arena, &client, binary_url, MAX_BINARY_BYTES) catch |err| {
        try out.print("stopped: could not download {s} ({s}); nothing was changed\n", .{ name, @errorName(err) });
        return false;
    };
    if (!matchesSum(binary, expected)) {
        try out.print("stopped: {s} does not match its SHA-256 in {s}; nothing was changed\n", .{ name, SUMS_NAME });
        return false;
    }

    const path = try std.process.executablePathAlloc(io, arena);
    if (!try replace(io, out, path, binary)) return false;
    try out.print("updated {s} from {s} to {s}\n", .{ path, cli.VERSION, latest });
    return true;
}

/// The body of a GET that answers 200.
fn get(arena: Allocator, client: *std.http.Client, url: []const u8, limit: usize) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = "cowshed/" ++ cli.VERSION } },
    });
    if (result.status == .not_found) return error.NotFound;
    if (result.status != .ok) return error.HttpStatusNotOk;
    if (body.written().len > limit) return error.ResponseTooLarge;
    return body.written();
}

/// Writes the new binary beside the old one, then renames it over: whoever runs
/// `cowshed` meanwhile gets one or the other whole.
fn replace(io: std.Io, out: *std.Io.Writer, path: []const u8, binary: []const u8) !bool {
    const folder_path = std.fs.path.dirname(path) orelse "/";
    const file_name = std.fs.path.basename(path);
    var folder = try Dir.openDirAbsolute(io, folder_path, .{});
    defer folder.close(io);

    const temporary = ".cowshed-update";
    folder.writeFile(io, .{
        .sub_path = temporary,
        .data = binary,
        .flags = .{ .permissions = .executable_file },
    }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => {
            try out.print("stopped: no permission to write in {s}; run `sudo cowshed update`. Nothing was changed\n", .{folder_path});
            return false;
        },
        else => |e| return e,
    };
    folder.rename(temporary, folder, file_name, io) catch |err| {
        folder.deleteFile(io, temporary) catch {};
        try out.print("stopped: could not replace {s} ({s}); nothing was changed\n", .{ path, @errorName(err) });
        return false;
    };
    return true;
}

const testing = std.testing;

test "a release file for each system with one" {
    try testing.expectEqualStrings("cowshed-linux-x86_64", assetName(.linux, .x86_64).?);
    try testing.expectEqualStrings("cowshed-linux-aarch64", assetName(.linux, .aarch64).?);
    try testing.expectEqualStrings("cowshed-macos-x86_64", assetName(.macos, .x86_64).?);
    try testing.expectEqualStrings("cowshed-macos-aarch64", assetName(.macos, .aarch64).?);
    try testing.expectEqual(null, assetName(.windows, .x86_64));
    try testing.expectEqual(null, assetName(.linux, .riscv64));
}

test "a tag's version" {
    try testing.expectEqualStrings("1.2.3", tagVersion("v1.2.3").?);
    try testing.expectEqual(null, tagVersion("1.2.3"));
    try testing.expectEqual(null, tagVersion("vnext"));
    try testing.expectEqual(null, tagVersion("v"));
}

test "the latest tag in GitHub's answer" {
    const answer =
        \\{"url": "x", "tag_name": "v0.2.0", "assets": [{"name": "a"}], "draft": false}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("v0.2.0", latestTag(arena.allocator(), answer).?);
    try testing.expectEqual(null, latestTag(arena.allocator(), "{\"message\": \"Not Found\"}"));
    try testing.expectEqual(null, latestTag(arena.allocator(), "<html>"));
}

test "only a later release is newer" {
    try testing.expect(isNewer("0.1.0", "0.2.0"));
    try testing.expect(isNewer("0.1.0", "0.1.1"));
    try testing.expect(isNewer("0.2.0-dev", "0.2.0"));
    try testing.expect(!isNewer("0.2.0", "0.2.0"));
    try testing.expect(!isNewer("0.3.0", "0.2.0"));
    try testing.expect(!isNewer("0.3.0-dev", "0.2.0"));
}

test "the sum for a file in SHA256SUMS" {
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');
    const sums = a ++ "  cowshed-linux-x86_64\n" ++ b ++ " *cowshed-macos-aarch64\r\n\nnot a line\n";
    try testing.expectEqualStrings(&a, expectedSum(sums, "cowshed-linux-x86_64").?);
    try testing.expectEqualStrings(&b, expectedSum(sums, "cowshed-macos-aarch64").?);
    try testing.expectEqual(null, expectedSum(sums, "cowshed-linux"));
    try testing.expectEqual(null, expectedSum("short  cowshed-linux-x86_64\n", "cowshed-linux-x86_64"));
}

test "a download matches its sum or not" {
    // sha256("abc")
    const sum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try testing.expect(matchesSum("abc", sum));
    try testing.expect(matchesSum("abc", "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"));
    try testing.expect(!matchesSum("abd", sum));
}

test "the swap leaves one whole file and no leftover" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "cowshed", .data = "old" });
    const folder = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(folder);
    const path = try std.fs.path.join(testing.allocator, &.{ folder, "cowshed" });
    defer testing.allocator.free(path);

    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try testing.expect(try replace(testing.io, &out, path, "new"));
    const now = try tmp.dir.readFileAlloc(testing.io, "cowshed", testing.allocator, .limited(16));
    defer testing.allocator.free(now);
    try testing.expectEqualStrings("new", now);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".cowshed-update", .{}));
}
