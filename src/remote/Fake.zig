//! The port for tests: records every command and answers from a script, so a test
//! can make any step fail with no server.

const std = @import("std");
const Remote = @import("Remote.zig");
const Allocator = std.mem.Allocator;
const Fake = @This();

pub const Answer = union(enum) {
    result: Remote.Result,
    connection_failed,
};

const Rule = struct {
    /// Applies when the command's words, joined by spaces, contain this.
    contains: []const u8,
    answer: Answer,
};

pub const Call = struct {
    line: []const u8,
    stdin: ?[]const u8,
};

arena: Allocator,
rules: std.ArrayList(Rule) = .empty,
calls: std.ArrayList(Call) = .empty,

pub fn init(arena: Allocator) Fake {
    return .{ .arena = arena };
}

pub fn remote(self: *Fake) Remote {
    return .{ .ptr = self, .runFn = run };
}

/// The latest rule that applies wins; with none, a command succeeds with no output.
pub fn on(self: *Fake, contains: []const u8, answer: Answer) Allocator.Error!void {
    try self.rules.append(self.arena, .{ .contains = contains, .answer = answer });
}

pub fn ran(self: Fake, contains: []const u8) bool {
    return self.position(contains) != null;
}

/// Where the first command containing this is, to test the order of steps.
pub fn position(self: Fake, contains: []const u8) ?usize {
    for (self.calls.items, 0..) |call, i| {
        if (std.mem.indexOf(u8, call.line, contains) != null) return i;
    }
    return null;
}

fn run(ptr: *anyopaque, arena: Allocator, command: Remote.Command) Remote.Error!Remote.Result {
    _ = arena;
    const self: *Fake = @ptrCast(@alignCast(ptr));
    const line = try std.mem.join(self.arena, " ", command.argv);
    try self.calls.append(self.arena, .{ .line = line, .stdin = command.stdin });
    var i = self.rules.items.len;
    while (i > 0) {
        i -= 1;
        const rule = self.rules.items[i];
        if (std.mem.indexOf(u8, line, rule.contains) == null) continue;
        return switch (rule.answer) {
            .result => |result| result,
            .connection_failed => error.ConnectionFailed,
        };
    }
    return .{ .exit_code = 0 };
}

const testing = std.testing;

test "records, answers by rule, the latest first, and fails on demand" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake.init(a);
    const target = fake.remote();

    try testing.expect((try target.run(a, .{ .argv = &.{ "docker", "ps" } })).ok());
    try testing.expect(fake.ran("docker ps"));
    try testing.expect(!fake.ran("docker stop"));

    try fake.on("docker", .{ .result = .{ .exit_code = 1 } });
    try fake.on("docker stop", .{ .result = .{ .exit_code = 0, .stdout = "stopped" } });
    try testing.expectEqual(1, (try target.run(a, .{ .argv = &.{ "docker", "rm" } })).exit_code);
    try testing.expectEqualStrings("stopped", (try target.run(a, .{ .argv = &.{ "docker", "stop", "x" } })).stdout);

    try fake.on("ssh-down", .connection_failed);
    try testing.expectError(error.ConnectionFailed, target.run(a, .{ .argv = &.{"ssh-down"} }));

    _ = try target.run(a, .{ .argv = &.{"cat"}, .stdin = "secret" });
    try testing.expectEqualStrings("secret", fake.calls.items[fake.calls.items.len - 1].stdin.?);
}
