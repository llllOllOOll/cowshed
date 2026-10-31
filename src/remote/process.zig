//! Starting a process on this machine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Output = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,

    pub fn exitCode(self: Output) ?u8 {
        return switch (self.term) {
            .exited => |code| code,
            else => null,
        };
    }
};

const READ_RESERVE = 4096;

fn writeAndClose(io: Io, file: Io.File, bytes: []const u8) void {
    defer file.close(io);
    // A command that stops reading early breaks the pipe; its exit code tells.
    file.writeStreamingAll(io, bytes) catch {};
}

/// Runs `argv`, giving it `stdin` and collecting its output, both at once, so a
/// command that fills a pipe cannot block the other side.
pub fn run(arena: Allocator, io: Io, argv: []const []const u8, stdin: ?[]const u8) !Output {
    return runWith(arena, io, argv, stdin, null);
}

/// As `run`, with an open file on stdin when `stdin_path` is given.
pub fn runWith(arena: Allocator, io: Io, argv: []const []const u8, stdin: ?[]const u8, stdin_path: ?[]const u8) !Output {
    const input: ?Io.File = if (stdin_path) |path| try Io.Dir.cwd().openFile(io, path, .{}) else null;
    defer if (input) |file| file.close(io);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (input) |file| .{ .file = file } else if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var writer: ?Io.Future(void) = null;
    if (stdin) |bytes| {
        const file = child.stdin.?;
        child.stdin = null;
        writer = try io.concurrent(writeAndClose, .{ io, file, bytes });
    }
    defer if (writer) |*task| task.await(io);

    var buffers: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(arena, io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();

    while (reader.fill(READ_RESERVE, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try reader.checkAnyError();

    const term = try child.wait(io);
    return .{
        .term = term,
        .stdout = try reader.toOwnedSlice(0),
        .stderr = try reader.toOwnedSlice(1),
    };
}

/// Runs `argv` with this process's own output, for what a person should watch.
pub fn runInherit(io: Io, argv: []const []const u8, cwd: ?[]const u8) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    defer child.kill(io);
    return child.wait(io);
}

const testing = std.testing;

test "output, exit code and stdin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try run(arena.allocator(), testing.io, &.{ "sh", "-c", "cat; echo err >&2; exit 3" }, "hello");
    try testing.expectEqualStrings("hello", out.stdout);
    try testing.expectEqualStrings("err\n", out.stderr);
    try testing.expectEqual(3, out.exitCode().?);
}

test "a large stdin and output do not block each other" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const big = try arena.allocator().alloc(u8, 4 * 1024 * 1024);
    @memset(big, 'x');
    const out = try run(arena.allocator(), testing.io, &.{"cat"}, big);
    try testing.expectEqual(big.len, out.stdout.len);
}

test "a command that ignores its stdin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const big = try arena.allocator().alloc(u8, 1024 * 1024);
    @memset(big, 'x');
    const out = try run(arena.allocator(), testing.io, &.{"true"}, big);
    try testing.expectEqual(0, out.exitCode().?);
}

test "a file as stdin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f", .data = "from a file" });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/f", .{tmp.sub_path});
    const out = try runWith(a, testing.io, &.{"cat"}, null, path);
    try testing.expectEqualStrings("from a file", out.stdout);
}
