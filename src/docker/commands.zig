//! Docker commands, built and never run: the core gives them to the remote port.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version: []const []const u8 = &.{ "docker", "version", "--format", "{{.Server.Version}}" };

pub const list_running: []const []const u8 = &.{ "docker", "ps", "--format", "{{.ID}}\t{{.Image}}\t{{.Names}}" };

/// Line by line: its entrypoint and command as JSON, then its networks. Nothing
/// else is asked for: a container's environment may hold secrets.
const INSPECT_FORMAT = "{{json .Config.Entrypoint}}\n{{json .Config.Cmd}}\n{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}";

pub fn inspectConfig(arena: Allocator, container: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "inspect", "--format", INSPECT_FORMAT, container });
}

pub fn containerState(arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "inspect", "--format", "{{.State.Running}}", name });
}

pub fn start(arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "start", name });
}

pub fn remove(arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "rm", "-f", name });
}

pub fn networkExists(arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "network", "inspect", "--format", "{{.Name}}", name });
}

pub fn networkCreate(arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "network", "create", name });
}

pub const AppContainer = struct {
    name: []const u8,
    image: []const u8,
    service: []const u8,
    role: []const u8,
    version: []const u8,
    /// What it was made from, when known.
    sources: ?[]const u8 = null,
    network: ?[]const u8 = null,
    cpus: ?[]const u8 = null,
    memory: ?[]const u8 = null,
    env_file: ?[]const u8 = null,
    clear_env: []const Pair = &.{},
    labels: []const Pair = &.{},
    volumes: []const []const u8 = &.{},
    cmd: ?[]const u8 = null,
};

pub const Pair = @import("../config/Config.zig").Pair;

pub fn appendVolumes(arena: Allocator, argv: *std.ArrayList([]const u8), volumes: []const []const u8) Allocator.Error!void {
    for (volumes) |volume| try argv.appendSlice(arena, &.{ "--volume", volume });
}

/// Clear variables are on this line, in the open, as they are in the config.
/// Secrets arrive only through `env_file`.
pub fn runApp(arena: Allocator, app: AppContainer) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "docker", "run", "-d", "--name", app.name, "--restart", "unless-stopped" });
    if (app.network) |network| try argv.appendSlice(arena, &.{ "--network", network });
    if (app.cpus) |cpus| try argv.appendSlice(arena, &.{ "--cpus", cpus });
    if (app.memory) |memory| try argv.appendSlice(arena, &.{ "--memory", memory });
    try argv.appendSlice(arena, &.{
        "--label", try std.fmt.allocPrint(arena, "service={s}", .{app.service}),
        "--label", try std.fmt.allocPrint(arena, "role={s}", .{app.role}),
        "--label", try std.fmt.allocPrint(arena, "version={s}", .{app.version}),
    });
    if (app.sources) |sources| {
        try argv.appendSlice(arena, &.{ "--label", try std.fmt.allocPrint(arena, "sources={s}", .{sources}) });
    }
    for (app.labels) |label| {
        try argv.appendSlice(arena, &.{ "--label", try std.fmt.allocPrint(arena, "{s}={s}", .{ label.name, label.value }) });
    }
    for (app.clear_env) |env| {
        try argv.appendSlice(arena, &.{ "--env", try std.fmt.allocPrint(arena, "{s}={s}", .{ env.name, env.value }) });
    }
    if (app.env_file) |path| try argv.appendSlice(arena, &.{ "--env-file", path });
    try appendVolumes(arena, &argv, app.volumes);
    try argv.append(arena, app.image);
    if (app.cmd) |cmd| try appendWords(arena, &argv, cmd);
    return argv.items;
}

pub const Migration = struct {
    name: []const u8,
    image: []const u8,
    service: []const u8,
    command: []const u8,
    timeout_s: u32,
    network: ?[]const u8 = null,
    cpus: ?[]const u8 = null,
    memory: ?[]const u8 = null,
    env_file: ?[]const u8 = null,
    clear_env: []const Pair = &.{},
    /// Its own variables: `--env` wins over the app's and over the env file.
    env: []const Pair = &.{},
    volumes: []const []const u8 = &.{},
};

pub const MIGRATION_TIMED_OUT = 124;

/// `timeout` would only signal the client, and what ignores a signal in a container goes
/// on: when the time is up, the container itself is removed. `$1` the limit, `$2` its
/// name, then the command.
const WITHIN_LIMIT =
    \\limit=$1; name=$2; shift 2
    \\flag=$(mktemp) && rm -f "$flag" || exit 1
    \\(sleep "$limit"; : > "$flag"; docker rm -f "$name") >/dev/null 2>&1 &
    \\watcher=$!
    \\"$@"; code=$?
    \\kill "$watcher" 2>/dev/null
    \\if [ -e "$flag" ]; then rm -f "$flag"; exit 124; fi
    \\exit "$code"
;

/// Attached, so its exit code is the command's. No `service` label: it is no version.
pub fn runMigration(arena: Allocator, migration: Migration) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "sh", "-c", WITHIN_LIMIT, "sh", try std.fmt.allocPrint(arena, "{d}", .{migration.timeout_s}), migration.name, "docker", "run", "--rm", "--name", migration.name, "--label", try std.fmt.allocPrint(arena, "oneoff={s}", .{migration.service}) });
    if (migration.network) |network| try argv.appendSlice(arena, &.{ "--network", network });
    if (migration.cpus) |cpus| try argv.appendSlice(arena, &.{ "--cpus", cpus });
    if (migration.memory) |memory| try argv.appendSlice(arena, &.{ "--memory", memory });
    for (migration.clear_env) |env| {
        try argv.appendSlice(arena, &.{ "--env", try std.fmt.allocPrint(arena, "{s}={s}", .{ env.name, env.value }) });
    }
    if (migration.env_file) |path| try argv.appendSlice(arena, &.{ "--env-file", path });
    for (migration.env) |env| {
        try argv.appendSlice(arena, &.{ "--env", try std.fmt.allocPrint(arena, "{s}={s}", .{ env.name, env.value }) });
    }
    try appendVolumes(arena, &argv, migration.volumes);
    try argv.append(arena, migration.image);
    try appendWords(arena, &argv, migration.command);
    return argv.items;
}

/// Splits on spaces and newlines, keeping what is in quotes together.
fn appendWords(arena: Allocator, argv: *std.ArrayList([]const u8), text: []const u8) Allocator.Error!void {
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    for (text) |c| {
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else {
                try word.append(arena, c);
            }
        } else if (c == '"' or c == '\'') {
            quote = c;
            in_word = true;
        } else if (c == ' ' or c == '\n' or c == '\t') {
            if (in_word) try argv.append(arena, try word.toOwnedSlice(arena));
            in_word = false;
        } else {
            try word.append(arena, c);
            in_word = true;
        }
    }
    if (in_word) try argv.append(arena, try word.toOwnedSlice(arena));
}

pub fn listAll(arena: Allocator, service: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "ps", "-a", "--filter", try std.fmt.allocPrint(arena, "label=service={s}", .{service}), "--format", "{{.Names}}\t{{.State}}\t{{.Label \"version\"}}\t{{.Label \"sources\"}}\t{{.CreatedAt}}" });
}

/// Only images Cowshed built, which carry the service's label: older ones of the
/// same name are not ours to remove.
pub fn imageTags(arena: Allocator, image: []const u8, service: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "images", "--filter", try std.fmt.allocPrint(arena, "reference={s}", .{image}), "--filter", try std.fmt.allocPrint(arena, "label=service={s}", .{service}), "--format", "{{.Tag}}" });
}

pub fn pid(arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "inspect", "--format", "{{.State.Pid}}", name });
}

pub fn stop(arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "stop", name });
}

pub fn logs(arena: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
    return arena.dupe([]const u8, &.{ "docker", "logs", "--tail", "20", name });
}

const testing = std.testing;

test "a container's command: labels, limits, env, and its words whole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try runApp(a, .{
        .name = "s-web-1",
        .image = "s:1",
        .service = "s",
        .role = "web",
        .version = "1",
        .network = "net",
        .memory = "2g",
        .env_file = "/e",
        .clear_env = &.{.{ .name = "A", .value = "b c" }},
        .volumes = &.{ "/srv/a b:/data", "n:/m:ro" },
        .cmd = "--nearest 24 --name \"two words\"\n--empty ''",
    });
    const line = try std.mem.join(a, "|", argv);
    try testing.expect(std.mem.indexOf(u8, line, "--name|s-web-1|--restart|unless-stopped|--network|net|--memory|2g") != null);
    try testing.expect(std.mem.indexOf(u8, line, "--label|version=1") != null);
    try testing.expect(std.mem.indexOf(u8, line, "--env|A=b c|--env-file|/e|--volume|/srv/a b:/data|--volume|n:/m:ro|s:1|--nearest|24|--name|two words|--empty|") != null);
    try testing.expectEqualStrings("", argv[argv.len - 1]);
}

test "a container's environment is never asked for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try inspectConfig(arena.allocator(), "abc");
    try testing.expect(std.mem.indexOf(u8, argv[3], "Env") == null);
    try testing.expectEqualStrings("abc", argv[4]);
}

test "image tags ask for the service's label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = try imageTags(arena.allocator(), "app", "s");
    try testing.expectEqualStrings("label=service=s", argv[5]);
}
