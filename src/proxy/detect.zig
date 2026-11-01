//! Finds the Traefik running on a server and reads how it is set up, or says why
//! it cannot be used. Setup and every deploy read it fresh: nothing is kept.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Remote = @import("../remote/Remote.zig");
const docker = @import("../docker/commands.zig");
const traefik = @import("traefik.zig");
const yaml = @import("../config/yaml.zig");
const Allocator = std.mem.Allocator;

/// Given a routes folder as `$1`, inside Traefik's container.
const CAN_USE_FROM_INSIDE = "test -d \"$1\" && test -w \"$1\" && command -v wget >/dev/null";

/// Traefik's own search, from inside its container: the path found, then the file.
/// Given the file its flags name as `$1`, if any. Exits with NO_SETTINGS_FILE if none.
const FIND_SETTINGS =
    \\show() { [ -f "$1" ] || return 1; printf '%s\n' "$1"; cat "$1"; exit 0; }
    \\if [ -n "$1" ]; then show "$1"; exit 3; fi
    \\for d in /etc/traefik ${XDG_CONFIG_HOME:+"$XDG_CONFIG_HOME"} ${HOME:+"$HOME/.config"} .; do
    \\  for e in yml yaml toml; do show "$d/traefik.$e"; done
    \\done
    \\exit 3
;
const NO_SETTINGS_FILE = 3;

pub const Traefik = struct {
    id: []const u8,
    name: []const u8,
    image: []const u8,
    network: []const u8,
    routes_dir: []const u8,
    http_entrypoint: ?[]const u8,
    https_entrypoint: ?[]const u8,
    resolver: ?[]const u8,
    api: bool,
};

pub const Outcome = union(enum) {
    traefik: Traefik,
    /// No Traefik runs here.
    none,
    /// Why this server cannot be used as it is.
    stopped: []const u8,
};

pub fn detect(arena: Allocator, remote: Remote, proxy: Config.Proxy) Remote.Error!Outcome {
    const listed = try remote.run(arena, .{ .argv = docker.list_running });
    if (!listed.ok()) return stopped(arena, "could not list containers: {s}", .{lastLine(listed.stderr)});

    var running: ?Traefik = null;
    var lines = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse continue;
        const image = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        if (!traefik.isTraefikImage(image)) continue;
        if (running != null) return stopped(arena, "more than one Traefik runs on this server: leave one", .{});
        running = .{ .id = id, .image = image, .name = name, .network = "", .routes_dir = "", .http_entrypoint = null, .https_entrypoint = null, .resolver = null, .api = false };
    }
    if (running) |found| return read(arena, remote, proxy, found);
    return .none;
}

fn read(arena: Allocator, remote: Remote, proxy: Config.Proxy, start: Traefik) Remote.Error!Outcome {
    const name = start.name;
    const inspected = try remote.run(arena, .{ .argv = try docker.inspectConfig(arena, start.id) });
    if (!inspected.ok()) return stopped(arena, "could not read Traefik's settings: {s}", .{lastLine(inspected.stderr)});

    var fields = std.mem.splitScalar(u8, inspected.stdout, '\n');
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, parseStrings(arena, fields.next() orelse "null"));
    try args.appendSlice(arena, parseStrings(arena, fields.next() orelse "null"));
    const networks = std.mem.trim(u8, fields.next() orelse "", " \r");
    var flags = traefik.parseFlags(args.items);

    if (flags.config_file != null or !flags.found()) {
        switch (try readSettings(arena, remote, start, flags.config_file orelse "")) {
            .flags => |from_file| flags = from_file,
            .stopped => |message| return .{ .stopped = message },
        }
    }
    if (flags.routes_file) {
        return stopped(arena, "Traefik `{s}` reads one route file, and a switch needs a folder (`providers.file.directory`). That change restarts Traefik and touches every app it serves: make it when that suits", .{name});
    }
    const routes = flags.routes_dir orelse {
        return stopped(arena, "Traefik `{s}` has no routes folder (`providers.file.directory`). Adding it restarts Traefik and touches every app it serves: make it when that suits", .{name});
    };
    if (flags.watch_off) {
        return stopped(arena, "Traefik `{s}` does not watch its routes folder (`providers.file.watch=false`): a switch would not be seen", .{name});
    }
    const can_use = try remote.run(arena, .{ .argv = &.{ "docker", "exec", start.id, "sh", "-c", CAN_USE_FROM_INSIDE, "sh", routes } });
    if (!can_use.ok()) {
        return stopped(arena, "Traefik `{s}`: from inside its container, `{s}` must be a writable folder, with `sh` and `wget` there", .{ name, routes });
    }
    if (proxy.ssl and flags.https_entrypoint == null) {
        return stopped(arena, "the config has `proxy.ssl: true`, and Traefik `{s}` has no entrypoint on 443", .{name});
    }
    if (proxy.ssl and flags.resolver == null) {
        return stopped(arena, "the config has `proxy.ssl: true`, and Traefik `{s}` has no certificate resolver", .{name});
    }
    if (!proxy.ssl and flags.http_entrypoint == null) {
        return stopped(arena, "Traefik `{s}` has no entrypoint on 80", .{name});
    }
    const network = flags.docker_network orelse firstWord(networks);
    if (network.len == 0) return stopped(arena, "Traefik `{s}` is on no network", .{name});

    var found = start;
    found.network = network;
    found.routes_dir = routes;
    found.http_entrypoint = flags.http_entrypoint;
    found.https_entrypoint = flags.https_entrypoint;
    found.resolver = flags.resolver;
    found.api = flags.api;
    return .{ .traefik = found };
}

const Settings = union(enum) {
    flags: traefik.Flags,
    stopped: []const u8,
};

/// Never says what the file holds: it may have secrets. Stays only in memory.
fn readSettings(arena: Allocator, remote: Remote, found: Traefik, named: []const u8) Remote.Error!Settings {
    const name = found.name;
    const read_file = try remote.run(arena, .{ .argv = &.{ "docker", "exec", found.id, "sh", "-c", FIND_SETTINGS, "sh", named } });
    const newline = std.mem.indexOfScalar(u8, read_file.stdout, '\n');
    if (read_file.exit_code == NO_SETTINGS_FILE or (read_file.ok() and newline == null)) {
        return .{ .stopped = try std.fmt.allocPrint(arena, "Traefik `{s}` has no entrypoint in its flags and no settings file: it is set up by its environment, which Cowshed does not read", .{name}) };
    }
    if (!read_file.ok()) {
        return .{ .stopped = try std.fmt.allocPrint(arena, "could not read Traefik `{s}`'s settings file from inside its container: {s}", .{ name, lastLine(read_file.stderr) }) };
    }
    const path = read_file.stdout[0..newline.?];
    if (std.mem.endsWith(u8, path, ".toml")) {
        return .{ .stopped = try std.fmt.allocPrint(arena, "Traefik `{s}` is set up by `{s}`, and Cowshed reads only YAML settings", .{ name, path }) };
    }
    var failure: yaml.Failure = undefined;
    const root = yaml.parseWith(arena, read_file.stdout[newline.? + 1 ..], &failure, .{ .foreign = true }) catch |err| switch (err) {
        error.InvalidYaml => return .{ .stopped = try std.fmt.allocPrint(arena, "could not understand Traefik `{s}`'s `{s}`, line {d}: {s}", .{ name, path, failure.line, failure.message }) },
        else => |e| return e,
    };
    return .{ .flags = traefik.parseSettings(root) };
}

fn stopped(arena: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!Outcome {
    return .{ .stopped = try std.fmt.allocPrint(arena, format, args) };
}

fn lastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\r\n ");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return trimmed[start..];
}

fn firstWord(text: []const u8) []const u8 {
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    return words.next() orelse "";
}

fn parseStrings(arena: Allocator, json: []const u8) []const []const u8 {
    const parsed = std.json.parseFromSliceLeaky(?[]const []const u8, arena, json, .{}) catch return &.{};
    return parsed orelse &.{};
}
