//! The port to the server. The core asks it to run a command, and never reaches
//! the outside by itself, so its whole flow can be tested with the fake.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Remote = @This();

/// One word per element: each arrives whole. A pipeline is `sh`, `-c`, its text.
pub const Command = struct {
    argv: []const []const u8,
    /// Given on the command's stdin: how a secret travels, never in `argv`.
    stdin: ?[]const u8 = null,
    /// A local file given on stdin instead, for what should not be held in memory.
    stdin_path: ?[]const u8 = null,
};

pub const Result = struct {
    exit_code: u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",

    pub fn ok(self: Result) bool {
        return self.exit_code == 0;
    }
};

pub const Error = Allocator.Error || error{
    /// The server could not be reached, or the connection broke.
    ConnectionFailed,
    /// The transport could not be started on this machine.
    TransportFailed,
};

ptr: *anyopaque,
runFn: *const fn (ptr: *anyopaque, arena: Allocator, command: Command) Error!Result,

/// Output lives in `arena`. A command failing on the server is a `Result`, not an error.
pub fn run(self: Remote, arena: Allocator, command: Command) Error!Result {
    return self.runFn(self.ptr, arena, command);
}
