//! The deploy lock: a folder on the server, since `mkdir` is atomic, per service.

const std = @import("std");
const Remote = @import("../remote/Remote.zig");
const Allocator = std.mem.Allocator;

const ACQUIRE =
    \\d="$HOME/.cowshed/locks/$1"
    \\mkdir -p "$HOME/.cowshed/locks" && mkdir "$d" && printf '%s\n' "$2" > "$d/details"
;
const STATUS = "cat \"$HOME/.cowshed/locks/$1/details\"";
const RELEASE = "rm -rf \"$HOME/.cowshed/locks/$1\"";

pub const Acquired = union(enum) {
    acquired,
    /// Who holds it, as they wrote it.
    held: []const u8,
};

pub fn acquire(arena: Allocator, remote: Remote, service: []const u8, details: []const u8) Remote.Error!Acquired {
    const result = try remote.run(arena, .{ .argv = &.{ "sh", "-c", ACQUIRE, "sh", service, details } });
    if (result.ok()) return .acquired;
    return .{ .held = (try status(arena, remote, service)) orelse "unknown: the lock has no details" };
}

/// Who holds it, or null when free.
pub fn status(arena: Allocator, remote: Remote, service: []const u8) Remote.Error!?[]const u8 {
    const result = try remote.run(arena, .{ .argv = &.{ "sh", "-c", STATUS, "sh", service } });
    if (!result.ok()) return null;
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

pub fn release(arena: Allocator, remote: Remote, service: []const u8) Remote.Error!void {
    _ = try remote.run(arena, .{ .argv = &.{ "sh", "-c", RELEASE, "sh", service } });
}

const testing = std.testing;
const Fake = @import("../remote/Fake.zig");

test "acquired, held and free" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake.init(a);
    try testing.expectEqual(.acquired, std.meta.activeTag(try acquire(a, fake.remote(), "s", "me")));
    try fake.on("mkdir", .{ .result = .{ .exit_code = 1 } });
    try fake.on("cat", .{ .result = .{ .exit_code = 0, .stdout = "someone at noon\n" } });
    try testing.expectEqualStrings("someone at noon", (try acquire(a, fake.remote(), "s", "me")).held);
    try fake.on("cat", .{ .result = .{ .exit_code = 1 } });
    try testing.expect((try status(a, fake.remote(), "s")) == null);
}
