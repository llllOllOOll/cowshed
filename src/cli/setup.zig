//! `cowshed setup`: reads the config, reaches the server, hands over to the core.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Ssh = @import("../remote/Ssh.zig");
const core = @import("../deploy/setup.zig");
const check = @import("check.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    config_path: []const u8 = check.DEFAULT_CONFIG_PATH,
    dry_run: bool = false,
};

/// False when something is wrong; what is wrong has been written to `out`.
pub fn run(arena: Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !bool {
    const config = try check.readConfig(arena, io, out, options.config_path) orelse return false;
    var ssh: Ssh = .{ .io = io, .user = config.ssh.user, .host = config.host, .port = config.ssh.port, .keys = config.ssh.keys };
    return core.run(arena, ssh.remote(), out, config, .{ .dry_run = options.dry_run }) catch |err| switch (err) {
        error.ConnectionFailed, error.TransportFailed => {
            try out.print("server {s}: {t}: {s}\n", .{ config.host, err, ssh.connection_error });
            return false;
        },
        else => |e| return e,
    };
}
