//! The commands on a deployed app: rollback, versions, logs, exec, audit, prune,
//! stop and remove. Each reads the config, reaches the server, asks the core.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Remote = @import("../remote/Remote.zig");
const Ssh = @import("../remote/Ssh.zig");
const deploy = @import("../deploy/deploy.zig");
const core = @import("../deploy/ops.zig");
const local = @import("../image/local.zig");
const check = @import("check.zig");
const log_file = @import("log.zig");
const Allocator = std.mem.Allocator;

const DEFAULT_LOG_LINES = "100";

pub const Action = union(enum) {
    rollback: []const u8,
    versions,
    logs: []const u8,
    exec: struct {
        version: ?[]const u8,
        /// The words of its `--env` options, `NAME=value` each.
        env: []const []const u8 = &.{},
        command: []const []const u8,
    },
    audit,
    prune,
    stop,
    remove: bool,
};

pub const Options = struct {
    action: Action,
    config_path: []const u8 = check.DEFAULT_CONFIG_PATH,
};

pub const Parsed = union(enum) {
    options: Options,
    invalid: []const u8,
};

const COMMANDS = [_][]const u8{ "rollback", "versions", "logs", "exec", "audit", "prune", "stop", "remove" };

pub fn isCommand(word: []const u8) bool {
    for (COMMANDS) |command| {
        if (eql(command, word)) return true;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// `args[0]` is the command.
pub fn parse(args: []const []const u8) Parsed {
    const command = args[0];
    var rest = args[1..];
    var config_path: []const u8 = check.DEFAULT_CONFIG_PATH;
    if (rest.len >= 1 and (eql(rest[0], "-c") or eql(rest[0], "--config"))) {
        if (rest.len < 2) return .{ .invalid = rest[0] };
        config_path = rest[1];
        rest = rest[2..];
    }
    const action: Action = if (eql(command, "rollback")) blk: {
        if (rest.len != 1) return .{ .invalid = command };
        break :blk .{ .rollback = rest[0] };
    } else if (eql(command, "logs")) blk: {
        if (rest.len == 0) break :blk .{ .logs = DEFAULT_LOG_LINES };
        if (rest.len != 2 or !eql(rest[0], "--lines")) return .{ .invalid = rest[0] };
        _ = std.fmt.parseInt(u32, rest[1], 10) catch return .{ .invalid = rest[1] };
        break :blk .{ .logs = rest[1] };
    } else if (eql(command, "exec")) blk: {
        var version: ?[]const u8 = null;
        // `--env` words are counted here, and taken from `args` in order by `envWords`.
        var env_count: usize = 0;
        while (rest.len >= 2 and (eql(rest[0], "--version") or eql(rest[0], "--env"))) {
            if (eql(rest[0], "--version")) version = rest[1] else env_count += 1;
            rest = rest[2..];
        }
        if (rest.len >= 1 and (eql(rest[0], "--version") or eql(rest[0], "--env"))) return .{ .invalid = rest[0] };
        if (rest.len >= 1 and eql(rest[0], "--")) rest = rest[1..];
        if (rest.len == 0) return .{ .invalid = command };
        break :blk .{ .exec = .{ .version = version, .env = if (env_count > 0) args[1 .. args.len - rest.len] else &.{}, .command = rest } };
    } else if (eql(command, "remove")) blk: {
        if (rest.len == 0) break :blk .{ .remove = false };
        if (rest.len != 1 or !eql(rest[0], "--yes")) return .{ .invalid = rest[0] };
        break :blk .{ .remove = true };
    } else blk: {
        if (rest.len != 0) return .{ .invalid = rest[0] };
        if (eql(command, "versions")) break :blk .versions;
        if (eql(command, "audit")) break :blk .audit;
        if (eql(command, "prune")) break :blk .prune;
        break :blk .stop;
    };
    return .{ .options = .{ .action = action, .config_path = config_path } };
}

/// False when something is wrong; what is wrong has been written to `out`.
pub fn run(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, screen: *std.Io.Writer, options: Options) !bool {
    const config = try check.readConfig(arena, io, screen, options.config_path) orelse return false;
    const log = if (options.action == .rollback) try log_file.open(arena, io, environ, screen, config.service, "rollback") else null;
    defer if (log) |file| file.close() catch {};
    const out = if (log) |file| &file.writer else screen;
    var ssh: Ssh = .{ .io = io, .user = config.ssh.user, .host = config.host, .port = config.ssh.port, .keys = config.ssh.keys };
    const remote = ssh.remote();
    const who = local.who(arena, io, environ);
    return dispatch(arena, remote, out, config, options.action, who) catch |err| switch (err) {
        error.ConnectionFailed, error.TransportFailed => {
            try out.print("server {s}: {t}: {s}\n", .{ config.host, err, ssh.connection_error });
            return false;
        },
        else => |e| return e,
    };
}

fn dispatch(arena: Allocator, remote: Remote, out: *std.Io.Writer, config: Config, action: Action, who: []const u8) !bool {
    return switch (action) {
        .rollback => |version| deploy.rollback(arena, remote, out, config, version, who),
        .versions => core.versions(arena, remote, out, config),
        .logs => |lines| core.logs(arena, remote, out, config, lines),
        .exec => |exec| core.exec(arena, remote, out, config, exec.version, try envPairs(arena, exec.env), exec.command),
        .audit => core.audit(arena, remote, out, config),
        .prune => deploy.pruneNow(arena, remote, out, config, who),
        .stop => core.stop(arena, remote, out, config, who),
        .remove => |confirmed| core.remove(arena, remote, out, config, who, confirmed),
    };
}

/// From the words before an exec's command, the values of its `--env` options.
fn envPairs(arena: Allocator, words: []const []const u8) Allocator.Error![]const Config.Pair {
    var pairs: std.ArrayList(Config.Pair) = .empty;
    var i: usize = 0;
    while (i + 1 < words.len) : (i += 1) {
        if (!eql(words[i], "--env")) continue;
        const word = words[i + 1];
        const equals = std.mem.indexOfScalar(u8, word, '=') orelse word.len;
        try pairs.append(arena, .{ .name = word[0..equals], .value = if (equals < word.len) word[equals + 1 ..] else "" });
        i += 1;
    }
    return pairs.items;
}

const testing = std.testing;

test "each command's words" {
    try testing.expectEqualStrings("v1", parse(&.{ "rollback", "v1" }).options.action.rollback);
    try testing.expectEqualStrings("a.yml", parse(&.{ "rollback", "-c", "a.yml", "v1" }).options.config_path);
    try testing.expectEqualStrings("7", parse(&.{ "logs", "--lines", "7" }).options.action.logs);
    try testing.expectEqualStrings("100", parse(&.{"logs"}).options.action.logs);
    try testing.expect(!parse(&.{"remove"}).options.action.remove);
    try testing.expect(parse(&.{ "remove", "--yes" }).options.action.remove);
    const exec = parse(&.{ "exec", "--version", "v1", "--", "ls", "-la" }).options.action.exec;
    try testing.expectEqualStrings("v1", exec.version.?);
    try testing.expectEqualStrings("-la", exec.command[1]);
}

test "what is refused" {
    try testing.expectEqualStrings("rollback", parse(&.{"rollback"}).invalid);
    try testing.expectEqualStrings("x", parse(&.{ "logs", "--lines", "x" }).invalid);
    try testing.expectEqualStrings("--force", parse(&.{ "remove", "--force" }).invalid);
    try testing.expectEqualStrings("exec", parse(&.{"exec"}).invalid);
    const exec = parse(&.{ "exec", "--env", "PG_DB=copy", "--version", "v2", "--env", "MIGRATE=1", "./app" }).options.action.exec;
    try testing.expectEqualStrings("v2", exec.version.?);
    try testing.expectEqualStrings("./app", exec.command[0]);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pairs = try envPairs(arena.allocator(), exec.env);
    try testing.expectEqual(2, pairs.len);
    try testing.expectEqualStrings("PG_DB", pairs[0].name);
    try testing.expectEqualStrings("copy", pairs[0].value);
    try testing.expectEqualStrings("MIGRATE", pairs[1].name);
    try testing.expectEqualStrings("--env", parse(&.{ "exec", "--env" }).invalid);
    try testing.expectEqualStrings("more", parse(&.{ "versions", "more" }).invalid);
}
