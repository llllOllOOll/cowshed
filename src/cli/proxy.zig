//! `cowshed proxy adopt`: reads the config, reaches the server, hands over to the core.

const std = @import("std");
const Ssh = @import("../remote/Ssh.zig");
const core = @import("../deploy/adopt.zig");
const local = @import("../image/local.zig");
const check = @import("check.zig");
const log_file = @import("log.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    config_path: []const u8 = check.DEFAULT_CONFIG_PATH,
    /// Without it, only says what it would do.
    yes: bool = false,
};

/// False when something is wrong; what is wrong has been written to `out`.
pub fn run(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, screen: *std.Io.Writer, options: Options) !bool {
    const config = try check.readConfig(arena, io, screen, options.config_path) orelse return false;
    const log = try log_file.open(arena, io, environ, screen, config.service, "proxy-adopt");
    defer log.close() catch {};
    const out = &log.writer;
    var ssh: Ssh = .{ .io = io, .user = config.ssh.user, .host = config.host, .port = config.ssh.port, .keys = config.ssh.keys };
    return core.run(arena, ssh.remote(), out, config, local.who(arena, io, environ), options.yes) catch |err| switch (err) {
        error.ConnectionFailed, error.TransportFailed => {
            try out.print("server {s}: {t}: {s}\n", .{ config.host, err, ssh.connection_error });
            return false;
        },
        else => |e| return e,
    };
}
