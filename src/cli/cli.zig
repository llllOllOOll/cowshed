//! Reads the command line and hands over to a command.

const std = @import("std");
const check = @import("check.zig");
const init = @import("init.zig");
const setup = @import("setup.zig");
const deploy = @import("deploy.zig");
const lock = @import("lock.zig");
const proxy = @import("proxy.zig");
const ops = @import("ops.zig");
const accessory = @import("accessory.zig");
const Allocator = std.mem.Allocator;

pub const VERSION = "0.0.1";

pub const USAGE =
    \\cowshed: deploy Docker containers to a server over SSH
    \\
    \\Usage: cowshed <command>
    \\
    \\  init       Start this project: config/deploy.yml and its secrets. Overwrites nothing
    \\    --host <server>        The server
    \\    --domain <name>        Where the app answers
    \\  check      Check config/deploy.yml and the secrets' names; runs no secret's command
    \\    -c, --config <path>    Another config file
    \\    --secrets <path>       Another secrets file
    \\    --remote               Also reach the server and check Docker (changes nothing)
    \\  setup      Prepare a server: Docker, folders, Traefik. Changes nothing that exists
    \\    -c, --config <path>    Another config file
    \\    --dry-run              Ask the server, say what would happen, change nothing
    \\  proxy adopt  Give a working Traefik a routes folder: says what it would do
    \\    -c, --config <path>    Another config file
    \\    --yes                  Do it: restarts Traefik, cuts every app it serves for seconds
    \\  deploy     Build, send and start a version, then move the traffic to it
    \\    -c, --config <path>    Another config file
    \\    --secrets <path>       Another secrets file
    \\    --dirty                Ship this folder as it is, as a test
    \\    --force                Deploy even if nothing changed
    \\    --migrate              Run the config's backup and migration before the new version
    \\  lock <status|release>   The deploy lock, for after an interrupted deploy
    \\    -c, --config <path>    Another config file
    \\  rollback <version>      Back to a version still on the server: no build
    \\  versions                What is on the server, and what is live
    \\  logs [--lines <n>]      The live container's latest logs
    \\  exec [--version <v>] <command...>
    \\                          A one-off container, with the live one's settings
    \\  audit                   Who deployed what, and when
    \\  prune                   Remove what no kept version uses
    \\  stop                    Take the app off the air; its containers stay
    \\  remove --yes            Remove the app from the server, for good
    \\    (each with -c, --config <path> before its other words)
    \\  accessory <action> <name>  A long-lived container beside the app, such as its database
    \\    boot <name|all>        Start it if it does not exist: folders, secrets, files
    \\    reboot <name|all>      Recreate it from the config; a cut, the old one back if it fails
    \\    start | stop <name|all>   Start or stop it; it stays, with what it holds
    \\    logs <name> [--lines <n>]  Its latest logs
    \\    exec <name> <command...>   A command in it, while it runs
    \\    remove <name> --yes    The container and its files; its directories stay
    \\    (-c, --config <path> and --secrets <path> right after `accessory`)
    \\  version    Show the version
    \\  help       Show this help
    \\
;

pub const Parsed = union(enum) {
    help,
    version,
    init: init.Options,
    check: check.Options,
    setup: setup.Options,
    deploy: deploy.Options,
    lock: lock.Options,
    proxy: proxy.Options,
    ops: ops.Options,
    accessory: accessory.Options,
    /// What was not understood.
    invalid: []const u8,
};

pub fn parse(args: []const []const u8) Parsed {
    if (args.len == 0) return .help;
    const command = args[0];
    if (eql(command, "help") or eql(command, "--help")) return .help;
    if (eql(command, "version") or eql(command, "--version")) return .version;
    if (eql(command, "init")) return parseInit(args[1..]);
    if (eql(command, "setup")) return parseSetup(args[1..]);
    if (eql(command, "deploy")) return parseDeploy(args[1..]);
    if (eql(command, "lock")) return parseLock(args[1..]);
    if (eql(command, "proxy")) return parseProxy(args[1..]);
    if (eql(command, "accessory")) return switch (accessory.parse(args)) {
        .options => |options| .{ .accessory = options },
        .invalid => |what| .{ .invalid = what },
    };
    if (ops.isCommand(command)) return switch (ops.parse(args)) {
        .options => |options| .{ .ops = options },
        .invalid => |what| .{ .invalid = what },
    };
    if (!eql(command, "check")) return .{ .invalid = command };

    var options: check.Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--remote")) {
            options.remote = true;
        } else if (eql(arg, "-c") or eql(arg, "--config")) {
            i += 1;
            if (i == args.len) return .{ .invalid = arg };
            options.config_path = args[i];
        } else if (eql(arg, "--secrets")) {
            i += 1;
            if (i == args.len) return .{ .invalid = arg };
            options.secrets_path = args[i];
        } else {
            return .{ .invalid = arg };
        }
    }
    return .{ .check = options };
}

fn parseInit(args: []const []const u8) Parsed {
    var options: init.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!eql(arg, "--host") and !eql(arg, "--domain")) return .{ .invalid = arg };
        i += 1;
        if (i == args.len) return .{ .invalid = arg };
        if (eql(arg, "--host")) options.host = args[i] else options.domain = args[i];
    }
    return .{ .init = options };
}

fn parseSetup(args: []const []const u8) Parsed {
    var options: setup.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--dry-run")) {
            options.dry_run = true;
        } else if (eql(arg, "-c") or eql(arg, "--config")) {
            i += 1;
            if (i == args.len) return .{ .invalid = arg };
            options.config_path = args[i];
        } else {
            return .{ .invalid = arg };
        }
    }
    return .{ .setup = options };
}

fn parseDeploy(args: []const []const u8) Parsed {
    var options: deploy.Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--dirty")) {
            options.dirty = true;
        } else if (eql(arg, "--force")) {
            options.force = true;
        } else if (eql(arg, "--migrate")) {
            options.migrate = true;
        } else if (eql(arg, "-c") or eql(arg, "--config")) {
            i += 1;
            if (i == args.len) return .{ .invalid = arg };
            options.config_path = args[i];
        } else if (eql(arg, "--secrets")) {
            i += 1;
            if (i == args.len) return .{ .invalid = arg };
            options.secrets_path = args[i];
        } else {
            return .{ .invalid = arg };
        }
    }
    return .{ .deploy = options };
}

fn parseProxy(args: []const []const u8) Parsed {
    if (args.len == 0) return .{ .invalid = "proxy" };
    if (!eql(args[0], "adopt")) return .{ .invalid = args[0] };
    var options: proxy.Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--yes")) {
            options.yes = true;
        } else if (eql(arg, "-c") or eql(arg, "--config")) {
            i += 1;
            if (i == args.len) return .{ .invalid = arg };
            options.config_path = args[i];
        } else {
            return .{ .invalid = arg };
        }
    }
    return .{ .proxy = options };
}

fn parseLock(args: []const []const u8) Parsed {
    if (args.len == 0) return .{ .invalid = "lock" };
    var options: lock.Options = .{ .action = std.meta.stringToEnum(lock.Action, args[0]) orelse return .{ .invalid = args[0] } };
    if (args.len == 3 and (eql(args[1], "-c") or eql(args[1], "--config"))) {
        options.config_path = args[2];
    } else if (args.len != 1) {
        return .{ .invalid = args[1] };
    }
    return .{ .lock = options };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The process's exit code.
pub fn run(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, out: *std.Io.Writer, args: []const []const u8) !u8 {
    switch (parse(args)) {
        .help => try out.writeAll(USAGE),
        .version => try out.writeAll(VERSION ++ "\n"),
        .init => |options| {
            if (!try init.run(arena, io, out, options)) return 1;
        },
        .check => |options| {
            if (!try check.run(arena, io, environ, out, options)) return 1;
        },
        .setup => |options| {
            if (!try setup.run(arena, io, environ, out, options)) return 1;
        },
        .deploy => |options| {
            if (!try deploy.run(arena, io, environ, out, options)) return 1;
        },
        .ops => |options| {
            if (!try ops.run(arena, io, environ, out, options)) return 1;
        },
        .proxy => |options| {
            if (!try proxy.run(arena, io, environ, out, options)) return 1;
        },
        .accessory => |options| {
            if (!try accessory.run(arena, io, environ, out, options)) return 1;
        },
        .lock => |options| {
            if (!try lock.run(arena, io, out, options)) return 1;
        },
        .invalid => |what| {
            try out.print("not understood: {s}\n\n", .{what});
            try out.writeAll(USAGE);
            return 2;
        },
    }
    return 0;
}

const testing = std.testing;

test "no argument shows the help" {
    try testing.expectEqual(.help, std.meta.activeTag(parse(&.{})));
}

test "commands and their flags" {
    try testing.expectEqual(.version, std.meta.activeTag(parse(&.{"version"})));
    try testing.expectEqual(.version, std.meta.activeTag(parse(&.{"--version"})));
    try testing.expectEqual(.help, std.meta.activeTag(parse(&.{"--help"})));
    const parsed = parse(&.{ "check", "-c", "a.yml", "--secrets", "s", "--remote" }).check;
    try testing.expectEqualStrings("a.yml", parsed.config_path);
    try testing.expectEqualStrings("s", parsed.secrets_path.?);
    try testing.expect(parsed.remote);
}

test "init and its flags" {
    const parsed = parse(&.{ "init", "--host", "h", "--domain", "d" }).init;
    try testing.expectEqualStrings("h", parsed.host.?);
    try testing.expectEqualStrings("d", parsed.domain.?);
    try testing.expectEqualStrings("--host", parse(&.{ "init", "--host" }).invalid);
    try testing.expectEqualStrings("--nope", parse(&.{ "init", "--nope" }).invalid);
}

test "setup and its flags" {
    const parsed = parse(&.{ "setup", "-c", "a.yml", "--dry-run" }).setup;
    try testing.expectEqualStrings("a.yml", parsed.config_path);
    try testing.expect(parsed.dry_run);
    try testing.expectEqualStrings("--nope", parse(&.{ "setup", "--nope" }).invalid);
}

test "deploy and lock" {
    try testing.expect(parse(&.{ "deploy", "--migrate" }).deploy.migrate);
    try testing.expect(!parse(&.{"deploy"}).deploy.migrate);
    const parsed = parse(&.{ "deploy", "--dirty", "-c", "a.yml" }).deploy;
    try testing.expect(parsed.dirty);
    try testing.expectEqualStrings("a.yml", parsed.config_path);
    try testing.expectEqual(lock.Action.release, parse(&.{ "lock", "release" }).lock.action);
}

test "proxy adopt" {
    try testing.expect(!parse(&.{ "proxy", "adopt" }).proxy.yes);
    const parsed = parse(&.{ "proxy", "adopt", "--yes", "-c", "a.yml" }).proxy;
    try testing.expect(parsed.yes);
    try testing.expectEqualStrings("a.yml", parsed.config_path);
    try testing.expectEqualStrings("proxy", parse(&.{"proxy"}).invalid);
    try testing.expectEqualStrings("nope", parse(&.{ "proxy", "nope" }).invalid);
    try testing.expectEqualStrings("--nope", parse(&.{ "proxy", "adopt", "--nope" }).invalid);
}

test "anything else is invalid, and names what" {
    try testing.expectEqualStrings("nonsense", parse(&.{"nonsense"}).invalid);
    try testing.expectEqualStrings("rollback", parse(&.{"rollback"}).invalid);
    try testing.expectEqualStrings("--nope", parse(&.{ "deploy", "--nope" }).invalid);
    try testing.expectEqualStrings("open", parse(&.{ "lock", "open" }).invalid);
    try testing.expectEqualStrings("--nope", parse(&.{ "check", "--nope" }).invalid);
    try testing.expectEqualStrings("-c", parse(&.{ "check", "-c" }).invalid);
}
