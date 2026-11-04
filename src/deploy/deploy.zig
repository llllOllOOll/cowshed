//! The deploy: the new version starts beside the old one and is proven before it
//! gets traffic. Until the switch, every failure leaves the old one untouched.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Remote = @import("../remote/Remote.zig");
const docker = @import("../docker/commands.zig");
const detect = @import("../proxy/detect.zig");
const route = @import("../proxy/route.zig");
const lock = @import("lock.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Stopped containers kept for a rollback.
const RETAIN_STOPPED = 3;
/// How long Traefik gets to show a route. A change took up to 2.3 s when tested.
const CONFIRM_LIMIT_S = 15;
const TRAEFIK_API = "http://127.0.0.1:8080/api/http/services";
const STATE_ESTABLISHED = "01";
/// How often a wait says it is still waiting.
const PROGRESS_EVERY_S = 5;

pub const Secret = struct { name: []const u8, value: []const u8 };

pub const ImageSender = struct {
    ptr: *anyopaque,
    /// Puts the image on the server. False when it could not; why is in `out`.
    sendFn: *const fn (ptr: *anyopaque, arena: Allocator, remote: Remote, out: *Writer) anyerror!bool,
};

pub const Input = struct {
    config: Config,
    version: []const u8,
    /// Who deploys, for the lock and the audit log.
    who: []const u8,
    /// What it was made from, on its container and in the audit log.
    sources: ?[]const u8 = null,
    /// Each by the name the container sees. Travels on stdin only.
    secrets: []const Secret = &.{},
    image: ImageSender,
    /// Asked for by name: runs the config's backup and migration before the new version.
    migrate: bool = false,
};

pub const Error = Remote.Error || Writer.Error || error{ImageFailed};

const Run = struct {
    arena: Allocator,
    remote: Remote,
    out: *Writer,
    input: Input,

    fn config(self: Run) Config {
        return self.input.config;
    }

    fn say(self: Run, comptime format: []const u8, args: anytype) Writer.Error!void {
        try self.out.print(format ++ "\n", args);
        try self.out.flush();
    }

    fn stop(self: Run, comptime format: []const u8, args: anytype) Writer.Error!bool {
        try self.say("stopped: " ++ format, args);
        return false;
    }

    fn ask(self: Run, argv: []const []const u8) Remote.Error!Remote.Result {
        return self.remote.run(self.arena, .{ .argv = argv });
    }

    fn wait(self: Run, seconds: u32) Remote.Error!void {
        _ = try self.ask(&.{ "sleep", try std.fmt.allocPrint(self.arena, "{d}", .{seconds}) });
    }

    fn inTraefik(self: Run, traefik: detect.Traefik, script: []const u8, args: []const []const u8, stdin: ?[]const u8) Remote.Error!Remote.Result {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.arena, &.{ "docker", "exec", "-i", traefik.id, "sh", "-c", script, "sh" });
        try argv.appendSlice(self.arena, args);
        return self.remote.run(self.arena, .{ .argv = argv.items, .stdin = stdin });
    }

    fn audit(self: Run, message: []const u8) Remote.Error!void {
        const line = try std.fmt.allocPrint(self.arena, "{s} {s} {s}: {s}", .{ self.input.who, self.config().service, self.input.version, message });
        _ = try self.ask(&.{ "sh", "-c", APPEND_AUDIT, "sh", self.config().service, line });
    }
};

const APPEND_AUDIT =
    \\mkdir -p "$HOME/.cowshed" && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$HOME/.cowshed/audit-$1.log"
;
const WRITE_ENV_FILE =
    \\umask 077 && mkdir -p "$HOME/.cowshed/env" && cat > "$HOME/.cowshed/env/$1" && printf %s "$HOME/.cowshed/env/$1"
;
const WRITE_ROUTE = "cat > \"$1/.$2.tmp\" && mv \"$1/.$2.tmp\" \"$1/$2\"";
const READ_ROUTE = "cat \"$1/$2\"";
const REMOVE_ROUTE = "rm -f \"$1/$2\"";
/// Files in the folder naming our router, ours aside: an earlier one would win.
const FIND_CLASH =
    \\cd "$1" && for f in *; do [ "$f" = "$2" ] || ! grep -q "$3:" "$f" 2>/dev/null || echo "$f"; done
;
const READ_CONNECTIONS = "cat \"/proc/$1/net/tcp\" \"/proc/$1/net/tcp6\" 2>/dev/null";
const DELETE_ENV_FILE = "rm -f \"$HOME/.cowshed/env/$1\"";
/// The versions to keep on stdin; any other's list of blobs goes.
const DROP_BLOB_LISTS =
    \\keep=$(cat)
    \\cd "$HOME/.cowshed/images/$1" 2>/dev/null || exit 0
    \\for f in *.blobs; do
    \\  [ -e "$f" ] || continue
    \\  printf '%s\n' "$keep" | grep -qx -- "${f%.blobs}" || rm -f "$f"
    \\done
;
/// Removes blobs that no kept version lists.
const COLLECT_BLOBS =
    \\cd "$HOME/.cowshed" || exit 0
    \\keep=$(cat images/*/*.blobs 2>/dev/null | sort -u)
    \\for f in blobs/sha256/*; do
    \\  [ -e "$f" ] || continue
    \\  printf '%s\n' "$keep" | grep -qx "${f##*/}" || rm -f "$f"
    \\done
;

/// `$1` the limit, `$2` how many stay, `$3` the service, `$4` the version, `$5` the image,
/// `$6` the command. What it prints is dropped, as a dump there would flood the log;
/// the end of what it says on failing is kept. A failed or empty folder goes, and only
/// after a good one do old ones go.
const RUN_BACKUP =
    \\limit=$1; keep=$2; root="$HOME/.cowshed/backups/$3"
    \\umask 077
    \\dir="$root/$(date -u +%Y%m%dT%H%M%SZ)-$4"
    \\mkdir -p "$dir" || exit 1
    \\err=$(mktemp) || exit 1
    \\COWSHED_BACKUP_DIR=$dir COWSHED_VERSION=$4 COWSHED_IMAGE=$5 timeout "$limit" sh -c "$6" >/dev/null 2>"$err" </dev/null
    \\code=$?
    \\if [ "$code" -ne 0 ]; then
    \\  tail -n 5 "$err" >&2; rm -f "$err"; rm -rf "$dir"
    \\  case "$code" in 124|143) exit 124;; esac
    \\  exit "$code"
    \\fi
    \\rm -f "$err"
    \\if [ -z "$(ls -A "$dir")" ]; then rmdir "$dir"; exit 125; fi
    \\printf '%s, %s\n' "$dir" "$(du -sh "$dir" | cut -f1)"
    \\ls -1 "$root" | sort -r | tail -n +"$((keep + 1))" | while read -r old; do rm -rf "${root:?}/$old"; done
;
const BACKUP_TIMED_OUT = 124;
const BACKUP_EMPTY = 125;

/// Whether what runs now was made from exactly these sources. If the server cannot
/// say, no: the deploy goes on and meets the trouble itself.
pub fn liveFrom(arena: Allocator, remote: Remote, service: []const u8, sources: []const u8) Remote.Error!bool {
    const listing = try remote.run(arena, .{ .argv = try docker.listAll(arena, service) });
    if (!listing.ok()) return false;
    var lines = std.mem.splitScalar(u8, listing.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const made_from = fields.next() orelse continue;
        if (std.mem.eql(u8, state, "running") and std.mem.eql(u8, made_from, sources)) return true;
    }
    return false;
}

/// False when it stopped; why has been written to `out`.
pub fn run(arena: Allocator, remote: Remote, out: *Writer, input: Input) Error!bool {
    const self: Run = .{ .arena = arena, .remote = remote, .out = out, .input = input };
    const service = input.config.service;

    try self.say("deploy: {s} {s} to {s}", .{ service, input.version, input.config.host });
    var traefik: ?detect.Traefik = null;
    if (input.config.proxy) |proxy| {
        try self.say("proxy: reading the server's Traefik", .{});
        switch (try detect.detect(arena, remote, proxy)) {
            .stopped => |message| return self.stop("{s}", .{message}),
            .none => return self.stop("no Traefik runs on this server: run `cowshed setup`", .{}),
            .traefik => |found| {
                traefik = found;
                try self.say("proxy: using `{s}`, network {s}", .{ found.name, found.network });
            },
        }
    }

    try self.say("lock: taking it", .{});
    const details = try std.fmt.allocPrint(arena, "{s}, version {s}", .{ input.who, input.version });
    switch (try lock.acquire(arena, remote, service, details)) {
        .acquired => {},
        .held => |who| return self.stop("another deploy holds the lock: {s}. If it died, `cowshed lock release`", .{who}),
    }
    defer releaseLock(self);

    try self.audit(if (input.sources) |sources| try std.fmt.allocPrint(arena, "deploy started, from {s}", .{sources}) else "deploy started");
    const done = try deployLocked(self, traefik);
    try self.audit(if (done) "deployed" else "deploy failed");
    return done;
}

/// Traefik's network first, then the project's own, each once.
pub fn networksOf(arena: Allocator, config: Config, traefik: ?detect.Traefik) Allocator.Error![]const []const u8 {
    var networks: std.ArrayList([]const u8) = .empty;
    if (traefik) |found| try networks.append(arena, found.network);
    for (config.networks) |network| {
        for (networks.items) |already| {
            if (std.mem.eql(u8, already, network)) break;
        } else try networks.append(arena, network);
    }
    return networks.items;
}

/// The project's networks are its own: made here if missing, used as they are
/// if not, and never removed.
fn ensureNetworks(self: Run) Error!bool {
    for (self.config().networks) |network| {
        if ((try self.ask(try docker.networkExists(self.arena, network))).ok()) continue;
        try self.say("network: making {s}", .{network});
        const made = try self.ask(try docker.networkCreate(self.arena, network));
        if (!made.ok()) return self.stop("could not make the network `{s}`: {s}", .{ network, std.mem.trimEnd(u8, made.stderr, "\r\n") });
    }
    return true;
}

fn releaseLock(self: Run) void {
    lock.release(self.arena, self.remote, self.config().service) catch {
        self.say("notice: could not release the lock: `cowshed lock release`", .{}) catch {};
        return;
    };
    self.say("lock: released", .{}) catch {};
}

fn deployLocked(self: Run, traefik: ?detect.Traefik) Error!bool {
    const config = self.config();
    const version = self.input.version;

    try self.say("image: sending {s}", .{version});
    const sent = self.input.image.sendFn(self.input.image.ptr, self.arena, self.remote, self.out) catch |err| switch (err) {
        error.ConnectionFailed => return error.ConnectionFailed,
        error.TransportFailed => return error.TransportFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return self.stop("sending the image: {t}", .{err}),
    };
    if (!sent) return false;
    if (!try ensureNetworks(self)) return false;

    const containers = try self.ask(try docker.listAll(self.arena, config.service));
    if (!containers.ok()) return self.stop("could not list containers: {s}", .{containers.stderr});
    const name = try freeName(self, containers.stdout);

    var env_file: ?[]const u8 = null;
    if (self.input.secrets.len > 0) {
        try self.say("secrets: writing {d} to the server's env file", .{self.input.secrets.len});
        env_file = try writeEnvFile(self, name) orelse return false;
    }

    if (self.input.migrate) {
        if (config.backup) |backup| {
            if (!try runBackup(self, backup)) {
                _ = try self.ask(&.{ "sh", "-c", DELETE_ENV_FILE, "sh", name });
                return false;
            }
        }
        if (config.migrate) |migrate| {
            if (!try runMigration(self, migrate, name, env_file, traefik)) {
                _ = try self.ask(&.{ "sh", "-c", DELETE_ENV_FILE, "sh", name });
                return false;
            }
        }
    }

    try self.say("container: starting {s}", .{name});
    const started = try self.ask(try docker.runApp(self.arena, .{
        .name = name,
        .image = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ config.image, version }),
        .service = config.service,
        .role = config.role,
        .version = version,
        .sources = self.input.sources,
        .networks = try networksOf(self.arena, config, traefik),
        .cpus = config.cpus,
        .memory = config.memory,
        .env_file = env_file,
        .clear_env = config.env.clear,
        .labels = config.labels,
        .volumes = config.volumes,
        .cmd = config.cmd,
    }));
    if (!started.ok()) {
        try discard(self, name);
        return self.stop("could not start the container: {s}", .{std.mem.trimEnd(u8, started.stderr, "\r\n")});
    }

    if (!try isHealthy(self, name, traefik)) {
        try showLogs(self, name);
        try discard(self, name);
        return self.stop("the new version did not pass its health check: the old one keeps serving", .{});
    }
    try self.say("health: {s} is healthy", .{name});

    if (traefik) |found| {
        if (!try switchRoute(self, found, name)) {
            try discard(self, name);
            return false;
        }
    }

    try retireOld(self, name);
    try self.say("prune: cleaning old versions", .{});
    try prune(self);
    try self.say("deployed {s}", .{version});
    return true;
}

/// Last before anything writes to the data. Nothing has changed if it fails.
fn runBackup(self: Run, backup: Config.Backup) Error!bool {
    const config = self.config();
    try self.say("backup: running, up to {d} s", .{backup.timeout_s});
    const result = try self.ask(&.{
        "sh",                                                                                 "-c",
        RUN_BACKUP,                                                                           "sh",
        try std.fmt.allocPrint(self.arena, "{d}", .{backup.timeout_s}),                       try std.fmt.allocPrint(self.arena, "{d}", .{backup.keep}),
        config.service,                                                                       self.input.version,
        try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ config.image, self.input.version }), backup.command,
    });
    if (!result.ok()) {
        try self.out.writeAll(result.stderr);
        try self.audit("backup failed");
        return switch (result.exit_code) {
            BACKUP_TIMED_OUT => self.stop("the backup passed its {d} s: nothing changed, the old version keeps serving", .{backup.timeout_s}),
            BACKUP_EMPTY => self.stop("the backup wrote nothing into `$COWSHED_BACKUP_DIR`: nothing changed, the old version keeps serving", .{}),
            else => self.stop("the backup failed with exit code {d}: nothing changed, the old version keeps serving", .{result.exit_code}),
        };
    }
    try self.say("backup: {s}", .{std.mem.trimEnd(u8, result.stdout, "\r\n")});
    try self.audit("backed up");
    return true;
}

/// Before the new version exists: if it fails, nothing has changed but what the
/// migration itself did.
fn runMigration(self: Run, migrate: Config.Migrate, name: []const u8, env_file: ?[]const u8, traefik: ?detect.Traefik) Error!bool {
    const config = self.config();
    const container = try std.fmt.allocPrint(self.arena, "{s}-migrate", .{name});
    try self.say("migrate: running `{s}` from {s}, up to {d} s; its output comes at the end", .{ migrate.command, self.input.version, migrate.timeout_s });
    const result = try self.ask(try docker.runMigration(self.arena, .{
        .name = container,
        .image = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ config.image, self.input.version }),
        .service = config.service,
        .command = migrate.command,
        .timeout_s = migrate.timeout_s,
        .networks = try networksOf(self.arena, config, traefik),
        .cpus = config.cpus,
        .memory = config.memory,
        .env_file = env_file,
        .clear_env = config.env.clear,
        .env = migrate.env,
        .volumes = config.volumes,
    }));
    try self.out.writeAll(result.stdout);
    try self.out.writeAll(result.stderr);
    if (result.exit_code == docker.MIGRATION_TIMED_OUT) {
        try self.audit("migration stopped: time is up");
        return self.stop("the migration passed its {d} s and was stopped, perhaps half done: the old version keeps serving. Look at the data before trying again", .{migrate.timeout_s});
    }
    if (!result.ok()) {
        try self.audit("migration failed");
        return self.stop("the migration failed with exit code {d}: the old version keeps serving. What it did before failing stays", .{result.exit_code});
    }
    try self.audit("migrated");
    try self.say("migrate: done", .{});
    return true;
}

/// `service-role-version`; deployed again, with `-2`, `-3`...: the running one
/// keeps its name, which the live route points at.
fn freeName(self: Run, listing: []const u8) Allocator.Error![]const u8 {
    const config = self.config();
    const base = try std.fmt.allocPrint(self.arena, "{s}-{s}-{s}", .{ config.service, config.role, self.input.version });
    var name = base;
    var attempt: u32 = 2;
    while (hasContainer(listing, name)) : (attempt += 1) {
        name = try std.fmt.allocPrint(self.arena, "{s}-{d}", .{ base, attempt });
    }
    return name;
}

fn hasContainer(listing: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        if (std.mem.eql(u8, fields.first(), name)) return true;
    }
    return false;
}

fn writeEnvFile(self: Run, name: []const u8) Error!?[]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (self.input.secrets) |secret| {
        // Docker's env files have one variable a line.
        if (std.mem.indexOfScalar(u8, secret.value, '\n') != null) {
            _ = try self.stop("the secret `{s}` has a line break, which an env file cannot hold", .{secret.name});
            return null;
        }
        try text.appendSlice(self.arena, secret.name);
        try text.append(self.arena, '=');
        try text.appendSlice(self.arena, secret.value);
        try text.append(self.arena, '\n');
    }
    const written = try self.remote.run(self.arena, .{ .argv = &.{ "sh", "-c", WRITE_ENV_FILE, "sh", name }, .stdin = text.items });
    if (!written.ok()) {
        _ = try self.stop("could not write the env file: {s}", .{std.mem.trimEnd(u8, written.stderr, "\r\n")});
        return null;
    }
    return written.stdout;
}

/// Stops and removes what this deploy started; nothing else.
fn discard(self: Run, name: []const u8) Remote.Error!void {
    _ = try self.ask(try docker.remove(self.arena, name));
    _ = try self.ask(&.{ "sh", "-c", DELETE_ENV_FILE, "sh", name });
}

fn showLogs(self: Run, name: []const u8) Error!void {
    const logs = try self.ask(try docker.logs(self.arena, name));
    try self.say("--- its logs\n{s}{s}---", .{ logs.stdout, logs.stderr });
}

fn isRunning(self: Run, name: []const u8) Remote.Error!bool {
    const state = try self.ask(try docker.containerState(self.arena, name));
    return state.ok() and std.mem.startsWith(u8, state.stdout, "true");
}

fn isHealthy(self: Run, name: []const u8, traefik: ?detect.Traefik) Error!bool {
    const config = self.config();
    const proxy = config.proxy orelse {
        // With no route there is no path to ask: it must stay up for a while.
        const settle = @min(config.deploy_timeout_s, 5);
        try self.say("health: no route to ask; watching it stay up for {d} s", .{settle});
        try self.wait(settle);
        return isRunning(self, name);
    };
    const health = proxy.health;
    const url = try std.fmt.allocPrint(self.arena, "http://{s}:{d}{s}", .{ name, proxy.app_port, health.path });
    try self.say("health: asking {s}, up to {d} s", .{ url, config.deploy_timeout_s });
    const timeout = try std.fmt.allocPrint(self.arena, "{d}", .{health.timeout_s});
    var waited: u32 = 0;
    while (waited < config.deploy_timeout_s) : (waited += health.interval_s) {
        if (!try isRunning(self, name)) {
            try self.say("health: {s} exited", .{name});
            return false;
        }
        const probe = try self.ask(&.{ "docker", "exec", traefik.?.id, "wget", "-q", "-O", "/dev/null", "-T", timeout, url });
        if (probe.ok()) return true;
        try self.wait(health.interval_s);
        const passed = waited + health.interval_s;
        if (passed % PROGRESS_EVERY_S < health.interval_s) {
            try self.say("health: not yet, {d} of {d} s", .{ passed, config.deploy_timeout_s });
        }
    }
    return false;
}

fn switchRoute(self: Run, traefik: detect.Traefik, name: []const u8) Error!bool {
    const config = self.config();
    const proxy = config.proxy.?;
    const file = try route.fileName(self.arena, config.service);
    const router = try route.routerName(self.arena, config.service);

    const clash = try self.inTraefik(traefik, FIND_CLASH, &.{ traefik.routes_dir, file, router }, null);
    const clashing = std.mem.trim(u8, clash.stdout, "\r\n ");
    if (clashing.len > 0) {
        return self.stop("`{s}` in Traefik's folder also names the router `{s}`: an earlier file would win", .{ clashing, router });
    }

    const previous = try self.inTraefik(traefik, READ_ROUTE, &.{ traefik.routes_dir, file }, null);
    const text = try route.render(self.arena, .{
        .service = config.service,
        .host = proxy.host,
        .container = name,
        .port = proxy.app_port,
        .entrypoint = if (proxy.ssl) traefik.https_entrypoint.? else traefik.http_entrypoint.?,
        .resolver = if (proxy.ssl) traefik.resolver else null,
        // Detection has already refused `ssl_redirect: false` with no HTTP entrypoint.
        .http_from = if (proxy.ssl) traefik.http_entrypoint else null,
        .redirect = proxy.ssl_redirect,
    });
    try self.say("switch: writing the route {s}", .{file});
    const written = try self.inTraefik(traefik, WRITE_ROUTE, &.{ traefik.routes_dir, file }, text);
    if (!written.ok()) {
        return self.stop("could not write the route: {s}", .{std.mem.trimEnd(u8, written.stderr, "\r\n")});
    }

    if (!traefik.api) {
        // Nothing to ask. The longest change seen when tested took 2.3 s.
        try self.say("notice: Traefik's API is off: the switch is not confirmed", .{});
        try self.wait(3);
        return true;
    }
    try self.say("switch: waiting for Traefik to take it, up to {d} s", .{CONFIRM_LIMIT_S});
    if (try showsRoute(self, traefik, router, name)) {
        try self.say("switch: traffic goes to {s}", .{name});
        return true;
    }

    // The new one is thrown away next, so the route must not point at it.
    try self.say("switch: not taken, putting the route back", .{});
    if (previous.ok()) {
        _ = try self.inTraefik(traefik, WRITE_ROUTE, &.{ traefik.routes_dir, file }, previous.stdout);
    } else {
        _ = try self.inTraefik(traefik, REMOVE_ROUTE, &.{ traefik.routes_dir, file }, null);
    }
    return self.stop("Traefik did not take the new route within {d} s. A broken file in `{s}` blocks every change there, and only Traefik's log says which: the route was put back", .{ CONFIRM_LIMIT_S, traefik.routes_dir });
}

fn showsRoute(self: Run, traefik: detect.Traefik, router: []const u8, name: []const u8) Error!bool {
    const url = try std.fmt.allocPrint(self.arena, TRAEFIK_API ++ "/{s}@file", .{router});
    var waited: u32 = 0;
    while (waited < CONFIRM_LIMIT_S) : (waited += 1) {
        const shown = try self.ask(&.{ "docker", "exec", traefik.id, "wget", "-qO-", url });
        if (shown.ok() and std.mem.indexOf(u8, shown.stdout, name) != null) return true;
        try self.wait(1);
        if (waited > 0 and waited % PROGRESS_EVERY_S == 0) {
            try self.say("switch: not yet, {d} of {d} s", .{ waited, CONFIRM_LIMIT_S });
        }
    }
    return false;
}

fn retireOld(self: Run, new_name: []const u8) Error!void {
    const config = self.config();
    const listing = try self.ask(try docker.listAll(self.arena, config.service));
    var old: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        if (std.mem.eql(u8, state, "running") and !std.mem.eql(u8, name, new_name)) try old.append(self.arena, name);
    }
    if (config.replaces) |name| {
        if (try isRunning(self, name)) try old.append(self.arena, name);
    }
    if (old.items.len == 0) {
        try self.say("old: nothing else was running", .{});
        return;
    }

    if (config.proxy) |proxy| try drain(self, old.items, proxy.app_port);
    for (old.items) |name| {
        try self.say("old: stopping {s}", .{name});
        const stopped = try self.ask(try docker.stop(self.arena, name));
        if (stopped.ok()) {
            try self.say("old: stopped {s}", .{name});
        } else {
            try self.say("notice: could not stop {s}: {s}", .{ name, std.mem.trimEnd(u8, stopped.stderr, "\r\n") });
        }
    }
}

/// Until no connection is left or `drain_timeout` passes. A WebSocket stays open
/// until then, and the stop cuts it.
fn drain(self: Run, names: []const []const u8, port: u16) Error!void {
    var waited: u32 = 0;
    const limit = self.config().drain_timeout_s;
    while (waited < limit) : (waited += 1) {
        var open: usize = 0;
        for (names) |name| open += try connectionsOf(self, name, port);
        if (open == 0) {
            try self.say("drain: no connections left", .{});
            return;
        }
        if (waited == 0) {
            try self.say("drain: {d} open, waiting up to {d} s", .{ open, limit });
        } else if (waited % PROGRESS_EVERY_S == 0) {
            try self.say("drain: {d} open, {d} of {d} s", .{ open, waited, limit });
        }
        try self.wait(1);
    }
    try self.say("drain: time is up, stopping what remains", .{});
}

fn connectionsOf(self: Run, name: []const u8, port: u16) Error!usize {
    const pid = try self.ask(try docker.pid(self.arena, name));
    if (!pid.ok()) return 0;
    const text = std.mem.trimEnd(u8, pid.stdout, "\r\n");
    const table = try self.ask(&.{ "sh", "-c", READ_CONNECTIONS, "sh", text });
    return countEstablished(table.stdout, port);
}

fn countEstablished(table: []const u8, port: u16) usize {
    var suffix: [5]u8 = undefined;
    const wanted = std.fmt.bufPrint(&suffix, ":{X:0>4}", .{port}) catch unreachable;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next() orelse continue;
        const local = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        if (std.mem.eql(u8, state, STATE_ESTABLISHED) and std.mem.endsWith(u8, local, wanted)) count += 1;
    }
    return count;
}

/// Keeps the newest stopped containers, and removes the images and blobs of every
/// other version, those of failed deploys too. A failure here costs only disk.
fn prune(self: Run) Error!void {
    const config = self.config();
    const listing = try self.ask(try docker.listAll(self.arena, config.service));
    if (!listing.ok()) return;
    var kept_stopped: u32 = 0;
    var removed: u32 = 0;
    var kept_versions: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        const version = fields.next() orelse continue;
        const stopped = std.mem.eql(u8, state, "exited") or std.mem.eql(u8, state, "dead") or std.mem.eql(u8, state, "created");
        if (stopped and kept_stopped >= RETAIN_STOPPED) {
            _ = try self.ask(try docker.remove(self.arena, name));
            _ = try self.ask(&.{ "sh", "-c", DELETE_ENV_FILE, "sh", name });
            removed += 1;
            continue;
        }
        if (stopped) kept_stopped += 1;
        try kept_versions.appendSlice(self.arena, version);
        try kept_versions.append(self.arena, '\n');
    }

    const images = try self.ask(try docker.imageTags(self.arena, config.image, config.service));
    if (images.ok()) {
        var tags = std.mem.tokenizeAny(u8, images.stdout, "\r\n");
        while (tags.next()) |tag| {
            if (std.mem.eql(u8, tag, "<none>") or hasLine(kept_versions.items, tag)) continue;
            _ = try self.ask(&.{ "docker", "rmi", try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ config.image, tag }) });
        }
    }
    _ = try self.remote.run(self.arena, .{ .argv = &.{ "sh", "-c", DROP_BLOB_LISTS, "sh", config.service }, .stdin = kept_versions.items });
    _ = try self.ask(&.{ "sh", "-c", COLLECT_BLOBS });
    if (removed > 0) try self.say("prune: removed {d}, kept the last {d} stopped", .{ removed, RETAIN_STOPPED });
}

fn hasLine(text: []const u8, wanted: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, wanted)) return true;
    }
    return false;
}

/// `cowshed prune`, under the lock.
pub fn pruneNow(arena: Allocator, remote: Remote, out: *Writer, config: Config, who: []const u8) Error!bool {
    const self: Run = .{ .arena = arena, .remote = remote, .out = out, .input = .{ .config = config, .version = "-", .who = who, .image = undefined } };
    switch (try lock.acquire(arena, remote, config.service, try std.fmt.allocPrint(arena, "{s}, pruning", .{who}))) {
        .acquired => {},
        .held => |holder| return self.stop("another deploy holds the lock: {s}", .{holder}),
    }
    defer lock.release(arena, remote, config.service) catch {};
    try prune(self);
    try self.say("prune done", .{});
    return true;
}

/// The same switch, on a container still on the server: no build. If the version
/// fails its health it is stopped again, and what is live stays live.
pub fn rollback(arena: Allocator, remote: Remote, out: *Writer, config: Config, version: []const u8, who: []const u8) Error!bool {
    const self: Run = .{ .arena = arena, .remote = remote, .out = out, .input = .{ .config = config, .version = version, .who = who, .image = undefined } };

    var traefik: ?detect.Traefik = null;
    if (config.proxy) |proxy| {
        switch (try detect.detect(arena, remote, proxy)) {
            .stopped => |message| return self.stop("{s}", .{message}),
            .none => return self.stop("no Traefik runs on this server: run `cowshed setup`", .{}),
            .traefik => |found| traefik = found,
        }
    }
    try self.say("lock: taking it", .{});
    const details = try std.fmt.allocPrint(arena, "{s}, rollback to {s}", .{ who, version });
    switch (try lock.acquire(arena, remote, config.service, details)) {
        .acquired => {},
        .held => |holder| return self.stop("another deploy holds the lock: {s}", .{holder}),
    }
    defer releaseLock(self);

    const listing = try self.ask(try docker.listAll(arena, config.service));
    if (!listing.ok()) return self.stop("could not list containers: {s}", .{listing.stderr});
    const name = findStopped(listing.stdout, version) orelse {
        if (isVersionRunning(listing.stdout, version)) return self.stop("version {s} is already live", .{version});
        return self.stop("no stopped container of version {s}: see `cowshed versions`", .{version});
    };

    try self.audit("rollback started");
    try self.say("container: starting {s}", .{name});
    const started = try self.ask(try docker.start(arena, name));
    if (!started.ok()) {
        try self.audit("rollback failed");
        return self.stop("could not start {s}: {s}", .{ name, std.mem.trimEnd(u8, started.stderr, "\r\n") });
    }
    var done = try isHealthy(self, name, traefik);
    if (done) {
        try self.say("health: {s} is healthy", .{name});
        if (traefik) |found| done = try switchRoute(self, found, name);
    } else {
        try showLogs(self, name);
        _ = try self.stop("version {s} did not pass its health check: what is live stays live", .{version});
    }
    if (!done) {
        _ = try self.ask(try docker.stop(arena, name));
        try self.audit("rollback failed");
        return false;
    }
    try retireOld(self, name);
    try self.audit("rolled back");
    try self.say("rolled back to {s}", .{version});
    return true;
}

/// The newest: `docker ps` lists newest first.
fn findStopped(listing: []const u8, version: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        const candidate = fields.next() orelse continue;
        if (std.mem.eql(u8, candidate, version) and !std.mem.eql(u8, state, "running")) return name;
    }
    return null;
}

fn isVersionRunning(listing: []const u8, version: []const u8) bool {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        const candidate = fields.next() orelse continue;
        if (std.mem.eql(u8, candidate, version) and std.mem.eql(u8, state, "running")) return true;
    }
    return false;
}

const testing = std.testing;
const Fake = @import("../remote/Fake.zig");

const INSPECT =
    \\null
    \\["--api.insecure=true","--entrypoints.web.address=:80","--entrypoints.websecure.address=:443","--providers.file.directory=/routes","--certificatesresolvers.le.acme.email=a@b"]
    \\public 
    \\
;
const NEW = "app-web-v2";
const NEW_ROUTE_SHOWN = "{\"url\":\"http://app-web-v2:80\"}";

const Sender = struct {
    fail: bool = false,
    sent: bool = false,

    fn send(ptr: *anyopaque, _: Allocator, _: Remote, out: *Writer) anyerror!bool {
        const self: *Sender = @ptrCast(@alignCast(ptr));
        self.sent = true;
        if (self.fail) try out.writeAll("sending failed\n");
        return !self.fail;
    }
};

const Harness = struct {
    migrating: bool = false,
    arena: std.heap.ArenaAllocator,
    fake: Fake = undefined,
    output: Writer.Allocating = undefined,
    sender: Sender = .{},

    fn begin(self: *Harness) !void {
        const a = self.arena.allocator();
        self.fake = Fake.init(a);
        self.output = .init(a);
        try self.on("docker ps --format", 0, "t1\ttraefik:3\ttraefik\n");
        try self.on("docker inspect --format {{json", 0, INSPECT);
        try self.on("docker ps -a", 0, "app-web-v1\trunning\tv1\n");
        try self.on("docker inspect --format {{.State.Running}}", 0, "true\n");
        try self.on("docker inspect --format {{.State.Pid}}", 0, "42\n");
        try self.on("wget -qO- http://127.0.0.1:8080", 0, NEW_ROUTE_SHOWN);
        // No route yet, unless a test says so.
        try self.on("cat \"$1/$2\"", 1, "");
    }

    fn on(self: *Harness, contains: []const u8, exit_code: u8, stdout: []const u8) !void {
        try self.fake.on(contains, .{ .result = .{ .exit_code = exit_code, .stdout = stdout, .stderr = "the error" } });
    }

    fn deploy(self: *Harness, change: Config) !bool {
        var config = change;
        config.service = "app";
        config.image = "app";
        config.host = "h";
        return run(self.arena.allocator(), self.fake.remote(), &self.output.writer, .{
            .config = config,
            .version = "v2",
            .who = "seven",
            .secrets = &.{.{ .name = "TOKEN", .value = "hidden-value" }},
            .image = .{ .ptr = &self.sender, .sendFn = Sender.send },
            .migrate = self.migrating,
        });
    }

    fn says(self: *Harness, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.output.written(), text) == null) {
            std.debug.print("output:\n{s}\n", .{self.output.written()});
            return error.TestExpectedOutput;
        }
    }

    fn before(self: *Harness, first: []const u8, second: []const u8) !void {
        try testing.expect(self.fake.position(first).? < self.fake.position(second).?);
    }

    /// Whatever failed: the old one was not stopped, the lock is free.
    fn oldUntouched(self: *Harness) !void {
        try testing.expect(!self.fake.ran("docker stop app-web-v1"));
        try testing.expect(!self.fake.ran("docker rm -f app-web-v1"));
        try testing.expect(self.fake.ran("rm -rf \"$HOME/.cowshed/locks/$1\""));
    }
};

fn harness() Harness {
    return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
}

const PROXIED: Config = .{ .service = "", .image = "", .host = "", .proxy = .{ .host = "a.example" }, .drain_timeout_s = 3 };

test "the order: lock, image, container, health, route, confirm, stop the old, unlock" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(try h.deploy(PROXIED));
    try testing.expect(h.sender.sent);
    try h.before("mkdir \"$d\"", "docker run");
    try h.before("docker run", "wget -q -O /dev/null");
    try h.before("wget -q -O /dev/null", "mv \"$1/.$2.tmp\"");
    try h.before("mv \"$1/.$2.tmp\"", "wget -qO- http://127.0.0.1:8080");
    try h.before("wget -qO- http://127.0.0.1:8080", "docker stop app-web-v1");
    try h.before("docker stop app-web-v1", "rm -rf \"$HOME/.cowshed/locks/$1\"");
    try testing.expect(h.fake.ran("http://app-web-v2:80/up"));
    try testing.expect(!h.fake.ran("docker stop app-web-v2"));
    try h.says("deployed v2");
}

test "a backup: after sending, before the migration, and it names what it made" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("COWSHED_BACKUP_DIR=", 0, "/root/.cowshed/backups/s/x, 40M\n");
    try h.on("docker run --rm", 0, "");
    var config = PROXIED;
    config.backup = .{ .command = "dump-it", .keep = 2, .timeout_s = 60 };
    config.migrate = .{ .command = "./app" };
    h.migrating = true;
    try testing.expect(try h.deploy(config));
    try h.before("COWSHED_BACKUP_DIR=", "docker run --rm");
    try h.before("docker run --rm", "docker run -d");
    try testing.expect(h.fake.ran("dump-it"));
    try h.says("backup: /root/.cowshed/backups/s/x, 40M");
}

test "a backup that fails, is empty or runs out of time: nothing else happens" {
    const cases = [_]struct { code: u8, says: []const u8 }{
        .{ .code = 7, .says = "exit code 7" },
        .{ .code = 124, .says = "passed its" },
        .{ .code = 125, .says = "wrote nothing" },
    };
    for (cases) |case| {
        var h = harness();
        defer h.arena.deinit();
        try h.begin();
        try h.on("umask 077", 0, "/home/u/.cowshed/env/app-web-v2");
        try h.on("COWSHED_BACKUP_DIR=", case.code, "");
        var config = PROXIED;
        config.backup = .{ .command = "dump-it" };
        config.migrate = .{ .command = "./app" };
        h.migrating = true;
        try testing.expect(!try h.deploy(config));
        try testing.expect(!h.fake.ran("docker run --rm"));
        try testing.expect(!h.fake.ran("docker run -d"));
        try testing.expect(!h.fake.ran("docker stop app-web-v1"));
        try testing.expect(h.fake.ran("rm -rf \"$HOME/.cowshed/locks/$1\""));
        try h.says(case.says);
    }
}

test "without --migrate: no backup and no migration, whatever the config says" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    var config = PROXIED;
    config.backup = .{ .command = "dump-it" };
    config.migrate = .{ .command = "./app" };
    try testing.expect(try h.deploy(config));
    try testing.expect(!h.fake.ran("dump-it"));
    try testing.expect(!h.fake.ran("docker run --rm"));
    try testing.expect(h.fake.ran("docker run -d"));
}

test "a migration: new image, after sending, before the new version, with the app's settings" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("umask 077", 0, "/home/u/.cowshed/env/app-web-v2");
    try h.on("sh 60 app-web-v2-migrate docker run", 0, "2 applied\n");
    var config = PROXIED;
    config.migrate = .{ .command = "./app \"two words\"", .env = &.{.{ .name = "MIGRATE", .value = "1" }}, .timeout_s = 60 };
    config.volumes = &.{"/srv:/data"};
    h.migrating = true;
    try testing.expect(try h.deploy(config));
    try h.before("umask 077", "sh 60 app-web-v2-migrate docker run");
    try h.before("sh 60 app-web-v2-migrate docker run", "docker run -d");
    const line = h.fake.calls.items[h.fake.position("sh 60 app-web-v2-migrate docker run").?].line;
    for ([_][]const u8{ "--rm", "--env MIGRATE=1", "--env-file /home/u/.cowshed/env/app-web-v2", "--volume /srv:/data", "--network" }) |part| {
        try testing.expect(std.mem.indexOf(u8, line, part) != null);
    }
    // No version to be listed, pruned or taken for the live one.
    try testing.expect(std.mem.indexOf(u8, line, "service=") == null);
    try h.says("2 applied");
    try h.says("migrate: done");
    try testing.expect(h.fake.ran("migrated"));
}

test "the project's networks: made if missing, used if there, the new version and its migration born on all" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("network inspect --format {{.Name}} own", 1, "");
    try h.on("umask 077", 0, "/home/u/.cowshed/env/app-web-v2");
    try h.on("sh 60 app-web-v2-migrate docker run", 0, "");
    var config = PROXIED;
    // Traefik's own, named again, is not joined twice.
    config.networks = &.{ "own", "public", "theirs" };
    config.migrate = .{ .command = "./app", .timeout_s = 60 };
    h.migrating = true;
    try testing.expect(try h.deploy(config));
    try testing.expect(h.fake.ran("docker network create own"));
    try testing.expect(!h.fake.ran("docker network create theirs"));
    try testing.expect(!h.fake.ran("docker network create public"));
    try h.before("docker network create own", "sh 60 app-web-v2-migrate docker run");
    for ([_][]const u8{ "sh 60 app-web-v2-migrate docker run", "docker run -d" }) |container| {
        const line = h.fake.calls.items[h.fake.position(container).?].line;
        try testing.expect(std.mem.indexOf(u8, line, "--network public --network own --network theirs") != null);
        try testing.expectEqual(1, std.mem.count(u8, line, "--network public"));
    }
}

test "a network that cannot be made stops it before any container, the old one untouched" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("network inspect --format {{.Name}} own", 1, "");
    try h.on("docker network create own", 1, "");
    var config = PROXIED;
    config.networks = &.{"own"};
    try testing.expect(!try h.deploy(config));
    try h.says("could not make the network `own`");
    try testing.expect(!h.fake.ran("docker run -d"));
    try testing.expect(!h.fake.ran("docker stop"));
    try testing.expect(h.fake.ran("rm -rf"));
}

test "a migration that fails: no new version, and the old one untouched" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("umask 077", 0, "/home/u/.cowshed/env/app-web-v2");
    try h.on("sh 300 app-web-v2-migrate docker run", 3, "bad column\n");
    var config = PROXIED;
    config.migrate = .{ .command = "./app" };
    h.migrating = true;
    try testing.expect(!try h.deploy(config));
    try testing.expect(!h.fake.ran("docker run -d"));
    try testing.expect(!h.fake.ran("mv \"$1/.$2.tmp\""));
    try testing.expect(!h.fake.ran("docker stop app-web-v1"));
    try testing.expect(h.fake.ran("rm -f \"$HOME/.cowshed/env/$1\""));
    try testing.expect(h.fake.ran("rm -rf \"$HOME/.cowshed/locks/$1\""));
    try h.says("bad column");
    try h.says("exit code 3: the old version keeps serving");
    try testing.expect(h.fake.ran("migration failed"));
}

test "a migration past its time: stopped and removed, the old one untouched" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("sh 300 app-web-v2-migrate docker run", 124, "");
    var config = PROXIED;
    config.migrate = .{ .command = "./app" };
    h.migrating = true;
    try testing.expect(!try h.deploy(config));
    try testing.expect(!h.fake.ran("docker run -d"));
    try h.says("perhaps half done");
}

test "what it was made from: on the container, in the log, and seen as live" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    var config = PROXIED;
    config.service = "app";
    config.image = "app";
    config.host = "h";
    const a = h.arena.allocator();
    try testing.expect(try run(a, h.fake.remote(), &h.output.writer, .{
        .config = config,
        .version = "v2",
        .who = "seven",
        .sources = "game@abc,engine@def",
        .image = .{ .ptr = &h.sender, .sendFn = Sender.send },
    }));
    try testing.expect(h.fake.ran("--label sources=game@abc,engine@def"));
    try testing.expect(h.fake.ran("deploy started, from game@abc,engine@def"));
    try h.on("docker ps -a", 0, "app-web-v2\trunning\tv2\tgame@abc,engine@def\napp-web-v1\texited\tv1\tgame@old,engine@def\n");
    try testing.expect(try liveFrom(a, h.fake.remote(), "app", "game@abc,engine@def"));
    try testing.expect(!try liveFrom(a, h.fake.remote(), "app", "game@old,engine@def"));
}

test "a secret travels on stdin, never on a command line" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("umask 077", 0, "/home/u/.cowshed/env/app-web-v2");
    try testing.expect(try h.deploy(PROXIED));
    for (h.fake.calls.items) |call| {
        try testing.expect(std.mem.indexOf(u8, call.line, "hidden-value") == null);
    }
    try testing.expect(std.mem.indexOf(u8, h.output.written(), "hidden-value") == null);
    const env = h.fake.calls.items[h.fake.position("umask 077").?];
    try testing.expectEqualStrings("TOKEN=hidden-value\n", env.stdin.?);
    try testing.expect(h.fake.ran("--env-file /home/u/.cowshed/env/app-web-v2"));
}

test "a line break in a secret stops it, before a container exists" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    var config = PROXIED;
    config.service = "app";
    config.image = "app";
    config.host = "h";
    try testing.expect(!try run(h.arena.allocator(), h.fake.remote(), &h.output.writer, .{
        .config = config,
        .version = "v2",
        .who = "seven",
        .secrets = &.{.{ .name = "TOKEN", .value = "hidden-one\nhidden-two" }},
        .image = .{ .ptr = &h.sender, .sendFn = Sender.send },
    }));
    try h.says("`TOKEN` has a line break");
    try testing.expect(!h.fake.ran("docker run"));
    try testing.expect(std.mem.indexOf(u8, h.output.written(), "hidden") == null);
    try h.oldUntouched();
}

test "the new one failing its health: thrown away, old untouched, route never written" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("wget -q -O /dev/null", 1, "");
    try h.on("docker logs", 0, "boom\n");
    var config = PROXIED;
    config.deploy_timeout_s = 3;
    try testing.expect(!try h.deploy(config));
    try h.says("did not pass its health check");
    try h.says("boom");
    try testing.expect(h.fake.ran("docker rm -f app-web-v2"));
    try testing.expect(!h.fake.ran("mv \"$1/.$2.tmp\""));
    try h.oldUntouched();
}

test "the new one exiting is seen at once" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker inspect --format {{.State.Running}}", 0, "false\n");
    try testing.expect(!try h.deploy(PROXIED));
    try h.says("exited");
    try testing.expect(!h.fake.ran("wget -q -O /dev/null"));
    try h.oldUntouched();
}

test "the image failing: no container starts" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    h.sender.fail = true;
    try testing.expect(!try h.deploy(PROXIED));
    try testing.expect(!h.fake.ran("docker run"));
    try h.oldUntouched();
}

test "the start failing: removed, old untouched" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker run", 125, "");
    try testing.expect(!try h.deploy(PROXIED));
    try h.says("could not start the container: the error");
    try testing.expect(h.fake.ran("docker rm -f app-web-v2"));
    try h.oldUntouched();
}

test "Traefik not taking the route, a first deploy: the route removed, old untouched" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("wget -qO- http://127.0.0.1:8080", 1, "");
    try testing.expect(!try h.deploy(PROXIED));
    try h.says("did not take the new route");
    try testing.expect(h.fake.ran("rm -f \"$1/$2\""));
    try testing.expect(h.fake.ran("docker rm -f app-web-v2"));
    try h.oldUntouched();
}

test "Traefik not taking the route: the previous one written back" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("cat \"$1/$2\"", 0, "the old route");
    try h.on("wget -qO- http://127.0.0.1:8080", 0, "{\"url\":\"http://app-web-v1:80\"}");
    try testing.expect(!try h.deploy(PROXIED));
    const last = h.fake.calls.items;
    var restored = false;
    for (last) |call| {
        if (call.stdin) |stdin| {
            if (std.mem.eql(u8, stdin, "the old route")) restored = true;
        }
    }
    try testing.expect(restored);
    try h.oldUntouched();
}

test "another file naming our router stops it before any switch" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("grep -q", 0, "aaa.yml\n");
    try testing.expect(!try h.deploy(PROXIED));
    try h.says("`aaa.yml`");
    try testing.expect(!h.fake.ran("mv \"$1/.$2.tmp\""));
    try h.oldUntouched();
}

test "a lock held: nothing happens, and it stays held" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("mkdir \"$d\"", 1, "");
    try h.on("cat \"$HOME/.cowshed/locks/$1/details\"", 0, "another, version v9\n");
    try testing.expect(!try h.deploy(PROXIED));
    try h.says("another, version v9");
    try testing.expect(!h.sender.sent);
    try testing.expect(!h.fake.ran("rm -rf \"$HOME/.cowshed/locks/$1\""));
}

test "no Traefik: run setup" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps --format", 0, "");
    try testing.expect(!try h.deploy(PROXIED));
    try h.says("run `cowshed setup`");
    try testing.expect(!h.fake.ran("mkdir \"$d\""));
}

test "the same version again takes a new name: the live one keeps its own" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps -a", 0, "app-web-v2\trunning\tv2\napp-web-v2-2\texited\tv2\n");
    try h.on("wget -qO- http://127.0.0.1:8080", 0, "http://app-web-v2-3:80");
    try testing.expect(try h.deploy(PROXIED));
    try testing.expect(h.fake.ran("--name app-web-v2-3"));
    try testing.expect(h.fake.ran("docker stop app-web-v2"));
}

test "a container from before Cowshed is stopped, never removed" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    var config = PROXIED;
    config.replaces = "grape-arena";
    try testing.expect(try h.deploy(config));
    try testing.expect(h.fake.ran("docker stop grape-arena"));
    try testing.expect(!h.fake.ran("docker rm -f grape-arena"));
}

const TABLE =
    \\  sl  local_address rem_address   st tx_queue
    \\   0: 00000000:0050 00000000:0000 0A 0
    \\   1: 0100007F:0050 0200007F:9C40 01 0
    \\   2: 0100007F:0050 0200007F:9C41 01 0
    \\   3: 0100007F:1F90 0200007F:9C42 01 0
;

test "counting: established, on the app's port" {
    try testing.expectEqual(2, countEstablished(TABLE, 80));
    try testing.expectEqual(1, countEstablished(TABLE, 8080));
    try testing.expectEqual(0, countEstablished(TABLE, 22));
}

test "draining waits for its time, then stops the old" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("/proc/$1/net/tcp", 0, TABLE);
    try testing.expect(try h.deploy(PROXIED));
    try h.says("drain: 2 open");
    try h.says("time is up");
    try testing.expect(h.fake.ran("docker stop app-web-v1"));
}

test "a container that cannot be stopped is told, the deploy is done" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker stop", 1, "");
    try testing.expect(try h.deploy(PROXIED));
    try h.says("could not stop app-web-v1");
}

test "prune keeps the newest stopped, and removes what only the rest used" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps -a", 0, "app-web-v5\trunning\tv5\napp-web-v4\texited\tv4\napp-web-v3\texited\tv3\napp-web-v2x\texited\tv2x\napp-web-v1\texited\tv1\n");
    try h.on("docker images", 0, "v5\nv4\nv1\nfailed\n<none>\n");
    try testing.expect(try h.deploy(PROXIED));
    try testing.expect(!h.fake.ran("docker rm -f app-web-v4"));
    try testing.expect(!h.fake.ran("docker rm -f app-web-v2x"));
    try testing.expect(h.fake.ran("docker rm -f app-web-v1"));
    try testing.expect(h.fake.ran("docker rmi app:v1"));
    try testing.expect(h.fake.ran("docker rmi app:failed"));
    try testing.expect(!h.fake.ran("docker rmi app:v4"));
    try testing.expect(!h.fake.ran("docker rmi app:<none>"));
    const lists = h.fake.calls.items[h.fake.position("*.blobs").?];
    try testing.expectEqualStrings("v5\nv4\nv3\nv2x\n", lists.stdin.?);
    try testing.expect(h.fake.ran("blobs/sha256/*"));
}

fn rollbackTo(h: *Harness, version: []const u8) !bool {
    var config = PROXIED;
    config.service = "app";
    config.image = "app";
    config.host = "h";
    return rollback(h.arena.allocator(), h.fake.remote(), &h.output.writer, config, version, "seven");
}

test "rollback: starts the stopped one, proves it, switches, stops the live one" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps -a", 0, "app-web-v2\trunning\tv2\napp-web-v1-2\texited\tv1\napp-web-v1\texited\tv1\n");
    try h.on("wget -qO- http://127.0.0.1:8080", 0, "http://app-web-v1-2:80");
    try testing.expect(try rollbackTo(&h, "v1"));
    try h.before("docker start app-web-v1-2", "wget -q -O /dev/null");
    try h.before("wget -q -O /dev/null", "mv \"$1/.$2.tmp\"");
    try h.before("mv \"$1/.$2.tmp\"", "docker stop app-web-v2");
    try testing.expect(!h.fake.ran("docker run"));
    try testing.expect(!h.sender.sent);
    try h.says("rolled back to v1");
}

test "rollback failing its health: stopped again, never removed, live untouched" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps -a", 0, "app-web-v2\trunning\tv2\napp-web-v1\texited\tv1\n");
    try h.on("docker inspect --format {{.State.Running}}", 0, "false\n");
    try testing.expect(!try rollbackTo(&h, "v1"));
    try testing.expect(h.fake.ran("docker stop app-web-v1"));
    try testing.expect(!h.fake.ran("docker rm -f"));
    try testing.expect(!h.fake.ran("docker stop app-web-v2"));
    try testing.expect(!h.fake.ran("mv \"$1/.$2.tmp\""));
}

test "rollback to what is live, or to nothing: told, nothing touched" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps -a", 0, "app-web-v2\trunning\tv2\n");
    try testing.expect(!try rollbackTo(&h, "v2"));
    try h.says("already live");
    try testing.expect(!try rollbackTo(&h, "v9"));
    try h.says("no stopped container of version v9");
    try testing.expect(!h.fake.ran("docker start"));
    try testing.expect(h.fake.ran("rm -rf \"$HOME/.cowshed/locks/$1\""));
}

test "with no proxy: no route and no drain, and it must stay up" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(try h.deploy(.{ .service = "", .image = "", .host = "" }));
    try testing.expect(!h.fake.ran("docker exec"));
    try testing.expect(!h.fake.ran("--network"));
    try testing.expect(h.fake.ran("docker stop app-web-v1"));
}

test "the audit log records the start and the end, with who" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(try h.deploy(PROXIED));
    try testing.expect(h.fake.ran("seven app v2: deploy started"));
    try testing.expect(h.fake.ran("seven app v2: deployed"));
}
