//! `cowshed lock`: who holds the deploy lock, and freeing it after a deploy died.

const std = @import("std");
const Ssh = @import("../remote/Ssh.zig");
const core = @import("../deploy/lock.zig");
const check = @import("check.zig");
const Allocator = std.mem.Allocator;

pub const Action = enum { status, release };

pub const Options = struct {
    action: Action,
    config_path: []const u8 = check.DEFAULT_CONFIG_PATH,
};

pub fn run(arena: Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !bool {
    const config = try check.readConfig(arena, io, out, options.config_path) orelse return false;
    var ssh: Ssh = .{ .io = io, .user = config.ssh.user, .host = config.host, .port = config.ssh.port, .keys = config.ssh.keys };
    const remote = ssh.remote();
    const held = core.status(arena, remote, config.service) catch |err| {
        try out.print("server {s}: {t}: {s}\n", .{ config.host, err, ssh.connection_error });
        return false;
    };
    switch (options.action) {
        .status => if (held) |who| try out.print("held: {s}\n", .{who}) else try out.writeAll("free\n"),
        .release => {
            core.release(arena, remote, config.service) catch |err| {
                try out.print("server {s}: {t}: {s}\n", .{ config.host, err, ssh.connection_error });
                return false;
            };
            if (held) |who| try out.print("released: {s}\n", .{who}) else try out.writeAll("it was free\n");
        },
    }
    return true;
}
