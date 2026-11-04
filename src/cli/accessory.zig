//! `cowshed accessory`: the long-lived containers beside the app. Reads the config,
//! its secrets and files on this machine, reaches the server, asks the core.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Ssh = @import("../remote/Ssh.zig");
const secrets = @import("../config/secrets.zig");
const core = @import("../deploy/accessory.zig");
const local = @import("../image/local.zig");
const check = @import("check.zig");
const deploy = @import("deploy.zig");
const Allocator = std.mem.Allocator;

const DEFAULT_LOG_LINES = "100";
/// A file mounted into an accessory: settings, a first script, a theme.
const MAX_FILE_BYTES = 4 * 1024 * 1024;

pub const Action = union(enum) {
    boot,
    start,
    stop,
    logs: []const u8,
    exec: []const []const u8,
    remove: bool,
};

pub const Options = struct {
    action: Action,
    /// An accessory's name, or `all` where that is allowed.
    name: []const u8,
    config_path: []const u8 = check.DEFAULT_CONFIG_PATH,
    secrets_path: ?[]const u8 = null,
};

pub const Parsed = union(enum) {
    options: Options,
    invalid: []const u8,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `args[0]` is `accessory`: `accessory [-c <path>] [--secrets <path>] <action> <name> ...`.
pub fn parse(args: []const []const u8) Parsed {
    var rest = args[1..];
    var options: Options = .{ .action = .boot, .name = "" };
    while (rest.len >= 1 and (eql(rest[0], "-c") or eql(rest[0], "--config") or eql(rest[0], "--secrets"))) {
        if (rest.len < 2) return .{ .invalid = rest[0] };
        if (eql(rest[0], "--secrets")) options.secrets_path = rest[1] else options.config_path = rest[1];
        rest = rest[2..];
    }
    if (rest.len < 2) return .{ .invalid = if (rest.len == 1) rest[0] else "accessory" };
    const action = rest[0];
    options.name = rest[1];
    const after = rest[2..];
    const all_allowed = eql(action, "boot") or eql(action, "start") or eql(action, "stop");
    if (eql(options.name, "all") and !all_allowed) return .{ .invalid = "all" };
    options.action = if (eql(action, "boot") or eql(action, "start") or eql(action, "stop")) blk: {
        if (after.len != 0) return .{ .invalid = after[0] };
        break :blk if (eql(action, "boot")) .boot else if (eql(action, "start")) .start else .stop;
    } else if (eql(action, "logs")) blk: {
        if (after.len == 0) break :blk .{ .logs = DEFAULT_LOG_LINES };
        if (after.len != 2 or !eql(after[0], "--lines")) return .{ .invalid = after[0] };
        _ = std.fmt.parseInt(u32, after[1], 10) catch return .{ .invalid = after[1] };
        break :blk .{ .logs = after[1] };
    } else if (eql(action, "exec")) blk: {
        const command = if (after.len >= 1 and eql(after[0], "--")) after[1..] else after;
        if (command.len == 0) return .{ .invalid = action };
        break :blk .{ .exec = command };
    } else if (eql(action, "remove")) blk: {
        if (after.len == 0) break :blk .{ .remove = false };
        if (after.len != 1 or !eql(after[0], "--yes")) return .{ .invalid = after[0] };
        break :blk .{ .remove = true };
    } else return .{ .invalid = action };
    return .{ .options = options };
}

/// False when something is wrong; what is wrong has been written to `out`.
pub fn run(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, out: *std.Io.Writer, options: Options) !bool {
    const config = try check.readConfig(arena, io, out, options.config_path) orelse return false;
    var chosen: std.ArrayList(Config.Accessory) = .empty;
    if (eql(options.name, "all")) {
        try chosen.appendSlice(arena, config.accessories);
        if (chosen.items.len == 0) {
            try out.writeAll("stopped: the config has no accessories\n");
            return false;
        }
    } else {
        const accessory = core.find(config, options.name) orelse {
            try out.print("stopped: the config has no accessory `{s}`\n", .{options.name});
            return false;
        };
        try chosen.append(arena, accessory);
    }

    var ssh: Ssh = .{ .io = io, .user = config.ssh.user, .host = config.host, .port = config.ssh.port, .keys = config.ssh.keys };
    const remote = ssh.remote();
    const who = local.who(arena, io, environ);
    var ok = true;
    for (chosen.items) |accessory| {
        const done = one(arena, io, environ, out, config, accessory, options, remote, who) catch |err| switch (err) {
            error.ConnectionFailed, error.TransportFailed => {
                try out.print("server {s}: {t}: {s}\n", .{ config.host, err, ssh.connection_error });
                return false;
            },
            else => |e| return e,
        };
        if (!done) ok = false;
    }
    return ok;
}

fn one(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, out: *std.Io.Writer, config: Config, accessory: Config.Accessory, options: Options, remote: @import("../remote/Remote.zig"), who: []const u8) !bool {
    return switch (options.action) {
        .boot => {
            const path = options.secrets_path orelse config.secrets orelse secrets.DEFAULT_PATH;
            const resolved = try deploy.resolveSecrets(arena, io, environ, out, config, accessory.env.secret, path) orelse return false;
            const files = try readFiles(arena, io, out, accessory) orelse return false;
            return core.boot(arena, remote, out, config, accessory, .{ .secrets = resolved, .files = files, .who = who });
        },
        .start => core.start(arena, remote, out, config, accessory, who),
        .stop => core.stop(arena, remote, out, config, accessory, who),
        .logs => |lines| core.logs(arena, remote, out, config, accessory, lines),
        .exec => |command| core.exec(arena, remote, out, config, accessory, command),
        .remove => |confirmed| core.remove(arena, remote, out, config, accessory, who, confirmed),
    };
}

/// Relative to this folder, as the config is.
fn readFiles(arena: Allocator, io: std.Io, out: *std.Io.Writer, accessory: Config.Accessory) !?[]const core.File {
    var files: std.ArrayList(core.File) = .empty;
    for (accessory.files) |entry| {
        const colon = std.mem.lastIndexOfScalar(u8, entry, ':').?;
        const path = entry[0..colon];
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_FILE_BYTES)) catch |err| {
            try out.print("stopped: the file {s} of accessory `{s}`: {t}\n", .{ path, accessory.name, err });
            return null;
        };
        try files.append(arena, .{ .inside = entry[colon + 1 ..], .content = content });
    }
    return files.items;
}

const testing = std.testing;

test "the words of each action" {
    const boot = parse(&.{ "accessory", "boot", "db" }).options;
    try testing.expectEqual(.boot, std.meta.activeTag(boot.action));
    try testing.expectEqualStrings("db", boot.name);
    const configured = parse(&.{ "accessory", "-c", "a.yml", "--secrets", "s", "stop", "all" }).options;
    try testing.expectEqualStrings("a.yml", configured.config_path);
    try testing.expectEqualStrings("s", configured.secrets_path.?);
    try testing.expectEqualStrings("all", configured.name);
    try testing.expectEqualStrings("7", parse(&.{ "accessory", "logs", "db", "--lines", "7" }).options.action.logs);
    try testing.expectEqualStrings("100", parse(&.{ "accessory", "logs", "db" }).options.action.logs);
    const exec = parse(&.{ "accessory", "exec", "db", "--", "psql", "-c", "select 1" }).options.action.exec;
    try testing.expectEqual(3, exec.len);
    try testing.expectEqualStrings("psql", exec[0]);
    try testing.expect(!parse(&.{ "accessory", "remove", "db" }).options.action.remove);
    try testing.expect(parse(&.{ "accessory", "remove", "db", "--yes" }).options.action.remove);
}

test "what is not understood" {
    try testing.expectEqualStrings("accessory", parse(&.{"accessory"}).invalid);
    try testing.expectEqualStrings("boot", parse(&.{ "accessory", "boot" }).invalid);
    try testing.expectEqualStrings("upgrade", parse(&.{ "accessory", "upgrade", "db" }).invalid);
    try testing.expectEqualStrings("all", parse(&.{ "accessory", "remove", "all" }).invalid);
    try testing.expectEqualStrings("all", parse(&.{ "accessory", "exec", "all", "x" }).invalid);
    try testing.expectEqualStrings("exec", parse(&.{ "accessory", "exec", "db" }).invalid);
    try testing.expectEqualStrings("--force", parse(&.{ "accessory", "remove", "db", "--force" }).invalid);
    try testing.expectEqualStrings("extra", parse(&.{ "accessory", "boot", "db", "extra" }).invalid);
}
