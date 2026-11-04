//! Prepares a server for its first deploy, and is safe to run again: it creates
//! what is missing and changes nothing that exists. Any other proxy, or a Traefik
//! that would need restarting, stops it with what to do: other apps live there.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Remote = @import("../remote/Remote.zig");
const docker = @import("../docker/commands.zig");
const traefik = @import("../proxy/traefik.zig");
const detect = @import("../proxy/detect.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Options = struct {
    /// Asks the server everything and changes nothing.
    dry_run: bool = false,
};

const IS_ROOT_OR_SUDO = "[ \"$(id -u)\" -eq 0 ] || sudo -n true";
const HAS_DOCKER = "command -v docker";
const INSTALL_DOCKER = "(curl -fsSL https://get.docker.com || wget -O - https://get.docker.com) | sh";
/// With the program holding each port, where the user may see it.
const LISTENING = "ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null";
const MAKE_FOLDERS =
    \\mkdir -p "$HOME/.cowshed/blobs" "$HOME/.cowshed/locks" "$HOME/.cowshed/traefik/routes" "$HOME/.cowshed/traefik/acme" && printf %s "$HOME"
;

const Run = struct {
    arena: Allocator,
    remote: Remote,
    out: *Writer,
    config: Config,
    options: Options,

    fn ask(self: Run, argv: []const []const u8) Remote.Error!Remote.Result {
        return self.remote.run(self.arena, .{ .argv = argv });
    }

    fn shell(self: Run, text: []const u8) Remote.Error!Remote.Result {
        return self.ask(&.{ "sh", "-c", text });
    }

    fn stop(self: Run, comptime format: []const u8, args: anytype) Writer.Error!bool {
        try self.out.print("stopped: " ++ format ++ "\n", args);
        return false;
    }

    fn lastLine(text: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, text, "\r\n ");
        const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
        return trimmed[start..];
    }
};

pub const Error = Remote.Error || Writer.Error;

/// False when it stopped; why has been written to `out`.
pub fn run(arena: Allocator, remote: Remote, out: *Writer, given: Config, options: Options) Error!bool {
    // An accessory's route needs Traefik as much as the app's does.
    var config = given;
    if (config.proxy == null) {
        for (config.accessories) |accessory| {
            if (accessory.proxy) |proxy| {
                config.proxy = proxy;
                break;
            }
        }
    }
    const self: Run = .{ .arena = arena, .remote = remote, .out = out, .config = config, .options = options };
    if (options.dry_run) try out.writeAll("dry run: nothing will change\n");
    if (!try ensureDocker(self)) return false;
    const home = try ensureFolders(self) orelse return false;
    if (config.proxy != null and !try ensureProxy(self, home)) return false;
    try out.writeAll("setup done\n");
    return true;
}

fn ensureDocker(self: Run) Error!bool {
    try self.out.writeAll("docker: checking\n");
    const found = try self.ask(docker.version);
    if (found.ok()) {
        try self.out.print("docker: {s}\n", .{std.mem.trimEnd(u8, found.stdout, "\r\n")});
        return true;
    }
    if ((try self.shell(HAS_DOCKER)).ok()) {
        return self.stop("Docker is installed and `{s}` cannot use it: {s}. Add the user to the `docker` group, or start Docker", .{ self.config.ssh.user, Run.lastLine(found.stderr) });
    }
    if (self.options.dry_run) {
        try self.out.writeAll("docker: missing, would be installed\n");
        return true;
    }
    if (!(try self.shell(IS_ROOT_OR_SUDO)).ok()) {
        return self.stop("Docker is missing, and installing it needs root or sudo without a password. Install it: https://docs.docker.com/engine/install/", .{});
    }
    try self.out.writeAll("docker: missing, installing with Docker's script\n");
    const installed = try self.shell(INSTALL_DOCKER);
    const after = try self.ask(docker.version);
    if (!after.ok()) {
        if ((try self.shell(HAS_DOCKER)).ok()) {
            return self.stop("Docker was installed and `{s}` cannot use it yet: {s}. A new login may be enough after joining the `docker` group", .{ self.config.ssh.user, Run.lastLine(after.stderr) });
        }
        return self.stop("installing Docker failed: {s}", .{Run.lastLine(installed.stderr)});
    }
    try self.out.print("docker: installed, {s}\n", .{std.mem.trimEnd(u8, after.stdout, "\r\n")});
    return true;
}

/// The server's home; in a dry run, how it is named.
fn ensureFolders(self: Run) Error!?[]const u8 {
    if (self.options.dry_run) {
        try self.out.writeAll("folders: ~/.cowshed would be made if missing\n");
        return "$HOME";
    }
    try self.out.writeAll("folders: making ~/.cowshed\n");
    const made = try self.shell(MAKE_FOLDERS);
    if (!made.ok()) {
        _ = try self.stop("could not make ~/.cowshed: {s}", .{Run.lastLine(made.stderr)});
        return null;
    }
    try self.out.writeAll("folders: ~/.cowshed\n");
    return made.stdout;
}

fn ensureProxy(self: Run, home: []const u8) Error!bool {
    try self.out.writeAll("traefik: looking for one on the server\n");
    switch (try detect.detect(self.arena, self.remote, self.config.proxy.?)) {
        .stopped => |message| return self.stop("{s}", .{message}),
        .none => return ensureOwn(self, home),
        .traefik => |found| {
            try self.out.print("traefik: using `{s}` ({s}), network {s}, routes {s}", .{ found.name, found.image, found.network, found.routes_dir });
            if (self.config.proxy.?.ssl) {
                try self.out.print(", entrypoint {s}, resolver {s}", .{ found.https_entrypoint.?, found.resolver.? });
            }
            try self.out.writeByte('\n');
            if (traefik.isFloating(found.image)) {
                try self.out.print("notice: `{s}` floats: recreating that container may bring another Traefik version. Pin one where it is defined, when a restart suits every app on it\n", .{found.image});
            }
            if (!found.api) {
                try self.out.writeAll("notice: Traefik's API is off: a switch cannot be confirmed through it\n");
            }
            return true;
        },
    }
}

fn ensureOwn(self: Run, home: []const u8) Error!bool {
    // Ours, stopped: it was made here, and is only started again.
    const state = try self.ask(try docker.containerState(self.arena, traefik.OWN_NAME));
    if (state.ok()) {
        if (self.options.dry_run) {
            try self.out.print("traefik: `{s}` is stopped, would be started\n", .{traefik.OWN_NAME});
            return true;
        }
        const started = try self.ask(try docker.start(self.arena, traefik.OWN_NAME));
        if (!started.ok()) return self.stop("could not start `{s}`: {s}", .{ traefik.OWN_NAME, Run.lastLine(started.stderr) });
        try self.out.print("traefik: started `{s}`\n", .{traefik.OWN_NAME});
        return true;
    }

    const proxy = self.config.proxy.?;
    if (proxy.ssl and proxy.acme_email == null) {
        return self.stop("there is no Traefik here, and certificates from Let's Encrypt need an email: set `proxy.acme_email`", .{});
    }

    const tcp = try tcpPorts(self.arena, self.config);
    var wanted: std.ArrayList(u16) = .empty;
    try wanted.appendSlice(self.arena, &.{ 80, 443 });
    try wanted.appendSlice(self.arena, tcp);
    const ports = try portsText(self.arena, wanted.items);
    const listening = try self.shell(LISTENING);
    if (listening.ok()) {
        for (wanted.items) |port| {
            if (traefik.listensOn(listening.stdout, port)) {
                return self.stop("port {d} is held by {s}. Cowshed will not touch it", .{ port, try holderOf(self, listening.stdout, port) });
            }
        }
    } else {
        try self.out.writeAll("notice: could not list the ports in use; starting Traefik will tell\n");
    }

    if (self.options.dry_run) {
        try self.out.print("traefik: none here, would start `{s}` ({s}) on {s}, network {s}\n", .{ traefik.OWN_NAME, traefik.OWN_IMAGE, ports, traefik.OWN_NETWORK });
        return true;
    }

    if (!(try self.ask(try docker.networkExists(self.arena, traefik.OWN_NETWORK))).ok()) {
        const created = try self.ask(try docker.networkCreate(self.arena, traefik.OWN_NETWORK));
        if (!created.ok()) return self.stop("could not create the network: {s}", .{Run.lastLine(created.stderr)});
    }
    const routes = try std.fmt.allocPrint(self.arena, "{s}/.cowshed/traefik/routes", .{home});
    const acme = try std.fmt.allocPrint(self.arena, "{s}/.cowshed/traefik/acme", .{home});
    try self.out.print("traefik: none here, starting `{s}` ({s}); a first download can take a while\n", .{ traefik.OWN_NAME, traefik.OWN_IMAGE });
    const ran = try self.ask(try traefik.ownRunCommand(self.arena, routes, acme, proxy.acme_email, tcp));
    if (!ran.ok()) {
        // A failed `docker run` leaves its container behind, on a port it never got.
        _ = try self.ask(try docker.remove(self.arena, traefik.OWN_NAME));
        return self.stop("could not start Traefik: {s}", .{Run.lastLine(ran.stderr)});
    }
    try self.out.print("traefik: started `{s}` ({s}) on {s}, network {s}\n", .{ traefik.OWN_NAME, traefik.OWN_IMAGE, ports, traefik.OWN_NETWORK });
    return true;
}

/// What holds `port`: a container publishing it, else the program `ss` or `netstat`
/// names, else that it cannot be told.
fn holderOf(self: Run, listening: []const u8, port: u16) Error![]const u8 {
    const listed = try self.ask(docker.list_running);
    if (listed.ok()) {
        for (try detect.parseRunning(self.arena, listed.stdout)) |container| {
            if (detect.publishes(container.ports, port)) {
                return std.fmt.allocPrint(self.arena, "the container `{s}` ({s})", .{ container.name, container.image });
            }
        }
    }
    if (programOn(listening, port)) |program| return std.fmt.allocPrint(self.arena, "the program `{s}`", .{program});
    return "a program this user cannot see";
}

/// From `ss -p` (`users:(("nginx",pid=1,fd=6))`) or `netstat -p` (`1/nginx`).
fn programOn(listening: []const u8, port: u16) ?[]const u8 {
    var buffer: [8]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buffer, ":{d}", .{port}) catch unreachable;
    var lines = std.mem.splitScalar(u8, listening, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        var on_port = false;
        var last: []const u8 = "";
        while (words.next()) |word| {
            if (std.mem.endsWith(u8, word, suffix)) on_port = true;
            last = word;
        }
        if (!on_port) continue;
        if (std.mem.indexOf(u8, line, "users:((\"")) |at| {
            const rest = line[at + "users:((\"".len ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |end| return rest[0..end];
        }
        if (std.mem.indexOfScalar(u8, last, '/')) |slash| {
            if (slash + 1 < last.len and std.ascii.isDigit(last[0])) return last[slash + 1 ..];
        }
    }
    return null;
}

/// The raw TCP ports the app and its accessories route, each once.
fn tcpPorts(arena: Allocator, config: Config) Allocator.Error![]const u16 {
    var ports: std.ArrayList(u16) = .empty;
    var proxies: std.ArrayList(Config.Proxy) = .empty;
    if (config.proxy) |proxy| try proxies.append(arena, proxy);
    for (config.accessories) |accessory| {
        if (accessory.proxy) |proxy| try proxies.append(arena, proxy);
    }
    for (proxies.items) |proxy| {
        for (proxy.tcp) |port| {
            if (std.mem.indexOfScalar(u16, ports.items, port) == null) try ports.append(arena, port);
        }
    }
    return ports.items;
}

/// `80, 443 and 60005`.
fn portsText(arena: Allocator, ports: []const u16) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (ports, 0..) |port, i| {
        if (i > 0) try text.appendSlice(arena, if (i == ports.len - 1) " and " else ", ");
        try text.print(arena, "{d}", .{port});
    }
    return text.items;
}

const testing = std.testing;
const Fake = @import("../remote/Fake.zig");

const VPS_INSPECT =
    \\["/entrypoint.sh"]
    \\["--api.insecure=true","--entrypoints.web.address=:80","--entrypoints.websecure.address=:443","--providers.docker=true","--providers.file.directory=/etc/traefik","--certificatesresolvers.letsencrypt.acme.email=a@b"]
    \\network_public 
    \\
;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    fake: Fake = undefined,
    output: Writer.Allocating = undefined,

    fn create() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn start(self: *Harness) void {
        self.fake = Fake.init(self.arena.allocator());
        self.output = .init(self.arena.allocator());
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    fn on(self: *Harness, contains: []const u8, exit_code: u8, stdout: []const u8) !void {
        try self.fake.on(contains, .{ .result = .{ .exit_code = exit_code, .stdout = stdout, .stderr = "the error" } });
    }

    fn setup(self: *Harness, proxy: ?Config.Proxy, options: Options) !bool {
        const config: Config = .{ .service = "s", .image = "i", .host = "h", .proxy = proxy };
        return run(self.arena.allocator(), self.fake.remote(), &self.output.writer, config, options);
    }

    fn says(self: *Harness, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.output.written(), text) == null) {
            std.debug.print("output:\n{s}\n", .{self.output.written()});
            return error.TestExpectedOutput;
        }
    }

    fn changedNothing(self: *Harness) !void {
        for ([_][]const u8{ "docker run", "network create", "docker start", "docker rm", "mkdir", "get.docker.com" }) |change| {
            try testing.expect(!self.fake.ran(change));
        }
    }
};

const PROXY: Config.Proxy = .{ .host = "a.example" };
const SSL_PROXY: Config.Proxy = .{ .host = "a.example", .ssl = true, .acme_email = "me@x" };

fn newServer(h: *Harness) !void {
    try h.on("docker version", 0, "29.1.3\n");
    try h.on("docker inspect --format {{.State.Running}}", 1, "");
    try h.on("network inspect", 1, "");
    try h.on("ss -ltn", 0, "LISTEN 0 1 0.0.0.0:22 0.0.0.0:*\n");
    try h.on("mkdir -p", 0, "/home/u");
}

test "a new server: folders, network and our own Traefik" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try newServer(&h);
    try testing.expect(try h.setup(SSL_PROXY, .{}));
    try testing.expect(h.fake.ran("network create cowshed"));
    try testing.expect(h.fake.ran("docker run -d --name cowshed-traefik"));
    try testing.expect(h.fake.ran("/home/u/.cowshed/traefik/routes:/etc/traefik/routes"));
    try testing.expect(h.fake.ran("acme.email=me@x"));
    try h.says("setup done");
}

test "a new server, dry run: asks and changes nothing" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try newServer(&h);
    try testing.expect(try h.setup(SSL_PROXY, .{ .dry_run = true }));
    try h.changedNothing();
    try h.says("would start `cowshed-traefik`");
}

test "an existing Traefik is used and left alone, its settings told" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try h.on("docker version", 0, "29\n");
    try h.on("mkdir -p", 0, "/home/u");
    try h.on("docker ps", 0, "abc\ttraefik:latest\ttraefik\t0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp\tweb\nd\tapp:1\tapp\n");
    try h.on("docker inspect", 0, VPS_INSPECT);
    try testing.expect(try h.setup(SSL_PROXY, .{}));
    try h.says("network network_public");
    try h.says("routes /etc/traefik");
    try h.says("entrypoint websecure");
    try h.says("resolver letsencrypt");
    try h.says("notice: `traefik:latest` floats");
    try testing.expect(h.fake.ran("docker exec abc sh -c"));
    try testing.expect(!h.fake.ran("docker run"));
    try testing.expect(!h.fake.ran("network create"));
    try testing.expect(!h.fake.ran("docker start"));
}

fn existingWith(h: *Harness, inspect: []const u8) !void {
    try h.on("docker version", 0, "29\n");
    try h.on("mkdir -p", 0, "/home/u");
    try h.on("docker ps", 0, "abc\ttraefik:3\tt\t0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp\tweb\n");
    try h.on("docker inspect", 0, inspect);
}

test "a Traefik that would need a restart stops it, untouched" {
    const cases = [_]struct { inspect: []const u8, says: []const u8 }{
        .{ .inspect = "null\n[\"--entrypoints.web.address=:80\"]\nnet \n", .says = "no routes folder" },
        .{ .inspect = "null\n[\"--entrypoints.web.address=:80\",\"--providers.file.filename=/a.yml\"]\nnet \n", .says = "reads one route file" },
        .{ .inspect = "null\n[\"--entrypoints.web.address=:80\",\"--providers.file.directory=/r\",\"--providers.file.watch=false\"]\nnet \n", .says = "does not watch" },
        .{ .inspect = "null\nnull\nnet \n", .says = "set up by its environment" },
    };
    for (cases) |case| {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try existingWith(&h, case.inspect);
        try testing.expect(!try h.setup(PROXY, .{}));
        try h.says(case.says);
        try testing.expect(!h.fake.ran("docker run"));
        try testing.expect(!h.fake.ran("docker rm"));
    }
}

const FILE_INSPECT = "[\"/entrypoint.sh\"]\n[\"traefik\"]\nweb \n";
const SETTINGS_SECRET = "s3cret-value";
const SETTINGS =
    \\/traefik.yml
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

test "a Traefik set up by a file with no routes folder: read, told and left alone" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try existingWith(&h, FILE_INSPECT);
    try h.on("traefik.$e", 0, SETTINGS);
    try testing.expect(!try h.setup(SSL_PROXY, .{ .dry_run = true }));
    try h.says("no routes folder");
    try h.changedNothing();
    try testing.expect(std.mem.indexOf(u8, h.output.written(), SETTINGS_SECRET) == null);
}

test "a Traefik set up by a file with a routes folder is used" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try existingWith(&h, FILE_INSPECT);
    // The routes folder, added to what the server holds.
    const with_folder = try std.mem.replaceOwned(u8, h.arena.allocator(), SETTINGS, "  docker:\n", "  file:\n    directory: /routes\n  docker:\n");
    try h.on("traefik.$e", 0, with_folder);
    try testing.expect(try h.setup(SSL_PROXY, .{}));
    try h.says("network web");
    try h.says("routes /routes");
    try h.says("entrypoint https");
    try h.says("resolver letsencrypt");
    try h.says("notice: Traefik's API is off");
    try testing.expect(!h.fake.ran("docker run"));
    try testing.expect(std.mem.indexOf(u8, h.output.written(), SETTINGS_SECRET) == null);
}

test "a settings file that cannot be read says why, without its contents" {
    const cases = [_]struct { exit_code: u8, stdout: []const u8, says: []const u8 }{
        .{ .exit_code = 0, .stdout = "/traefik.toml\n[api]\n", .says = "reads only YAML" },
        .{ .exit_code = 0, .stdout = "/traefik.yml\nemail: &a s3cret-value\n", .says = "`/traefik.yml`, line 1" },
        .{ .exit_code = 126, .stdout = "", .says = "could not read" },
    };
    for (cases) |case| {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try existingWith(&h, FILE_INSPECT);
        try h.on("traefik.$e", case.exit_code, case.stdout);
        try testing.expect(!try h.setup(SSL_PROXY, .{}));
        try h.says(case.says);
        try testing.expect(std.mem.indexOf(u8, h.output.written(), SETTINGS_SECRET) == null);
    }
}

test "what an existing Traefik lacks for ssl, or from inside" {
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try existingWith(&h, "null\n[\"--entrypoints.web.address=:80\",\"--providers.file.directory=/r\"]\nnet \n");
        try testing.expect(!try h.setup(SSL_PROXY, .{}));
        try h.says("no entrypoint on 443");
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try existingWith(&h, "null\n[\"--entrypoints.w.address=:443\",\"--providers.file.directory=/r\"]\nnet \n");
        try testing.expect(!try h.setup(SSL_PROXY, .{}));
        try h.says("no certificate resolver");
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try existingWith(&h, VPS_INSPECT);
        try h.on("docker exec", 1, "");
        try testing.expect(!try h.setup(PROXY, .{}));
        try h.says("must be a writable folder");
    }
}

test "ssl_redirect off needs plain HTTP to reach the app" {
    const plain: Config.Proxy = .{ .host = "a.example", .ssl = true, .ssl_redirect = false };
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try existingWith(&h, "null\n[\"--entrypoints.web.address=:80\",\"--entrypoints.web.http.redirections.entrypoint.to=websecure\",\"--entrypoints.websecure.address=:443\",\"--providers.file.directory=/r\",\"--certificatesresolvers.le.acme.email=a@b\"]\nnet \n");
        try testing.expect(!try h.setup(plain, .{}));
        try h.says("sends all of `web` to HTTPS itself");
        // Traefik is left as it is: no restart, no container touched.
        try testing.expect(!h.fake.ran("docker run"));
        try testing.expect(!h.fake.ran("docker rm"));
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try existingWith(&h, "null\n[\"--entrypoints.websecure.address=:443\",\"--providers.file.directory=/r\",\"--certificatesresolvers.le.acme.email=a@b\"]\nnet \n");
        try testing.expect(!try h.setup(plain, .{}));
        try h.says("`proxy.ssl_redirect: false`, and Traefik `t` has no entrypoint on 80");
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try existingWith(&h, VPS_INSPECT);
        try testing.expect(try h.setup(plain, .{}));
    }
}

test "an accessory's route needs Traefik too, when the app has none" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try newServer(&h);
    const config: Config = .{ .service = "s", .image = "i", .host = "h", .accessories = &.{.{ .name = "kc", .image = "k", .proxy = PROXY }} };
    try testing.expect(try run(h.arena.allocator(), h.fake.remote(), &h.output.writer, config, .{}));
    try testing.expect(h.fake.ran("docker run"));
    try h.says("traefik: started");
}

test "a new server with raw TCP ports: our Traefik publishes them, if nothing else holds them" {
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try newServer(&h);
        var proxy = PROXY;
        proxy.tcp = &.{60005};
        try testing.expect(try h.setup(proxy, .{}));
        try testing.expect(h.fake.ran("-p 60005:60005"));
        try testing.expect(h.fake.ran("--entrypoints.tcp-60005.address=:60005"));
        try h.says("on 80, 443 and 60005");
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try newServer(&h);
        try h.on("ss -ltn", 0, "LISTEN 0 1 0.0.0.0:60005 0.0.0.0:*\n");
        var proxy = PROXY;
        proxy.tcp = &.{60005};
        try testing.expect(!try h.setup(proxy, .{}));
        try h.says("port 60005 is held by a program this user cannot see");
        try testing.expect(!h.fake.ran("docker run"));
    }
}

test "two Traefiks, and another program on the ports, stop it" {
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try newServer(&h);
        try h.on("docker ps", 0, "a\ttraefik:3\tone\t0.0.0.0:80->80/tcp\tweb\nb\ttraefik:3\ttwo\t0.0.0.0:443->443/tcp\tweb\n");
        try testing.expect(!try h.setup(PROXY, .{}));
        try h.says("more than one Traefik");
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try newServer(&h);
        try h.on("ss -ltn", 0, "LISTEN 0 1 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=7,fd=6))\n");
        try testing.expect(!try h.setup(PROXY, .{}));
        try h.says("port 443 is held by the program `nginx`. Cowshed will not touch it");
        try testing.expect(!h.fake.ran("docker run"));
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try newServer(&h);
        try h.on("ss -ltn", 0, "tcp 0 0 0.0.0.0:80 0.0.0.0:* LISTEN 812/caddy\n");
        try testing.expect(!try h.setup(PROXY, .{}));
        try h.says("port 80 is held by the program `caddy`");
    }
}

test "a Traefik on other ports is not the server's; what holds 80 is named, whatever it is" {
    // Another proxy on 80 and 443, and a Traefik that serves only a raw TCP port.
    const RUNNING =
        "k1\tbasecamp/kamal-proxy:v0.9.0\tkamal-proxy\t0.0.0.0:80->80/tcp, [::]:80->80/tcp, 0.0.0.0:443->443/tcp, [::]:443->443/tcp\tkamal\n" ++
        "t1\ttraefik:v3.6.1\tapp-tcp\t80/tcp, 0.0.0.0:60005->60005/tcp, [::]:60005->60005/tcp\tkamal\n";
    const LISTEN = "LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:((\"docker-proxy\",pid=1,fd=8))\n" ++
        "LISTEN 0 4096 0.0.0.0:60005 0.0.0.0:* users:((\"docker-proxy\",pid=2,fd=8))\n";
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try newServer(&h);
        try h.on("docker ps", 0, RUNNING);
        try h.on("ss -ltn", 0, LISTEN);
        try testing.expect(!try h.setup(PROXY, .{}));
        try h.says("port 80 is held by the container `kamal-proxy` (basecamp/kamal-proxy:v0.9.0). Cowshed will not touch it");
        // Not read as the server's Traefik, and nothing started or changed.
        try testing.expect(!h.fake.ran("k1"));
        try testing.expect(!h.fake.ran("t1"));
        try testing.expect(!h.fake.ran("docker run"));
    }
    {
        // With 80 and 443 free, the raw TCP port's holder is named.
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try newServer(&h);
        try h.on("docker ps", 0, RUNNING[std.mem.indexOf(u8, RUNNING, "t1").?..]);
        try h.on("ss -ltn", 0, LISTEN[std.mem.indexOf(u8, LISTEN, "LISTEN 0 4096 0.0.0.0:60005").?..]);
        var proxy = PROXY;
        proxy.tcp = &.{60005};
        try testing.expect(!try h.setup(proxy, .{}));
        try h.says("port 60005 is held by the container `app-tcp` (traefik:v3.6.1)");
        try testing.expect(!h.fake.ran("docker run"));
    }
}

test "a Traefik on the host's network holds the ports itself, and is the server's" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try h.on("docker version", 0, "29\n");
    try h.on("mkdir -p", 0, "/home/u");
    try h.on("docker ps", 0, "abc\ttraefik:3\tt\t\thost\n");
    try h.on("docker inspect", 0, VPS_INSPECT);
    _ = try h.setup(SSL_PROXY, .{});
    try testing.expect(h.fake.ran("docker exec abc"));
    try testing.expect(!h.fake.ran("docker run"));
}

test "ssl with no email, on a new server, stops before anything starts" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try newServer(&h);
    try testing.expect(!try h.setup(.{ .host = "a", .ssl = true }, .{}));
    try h.says("set `proxy.acme_email`");
    try testing.expect(!h.fake.ran("docker run"));
}

test "our own Traefik, stopped, is only started again" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try newServer(&h);
    try h.on("docker inspect --format {{.State.Running}}", 0, "false\n");
    try testing.expect(try h.setup(PROXY, .{}));
    try testing.expect(h.fake.ran("docker start cowshed-traefik"));
    try testing.expect(!h.fake.ran("docker run"));
}

test "a failed start leaves no container behind" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try newServer(&h);
    try h.on("docker run", 125, "");
    try testing.expect(!try h.setup(PROXY, .{}));
    try h.says("could not start Traefik: the error");
    try testing.expect(h.fake.ran("docker rm -f cowshed-traefik"));
}

test "Docker: usable, unusable, missing without root, installed, failing" {
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try h.on("docker version", 1, "");
        try testing.expect(!try h.setup(null, .{}));
        try h.says("cannot use it");
        try testing.expect(!h.fake.ran("get.docker.com"));
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try h.on("docker version", 127, "");
        try h.on("command -v docker", 1, "");
        try h.on("sudo -n true", 1, "");
        try testing.expect(!try h.setup(null, .{}));
        try h.says("needs root or sudo");
        try testing.expect(!h.fake.ran("get.docker.com"));
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try h.on("docker version", 127, "");
        try h.on("command -v docker", 1, "");
        try testing.expect(try h.setup(null, .{ .dry_run = true }));
        try h.says("would be installed");
        try h.changedNothing();
    }
    {
        var h = Harness.create();
        defer h.deinit();
        h.start();
        try h.on("docker version", 127, "");
        try h.on("command -v docker", 1, "");
        try testing.expect(!try h.setup(null, .{}));
        try testing.expect(h.fake.ran("get.docker.com"));
        try h.says("installing Docker failed");
    }
}

test "folders that cannot be made stop it" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try h.on("docker version", 0, "29\n");
    try h.on("mkdir -p", 1, "");
    try testing.expect(!try h.setup(PROXY, .{}));
    try h.says("could not make ~/.cowshed: the error");
}

test "no proxy in the config: no Traefik is touched" {
    var h = Harness.create();
    defer h.deinit();
    h.start();
    try h.on("docker version", 0, "29\n");
    try testing.expect(try h.setup(null, .{}));
    try testing.expect(!h.fake.ran("docker ps"));
}
