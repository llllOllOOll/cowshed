//! What is done to a deployed app, deploys aside: looking at it, one-off commands,
//! taking it off the air and removing it.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Remote = @import("../remote/Remote.zig");
const docker = @import("../docker/commands.zig");
const detect = @import("../proxy/detect.zig");
const route = @import("../proxy/route.zig");
const lock = @import("lock.zig");
const deploy = @import("deploy.zig");
const secrets = @import("../config/secrets.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const AUDIT_LINES = "50";
const CREATED_SHOWN = "2026-11-01 15:04".len;
const READ_AUDIT = "tail -n " ++ AUDIT_LINES ++ " \"$HOME/.cowshed/audit-$1.log\" 2>/dev/null";
const REMOVE_ROUTE = "rm -f \"$1/$2\"";
const ENV_FILE_IF_ANY =
    \\f="$HOME/.cowshed/env/$1"; [ -e "$f" ] && printf %s "$f"
;
const REMOVE_FILES =
    \\rm -rf "$HOME/.cowshed/images/$1" "$HOME/.cowshed/env/$1-"*
;

pub const Error = Remote.Error || Writer.Error;

const Row = struct { name: []const u8, state: []const u8, version: []const u8, sources: []const u8 = "", created: []const u8 = "" };

fn parseRows(arena: Allocator, listing: []const u8) Allocator.Error![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const state = fields.next() orelse continue;
        const version = fields.next() orelse continue;
        try rows.append(arena, .{ .name = name, .state = state, .version = version, .sources = fields.next() orelse "", .created = fields.next() orelse "" });
    }
    return rows.items;
}

fn list(arena: Allocator, remote: Remote, out: *Writer, config: Config) Error!?[]const Row {
    const listing = try remote.run(arena, .{ .argv = try docker.listAll(arena, config.service) });
    if (!listing.ok()) {
        try out.print("stopped: could not list containers: {s}\n", .{trimmed(listing.stderr)});
        return null;
    }
    return try parseRows(arena, listing.stdout);
}

fn liveOf(rows: []const Row) ?Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.state, "running")) return row;
    }
    return null;
}

fn trimmed(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n ");
}

pub fn versions(arena: Allocator, remote: Remote, out: *Writer, config: Config) Error!bool {
    const rows = try list(arena, remote, out, config) orelse return false;
    if (rows.len == 0) {
        try out.writeAll("nothing deployed\n");
        return true;
    }
    for (rows) |row| {
        const mark: []const u8 = if (std.mem.eql(u8, row.state, "running")) "live" else "    ";
        try out.print("{s}  {s}  {s}", .{ mark, row.version, row.name });
        // `2026-11-01 15:04:05 -0300 -03`: to the minute, in the server's time.
        if (row.created.len > 0) try out.print("  {s}", .{row.created[0..@min(row.created.len, CREATED_SHOWN)]});
        if (row.sources.len > 0) try out.print("  ({s})", .{row.sources});
        try out.writeByte('\n');
        if (isStuck(row)) try warnStuck(out, row);
    }
    return true;
}

/// Not at rest and not live: one restarting runs its code again each time Docker
/// starts it, a queue's jobs or a cron's too.
fn isStuck(row: Row) bool {
    return !std.mem.eql(u8, row.state, "running") and docker.isActive(row.state);
}

fn warnStuck(out: *Writer, row: Row) Writer.Error!void {
    try out.print("warning: {s} is {s}, not live: if it keeps exiting, Docker starts it again and its code runs each time. The next deploy stops it\n", .{ row.name, row.state });
}

/// For `check --remote`: warns of each version stuck so; true when there is none.
pub fn checkStuck(arena: Allocator, remote: Remote, out: *Writer, config: Config) Error!bool {
    const listing = try remote.run(arena, .{ .argv = try docker.listAll(arena, config.service) });
    if (!listing.ok()) return true;
    var none = true;
    for (try parseRows(arena, listing.stdout)) |row| {
        if (!isStuck(row)) continue;
        try warnStuck(out, row);
        none = false;
    }
    return none;
}

pub fn logs(arena: Allocator, remote: Remote, out: *Writer, config: Config, lines: []const u8) Error!bool {
    const rows = try list(arena, remote, out, config) orelse return false;
    const live = liveOf(rows) orelse {
        try out.writeAll("stopped: nothing is live\n");
        return false;
    };
    const result = try remote.run(arena, .{ .argv = &.{ "docker", "logs", "--tail", lines, live.name } });
    try out.writeAll(result.stdout);
    try out.writeAll(result.stderr);
    return result.ok();
}

pub fn audit(arena: Allocator, remote: Remote, out: *Writer, config: Config) Error!bool {
    const result = try remote.run(arena, .{ .argv = &.{ "sh", "-c", READ_AUDIT, "sh", config.service } });
    if (result.stdout.len == 0) {
        try out.writeAll("nothing recorded\n");
        return true;
    }
    try out.writeAll(result.stdout);
    return true;
}

/// A new container of `version` (the live one's by default), with the live one's
/// variables and network, removed when it ends. Its exit code decides the result.
/// `env` replaces variables for this run alone; a secret is not one of them, as it
/// travels only by the env file, and only names are said.
pub fn exec(arena: Allocator, remote: Remote, out: *Writer, config: Config, version: ?[]const u8, env: []const Config.Pair, command: []const []const u8) Error!bool {
    for (env) |pair| {
        if (!isVariableName(pair.name)) {
            try out.print("stopped: `--env {s}` is no variable's name: letters, digits and `_`, not starting with a digit\n", .{pair.name});
            return false;
        }
        for (config.env.secret) |entry| {
            if (std.mem.eql(u8, secrets.targetOf(entry), pair.name)) {
                try out.print("stopped: `{s}` is a secret: it travels only by the env file, never on a command line\n", .{pair.name});
                return false;
            }
        }
    }
    const rows = try list(arena, remote, out, config) orelse return false;
    const live = liveOf(rows);
    const chosen = version orelse if (live) |row| row.version else {
        try out.writeAll("stopped: nothing is live: name a version with `--version`\n");
        return false;
    };
    const image = try std.fmt.allocPrint(arena, "{s}:{s}", .{ config.image, chosen });

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "docker", "run", "--rm", "--label", try std.fmt.allocPrint(arena, "oneoff={s}", .{config.service}) });
    var traefik: ?detect.Traefik = null;
    if (config.proxy) |proxy| {
        switch (try detect.detect(arena, remote, proxy)) {
            .traefik => |found| traefik = found,
            else => {},
        }
    }
    try docker.appendNetworks(arena, &argv, try deploy.networksOf(arena, config, traefik));
    for (config.env.clear) |clear| {
        try argv.appendSlice(arena, &.{ "--env", try std.fmt.allocPrint(arena, "{s}={s}", .{ clear.name, clear.value }) });
    }
    if (live) |row| {
        const env_file = try remote.run(arena, .{ .argv = &.{ "sh", "-c", ENV_FILE_IF_ANY, "sh", row.name } });
        if (env_file.ok()) try argv.appendSlice(arena, &.{ "--env-file", env_file.stdout });
    } else if (config.env.secret.len > 0) {
        try out.writeAll("notice: nothing is live, so this runs without the app's secrets\n");
    }
    // After the env file: an `--env` wins over it.
    for (env) |pair| {
        try argv.appendSlice(arena, &.{ "--env", try std.fmt.allocPrint(arena, "{s}={s}", .{ pair.name, pair.value }) });
    }
    try docker.appendVolumes(arena, &argv, config.volumes);
    try argv.append(arena, image);
    try argv.appendSlice(arena, command);

    try out.print("exec: running in a new container of {s}; its output comes at the end\n", .{chosen});
    for (env) |pair| try out.print("exec: {s} set for this run\n", .{pair.name});
    const result = try remote.run(arena, .{ .argv = argv.items });
    try out.writeAll(result.stdout);
    try out.writeAll(result.stderr);
    if (!result.ok()) try out.print("exit code {d}\n", .{result.exit_code});
    return result.ok();
}

/// Takes the route away first, then stops what runs. The containers stay.
pub fn stop(arena: Allocator, remote: Remote, out: *Writer, config: Config, who: []const u8) Error!bool {
    switch (try lock.acquire(arena, remote, config.service, try std.fmt.allocPrint(arena, "{s}, stopping", .{who}))) {
        .acquired => {},
        .held => |holder| {
            try out.print("stopped: another deploy holds the lock: {s}\n", .{holder});
            return false;
        },
    }
    defer lock.release(arena, remote, config.service) catch {};
    try removeRoute(arena, remote, out, config);
    const rows = try list(arena, remote, out, config) orelse return false;
    var ok = true;
    for (rows) |row| {
        if (!docker.isActive(row.state)) continue;
        // One in a loop, even seen running for a moment, could be started again
        // before the stop ends. A rollback gives the policy back.
        _ = try remote.run(arena, .{ .argv = try docker.noRestart(arena, row.name) });
        const stopped = try remote.run(arena, .{ .argv = try docker.stop(arena, row.name) });
        if (stopped.ok()) {
            try out.print("stopped {s}\n", .{row.name});
        } else {
            try out.print("could not stop {s}: {s}\n", .{ row.name, trimmed(stopped.stderr) });
            ok = false;
        }
    }
    return ok;
}

/// For good: route, containers, images and their files. Accessories, the audit log,
/// a container named in `replaces` and what volumes hold stay. Without `confirmed` it only tells.
pub fn remove(arena: Allocator, remote: Remote, out: *Writer, config: Config, who: []const u8, confirmed: bool) Error!bool {
    const rows = try list(arena, remote, out, config) orelse return false;
    if (!confirmed) {
        try out.print("this removes {s} from {s}, its route and these {d} containers, and cannot be undone:\n", .{ config.service, config.host, rows.len });
        for (rows) |row| try out.print("  {s} ({s})\n", .{ row.name, row.state });
        for (config.volumes) |volume| try out.print("  the volume {s} stays, with what it holds\n", .{volume});
        try out.writeAll("run it again with `--yes`\n");
        return false;
    }
    switch (try lock.acquire(arena, remote, config.service, try std.fmt.allocPrint(arena, "{s}, removing", .{who}))) {
        .acquired => {},
        .held => |holder| {
            try out.print("stopped: another deploy holds the lock: {s}\n", .{holder});
            return false;
        },
    }
    defer lock.release(arena, remote, config.service) catch {};
    try removeRoute(arena, remote, out, config);
    for (rows) |row| {
        _ = try remote.run(arena, .{ .argv = try docker.remove(arena, row.name) });
        try out.print("removed {s}\n", .{row.name});
    }
    const images = try remote.run(arena, .{ .argv = try docker.imageTags(arena, config.image, config.service) });
    if (images.ok()) {
        var tags = std.mem.tokenizeAny(u8, images.stdout, "\r\n");
        while (tags.next()) |tag| {
            if (std.mem.eql(u8, tag, "<none>")) continue;
            _ = try remote.run(arena, .{ .argv = &.{ "docker", "rmi", try std.fmt.allocPrint(arena, "{s}:{s}", .{ config.image, tag }) } });
        }
    }
    _ = try remote.run(arena, .{ .argv = &.{ "sh", "-c", REMOVE_FILES, "sh", config.service } });
    for (config.volumes) |volume| try out.print("kept the volume {s}\n", .{volume});
    try out.writeAll("removed\n");
    return true;
}

fn removeRoute(arena: Allocator, remote: Remote, out: *Writer, config: Config) Error!void {
    const proxy = config.proxy orelse return;
    switch (try detect.detect(arena, remote, proxy)) {
        .traefik => |found| {
            const file = try route.fileName(arena, config.service);
            const removed = try remote.run(arena, .{ .argv = &.{ "docker", "exec", found.id, "sh", "-c", REMOVE_ROUTE, "sh", found.routes_dir, file } });
            if (!removed.ok()) try out.print("notice: could not remove the route: {s}\n", .{trimmed(removed.stderr)});
        },
        .none => {},
        .stopped => |message| try out.print("notice: the route was not touched: {s}\n", .{message}),
    }
}

fn isVariableName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

const testing = std.testing;
const Fake = @import("../remote/Fake.zig");

const CONFIG: Config = .{ .service = "app", .image = "app", .host = "h" };
const LISTING = "app-web-v2\trunning\tv2\napp-web-v1\texited\tv1\n";

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    fake: Fake = undefined,
    output: Writer.Allocating = undefined,

    fn begin(self: *Harness) !void {
        const a = self.arena.allocator();
        self.fake = Fake.init(a);
        self.output = .init(a);
        try self.on("docker ps -a", 0, LISTING);
    }

    fn on(self: *Harness, contains: []const u8, code: u8, stdout: []const u8) !void {
        try self.fake.on(contains, .{ .result = .{ .exit_code = code, .stdout = stdout, .stderr = "" } });
    }

    fn says(self: *Harness, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.output.written(), text) == null) {
            std.debug.print("output:\n{s}\n", .{self.output.written()});
            return error.TestExpectedOutput;
        }
    }
};

fn harness() Harness {
    return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
}

test "versions mark what is live" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(try versions(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG));
    try h.says("live  v2  app-web-v2");
    try h.says("      v1  app-web-v1");
    try h.on("docker ps -a", 0, "a\trunning\tv3\tgame@abc\n");
    try testing.expect(try versions(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG));
    try h.says("live  v3  a  (game@abc)");
}

test "versions warn of one restarting that is not live" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps -a", 0, "app-web-v2\trunning\tv2\napp-web-v1\trestarting\tv1\n");
    try testing.expect(try versions(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG));
    try h.says("warning: app-web-v1 is restarting, not live");
    try testing.expect(std.mem.indexOf(u8, h.output.written(), "app-web-v2 is") == null);
}

test "check --remote's look: one restarting is warned of, the live one is not" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(try checkStuck(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG));
    try h.on("docker ps -a", 0, "app-web-v2\trunning\tv2\napp-web-v1\trestarting\tv1\n");
    try testing.expect(!try checkStuck(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG));
    try h.says("warning: app-web-v1 is restarting");
}

test "stop: one restarting too, its restarts turned off first" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps -a", 0, "app-web-v2\trunning\tv2\napp-web-v1\trestarting\tv1\napp-web-v0\texited\tv0\n");
    try testing.expect(try stop(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, "me"));
    try testing.expect(h.fake.position("docker update --restart no app-web-v2").? < h.fake.position("docker stop app-web-v2").?);
    try testing.expect(h.fake.position("docker update --restart no app-web-v1").? < h.fake.position("docker stop app-web-v1").?);
    try testing.expect(!h.fake.ran("docker stop app-web-v0"));
}

test "logs are the live container's" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(try logs(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, "5"));
    try testing.expect(h.fake.ran("docker logs --tail 5 app-web-v2"));
}

test "exec: the live version, its env file, its words whole, its exit code" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("$HOME/.cowshed/env/$1", 0, "/home/u/.cowshed/env/app-web-v2");
    var config = CONFIG;
    config.env = .{ .clear = &.{.{ .name = "A", .value = "1" }} };
    config.volumes = &.{"/srv/d:/data"};
    const a = h.arena.allocator();
    try testing.expect(try exec(a, h.fake.remote(), &h.output.writer, config, null, &.{}, &.{ "./migrate", "--to", "two words" }));
    try testing.expect(h.fake.ran("docker run --rm"));
    try testing.expect(h.fake.ran("--env A=1 --env-file /home/u/.cowshed/env/app-web-v2 --volume /srv/d:/data app:v2 ./migrate --to two words"));
    try h.on("docker run --rm", 3, "");
    try testing.expect(!try exec(a, h.fake.remote(), &h.output.writer, config, "v1", &.{}, &.{"x"}));
    try testing.expect(h.fake.ran("app:v1 x"));
    try h.says("exit code 3");
}

test "exec joins the project's networks too" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    var config = CONFIG;
    config.networks = &.{"own"};
    try testing.expect(try exec(h.arena.allocator(), h.fake.remote(), &h.output.writer, config, null, &.{}, &.{"x"}));
    const line = h.fake.calls.items[h.fake.position("docker run --rm").?].line;
    try testing.expect(std.mem.indexOf(u8, line, "--network own") != null);
}

test "exec --env: after the env file so it wins, only its name said; a secret or a bad name refused" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("$HOME/.cowshed/env/$1", 0, "/home/u/.cowshed/env/app-web-v2");
    var config = CONFIG;
    config.env = .{ .clear = &.{.{ .name = "PG_DB", .value = "live" }}, .secret = &.{ "PG_PASSWORD", "TOKEN:FROM_FILE" } };
    const a = h.arena.allocator();
    try testing.expect(try exec(a, h.fake.remote(), &h.output.writer, config, "v3", &.{.{ .name = "PG_DB", .value = "rehearsal" }}, &.{"./app"}));
    try testing.expect(h.fake.ran("--env PG_DB=live --env-file /home/u/.cowshed/env/app-web-v2 --env PG_DB=rehearsal app:v3 ./app"));
    try h.says("exec: PG_DB set for this run");
    try testing.expect(std.mem.indexOf(u8, h.output.written(), "rehearsal") == null);
    const runs = h.fake.calls.items.len;
    try testing.expect(!try exec(a, h.fake.remote(), &h.output.writer, config, null, &.{.{ .name = "PG_PASSWORD", .value = "x" }}, &.{"./app"}));
    try h.says("`PG_PASSWORD` is a secret");
    try testing.expect(!try exec(a, h.fake.remote(), &h.output.writer, config, null, &.{.{ .name = "TOKEN", .value = "x" }}, &.{"./app"}));
    try testing.expect(!try exec(a, h.fake.remote(), &h.output.writer, config, null, &.{.{ .name = "1BAD", .value = "x" }}, &.{"./app"}));
    try h.says("no variable's name");
    try testing.expectEqual(runs, h.fake.calls.items.len);
}

test "exec with nothing live needs a version" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker ps -a", 0, "app-web-v1\texited\tv1\n");
    try testing.expect(!try exec(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, null, &.{}, &.{"x"}));
    try h.says("nothing is live");
}

test "stop: the running one, its container kept" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(try stop(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, "me"));
    try testing.expect(h.fake.ran("docker stop app-web-v2"));
    try testing.expect(!h.fake.ran("docker stop app-web-v1"));
    try testing.expect(!h.fake.ran("docker rm"));
}

test "remove without --yes only tells" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try testing.expect(!try remove(h.arena.allocator(), h.fake.remote(), &h.output.writer, CONFIG, "me", false));
    try h.says("cannot be undone");
    try h.says("app-web-v1");
    try testing.expect(!h.fake.ran("docker rm"));
    try testing.expect(!h.fake.ran("rm -rf"));
}

test "remove with --yes: containers, images, files, and nothing while locked" {
    var h = harness();
    defer h.arena.deinit();
    try h.begin();
    try h.on("docker images", 0, "v2\nv1\n");
    const a = h.arena.allocator();
    try testing.expect(try remove(a, h.fake.remote(), &h.output.writer, CONFIG, "me", true));
    try testing.expect(h.fake.ran("docker rm -f app-web-v2"));
    try testing.expect(h.fake.ran("docker rm -f app-web-v1"));
    try testing.expect(h.fake.ran("docker rmi app:v1"));
    try testing.expect(h.fake.ran(".cowshed/images/$1"));

    var locked = harness();
    defer locked.arena.deinit();
    try locked.begin();
    try locked.on("mkdir \"$d\"", 1, "");
    try testing.expect(!try remove(locked.arena.allocator(), locked.fake.remote(), &locked.output.writer, CONFIG, "me", true));
    try testing.expect(!locked.fake.ran("docker rm"));
}
