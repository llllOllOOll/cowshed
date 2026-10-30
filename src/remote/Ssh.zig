//! The real adapter: the system's `ssh`, so keys, the agent and `~/.ssh/config`
//! work as they already do. One connection is shared between commands.

const std = @import("std");
const Remote = @import("Remote.zig");
const process = @import("process.zig");
const Allocator = std.mem.Allocator;
const Ssh = @This();

/// `ssh` itself exits with this when it fails, not the remote command.
const SSH_FAILURE_EXIT = 255;
const CONNECT_TIMEOUT_S = 10;
const CONTROL_PERSIST_S = 60;

io: std.Io,
user: []const u8,
host: []const u8,
port: u16,
keys: []const []const u8 = &.{},
program: []const u8 = "ssh",
/// What `ssh` said when the last command ended in `error.ConnectionFailed`.
connection_error: []const u8 = "",

pub fn remote(self: *Ssh) Remote {
    return .{ .ptr = self, .runFn = run };
}

fn run(ptr: *anyopaque, arena: Allocator, command: Remote.Command) Remote.Error!Remote.Result {
    const self: *Ssh = @ptrCast(@alignCast(ptr));
    const argv = try self.buildArgv(arena, command.argv);
    const output = process.runWith(arena, self.io, argv, command.stdin, command.stdin_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TransportFailed,
    };
    const code = output.exitCode() orelse return error.ConnectionFailed;
    if (code == SSH_FAILURE_EXIT) {
        self.connection_error = std.mem.trimEnd(u8, output.stderr, "\r\n");
        return error.ConnectionFailed;
    }
    return .{ .exit_code = code, .stdout = output.stdout, .stderr = output.stderr };
}

pub fn buildArgv(self: Ssh, arena: Allocator, words: []const []const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        self.program,
        "-o",
        "BatchMode=yes",
        "-o",
        std.fmt.comptimePrint("ConnectTimeout={d}", .{CONNECT_TIMEOUT_S}),
        "-o",
        "ControlMaster=auto",
        "-o",
        "ControlPath=~/.ssh/cowshed-%C",
        "-o",
        std.fmt.comptimePrint("ControlPersist={d}", .{CONTROL_PERSIST_S}),
        "-p",
        try std.fmt.allocPrint(arena, "{d}", .{self.port}),
    });
    for (self.keys) |key| try argv.appendSlice(arena, &.{ "-i", key });
    try argv.append(arena, try std.fmt.allocPrint(arena, "{s}@{s}", .{ self.user, self.host }));
    try argv.append(arena, "--");
    try argv.append(arena, try joinQuoted(arena, words));
    return argv.items;
}

/// `ssh` joins its words into one line for the remote shell: each is quoted here,
/// so spaces, quotes, `$` and an empty word arrive as they left.
pub fn joinQuoted(arena: Allocator, words: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |word, i| {
        if (i > 0) try out.append(arena, ' ');
        try appendQuoted(arena, &out, word);
    }
    return out.items;
}

fn appendQuoted(arena: Allocator, out: *std.ArrayList(u8), word: []const u8) Allocator.Error!void {
    if (word.len > 0 and isPlain(word)) return out.appendSlice(arena, word);
    try out.append(arena, '\'');
    for (word) |c| {
        if (c == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else {
            try out.append(arena, c);
        }
    }
    try out.append(arena, '\'');
}

fn isPlain(word: []const u8) bool {
    for (word) |c| {
        const safe = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_./=:@%+,", c) != null;
        if (!safe) return false;
    }
    return true;
}

const testing = std.testing;

const TRICKY = [_][]const u8{ "--nearest 24", "it's", "$HOME", "`date`", "", "a\"b", "back\\slash", "new\nline", "*", "; rm -rf x", "plain" };

test "the argv: options, key, target, and one line for the remote shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ssh: Ssh = .{ .io = testing.io, .user = "seven", .host = "h.example", .port = 2222, .keys = &.{"~/.ssh/k"} };
    const argv = try ssh.buildArgv(arena.allocator(), &.{ "docker", "run", "--name", "a b" });
    try testing.expectEqualStrings("ssh", argv[0]);
    try testing.expectEqualStrings("BatchMode=yes", argv[2]);
    try testing.expectEqualStrings("seven@h.example", argv[argv.len - 3]);
    try testing.expectEqualStrings("--", argv[argv.len - 2]);
    try testing.expectEqualStrings("docker run --name 'a b'", argv[argv.len - 1]);
    try testing.expectEqualStrings("~/.ssh/k", argv[argv.len - 4]);
    try testing.expectEqualStrings("-i", argv[argv.len - 5]);
}

test "words arrive whole through a shell, as on the server" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var words: std.ArrayList([]const u8) = .empty;
    try words.appendSlice(arena.allocator(), &.{ "printf", "%s\\0" });
    try words.appendSlice(arena.allocator(), &TRICKY);
    const line = try joinQuoted(arena.allocator(), words.items);
    const out = try process.run(arena.allocator(), testing.io, &.{ "sh", "-c", line }, null);
    try testing.expectEqual(0, out.exitCode().?);

    var received = std.mem.splitScalar(u8, out.stdout, 0);
    for (TRICKY) |want| try testing.expectEqualStrings(want, received.next().?);
    try testing.expectEqualStrings("", received.next().?);
    try testing.expect(received.next() == null);
}

/// Stands in for `ssh`: a script that runs the last argument in a shell, as the
/// server would, or fails as `ssh` does when it finds `DOWN` there.
const FAKE_SSH =
    \\#!/bin/sh
    \\for last; do :; done
    \\case "$last" in *DOWN*) echo "no route to host" >&2; exit 255;; esac
    \\exec sh -c "$last"
    \\
;

test "run: result, stdin, a command's failure and a connection's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "ssh", .{ .permissions = .executable_file });
    try file.writeStreamingAll(testing.io, FAKE_SSH);
    file.close(testing.io);
    const program = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ssh", .{tmp.sub_path});

    var ssh: Ssh = .{ .io = testing.io, .user = "u", .host = "h", .port = 22, .program = program };
    const target = ssh.remote();

    const echoed = try target.run(a, .{ .argv = &.{ "printf", "%s", "a b" } });
    try testing.expect(echoed.ok());
    try testing.expectEqualStrings("a b", echoed.stdout);

    const fed = try target.run(a, .{ .argv = &.{"cat"}, .stdin = "from stdin" });
    try testing.expectEqualStrings("from stdin", fed.stdout);

    const failed = try target.run(a, .{ .argv = &.{ "sh", "-c", "exit 7" } });
    try testing.expectEqual(7, failed.exit_code);

    try testing.expectError(error.ConnectionFailed, target.run(a, .{ .argv = &.{"DOWN"} }));
    try testing.expectEqualStrings("no route to host", ssh.connection_error);
}
