//! `cowshed proxy adopt`: gives a working Traefik a routes folder. This restarts it,
//! cutting every app it serves for a moment, so it happens only when asked for by
//! name. All is proven before the cut, and a failure after it puts everything back.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Remote = @import("../remote/Remote.zig");
const docker = @import("../docker/commands.zig");
const detect = @import("../proxy/detect.zig");
const edit = @import("../proxy/adopt.zig");
const traefik = @import("../proxy/traefik.zig");
const lock = @import("lock.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = Remote.Error || Writer.Error || Allocator.Error;

pub const ROUTES_MOUNT = "/cowshed-routes";
const LOCK = "traefik-adopt";
const TEST_NAME = "cowshed-adopt-test";
const API_VERSION = "http://127.0.0.1:8080/api/version";
const API_ROUTERS = "http://127.0.0.1:8080/api/http/routers?per_page=1000";
const TEST_LIMIT_S = 10;
const CONFIRM_LIMIT_S = 30;
const NO_CURL = 3;

/// Line by line: Compose's project, folder, files and service, the image, its working
/// folder, then its mounts. Never its environment.
const INSPECT =
    \\{{index .Config.Labels "com.docker.compose.project"}}
    \\{{index .Config.Labels "com.docker.compose.project.working_dir"}}
    \\{{index .Config.Labels "com.docker.compose.project.config_files"}}
    \\{{index .Config.Labels "com.docker.compose.service"}}
    \\{{.Image}}
    \\{{.Config.WorkingDir}}
    \\{{range .Mounts}}{{.Type}}{{"\t"}}{{.Source}}{{"\t"}}{{.Destination}}{{"\n"}}{{end}}
;
const LABELS = "{{if eq (index .Config.Labels \"traefik.enable\") \"true\"}}{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{\"\\n\"}}{{end}}{{end}}";

/// `$1` the Compose file, `$2` the settings file, then what else Traefik mounts.
/// Holds certificates' keys: only its owner reads it.
const BACK_UP =
    \\d="$HOME/.cowshed/backups/traefik-$(date -u +%Y%m%dT%H%M%SZ)"
    \\mkdir -p "$d" && chmod 700 "$d" || exit 1
    \\cp -p "$1" "$d/compose" && cp -p "$2" "$d/settings" || exit 1
    \\shift 2; i=0
    \\for p in "$@"; do
    \\  i=$((i + 1))
    \\  [ -S "$p" ] && continue
    \\  cp -a "$p" "$d/mount-$i" || exit 1
    \\done
    \\printf %s "$d"
;
const STAGE = "cp -p \"$1\" \"$1.cowshed-new\" && cat > \"$1.cowshed-new\"";
const UNSTAGE = "rm -f \"$1.cowshed-new\" \"$2.cowshed-new\"";
const INSTALL = "mv \"$1.cowshed-new\" \"$1\" && mv \"$2.cowshed-new\" \"$2\"";
const RESTORE = "cp -p \"$3/compose\" \"$1\" && cp -p \"$3/settings\" \"$2\"";
const COMPOSE_CHECK = "cd \"$1\" && docker compose -f \"$2\" -p \"$3\" config -q";
const COMPOSE_UP = "cd \"$1\" && docker compose -f \"$2\" -p \"$3\" up -d --no-deps --pull never \"$4\"";
const HOST_CODES =
    \\command -v curl >/dev/null || exit 3
    \\for s in http https; do
    \\  curl -s -o /dev/null --max-time 5 -w '%{http_code} ' --resolve "$1:80:127.0.0.1" --resolve "$1:443:127.0.0.1" "$s://$1/" || true
    \\done
;
const APPEND_AUDIT =
    \\mkdir -p "$HOME/.cowshed" && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$HOME/.cowshed/audit-traefik.log"
;

const Facts = struct {
    id: []const u8,
    name: []const u8,
    project: []const u8,
    folder: []const u8,
    compose_path: []const u8,
    service: []const u8,
    image: []const u8,
    command: []const []const u8,
    settings_path: []const u8,
    settings_mount: []const u8,
    routes_host: []const u8,
    /// Bind-mounted sources, to back up.
    sources: []const []const u8,
    new_settings: []const u8,
    new_compose: []const u8,
};

const Run = struct {
    arena: Allocator,
    remote: Remote,
    out: *Writer,
    config: Config,

    fn ask(self: Run, argv: []const []const u8) Remote.Error!Remote.Result {
        return self.remote.run(self.arena, .{ .argv = argv });
    }

    fn shell(self: Run, script: []const u8, args: []const []const u8) Remote.Error!Remote.Result {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.arena, &.{ "sh", "-c", script, "sh" });
        try argv.appendSlice(self.arena, args);
        return self.ask(argv.items);
    }

    fn stop(self: Run, comptime format: []const u8, args: anytype) Writer.Error!bool {
        try self.out.print("stopped: " ++ format ++ "\n", args);
        return false;
    }
};

fn lastLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\r\n ");
    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return trimmed[start..];
}

/// False when it stopped; why has been written to `out`. Without `confirmed` it only
/// says what it would do, and changes nothing.
pub fn run(arena: Allocator, remote: Remote, out: *Writer, config: Config, who: []const u8, confirmed: bool) Error!bool {
    const self: Run = .{ .arena = arena, .remote = remote, .out = out, .config = config };

    const listed = try self.ask(docker.list_running);
    if (!listed.ok()) return self.stop("could not list containers: {s}", .{lastLine(listed.stderr)});
    var running: ?detect.Traefik = null;
    var lines = std.mem.splitScalar(u8, listed.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse continue;
        const image = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        if (!traefik.isTraefikImage(image)) continue;
        if (running != null) return self.stop("more than one Traefik runs on this server: leave one", .{});
        running = .{ .id = id, .image = image, .name = name, .network = "", .routes_dir = "", .http_entrypoint = null, .https_entrypoint = null, .resolver = null, .api = false };
    }
    const found = running orelse {
        try out.writeAll("no Traefik runs here: nothing to adopt. `cowshed setup` starts one\n");
        return true;
    };

    const facts = try gather(self, found) orelse return false;
    if (facts.new_settings.len == 0) return true;

    try out.print("adopt: Traefik `{s}` belongs to Compose project `{s}`\n", .{ facts.name, facts.project });
    try out.print("  {s}: adds `providers.file.directory: {s}` and `api.insecure: true` (its port stays unpublished)\n", .{ facts.settings_path, ROUTES_MOUNT });
    try out.print("  {s}: mounts {s} on {s} in service `{s}`\n", .{ facts.compose_path, facts.routes_host, ROUTES_MOUNT, facts.service });
    try out.writeAll("  backs up those files and what Traefik mounts, certificates included, to ~/.cowshed/backups\n");
    try out.writeAll("  tries the new settings in a throwaway container, on no published port\n");
    try out.print("  recreates only `{s}`, same image: every app it serves is cut for some seconds\n", .{facts.name});
    try out.writeAll("  checks those apps; if any got worse, puts everything back\n");
    if (!confirmed) {
        try out.writeAll("nothing changed. Run it again with `--yes`, at a time that suits every app on this server\n");
        return true;
    }

    switch (try lock.acquire(arena, remote, LOCK, try std.fmt.allocPrint(arena, "{s}, adopting Traefik", .{who}))) {
        .acquired => {},
        .held => |holder| return self.stop("another adoption holds the lock: {s}", .{holder}),
    }
    defer lock.release(arena, remote, LOCK) catch {};
    return adopt(self, facts, who);
}

fn gather(self: Run, found: detect.Traefik) Error!?Facts {
    const name = found.name;
    const read = try detect.readFlags(self.arena, self.remote, found);
    const flags, const settings_path = switch (read) {
        .stopped => |message| {
            _ = try self.stop("{s}", .{message});
            return null;
        },
        .flags => |flags| .{ flags.flags, flags.settings_path },
    };
    if (flags.routes_dir != null and !flags.watch_off) {
        try self.out.print("Traefik `{s}` already has a routes folder: nothing to do\n", .{name});
        return empty(found);
    }
    if (flags.routes_file or flags.watch_off) {
        _ = try self.stop("Traefik `{s}` already uses a file provider in a way Cowshed will not change by itself: make it `providers.file.directory`, with watching on", .{name});
        return null;
    }
    const settings = settings_path orelse {
        _ = try self.stop("Traefik `{s}` is set up by its flags, and `adopt` only edits a YAML settings file for now. Add `--providers.file.directory`, and mount that folder", .{name});
        return null;
    };

    const inspected = try self.ask(&.{ "docker", "inspect", "--format", INSPECT, found.id });
    if (!inspected.ok()) {
        _ = try self.stop("could not read Traefik's container: {s}", .{lastLine(inspected.stderr)});
        return null;
    }
    var fields = std.mem.splitScalar(u8, inspected.stdout, '\n');
    const project = fields.next() orelse "";
    const folder = fields.next() orelse "";
    const files = fields.next() orelse "";
    const service = fields.next() orelse "";
    const image = fields.next() orelse "";
    const working = fields.next() orelse "";
    if (project.len == 0 or folder.len == 0 or files.len == 0 or service.len == 0) {
        _ = try self.stop("Traefik `{s}` was not started by Compose, and `adopt` only handles that for now. Add a routes folder to it by hand", .{name});
        return null;
    }
    if (std.mem.indexOfScalar(u8, files, ',') != null) {
        _ = try self.stop("Traefik `{s}` comes from several Compose files, and `adopt` edits only one: add the routes folder by hand", .{name});
        return null;
    }

    const wanted = try absolute(self.arena, working, settings);
    var settings_host: ?[]const u8 = null;
    var sources: std.ArrayList([]const u8) = .empty;
    while (fields.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, '\t');
        const kind = parts.next() orelse continue;
        const source = parts.next() orelse continue;
        const destination = parts.next() orelse continue;
        if (!std.mem.eql(u8, kind, "bind")) continue;
        if (std.mem.eql(u8, destination, wanted)) {
            settings_host = source;
        } else {
            try sources.append(self.arena, source);
        }
    }
    const host_settings = settings_host orelse {
        _ = try self.stop("Traefik `{s}`'s `{s}` is not a file mounted from the server: there is nothing to edit", .{ name, wanted });
        return null;
    };

    const settings_text = try self.shell("cat \"$1\"", &.{host_settings});
    const compose_text = try self.shell("cat \"$1\"", &.{files});
    if (!settings_text.ok() or !compose_text.ok()) {
        _ = try self.stop("could not read `{s}` and `{s}` on the server: `adopt` needs a user who can", .{ host_settings, files });
        return null;
    }
    const new_settings = try edit.editSettings(self.arena, settings_text.stdout, ROUTES_MOUNT) orelse {
        _ = try self.stop("`{s}` has a shape Cowshed will not edit safely. Add `providers.file.directory` and `api.insecure` by hand", .{host_settings});
        return null;
    };
    const dir = std.fs.path.dirname(host_settings) orelse "/";
    const routes_host = try std.fmt.allocPrint(self.arena, "{s}/cowshed-routes", .{dir});
    const volume = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ routes_host, ROUTES_MOUNT });
    const new_compose = try edit.editCompose(self.arena, compose_text.stdout, service, volume) orelse {
        _ = try self.stop("could not find the volumes of service `{s}` in `{s}`: add {s} by hand", .{ service, files, volume });
        return null;
    };

    const config_read = try self.ask(try docker.inspectConfig(self.arena, found.id));
    var config_lines = std.mem.splitScalar(u8, config_read.stdout, '\n');
    _ = config_lines.next();
    return .{
        .id = found.id,
        .name = name,
        .project = project,
        .folder = folder,
        .compose_path = files,
        .service = service,
        .image = image,
        .command = detect.parseStrings(self.arena, config_lines.next() orelse "null"),
        .settings_path = host_settings,
        .settings_mount = wanted,
        .routes_host = routes_host,
        .sources = sources.items,
        .new_settings = new_settings,
        .new_compose = new_compose,
    };
}

fn empty(found: detect.Traefik) Facts {
    return .{ .id = found.id, .name = found.name, .project = "", .folder = "", .compose_path = "", .service = "", .image = "", .command = &.{}, .settings_path = "", .settings_mount = "", .routes_host = "", .sources = &.{}, .new_settings = "", .new_compose = "" };
}

fn absolute(arena: Allocator, working: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (path.len > 0 and path[0] == '/') return path;
    const bare = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    const base = std.mem.trimEnd(u8, working, "/");
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, bare });
}

fn adopt(self: Run, facts: Facts, who: []const u8) Error!bool {
    // What the apps answer now, to compare with after.
    const labelled = try readLabels(self);
    const before = try hostCodes(self, labelled.hosts);
    if (before) |codes| {
        for (labelled.hosts, codes) |host, code| try self.out.print("before: {s} answers {s} (http, https)\n", .{ host, code });
    } else {
        try self.out.writeAll("notice: no `curl` on the server: apps are checked through Traefik's routers only\n");
    }

    try self.out.writeAll("backup: copying\n");
    var backup_args: std.ArrayList([]const u8) = .empty;
    try backup_args.appendSlice(self.arena, &.{ facts.compose_path, facts.settings_path });
    try backup_args.appendSlice(self.arena, facts.sources);
    const backup = try self.shell(BACK_UP, backup_args.items);
    if (!backup.ok()) return self.stop("could not back up: {s}. Nothing changed", .{lastLine(backup.stderr)});
    const backup_dir = std.mem.trim(u8, backup.stdout, "\r\n ");
    try self.out.print("backup: {s}\n", .{backup_dir});

    const made = try self.ask(&.{ "mkdir", "-p", facts.routes_host });
    if (!made.ok()) return self.stop("could not make {s}: {s}. Traefik and its files are as they were", .{ facts.routes_host, lastLine(made.stderr) });

    if (!try prove(self, facts)) {
        _ = try self.shell(UNSTAGE, &.{ facts.compose_path, facts.settings_path });
        return false;
    }

    try self.out.print("switch: recreating `{s}`\n", .{facts.name});
    _ = try self.shell(APPEND_AUDIT, &.{try std.fmt.allocPrint(self.arena, "{s} adoption started, backup {s}", .{ who, backup_dir })});
    const installed = try self.shell(INSTALL, &.{ facts.compose_path, facts.settings_path });
    if (!installed.ok()) {
        try restore(self, facts, backup_dir, false);
        return self.stop("could not install the new files: {s}", .{lastLine(installed.stderr)});
    }
    const up = try self.shell(COMPOSE_UP, &.{ facts.folder, facts.compose_path, facts.project, facts.service });
    if (!up.ok()) {
        try restore(self, facts, backup_dir, true);
        return self.stop("Compose could not recreate it: {s}", .{lastLine(up.stderr)});
    }

    try self.out.print("check: waiting for {d} routers and {d} hosts as they were, up to {d} s\n", .{ labelled.routers.len, labelled.hosts.len, CONFIRM_LIMIT_S });
    if (try confirm(self, labelled, before)) |problem| {
        try self.out.print("check: {s}\n", .{problem});
        try restore(self, facts, backup_dir, true);
        return self.stop("the apps did not come back as they were: {s}. Everything was put back; the backup stays in {s}", .{ problem, backup_dir });
    }
    for (labelled.routers) |router| try self.out.print("check: router {s} enabled\n", .{router});
    if (before != null) {
        const now = try hostCodes(self, labelled.hosts) orelse &.{};
        for (labelled.hosts, now) |host, code| try self.out.print("check: {s} answers {s} (http, https)\n", .{ host, code });
    }
    _ = try self.shell(APPEND_AUDIT, &.{try std.fmt.allocPrint(self.arena, "{s} adopted", .{who})});
    try self.out.print("adopted: routes folder {s}, backup in {s}\n", .{ ROUTES_MOUNT, backup_dir });
    return true;
}

/// Before any cut: Compose reads the new file, and Traefik starts on the new settings.
fn prove(self: Run, facts: Facts) Error!bool {
    const staged_settings = try self.remote.run(self.arena, .{ .argv = &.{ "sh", "-c", STAGE, "sh", facts.settings_path }, .stdin = facts.new_settings });
    const staged_compose = try self.remote.run(self.arena, .{ .argv = &.{ "sh", "-c", STAGE, "sh", facts.compose_path }, .stdin = facts.new_compose });
    if (!staged_settings.ok() or !staged_compose.ok()) {
        return self.stop("could not write beside the files: `adopt` needs a user who can. Traefik and its files are as they were", .{});
    }
    const new_compose = try std.fmt.allocPrint(self.arena, "{s}.cowshed-new", .{facts.compose_path});
    const checked = try self.shell(COMPOSE_CHECK, &.{ facts.folder, new_compose, facts.project });
    if (!checked.ok()) return self.stop("Compose refuses the new file: {s}. Traefik and its files are as they were", .{lastLine(checked.stderr)});

    try self.out.writeAll("try: the new settings, in a throwaway container\n");
    const new_settings = try std.fmt.allocPrint(self.arena, "{s}.cowshed-new", .{facts.settings_path});
    _ = try self.ask(try docker.remove(self.arena, TEST_NAME));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(self.arena, &.{
        "docker", "run",                                                                                     "-d", "--name",                                                                            TEST_NAME,
        "-v",     try std.fmt.allocPrint(self.arena, "{s}:{s}:ro", .{ new_settings, facts.settings_mount }), "-v", try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ facts.routes_host, ROUTES_MOUNT }), facts.image,
    });
    try argv.appendSlice(self.arena, facts.command);
    const started = try self.ask(argv.items);
    defer _ = self.ask(docker.remove(self.arena, TEST_NAME) catch &.{}) catch {};
    if (!started.ok()) return self.stop("the new settings did not start: {s}. Traefik and its files are as they were", .{lastLine(started.stderr)});

    var waited: u32 = 0;
    while (waited < TEST_LIMIT_S) : (waited += 1) {
        const usable = try self.ask(&.{ "docker", "exec", TEST_NAME, "sh", "-c", "test -w \"$1\" && wget -qO- \"$2\"", "sh", ROUTES_MOUNT, API_VERSION });
        if (usable.ok()) return true;
        _ = try self.ask(&.{ "sleep", "1" });
    }
    return self.stop("Traefik did not come up on the new settings within {d} s. Traefik and its files are as they were", .{TEST_LIMIT_S});
}

fn readLabels(self: Run) Error!edit.Labelled {
    const ids = try self.ask(&.{ "docker", "ps", "-q" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(self.arena, &.{ "docker", "inspect", "--format", LABELS });
    var words = std.mem.tokenizeAny(u8, ids.stdout, "\r\n ");
    var any = false;
    while (words.next()) |id| {
        try argv.append(self.arena, id);
        any = true;
    }
    if (!any) return .{ .routers = &.{}, .hosts = &.{} };
    const labels = try self.ask(argv.items);
    return edit.parseLabels(self.arena, labels.stdout);
}

/// One `http https` pair for each host; null without `curl`.
fn hostCodes(self: Run, hosts: []const []const u8) Error!?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (hosts) |host| {
        const codes = try self.shell(HOST_CODES, &.{host});
        if (codes.exit_code == NO_CURL) return null;
        try out.append(self.arena, std.mem.trim(u8, codes.stdout, " \r\n"));
    }
    return out.items;
}

const RouterState = struct { name: []const u8 = "", status: []const u8 = "" };

/// What is wrong after the switch, or null once all is as it was.
fn confirm(self: Run, labelled: edit.Labelled, before: ?[]const []const u8) Error!?[]const u8 {
    var problem: []const u8 = "Traefik's API did not answer";
    var waited: u32 = 0;
    while (waited < CONFIRM_LIMIT_S) : (waited += 1) {
        if (waited > 0) _ = try self.ask(&.{ "sleep", "1" });
        problem = try firstProblem(self, labelled, before) orelse return null;
    }
    return problem;
}

fn firstProblem(self: Run, labelled: edit.Labelled, before: ?[]const []const u8) Error!?[]const u8 {
    const proxy = self.config.proxy orelse Config.Proxy{ .host = "" };
    const outcome = try detect.detect(self.arena, self.remote, proxy);
    const found = switch (outcome) {
        .traefik => |t| t,
        .none => return "no Traefik is running",
        .stopped => |message| return message,
    };
    const answer = try self.ask(&.{ "docker", "exec", found.id, "wget", "-qO-", API_ROUTERS });
    if (!answer.ok()) return "Traefik's API did not answer";
    const routers = std.json.parseFromSliceLeaky([]const RouterState, self.arena, answer.stdout, .{ .ignore_unknown_fields = true }) catch return "Traefik's API gave no list of routers";
    for (labelled.routers) |wanted| {
        for (routers) |router| {
            if (!std.mem.eql(u8, router.name, wanted)) continue;
            if (!std.mem.eql(u8, router.status, "enabled")) {
                return try std.fmt.allocPrint(self.arena, "router {s} is {s}", .{ wanted, router.status });
            }
            break;
        } else return try std.fmt.allocPrint(self.arena, "router {s} is gone", .{wanted});
    }
    const was = before orelse return null;
    const now = try hostCodes(self, labelled.hosts) orelse return null;
    for (labelled.hosts, was, now) |host, a, b| {
        var a_codes = std.mem.tokenizeScalar(u8, a, ' ');
        var b_codes = std.mem.tokenizeScalar(u8, b, ' ');
        while (a_codes.next()) |code_before| {
            const code_after = b_codes.next() orelse "000";
            if (!edit.stillAnswers(code_before, code_after)) {
                return try std.fmt.allocPrint(self.arena, "{s} answered {s} and now {s}", .{ host, code_before, code_after });
            }
        }
    }
    return null;
}

fn restore(self: Run, facts: Facts, backup_dir: []const u8, recreate: bool) Error!void {
    try self.out.writeAll("restore: putting the files back\n");
    const restored = try self.shell(RESTORE, &.{ facts.compose_path, facts.settings_path, backup_dir });
    if (!restored.ok()) {
        try self.out.print("RESTORE FAILED: {s}. The originals are in {s}\n", .{ lastLine(restored.stderr), backup_dir });
        return;
    }
    if (!recreate) return;
    const up = try self.shell(COMPOSE_UP, &.{ facts.folder, facts.compose_path, facts.project, facts.service });
    if (!up.ok()) {
        try self.out.print("RESTORE FAILED: Compose could not bring Traefik back: {s}. The originals are in place: run `docker compose up -d {s}` in {s}\n", .{ lastLine(up.stderr), facts.service, facts.folder });
        return;
    }
    try self.out.writeAll("restore: Traefik recreated as it was\n");
}

const testing = std.testing;
const Fake = @import("../remote/Fake.zig");

const SETTINGS =
    \\entryPoints:
    \\  http:
    \\    address: ":80"
    \\  https:
    \\    address: ":443"
    \\providers:
    \\  docker:
    \\    exposedByDefault: false
    \\certificatesResolvers:
    \\  letsencrypt:
    \\    acme:
    \\      email: s3cret-value
    \\
;
const AFTER = "/traefik.yml\nentryPoints:\n  http:\n    address: \":80\"\n  https:\n    address: \":443\"\nproviders:\n  file:\n    directory: /cowshed-routes\napi:\n  insecure: true\ncertificatesResolvers:\n  le:\n    acme:\n      email: s3cret-value\n";
const COMPOSE = "services:\n  traefik:\n    image: traefik:latest\n    volumes:\n      - ./traefik.yml:/traefik.yml:ro\n";
const INSPECTED = "openproject\n/opt/op\n/opt/op/docker-compose.yml\ntraefik\nsha256:abc\n/\nbind\t/var/run/docker.sock\t/var/run/docker.sock\nbind\t/opt/op/traefik/traefik.yml\t/traefik.yml\nbind\t/opt/op/traefik/acme.json\t/acme.json\n";
const ROUTERS = "[{\"name\":\"op@docker\",\"status\":\"enabled\"},{\"name\":\"api@internal\",\"status\":\"enabled\"}]";

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    fake: Fake = undefined,
    output: Writer.Allocating = undefined,

    fn create() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn start(self: *Harness) !void {
        const a = self.arena.allocator();
        self.fake = Fake.init(a);
        self.output = .init(a);
        try self.on("docker ps --format", 0, "abc\ttraefik:latest\ttraefik\nd\tapp:1\tapp\n");
        try self.on("docker inspect --format {{json", 0, "[\"/entrypoint.sh\"]\n[\"traefik\"]\nweb \n");
        try self.on("traefik.$e", 0, "/traefik.yml\n" ++ SETTINGS);
        try self.on("docker inspect --format {{index .Config.Labels \"com.docker.compose.project\"}}", 0, INSPECTED);
        try self.on("cat \"$1\" sh /opt/op/traefik/traefik.yml", 0, SETTINGS);
        try self.on("cat \"$1\" sh /opt/op/docker-compose.yml", 0, COMPOSE);
        try self.on("docker ps -q", 0, "abc\nd\n");
        try self.on("traefik.enable", 0, "traefik.http.routers.op.rule=Host(`op.example`)\n");
        try self.on("--resolve", 0, "200 301 ");
        try self.on("cp -a", 0, "/root/.cowshed/backups/traefik-1");
        // After the switch, Traefik reads as adopted, with its routers.
        try self.after("up -d --no-deps", "traefik.$e", 0, AFTER);
        try self.on("api/http/routers", 0, ROUTERS);
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    fn on(self: *Harness, contains: []const u8, exit_code: u8, stdout: []const u8) !void {
        try self.fake.on(contains, .{ .result = .{ .exit_code = exit_code, .stdout = stdout, .stderr = "the error" } });
    }

    fn after(self: *Harness, trigger: []const u8, contains: []const u8, exit_code: u8, stdout: []const u8) !void {
        try self.fake.onAfter(trigger, contains, .{ .result = .{ .exit_code = exit_code, .stdout = stdout, .stderr = "the error" } });
    }

    fn adopt(self: *Harness, confirmed: bool) !bool {
        return run(self.arena.allocator(), self.fake.remote(), &self.output.writer, .{ .service = "s", .image = "i", .host = "h" }, "me", confirmed);
    }

    fn says(self: *Harness, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.output.written(), text) == null) {
            std.debug.print("output:\n{s}\n", .{self.output.written()});
            return error.TestExpectedOutput;
        }
    }

    fn touchedNothing(self: *Harness) !void {
        for ([_][]const u8{ "up -d", "mv \"$1", "cowshed-new", "mkdir -p /" }) |change| {
            try testing.expect(!self.fake.ran(change));
        }
    }

    fn noSecret(self: *Harness) !void {
        try testing.expect(std.mem.indexOf(u8, self.output.written(), "s3cret-value") == null);
        for (self.fake.calls.items) |call| {
            try testing.expect(std.mem.indexOf(u8, call.line, "s3cret-value") == null);
        }
    }
};

test "without --yes: says all, changes nothing" {
    var h = Harness.create();
    defer h.deinit();
    try h.start();
    try testing.expect(try h.adopt(false));
    try h.says("Compose project `openproject`");
    try h.says("every app it serves is cut");
    try h.says("Run it again with `--yes`");
    try h.touchedNothing();
    try testing.expect(!h.fake.ran("cp -a"));
    try h.noSecret();
}

test "with --yes: backup, proof, then the switch, of that service only" {
    var h = Harness.create();
    defer h.deinit();
    try h.start();
    try testing.expect(try h.adopt(true));
    const order = [_][]const u8{ "cp -a", "mkdir -p /opt/op/traefik/cowshed-routes", "config -q", "docker run -d --name cowshed-adopt-test", "mv \"$1.cowshed-new\"", "up -d --no-deps --pull never" };
    for (order[0 .. order.len - 1], order[1..]) |a, b| {
        try testing.expect(h.fake.position(a).? < h.fake.position(b).?);
    }
    try testing.expect(h.fake.ran("/opt/op /opt/op/docker-compose.yml openproject traefik"));
    try testing.expect(h.fake.ran("docker rm -f cowshed-adopt-test"));
    try testing.expect(!h.fake.ran("-p 80"));
    try testing.expect(!h.fake.ran("restore"));
    try h.says("before: op.example answers 200 301 (http, https)");
    try h.says("check: router op@docker enabled");
    try h.says("check: op.example answers 200 301 (http, https)");
    try h.says("adopted: routes folder /cowshed-routes");
    try h.noSecret();
    // The edited files went by stdin.
    var edited = false;
    for (h.fake.calls.items) |call| {
        if (call.stdin) |stdin| edited = edited or std.mem.indexOf(u8, stdin, "/cowshed-routes") != null;
    }
    try testing.expect(edited);
}

test "a failure before the cut: nothing recreated, nothing installed" {
    const cases = [_]struct { contains: []const u8, says: []const u8 }{
        .{ .contains = "cp -a", .says = "could not back up" },
        .{ .contains = "config -q", .says = "Compose refuses" },
        .{ .contains = "docker run -d --name cowshed-adopt-test", .says = "did not start" },
        .{ .contains = "test -w", .says = "did not come up" },
    };
    for (cases) |case| {
        var h = Harness.create();
        defer h.deinit();
        try h.start();
        try h.on(case.contains, 1, "");
        try testing.expect(!try h.adopt(true));
        try h.says(case.says);
        try testing.expect(!h.fake.ran("up -d"));
        try testing.expect(!h.fake.ran("mv \"$1.cowshed-new\""));
    }
}

test "an app worse after: files put back and Traefik recreated" {
    var h = Harness.create();
    defer h.deinit();
    try h.start();
    try h.after("up -d --no-deps", "--resolve", 0, "502 000 ");
    try testing.expect(!try h.adopt(true));
    try h.says("op.example answered 200 and now 502");
    try h.says("Everything was put back");
    const first = h.fake.position("cp -p \"$3/compose\"").?;
    var recreated = false;
    for (h.fake.calls.items[first..]) |call| {
        recreated = recreated or std.mem.indexOf(u8, call.line, "up -d --no-deps") != null;
    }
    try testing.expect(recreated);
}

test "a router gone, and Compose failing: put back too" {
    {
        var h = Harness.create();
        defer h.deinit();
        try h.start();
        try h.on("api/http/routers", 0, "[]");
        try testing.expect(!try h.adopt(true));
        try h.says("router op@docker is gone");
        try testing.expect(h.fake.ran("cp -p \"$3/compose\""));
    }
    {
        var h = Harness.create();
        defer h.deinit();
        try h.start();
        try h.on("up -d --no-deps", 1, "");
        try testing.expect(!try h.adopt(true));
        try h.says("Compose could not recreate it");
        try h.says("RESTORE FAILED");
        try testing.expect(h.fake.ran("cp -p \"$3/compose\""));
    }
}

test "what it does not handle: refused, untouched" {
    const cases = [_]struct { contains: []const u8, stdout: []const u8, says: []const u8 }{
        .{ .contains = "{{index .Config.Labels \"com.docker.compose.project\"}}", .stdout = "\n\n\n\nsha\n/\n", .says = "not started by Compose" },
        .{ .contains = "{{index .Config.Labels \"com.docker.compose.project\"}}", .stdout = "p\n/o\n/o/a.yml,/o/b.yml\nt\nsha\n/\n", .says = "several Compose files" },
        .{ .contains = "{{index .Config.Labels \"com.docker.compose.project\"}}", .stdout = "p\n/o\n/o/a.yml\nt\nsha\n/\nvolume\t/x\t/traefik.yml\n", .says = "not a file mounted" },
        .{ .contains = "cat \"$1\" sh /opt/op/docker-compose.yml", .stdout = "services:\n  other:\n    image: a\n", .says = "could not find the volumes" },
    };
    for (cases) |case| {
        var h = Harness.create();
        defer h.deinit();
        try h.start();
        try h.on(case.contains, 0, case.stdout);
        try testing.expect(!try h.adopt(true));
        try h.says(case.says);
        try h.touchedNothing();
    }
}

test "already adopted, or no Traefik: nothing to do" {
    {
        var h = Harness.create();
        defer h.deinit();
        try h.start();
        try h.on("traefik.$e", 0, AFTER);
        try testing.expect(try h.adopt(true));
        try h.says("nothing to do");
        try h.touchedNothing();
    }
    {
        var h = Harness.create();
        defer h.deinit();
        try h.start();
        try h.on("docker ps --format", 0, "d\tapp:1\tapp\n");
        try testing.expect(try h.adopt(true));
        try h.says("nothing to adopt");
    }
}
