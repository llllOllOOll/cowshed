//! `cowshed check`: reads the config and the secrets' names, runs none of the
//! secrets' commands, changes nothing. With `--remote`, also talks to the server.

const std = @import("std");
const Config = @import("../config/Config.zig");
const secrets = @import("../config/secrets.zig");
const local = @import("../image/local.zig");
const Remote = @import("../remote/Remote.zig");
const Ssh = @import("../remote/Ssh.zig");
const Allocator = std.mem.Allocator;

pub const DEFAULT_CONFIG_PATH = "config/deploy.yml";

pub const Options = struct {
    config_path: []const u8 = DEFAULT_CONFIG_PATH,
    /// Above the config's own `secrets`.
    secrets_path: ?[]const u8 = null,
    remote: bool = false,
};

const MAX_FILE_BYTES = 1024 * 1024;

/// False when something is wrong; what is wrong has been written to `out`.
pub fn run(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, out: *std.Io.Writer, options: Options) !bool {
    const config = try readConfig(arena, io, out, options.config_path) orelse return false;

    try out.print("{s}: {s}, role {s}, host {s}\n", .{ options.config_path, config.service, config.role, config.host });
    for (config.notices) |notice| try out.print("notice: {s}\n", .{notice});

    var ok = try checkSecrets(arena, io, out, config, options.secrets_path orelse config.secrets orelse secrets.DEFAULT_PATH);
    if (config.env_file) |written| {
        // Only that it is there: running it is for a deploy.
        const path = try local.expandHome(arena, environ, written);
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            try out.print("`env_file` {s} is not there\n", .{path});
            ok = false;
        };
    }
    if (options.remote) ok = try checkRemote(arena, io, out, config) and ok;
    return ok;
}

/// Null when it cannot be used; why has been written to `out`.
pub fn readConfig(arena: Allocator, io: std.Io, out: *std.Io.Writer, path: []const u8) !?Config {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_FILE_BYTES)) catch |err| {
        try out.print("{s}: {t}\n", .{ path, err });
        return null;
    };
    var problems: std.ArrayList(Config.Problem) = .empty;
    return Config.parse(arena, source, &problems) catch |err| switch (err) {
        error.InvalidConfig => {
            for (problems.items) |problem| {
                try out.print("{s}:{d}: {s}\n", .{ path, problem.line, problem.message });
            }
            return null;
        },
        else => |e| return e,
    };
}

fn checkSecrets(arena: Allocator, io: std.Io, out: *std.Io.Writer, config: Config, path: []const u8) !bool {
    var wanted: std.ArrayList([]const u8) = .empty;
    try wanted.appendSlice(arena, config.env.secret);
    for (config.accessories) |accessory| try wanted.appendSlice(arena, accessory.env.secret);
    if (wanted.items.len == 0) return true;

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_FILE_BYTES)) catch |err| {
        try out.print("{s}: {t}: the config uses {d} secrets\n", .{ path, err, wanted.items.len });
        return false;
    };
    const defined = try secrets.names(arena, source);
    var ok = true;
    for (wanted.items) |entry| {
        const name = secrets.sourceOf(entry);
        for (defined) |candidate| {
            if (std.mem.eql(u8, candidate, name)) break;
        } else {
            try out.print("{s}: `{s}` is used by the config and not defined\n", .{ path, name });
            ok = false;
        }
    }
    return ok;
}

fn checkRemote(arena: Allocator, io: std.Io, out: *std.Io.Writer, config: Config) !bool {
    var ssh: Ssh = .{ .io = io, .user = config.ssh.user, .host = config.host, .port = config.ssh.port, .keys = config.ssh.keys };
    const remote = ssh.remote();

    const words = [_][]const u8{ "--nearest 24", "it's", "$HOME", "" };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "printf", "%s\\n" });
    try argv.appendSlice(arena, &words);
    const echo = remote.run(arena, .{ .argv = argv.items }) catch |err| {
        try out.print("server: {t}: {s}\n", .{ err, ssh.connection_error });
        return false;
    };
    if (!std.mem.eql(u8, echo.stdout, "--nearest 24\nit's\n$HOME\n\n")) {
        try out.print("server: arguments did not arrive whole\n", .{});
        return false;
    }
    try out.writeAll("server: reached, arguments arrive whole\n");

    const docker = remote.run(arena, .{ .argv = &.{ "docker", "version", "--format", "{{.Server.Version}}" } }) catch |err| {
        try out.print("server: {t}: {s}\n", .{ err, ssh.connection_error });
        return false;
    };
    if (!docker.ok()) {
        try out.print("server: Docker is not usable by {s}\n", .{config.ssh.user});
        return false;
    }
    try out.print("server: Docker {s}\n", .{std.mem.trimEnd(u8, docker.stdout, "\r\n")});
    return true;
}

const testing = std.testing;

fn writeFile(dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = bytes });
}

fn absolute(arena: Allocator, tmp: anytype, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "a good config, a missing secret, and a bad option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ = std.process.Environ.Map.init(a);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "good.yml", "service: s\nimage: i\nservers:\n  - h\nenv:\n  secret:\n    - A\n    - B:C\n");
    try writeFile(tmp.dir, "bad.yml", "service: s\nimage: i\nservers:\n  - h\nnope: 1\n");
    try writeFile(tmp.dir, "secrets", "A=$(exit 1)\nC=1\n");
    try writeFile(tmp.dir, "short", "A=1\n");

    var output: std.Io.Writer.Allocating = .init(a);
    const secrets_path = try absolute(a, tmp, "secrets");
    try testing.expect(try run(a, testing.io, &environ, &output.writer, .{ .config_path = try absolute(a, tmp, "good.yml"), .secrets_path = secrets_path }));

    output.clearRetainingCapacity();
    try testing.expect(!try run(a, testing.io, &environ, &output.writer, .{ .config_path = try absolute(a, tmp, "good.yml"), .secrets_path = try absolute(a, tmp, "short") }));
    try testing.expect(std.mem.indexOf(u8, output.written(), "`C` is used by the config") != null);

    output.clearRetainingCapacity();
    try testing.expect(!try run(a, testing.io, &environ, &output.writer, .{ .config_path = try absolute(a, tmp, "bad.yml") }));
    try testing.expect(std.mem.indexOf(u8, output.written(), ":5: unknown option `nope`") != null);

    output.clearRetainingCapacity();
    try testing.expect(!try run(a, testing.io, &environ, &output.writer, .{ .config_path = "does/not/exist.yml" }));
}

test "an env_file is looked for, not run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ = std.process.Environ.Map.init(a);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const marker = try absolute(a, tmp, "ran");
    try writeFile(tmp.dir, "env", try std.fmt.allocPrint(a, "touch {s}\n", .{marker}));
    const present = try std.fmt.allocPrint(a, "service: s\nimage: i\nservers:\n  - h\nenv_file: {s}\n", .{try absolute(a, tmp, "env")});
    try writeFile(tmp.dir, "present.yml", present);
    try writeFile(tmp.dir, "absent.yml", "service: s\nimage: i\nservers:\n  - h\nenv_file: /nowhere/env\n");

    var output: std.Io.Writer.Allocating = .init(a);
    try testing.expect(try run(a, testing.io, &environ, &output.writer, .{ .config_path = try absolute(a, tmp, "present.yml") }));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "ran", .{}));
    try testing.expect(!try run(a, testing.io, &environ, &output.writer, .{ .config_path = try absolute(a, tmp, "absent.yml") }));
    try testing.expect(std.mem.indexOf(u8, output.written(), "`env_file` /nowhere/env is not there") != null);
}
