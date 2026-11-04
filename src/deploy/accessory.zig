//! Accessories: long-lived containers beside the app, such as its database, named
//! `<service>-<name>`. Started once and left running across deploys; recreated only
//! when asked. Their files live in `~/.cowshed/accessories/<service>-<name>/`, apart
//! from the app's, so nothing done to the app reaches them.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Remote = @import("../remote/Remote.zig");
const docker = @import("../docker/commands.zig");
const deploy = @import("deploy.zig");
const lock = @import("lock.zig");
const routing = @import("routing.zig");
const detect = @import("../proxy/detect.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = Remote.Error || Writer.Error;

/// A file of `files`, read on this machine.
pub const File = struct {
    /// Where it is mounted in the container.
    inside: []const u8,
    content: []const u8,
};

pub const Input = struct {
    secrets: []const deploy.Secret = &.{},
    /// In the order of the accessory's `files`.
    files: []const File = &.{},
    who: []const u8 = "",
};

/// Its folder, its `directories` under it, and the folder's path. `$1` its name, then
/// the directories' names.
const PREPARE =
    \\d="$HOME/.cowshed/accessories/$1"; shift
    \\umask 077 && mkdir -p "$d/files" || exit 1
    \\umask 022 && for x in "$@"; do mkdir -p "$d/directories/$x" || exit 1; done
    \\printf %s "$d"
;
/// Secrets on stdin, never on a command line. `$1` the folder.
const WRITE_ENV = "umask 077 && cat > \"$1/env\"";
/// `$1` the folder, `$2` the file's name there.
const WRITE_FILE = "umask 022 && cat > \"$1/files/$2\"";
/// What `remove` takes: the env file and the files sent. Directories stay.
const REMOVE_FILES = "d=\"$HOME/.cowshed/accessories/$1\"; rm -rf \"$d/env\" \"$d/files\"";
const APPEND_AUDIT =
    \\mkdir -p "$HOME/.cowshed" && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$HOME/.cowshed/audit-$1.log"
;
/// Seconds after the start for an accessory that exits at once to be seen.
const SETTLE_S = "3";
/// Running and never restarted: with `--restart`, one that dies is started again,
/// and can be caught running between two deaths.
const STILL_RUNNING = "sleep \"$1\"; docker inspect --format '{{.State.Running}} {{.RestartCount}}' \"$2\"";
const RUNNING_SINCE_START = "true 0";

pub fn containerName(arena: Allocator, config: Config, accessory: Config.Accessory) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ config.service, accessory.name });
}

pub fn find(config: Config, name: []const u8) ?Config.Accessory {
    for (config.accessories) |accessory| {
        if (std.mem.eql(u8, accessory.name, name)) return accessory;
    }
    return null;
}

/// Its own, or the project's when it names none.
pub fn networksOf(config: Config, accessory: Config.Accessory) []const []const u8 {
    return accessory.networks orelse config.networks;
}

/// Traefik's network first, with `proxy`, then its own.
fn joined(arena: Allocator, config: Config, accessory: Config.Accessory, traefik: ?detect.Traefik) Allocator.Error![]const []const u8 {
    var networks: std.ArrayList([]const u8) = .empty;
    if (traefik) |found| try networks.append(arena, found.network);
    for (networksOf(config, accessory)) |network| {
        for (networks.items) |already| {
            if (std.mem.eql(u8, already, network)) break;
        } else try networks.append(arena, network);
    }
    return networks.items;
}

const Proxying = union(enum) {
    none,
    traefik: detect.Traefik,
    stopped,
};

/// The Traefik its `proxy` needs, if it has one.
fn proxying(arena: Allocator, remote: Remote, out: *Writer, accessory: Config.Accessory) Error!Proxying {
    const proxy = accessory.proxy orelse return .none;
    switch (try detect.detect(arena, remote, proxy)) {
        .traefik => |found| return .{ .traefik = found },
        .none => {
            try out.print("stopped: `accessories.{s}.proxy` needs Traefik, and none runs here: `cowshed setup`\n", .{accessory.name});
            return .stopped;
        },
        .stopped => |message| {
            try out.print("stopped: {s}\n", .{message});
            return .stopped;
        },
    }
}

fn traefikOf(proxied: Proxying) ?detect.Traefik {
    return switch (proxied) {
        .traefik => |found| found,
        else => null,
    };
}

const State = enum { missing, running, stopped };

fn state(arena: Allocator, remote: Remote, name: []const u8) Remote.Error!State {
    const inspected = try remote.run(arena, .{ .argv = try docker.containerState(arena, name) });
    if (!inspected.ok()) return .missing;
    return if (std.mem.eql(u8, std.mem.trim(u8, inspected.stdout, " \r\n"), "true")) .running else .stopped;
}

fn audit(arena: Allocator, remote: Remote, config: Config, who: []const u8, message: []const u8) Remote.Error!void {
    const line = try std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ who, config.service, message });
    _ = try remote.run(arena, .{ .argv = &.{ "sh", "-c", APPEND_AUDIT, "sh", config.service, line } });
}

fn trimmed(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \r\n");
}

/// Starts it if it does not exist. One that exists is left as it is: `reboot`
/// recreates it.
pub fn boot(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, input: Input) Error!bool {
    const name = try containerName(arena, config, accessory);
    switch (try state(arena, remote, name)) {
        .running => {
            try out.print("accessory: {s} already runs; `cowshed accessory reboot {s}` recreates it\n", .{ name, accessory.name });
            return true;
        },
        .stopped => {
            try out.print("stopped: {s} exists and is stopped: `cowshed accessory start {s}`\n", .{ name, accessory.name });
            return false;
        },
        .missing => {},
    }
    const proxied = try proxying(arena, remote, out, accessory);
    if (proxied == .stopped) return false;
    if (!try acquire(arena, remote, out, name, input.who, "booting")) return false;
    defer lock.release(arena, remote, name) catch {};
    const ready = try prepare(arena, remote, out, config, accessory, input, name, traefikOf(proxied)) orelse return false;
    if (!try launch(arena, remote, out, config, accessory, name, ready)) {
        try audit(arena, remote, config, input.who, try std.fmt.allocPrint(arena, "accessory {s} failed to boot", .{accessory.name}));
        return false;
    }
    try audit(arena, remote, config, input.who, try std.fmt.allocPrint(arena, "accessory {s} booted", .{accessory.name}));
    return true;
}

/// Recreates it from the config as it is now: a new image tag, other settings,
/// new secrets or files. What it serves is cut while the new one starts, and its
/// data, in its directories, carries over. If the new one fails, the old one is
/// put back as it was.
pub fn reboot(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, input: Input) Error!bool {
    const name = try containerName(arena, config, accessory);
    const old = try std.fmt.allocPrint(arena, "{s}-replaced", .{name});
    const proxied = try proxying(arena, remote, out, accessory);
    if (proxied == .stopped) return false;
    if (!try acquire(arena, remote, out, name, input.who, "rebooting")) return false;
    defer lock.release(arena, remote, name) catch {};
    if (try state(arena, remote, old) != .missing) {
        try out.print("stopped: {s} is there, from a reboot that did not end: see which of it and {s} holds what you need, and remove the other\n", .{ old, name });
        return false;
    }
    const before = try state(arena, remote, name);
    // All that can fail before anything is touched.
    const ready = try prepare(arena, remote, out, config, accessory, input, name, traefikOf(proxied)) orelse return false;
    if (before == .missing) {
        try out.print("accessory: {s} does not exist; booting it\n", .{name});
        if (!try launch(arena, remote, out, config, accessory, name, ready)) return false;
        try audit(arena, remote, config, input.who, try std.fmt.allocPrint(arena, "accessory {s} booted", .{accessory.name}));
        return true;
    }

    // Its data cannot be open in two containers at once: the old one stops first.
    const renamed = try remote.run(arena, .{ .argv = &.{ "docker", "rename", name, old } });
    if (!renamed.ok()) {
        try out.print("stopped: could not set {s} aside: {s}\n", .{ name, trimmed(renamed.stderr) });
        return false;
    }
    if (before == .running) {
        try out.print("accessory: stopping {s}; what it serves is cut until the new one runs\n", .{name});
        const stopped = try remote.run(arena, .{ .argv = try docker.stop(arena, old) });
        if (!stopped.ok()) {
            _ = try remote.run(arena, .{ .argv = &.{ "docker", "rename", old, name } });
            try out.print("stopped: could not stop {s}: {s}; it was left as it was\n", .{ name, trimmed(stopped.stderr) });
            return false;
        }
    }
    if (!try launch(arena, remote, out, config, accessory, name, ready)) {
        _ = try remote.run(arena, .{ .argv = &.{ "docker", "rename", old, name } });
        if (before == .running) {
            const back = try remote.run(arena, .{ .argv = try docker.start(arena, name) });
            if (!back.ok()) {
                try out.print("PUT BACK FAILED: {s} is stopped: `cowshed accessory start {s}`: {s}\n", .{ name, accessory.name, trimmed(back.stderr) });
                try audit(arena, remote, config, input.who, try std.fmt.allocPrint(arena, "accessory {s} reboot failed, the old one stopped", .{accessory.name}));
                return false;
            }
        }
        try out.print("accessory: the old {s} is back, as it was\n", .{name});
        try audit(arena, remote, config, input.who, try std.fmt.allocPrint(arena, "accessory {s} reboot failed, the old one back", .{accessory.name}));
        return false;
    }
    _ = try remote.run(arena, .{ .argv = try docker.remove(arena, old) });
    try audit(arena, remote, config, input.who, try std.fmt.allocPrint(arena, "accessory {s} rebooted", .{accessory.name}));
    try out.print("accessory: rebooted {s}\n", .{name});
    return true;
}

fn acquire(arena: Allocator, remote: Remote, out: *Writer, name: []const u8, who: []const u8, doing: []const u8) Error!bool {
    switch (try lock.acquire(arena, remote, name, try std.fmt.allocPrint(arena, "{s}, {s}", .{ who, doing }))) {
        .acquired => return true,
        .held => |holder| {
            try out.print("stopped: another command holds the lock of {s}: {s}\n", .{ name, holder });
            return false;
        },
    }
}

/// What a start needs, on the server and ready.
const Prepared = struct {
    env_file: ?[]const u8,
    volumes: []const []const u8,
    networks: []const []const u8,
    traefik: ?detect.Traefik,
};

/// Its networks, its folder, its env file and its files. Nothing that runs is touched.
fn prepare(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, input: Input, name: []const u8, traefik: ?detect.Traefik) Error!?Prepared {
    // Traefik's network is there already; its own may not be.
    for (networksOf(config, accessory)) |network| {
        if ((try remote.run(arena, .{ .argv = try docker.networkExists(arena, network) })).ok()) continue;
        try out.print("network: making {s}\n", .{network});
        const made = try remote.run(arena, .{ .argv = try docker.networkCreate(arena, network) });
        if (!made.ok()) {
            try out.print("stopped: could not make the network `{s}`: {s}\n", .{ network, trimmed(made.stderr) });
            return null;
        }
    }

    var folders: std.ArrayList([]const u8) = .empty;
    try folders.appendSlice(arena, &.{ "sh", "-c", PREPARE, "sh", name });
    for (accessory.directories) |directory| try folders.append(arena, directory[0..std.mem.indexOfScalar(u8, directory, ':').?]);
    const prepared = try remote.run(arena, .{ .argv = folders.items });
    if (!prepared.ok()) {
        try out.print("stopped: could not prepare its folder: {s}\n", .{trimmed(prepared.stderr)});
        return null;
    }
    const folder = trimmed(prepared.stdout);

    var env_file: ?[]const u8 = null;
    if (input.secrets.len > 0) {
        var text: std.ArrayList(u8) = .empty;
        for (input.secrets) |secret| {
            if (std.mem.indexOfScalar(u8, secret.value, '\n') != null) {
                try out.print("stopped: the secret `{s}` has a line break, which an env file cannot hold\n", .{secret.name});
                return null;
            }
            try text.print(arena, "{s}={s}\n", .{ secret.name, secret.value });
        }
        const written = try remote.run(arena, .{ .argv = &.{ "sh", "-c", WRITE_ENV, "sh", folder }, .stdin = text.items });
        if (!written.ok()) {
            try out.print("stopped: could not write its env file: {s}\n", .{trimmed(written.stderr)});
            return null;
        }
        try out.print("secrets: writing {d} to its env file\n", .{input.secrets.len});
        env_file = try std.fmt.allocPrint(arena, "{s}/env", .{folder});
    }

    var volumes: std.ArrayList([]const u8) = .empty;
    for (accessory.directories) |directory| {
        const colon = std.mem.indexOfScalar(u8, directory, ':').?;
        try volumes.append(arena, try std.fmt.allocPrint(arena, "{s}/directories/{s}:{s}", .{ folder, directory[0..colon], directory[colon + 1 ..] }));
    }
    for (input.files, 0..) |file, i| {
        // Numbered: two files of the same name in different places do not clash.
        const stored = try std.fmt.allocPrint(arena, "{d}-{s}", .{ i, std.fs.path.basenamePosix(file.inside) });
        const sent = try remote.run(arena, .{ .argv = &.{ "sh", "-c", WRITE_FILE, "sh", folder, stored }, .stdin = file.content });
        if (!sent.ok()) {
            try out.print("stopped: could not send the file for {s}: {s}\n", .{ file.inside, trimmed(sent.stderr) });
            return null;
        }
        try volumes.append(arena, try std.fmt.allocPrint(arena, "{s}/files/{s}:{s}:ro", .{ folder, stored, file.inside }));
    }
    try volumes.appendSlice(arena, accessory.volumes);
    return .{ .env_file = env_file, .volumes = volumes.items, .networks = try joined(arena, config, accessory, traefik), .traefik = traefik };
}

/// Starts the container and waits to see it stay up. If not, it is shown and
/// removed, and its directories stay as they are.
fn launch(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, name: []const u8, ready: Prepared) Error!bool {
    try out.print("accessory: starting {s} ({s})\n", .{ name, accessory.image });
    const started = try remote.run(arena, .{ .argv = try docker.runAccessory(arena, .{
        .name = name,
        .image = accessory.image,
        .service = config.service,
        .accessory = accessory.name,
        .networks = ready.networks,
        .publish = accessory.port,
        .env_file = ready.env_file,
        .clear_env = accessory.env.clear,
        .volumes = ready.volumes,
        .cmd = accessory.cmd,
    }) });
    if (!started.ok()) {
        // A failed `docker run` can leave its container behind.
        _ = try remote.run(arena, .{ .argv = try docker.remove(arena, name) });
        try out.print("stopped: {s} did not start: {s}\n", .{ name, trimmed(started.stderr) });
        return false;
    }
    const ctx: routing.Context = .{ .arena = arena, .remote = remote, .out = out };
    if (ready.traefik) |traefik| {
        const proxy = accessory.proxy.?;
        if (!try routing.healthy(ctx, traefik, name, proxy, accessory.boot_timeout_s)) {
            try discard(arena, remote, out, name, "did not pass its health check");
            return false;
        }
        try out.print("health: {s} is healthy\n", .{name});
        // The same name across reboots: the route is the same, and taken at once.
        if (!try routing.switchTo(ctx, traefik, .{ .key = name, .proxy = proxy, .container = name })) {
            _ = try remote.run(arena, .{ .argv = try docker.remove(arena, name) });
            return false;
        }
    } else {
        const running = try remote.run(arena, .{ .argv = &.{ "sh", "-c", STILL_RUNNING, "sh", SETTLE_S, name } });
        if (!running.ok() or !std.mem.eql(u8, trimmed(running.stdout), RUNNING_SINCE_START)) {
            try discard(arena, remote, out, name, "exited at once");
            return false;
        }
    }
    try out.print("accessory: {s} runs\n", .{name});
    return true;
}

/// Shows its last logs and removes it. Its directories stay.
fn discard(arena: Allocator, remote: Remote, out: *Writer, name: []const u8, why: []const u8) Error!void {
    const last = try remote.run(arena, .{ .argv = try docker.logs(arena, name) });
    try out.print("--- its logs\n{s}{s}---\n", .{ last.stdout, last.stderr });
    _ = try remote.run(arena, .{ .argv = try docker.remove(arena, name) });
    try out.print("stopped: {s} {s}; its directories stay as they are\n", .{ name, why });
}

pub fn start(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, who: []const u8) Error!bool {
    const name = try containerName(arena, config, accessory);
    switch (try state(arena, remote, name)) {
        .running => {
            try out.print("accessory: {s} already runs\n", .{name});
            return true;
        },
        .missing => {
            try out.print("stopped: {s} does not exist: `cowshed accessory boot {s}`\n", .{ name, accessory.name });
            return false;
        },
        .stopped => {},
    }
    const started = try remote.run(arena, .{ .argv = try docker.start(arena, name) });
    if (!started.ok()) {
        try out.print("stopped: could not start {s}: {s}\n", .{ name, trimmed(started.stderr) });
        return false;
    }
    try audit(arena, remote, config, who, try std.fmt.allocPrint(arena, "accessory {s} started", .{accessory.name}));
    try out.print("accessory: started {s}\n", .{name});
    return true;
}

/// The container stays, with all it holds: `start` brings it back.
pub fn stop(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, who: []const u8) Error!bool {
    const name = try containerName(arena, config, accessory);
    switch (try state(arena, remote, name)) {
        .missing => {
            try out.print("accessory: {s} does not exist\n", .{name});
            return true;
        },
        .stopped => {
            try out.print("accessory: {s} is already stopped\n", .{name});
            return true;
        },
        .running => {},
    }
    const stopped = try remote.run(arena, .{ .argv = try docker.stop(arena, name) });
    if (!stopped.ok()) {
        try out.print("stopped: could not stop {s}: {s}\n", .{ name, trimmed(stopped.stderr) });
        return false;
    }
    try audit(arena, remote, config, who, try std.fmt.allocPrint(arena, "accessory {s} stopped", .{accessory.name}));
    try out.print("accessory: stopped {s}\n", .{name});
    return true;
}

pub fn logs(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, lines: []const u8) Error!bool {
    const name = try containerName(arena, config, accessory);
    const result = try remote.run(arena, .{ .argv = &.{ "docker", "logs", "--tail", lines, name } });
    try out.writeAll(result.stdout);
    try out.writeAll(result.stderr);
    return result.ok();
}

/// In the running container: a database's own tools reach its live data. Its exit
/// code decides; its output comes when it ends.
pub fn exec(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, command: []const []const u8) Error!bool {
    const name = try containerName(arena, config, accessory);
    if (try state(arena, remote, name) != .running) {
        try out.print("stopped: {s} is not running\n", .{name});
        return false;
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "docker", "exec", name });
    try argv.appendSlice(arena, command);
    try out.print("exec: running in {s}; its output comes at the end\n", .{name});
    const result = try remote.run(arena, .{ .argv = argv.items });
    try out.writeAll(result.stdout);
    try out.writeAll(result.stderr);
    if (!result.ok()) try out.print("exit code {d}\n", .{result.exit_code});
    return result.ok();
}

/// The container, its env file and the files sent. Its directories and volumes stay,
/// with what they hold. Without `confirmed` it only tells.
pub fn remove(arena: Allocator, remote: Remote, out: *Writer, config: Config, accessory: Config.Accessory, who: []const u8, confirmed: bool) Error!bool {
    const name = try containerName(arena, config, accessory);
    const current = try state(arena, remote, name);
    if (!confirmed) {
        try out.print("this removes the accessory {s} from {s}, and cannot be undone:\n", .{ name, config.host });
        try out.print("  the container {s} ({s}), its env file and the files sent\n", .{ name, @tagName(current) });
        if (accessory.proxy) |proxy| try out.print("  its route, {s}\n", .{proxy.host});
        for (accessory.directories) |directory| try out.print("  the directory {s} stays, with what it holds\n", .{directory});
        for (accessory.volumes) |volume| try out.print("  the volume {s} stays, with what it holds\n", .{volume});
        try out.writeAll("run it again with `--yes`\n");
        return false;
    }
    switch (try lock.acquire(arena, remote, name, try std.fmt.allocPrint(arena, "{s}, removing", .{who}))) {
        .acquired => {},
        .held => |holder| {
            try out.print("stopped: another command holds the lock of {s}: {s}\n", .{ name, holder });
            return false;
        },
    }
    defer lock.release(arena, remote, name) catch {};
    if (current != .missing) {
        const removed = try remote.run(arena, .{ .argv = try docker.remove(arena, name) });
        if (!removed.ok()) {
            try out.print("stopped: could not remove {s}: {s}\n", .{ name, trimmed(removed.stderr) });
            return false;
        }
    }
    _ = try remote.run(arena, .{ .argv = &.{ "sh", "-c", REMOVE_FILES, "sh", name } });
    if (accessory.proxy) |proxy| {
        switch (try detect.detect(arena, remote, proxy)) {
            .traefik => |found| {
                const ctx: routing.Context = .{ .arena = arena, .remote = remote, .out = out };
                if (!try routing.removeRoute(ctx, found, name)) try out.print("notice: could not remove the route of {s}\n", .{name});
            },
            .none => {},
            .stopped => |message| try out.print("notice: its route was not touched: {s}\n", .{message}),
        }
    }
    for (accessory.directories) |directory| try out.print("kept the directory {s}\n", .{directory});
    for (accessory.volumes) |volume| try out.print("kept the volume {s}\n", .{volume});
    try audit(arena, remote, config, who, try std.fmt.allocPrint(arena, "accessory {s} removed", .{accessory.name}));
    try out.print("removed {s}\n", .{name});
    return true;
}

const testing = std.testing;
const Fake = @import("../remote/Fake.zig");

const DB: Config.Accessory = .{
    .name = "db",
    .image = "postgres:17",
    .port = "127.0.0.1:5432:5432",
    .env = .{ .clear = &.{.{ .name = "POSTGRES_USER", .value = "app" }}, .secret = &.{"POSTGRES_PASSWORD"} },
    .files = &.{"config/init.sql:/docker-entrypoint-initdb.d/init.sql"},
    .directories = &.{"data:/var/lib/postgresql/data"},
};
const CONFIG: Config = .{ .service = "app", .image = "app", .host = "h", .networks = &.{"own"}, .accessories = &.{DB} };
const FOLDER = "/home/u/.cowshed/accessories/app-db";

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    fake: Fake = undefined,
    output: Writer.Allocating = undefined,

    fn begin(self: *Harness) !void {
        const a = self.arena.allocator();
        self.fake = Fake.init(a);
        self.output = .init(a);
        try self.on("{{.State.Running}} app-db", 1, "");
        try self.on("mkdir -p \"$d/files\"", 0, FOLDER);
        try self.on("sleep \"$1\"", 0, "true 0\n");
    }

    fn on(self: *Harness, contains: []const u8, code: u8, stdout: []const u8) !void {
        try self.fake.on(contains, .{ .result = .{ .exit_code = code, .stdout = stdout, .stderr = "the error" } });
    }

    fn boot(self: *Harness) !bool {
        return accessory_boot(self.arena.allocator(), self.fake.remote(), &self.output.writer);
    }

    fn says(self: *Harness, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.output.written(), text) == null) {
            std.debug.print("output:\n{s}\n", .{self.output.written()});
            return error.TestExpectedOutput;
        }
    }

    fn before(self: *Harness, first: []const u8, second: []const u8) !void {
        const a = self.fake.position(first) orelse return error.TestFirstNotRun;
        const b = self.fake.position(second) orelse return error.TestSecondNotRun;
        if (a >= b) {
            std.debug.print("`{s}` came after `{s}`\n", .{ first, second });
            return error.TestWrongOrder;
        }
    }

    fn line(self: *Harness, contains: []const u8) []const u8 {
        return self.fake.calls.items[self.fake.position(contains).?].line;
    }
};

fn harness() Harness {
    return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
}

const INPUT: Input = .{
    .secrets = &.{.{ .name = "POSTGRES_PASSWORD", .value = "s3cret" }},
    .files = &.{.{ .inside = "/docker-entrypoint-initdb.d/init.sql", .content = "CREATE DATABASE kc;\n" }},
    .who = "me",
};

fn accessory_boot(arena: Allocator, remote: Remote, out: *Writer) !bool {
    return boot(arena, remote, out, CONFIG, DB, INPUT);
}

test "boot: its folder, its secrets on stdin, its files, then the container on the project's networks" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(try h.boot());
    try testing.expect(std.mem.endsWith(u8, h.line("mkdir \"$d\""), "sh app-db me, booting"));
    try testing.expect(h.fake.ran("docker network inspect --format {{.Name}} own"));
    try testing.expect(std.mem.endsWith(u8, h.line("mkdir -p \"$d/files\""), "sh app-db data"));
    const env = h.fake.calls.items[h.fake.position("cat > \"$1/env\"").?];
    try testing.expectEqualStrings("POSTGRES_PASSWORD=s3cret\n", env.stdin.?);
    const file = h.fake.calls.items[h.fake.position("cat > \"$1/files/$2\"").?];
    try testing.expect(std.mem.endsWith(u8, file.line, FOLDER ++ " 0-init.sql"));
    try testing.expectEqualStrings("CREATE DATABASE kc;\n", file.stdin.?);
    const run = h.line("docker run -d --name app-db");
    for ([_][]const u8{
        "--network own",
        "--publish 127.0.0.1:5432:5432",
        "--env POSTGRES_USER=app",
        "--env-file " ++ FOLDER ++ "/env",
        "--volume " ++ FOLDER ++ "/directories/data:/var/lib/postgresql/data",
        "--volume " ++ FOLDER ++ "/files/0-init.sql:/docker-entrypoint-initdb.d/init.sql:ro",
    }) |part| {
        if (std.mem.indexOf(u8, run, part) == null) {
            std.debug.print("missing `{s}` in: {s}\n", .{ part, run });
            return error.TestExpectedPart;
        }
    }
    // No secret on any command line.
    for (h.fake.calls.items) |call| try testing.expect(std.mem.indexOf(u8, call.line, "s3cret") == null);
    try testing.expect(h.fake.ran("accessory db booted"));
    try h.says("accessory: app-db runs");
}

test "boot: one that runs is left alone, one that is stopped is told" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("{{.State.Running}} app-db", 0, "true\n");
    try testing.expect(try h.boot());
    try h.says("already runs");
    try testing.expect(!h.fake.ran("docker run"));
    try h.on("{{.State.Running}} app-db", 0, "false\n");
    try testing.expect(!try h.boot());
    try h.says("`cowshed accessory start db`");
    try testing.expect(!h.fake.ran("docker run"));
}

test "boot: one that exits at once is shown, removed, its directories kept" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("sleep \"$1\"", 0, "false 0\n");
    try h.on("docker logs", 0, "FATAL: bad setting\n");
    try testing.expect(!try h.boot());
    // Caught running again after dying: still a failure.
    try h.on("sleep \"$1\"", 0, "true 2\n");
    try testing.expect(!try h.boot());
    try h.says("FATAL: bad setting");
    try h.says("exited at once; its directories stay");
    try testing.expect(h.fake.ran("docker rm -f app-db"));
    try testing.expect(!h.fake.ran("\"$d/env\" \"$d/files\""));
}

test "boot: a start that fails leaves no container, a network that cannot be made starts nothing" {
    {
        var h = harness();
        defer h.arena.deinit();
        try h.begin();
        try h.on("docker run -d", 125, "");
        try testing.expect(!try h.boot());
        try testing.expect(h.fake.ran("docker rm -f app-db"));
        try h.says("did not start: the error");
    }
    {
        var h = harness();
        defer h.arena.deinit();
        try h.begin();
        try h.on("network inspect", 1, "");
        try h.on("network create", 1, "");
        try testing.expect(!try h.boot());
        try testing.expect(!h.fake.ran("docker run"));
        try testing.expect(!h.fake.ran("mkdir -p \"$d/files\""));
    }
}

test "boot: a lock held stops it" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("mkdir \"$d\"", 1, "");
    try h.on("cat \"$HOME/.cowshed/locks/$1/details\"", 0, "someone, booting");
    try testing.expect(!try h.boot());
    try h.says("holds the lock of app-db");
    try testing.expect(!h.fake.ran("docker run"));
}

test "an accessory naming its own networks joins those, not the project's" {
    var accessory = DB;
    accessory.networks = &.{"theirs"};
    try testing.expectEqualStrings("theirs", networksOf(CONFIG, accessory)[0]);
    try testing.expectEqualStrings("own", networksOf(CONFIG, DB)[0]);
}

test "start, stop, exec: by its state" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    const a = h.arena.allocator();
    const remote = h.fake.remote();
    const out = &h.output.writer;
    try testing.expect(!try start(a, remote, out, CONFIG, DB, "me"));
    try h.says("`cowshed accessory boot db`");
    try testing.expect(try stop(a, remote, out, CONFIG, DB, "me"));
    try testing.expect(!try exec(a, remote, out, CONFIG, DB, &.{"psql"}));
    try h.on("{{.State.Running}} app-db", 0, "false\n");
    try testing.expect(try start(a, remote, out, CONFIG, DB, "me"));
    try testing.expect(h.fake.ran("docker start app-db"));
    try h.on("{{.State.Running}} app-db", 0, "true\n");
    try testing.expect(try stop(a, remote, out, CONFIG, DB, "me"));
    try testing.expect(h.fake.ran("docker stop app-db"));
    try h.on("docker exec app-db", 0, "1 row\n");
    try testing.expect(try exec(a, remote, out, CONFIG, DB, &.{ "psql", "-c", "select 1" }));
    try testing.expect(h.fake.ran("docker exec app-db psql -c select 1"));
    try h.says("1 row");
}

test "remove: tells without --yes; with it takes the container and its files, never its directories" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("{{.State.Running}} app-db", 0, "true\n");
    const a = h.arena.allocator();
    try testing.expect(!try remove(a, h.fake.remote(), &h.output.writer, CONFIG, DB, "me", false));
    try h.says("the directory data:/var/lib/postgresql/data stays");
    try testing.expect(!h.fake.ran("docker rm"));
    try testing.expect(try remove(a, h.fake.remote(), &h.output.writer, CONFIG, DB, "me", true));
    try testing.expect(h.fake.ran("docker rm -f app-db"));
    const files = h.line("rm -rf");
    try testing.expect(std.mem.indexOf(u8, files, "\"$d/env\" \"$d/files\"") != null);
    try testing.expect(std.mem.indexOf(u8, files, "directories") == null);
    try h.says("kept the directory data:/var/lib/postgresql/data");
}

test "reboot: prepared first, the old one set aside and stopped, the new one proven, then the old removed" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("{{.State.Running}} app-db", 0, "true\n");
    try h.on("{{.State.Running}} app-db-replaced", 1, "");
    const a = h.arena.allocator();
    try testing.expect(try reboot(a, h.fake.remote(), &h.output.writer, CONFIG, DB, INPUT));
    try h.before("cat > \"$1/files/$2\"", "docker rename app-db app-db-replaced");
    try h.before("docker rename app-db app-db-replaced", "docker stop app-db-replaced");
    try h.before("docker stop app-db-replaced", "docker run -d --name app-db");
    try h.before("sleep \"$1\"", "docker rm -f app-db-replaced");
    try testing.expect(h.fake.ran("accessory db rebooted"));
    try h.says("what it serves is cut until the new one runs");
}

test "reboot: a new one that fails puts the old one back, running" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("{{.State.Running}} app-db", 0, "true\n");
    try h.on("{{.State.Running}} app-db-replaced", 1, "");
    try h.on("sleep \"$1\"", 0, "true 1\n");
    const a = h.arena.allocator();
    try testing.expect(!try reboot(a, h.fake.remote(), &h.output.writer, CONFIG, DB, INPUT));
    try h.before("docker rm -f app-db", "docker rename app-db-replaced app-db");
    try h.before("docker rename app-db-replaced app-db", "docker start app-db");
    try testing.expect(!h.fake.ran("docker rm -f app-db-replaced"));
    try h.says("the old app-db is back");
    try testing.expect(h.fake.ran("reboot failed, the old one back"));
}

test "reboot: a stopped one comes back stopped; a missing one is booted; a leftover stops it" {
    {
        var h = harness();
        defer h.arena.deinit();
        try h.begin();
        try h.on("{{.State.Running}} app-db", 0, "false\n");
        try h.on("{{.State.Running}} app-db-replaced", 1, "");
        try h.on("sleep \"$1\"", 0, "false 0\n");
        try testing.expect(!try reboot(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, DB, INPUT));
        try testing.expect(!h.fake.ran("docker stop"));
        try testing.expect(!h.fake.ran("docker start"));
        try testing.expect(h.fake.ran("docker rename app-db-replaced app-db"));
    }
    {
        var h = harness();
        defer h.arena.deinit();
        try h.begin();
        try h.on("{{.State.Running}} app-db-replaced", 1, "");
        try testing.expect(try reboot(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, DB, INPUT));
        try testing.expect(!h.fake.ran("docker rename"));
        try h.says("does not exist; booting it");
    }
    {
        var h = harness();
        defer h.arena.deinit();
        try h.begin();
        try h.on("{{.State.Running}} app-db", 0, "true\n");
        try h.on("{{.State.Running}} app-db-replaced", 0, "false\n");
        try testing.expect(!try reboot(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, DB, INPUT));
        try h.says("from a reboot that did not end");
        try testing.expect(!h.fake.ran("docker run"));
        try testing.expect(!h.fake.ran("docker rename"));
    }
}

test "reboot: a failure before anything is touched leaves the old one running" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("{{.State.Running}} app-db", 0, "true\n");
    try h.on("{{.State.Running}} app-db-replaced", 1, "");
    try h.on("cat > \"$1/files/$2\"", 1, "");
    try testing.expect(!try reboot(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, DB, INPUT));
    try testing.expect(!h.fake.ran("docker rename"));
    try testing.expect(!h.fake.ran("docker stop"));
}

const KEYCLOAK: Config.Accessory = .{
    .name = "keycloak",
    .image = "keycloak",
    .cmd = "start",
    .proxy = .{ .host = "auth.example", .app_port = 8080, .ssl = true, .health = .{ .path = "/realms/master" } },
    .boot_timeout_s = 10,
};
const PROXIED: Config = .{ .service = "app", .image = "app", .host = "h", .networks = &.{"own"}, .accessories = &.{KEYCLOAK} };
const TRAEFIK_INSPECT =
    \\null
    \\["--api.insecure=true","--entrypoints.web.address=:80","--entrypoints.websecure.address=:443","--providers.file.directory=/routes","--certificatesresolvers.le.acme.email=a@b"]
    \\public 
    \\
;

fn withTraefik(h: *Harness) !void {
    try h.on("docker ps --format", 0, "t1\ttraefik:3\ttraefik\n");
    try h.on("docker inspect --format {{json", 0, TRAEFIK_INSPECT);
    try h.on("{{.State.Running}} app-keycloak", 1, "");
    try h.on("mkdir -p \"$d/files\"", 0, "/home/u/.cowshed/accessories/app-keycloak");
    // No route yet.
    try h.on("cat \"$1/$2\"", 1, "");
    try h.on("wget -qO- http://127.0.0.1:8080", 0, "{\"url\":\"http://app-keycloak:8080\"}");
}

test "proxy: on Traefik's network first, healthy through Traefik, then its route" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try withTraefik(&h);
    // Running from the start once it exists.
    try h.fake.onAfter("docker run -d --name app-keycloak", "{{.State.Running}} app-keycloak", .{ .result = .{ .exit_code = 0, .stdout = "true\n" } });
    const a = h.arena.allocator();
    try testing.expect(try boot(a, h.fake.remote(), &h.output.writer, PROXIED, KEYCLOAK, .{ .who = "me" }));
    try testing.expect(std.mem.indexOf(u8, h.line("docker run -d --name app-keycloak"), "--network public --network own") != null);
    try testing.expect(h.fake.ran("wget -q -O /dev/null -T 5 http://app-keycloak:8080/realms/master"));
    try h.before("wget -q -O /dev/null", "cat > \"$1/.$2.tmp\"");
    const route_write = h.fake.calls.items[h.fake.position("cat > \"$1/.$2.tmp\"").?];
    try testing.expect(std.mem.endsWith(u8, route_write.line, "/routes cowshed-app-keycloak.yml"));
    try testing.expect(std.mem.indexOf(u8, route_write.stdin.?, "url: http://app-keycloak:8080") != null);
    try testing.expect(std.mem.indexOf(u8, route_write.stdin.?, "Host(`auth.example`)") != null);
    // No settle wait: health decides.
    try testing.expect(!h.fake.ran("sleep \"$1\""));
}

test "proxy: unhealthy is shown and removed, and no route is written" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try withTraefik(&h);
    try h.fake.onAfter("docker run -d --name app-keycloak", "{{.State.Running}} app-keycloak", .{ .result = .{ .exit_code = 0, .stdout = "true\n" } });
    try h.on("wget -q -O /dev/null", 1, "");
    try h.on("docker logs", 0, "still starting\n");
    const a = h.arena.allocator();
    try testing.expect(!try boot(a, h.fake.remote(), &h.output.writer, PROXIED, KEYCLOAK, .{ .who = "me" }));
    try h.says("did not pass its health check");
    try h.says("still starting");
    try testing.expect(h.fake.ran("docker rm -f app-keycloak"));
    try testing.expect(!h.fake.ran("cat > \"$1/.$2.tmp\""));
}

test "proxy: with no Traefik nothing starts; remove takes its route" {
    {
        var h = harness();
        defer h.arena.deinit();
        try h.begin();
        try h.on("docker ps --format", 0, "");
        try h.on("{{.State.Running}} app-keycloak", 1, "");
        try testing.expect(!try boot(h.arena.allocator(), h.fake.remote(), &h.output.writer, PROXIED, KEYCLOAK, .{ .who = "me" }));
        try h.says("needs Traefik, and none runs here");
        try testing.expect(!h.fake.ran("docker run"));
        try testing.expect(!h.fake.ran("locks"));
    }
    {
        var h = harness();
        defer h.arena.deinit();
        try h.begin();
        try withTraefik(&h);
        try h.on("{{.State.Running}} app-keycloak", 0, "true\n");
        try testing.expect(try remove(h.arena.allocator(), h.fake.remote(), &h.output.writer, PROXIED, KEYCLOAK, "me", true));
        try testing.expect(std.mem.endsWith(u8, h.line("rm -f \"$1/$2\""), "/routes cowshed-app-keycloak.yml"));
    }
}
