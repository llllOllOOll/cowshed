//! What a running Traefik is set up to do, read from its flags or its settings file,
//! and the Traefik Cowshed starts on a server that has none.

const std = @import("std");
const yaml = @import("../config/yaml.zig");
const Allocator = std.mem.Allocator;

/// The version the risk tests ran on (docs/spikes.md). Pinned: `latest` floats.
pub const OWN_IMAGE = "traefik:3.6.6";
pub const OWN_NAME = "cowshed-traefik";
pub const OWN_NETWORK = "cowshed";
pub const OWN_RESOLVER = "letsencrypt";
/// Traefik serves its API on the entrypoint named `traefik`.
pub const PRIVATE_API_ADDRESS = "127.0.0.1:8080";
const OWN_ROUTES_MOUNT = "/etc/traefik/routes";
const OWN_ACME_MOUNT = "/etc/letsencrypt";

/// More than a server's Traefik has in practice; beyond it, the rest go unseen.
pub const MAX_ENTRYPOINTS = 16;
pub const Entrypoint = struct { name: []const u8, port: u16 };

pub const Flags = struct {
    /// Every TCP entrypoint, by the port it listens on.
    entrypoints: [MAX_ENTRYPOINTS]Entrypoint = undefined,
    entrypoint_count: usize = 0,
    http_entrypoint: ?[]const u8 = null,
    https_entrypoint: ?[]const u8 = null,
    /// The HTTP entrypoint sends everything to HTTPS itself
    /// (`entrypoints.<it>.http.redirections`), ahead of any router: no plain
    /// HTTP reaches an app through it.
    http_redirects: bool = false,
    resolver: ?[]const u8 = null,
    routes_dir: ?[]const u8 = null,
    /// A single file rather than a folder: a rename into place would break it.
    routes_file: bool = false,
    watch_off: bool = false,
    api: bool = false,
    docker_network: ?[]const u8 = null,
    /// `--configFile`: Traefik then reads that file, whatever else its flags say.
    config_file: ?[]const u8 = null,

    /// With no entrypoint in its flags, it is set up by a file or the environment.
    pub fn found(self: Flags) bool {
        return self.http_entrypoint != null or self.https_entrypoint != null;
    }

    fn addEntrypoint(self: *Flags, name: []const u8, address: []const u8) void {
        // UDP shares no port with TCP's routers.
        if (std.mem.endsWith(u8, address, "/udp")) return;
        const bare = if (std.mem.endsWith(u8, address, "/tcp")) address[0 .. address.len - 4] else address;
        if (std.mem.endsWith(u8, bare, ":80")) self.http_entrypoint = name;
        if (std.mem.endsWith(u8, bare, ":443")) self.https_entrypoint = name;
        const colon = std.mem.lastIndexOfScalar(u8, bare, ':') orelse return;
        const port = std.fmt.parseInt(u16, bare[colon + 1 ..], 10) catch return;
        if (self.entrypoint_count == MAX_ENTRYPOINTS) return;
        self.entrypoints[self.entrypoint_count] = .{ .name = name, .port = port };
        self.entrypoint_count += 1;
    }

    /// The entrypoint listening on this TCP port, if any.
    pub fn entrypointOn(self: Flags, port: u16) ?[]const u8 {
        for (self.entrypoints[0..self.entrypoint_count]) |entrypoint| {
            if (entrypoint.port == port) return entrypoint.name;
        }
        return null;
    }
};

/// Traefik's flags are case-insensitive; the names inside them are not.
fn matchPrefix(key: []const u8, prefix: []const u8) ?[]const u8 {
    if (key.len < prefix.len or !std.ascii.eqlIgnoreCase(key[0..prefix.len], prefix)) return null;
    return key[prefix.len..];
}

pub fn parseFlags(args: []const []const u8) Flags {
    var flags: Flags = .{};
    for (args) |arg| {
        const text = matchPrefix(arg, "--") orelse continue;
        const equals = std.mem.indexOfScalar(u8, text, '=');
        const key = if (equals) |i| text[0..i] else text;
        const value = if (equals) |i| text[i + 1 ..] else "true";

        if (matchPrefix(key, "entrypoints.")) |rest| {
            const name_end = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
            if (!std.ascii.eqlIgnoreCase(rest[name_end + 1 ..], "address")) continue;
            flags.addEntrypoint(rest[0..name_end], value);
        } else if (matchPrefix(key, "certificatesresolvers.")) |rest| {
            const name_end = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
            if (flags.resolver == null) flags.resolver = rest[0..name_end];
        } else if (std.ascii.eqlIgnoreCase(key, "configfile")) {
            flags.config_file = value;
        } else if (std.ascii.eqlIgnoreCase(key, "providers.file.directory")) {
            flags.routes_dir = value;
        } else if (std.ascii.eqlIgnoreCase(key, "providers.file.filename")) {
            flags.routes_file = true;
        } else if (std.ascii.eqlIgnoreCase(key, "providers.file.watch")) {
            flags.watch_off = std.ascii.eqlIgnoreCase(value, "false");
        } else if (std.ascii.eqlIgnoreCase(key, "providers.docker.network")) {
            flags.docker_network = value;
        } else if (std.ascii.eqlIgnoreCase(key, "api") or std.ascii.eqlIgnoreCase(key, "api.insecure")) {
            flags.api = !std.ascii.eqlIgnoreCase(value, "false");
        }
    }
    // Once the HTTP entrypoint is known, whatever order the flags came in.
    if (flags.http_entrypoint) |http| {
        for (args) |arg| {
            const text = matchPrefix(arg, "--") orelse continue;
            const key = text[0 .. std.mem.indexOfScalar(u8, text, '=') orelse text.len];
            const rest = matchPrefix(key, "entrypoints.") orelse continue;
            if (rest.len <= http.len or !std.mem.eql(u8, rest[0..http.len], http) or rest[http.len] != '.') continue;
            if (std.ascii.eqlIgnoreCase(rest[http.len + 1 ..], "http.redirections.entrypoint.to")) flags.http_redirects = true;
        }
    }
    return flags;
}

/// The same, from Traefik's settings file. Only these keys are read: the file may
/// hold secrets, and none of it is kept or shown.
pub fn parseSettings(root: yaml.Value) Flags {
    var flags: Flags = .{};
    if (field(root, "entrypoints")) |entrypoints| {
        if (entrypoints == .map) {
            for (entrypoints.map) |entry| {
                const address = scalar(entry.value, "address") orelse continue;
                flags.addEntrypoint(entry.key, address);
            }
            if (flags.http_entrypoint) |http| {
                for (entrypoints.map) |entry| {
                    if (!std.mem.eql(u8, entry.key, http)) continue;
                    const redirections = field(field(entry.value, "http") orelse break, "redirections") orelse break;
                    flags.http_redirects = scalar(field(redirections, "entrypoint") orelse break, "to") != null;
                }
            }
        }
    }
    if (field(root, "certificatesresolvers")) |resolvers| {
        if (resolvers == .map and resolvers.map.len > 0) flags.resolver = resolvers.map[0].key;
    }
    if (field(root, "providers")) |providers| {
        if (field(providers, "file")) |file| {
            flags.routes_dir = scalar(file, "directory");
            flags.routes_file = scalar(file, "filename") != null;
            if (scalar(file, "watch")) |watch| flags.watch_off = std.ascii.eqlIgnoreCase(watch, "false");
        }
        if (field(providers, "docker")) |docker| flags.docker_network = scalar(docker, "network");
    }
    if (field(root, "api")) |api| {
        if (scalar(api, "insecure")) |insecure| flags.api = std.ascii.eqlIgnoreCase(insecure, "true");
    }
    return flags;
}

/// The address of the entrypoint that serves Traefik's API, if the file sets one.
pub fn apiAddress(root: yaml.Value) ?[]const u8 {
    const entrypoints = field(root, "entrypoints") orelse return null;
    const own = field(entrypoints, "traefik") orelse return null;
    return scalar(own, "address");
}

/// Traefik's keys are case-insensitive.
fn field(value: yaml.Value, key: []const u8) ?yaml.Value {
    if (value != .map) return null;
    for (value.map) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, key)) return entry.value;
    }
    return null;
}

fn scalar(value: yaml.Value, key: []const u8) ?[]const u8 {
    const found = field(value, key) orelse return null;
    return if (found == .scalar) found.scalar else null;
}

/// `true` for `traefik`, `traefik:3`, `registry.example/x/traefik:latest`.
pub fn isTraefikImage(image: []const u8) bool {
    return std.mem.eql(u8, imageName(image), "traefik");
}

fn imageName(image: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, image, '/')) |i| image[i + 1 ..] else image;
    const tag = std.mem.indexOfScalar(u8, base, ':') orelse return base;
    return base[0..tag];
}

/// No tag, or `latest`: a recreated container may bring another version.
pub fn isFloating(image: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, image, '/')) |i| image[i + 1 ..] else image;
    const tag = std.mem.indexOfScalar(u8, base, ':') orelse return true;
    return std.mem.eql(u8, base[tag + 1 ..], "latest");
}

/// Whether a line of `ss -ltn` or `netstat -ltn` shows `port` as a local address.
pub fn listensOn(listing: []const u8, port: u16) bool {
    var buffer: [8]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buffer, ":{d}", .{port}) catch unreachable;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        while (words.next()) |word| {
            if (std.mem.endsWith(u8, word, suffix)) return true;
        }
    }
    return false;
}

/// `routes` and `acme` are folders on the server. Without an email it has no
/// certificates: an app on `ssl: true` needs one, which `setup` checks first.
/// The entrypoint our own Traefik has for a raw TCP port.
pub fn ownTcpEntrypoint(arena: Allocator, port: u16) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "tcp-{d}", .{port});
}

/// With `tcp`, an entrypoint and a published port for each.
pub fn ownRunCommand(arena: Allocator, routes: []const u8, acme: []const u8, acme_email: ?[]const u8, tcp: []const u16) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "docker",         "run",                                                               "-d",
        "--name",         OWN_NAME,                                                            "--restart",
        "unless-stopped", "--network",                                                         OWN_NETWORK,
        "-p",             "80:80",                                                             "-p",
        "443:443",        "-v",                                                                try std.fmt.allocPrint(arena, "{s}:{s}", .{ routes, OWN_ROUTES_MOUNT }),
        "-v",             try std.fmt.allocPrint(arena, "{s}:{s}", .{ acme, OWN_ACME_MOUNT }),
    });
    for (tcp) |port| try argv.appendSlice(arena, &.{ "-p", try std.fmt.allocPrint(arena, "{d}:{d}", .{ port, port }) });
    try argv.appendSlice(arena, &.{
        OWN_IMAGE,
        "--global.checkNewVersion=false",
        "--global.sendAnonymousUsage=false",
        // Its API answers only inside its own container: no neighbour reads it.
        "--api.insecure=true",
        "--entrypoints.traefik.address=" ++ PRIVATE_API_ADDRESS,
        "--entrypoints.web.address=:80",
        "--entrypoints.websecure.address=:443",
        "--providers.file.directory=" ++ OWN_ROUTES_MOUNT,
    });
    for (tcp) |port| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "--entrypoints.{s}.address=:{d}", .{ try ownTcpEntrypoint(arena, port), port }));
    }
    if (acme_email) |email| {
        const prefix = "--certificatesresolvers." ++ OWN_RESOLVER ++ ".acme.";
        try argv.appendSlice(arena, &.{
            try std.fmt.allocPrint(arena, prefix ++ "email={s}", .{email}),
            prefix ++ "storage=" ++ OWN_ACME_MOUNT ++ "/acme.json",
            prefix ++ "httpchallenge.entrypoint=web",
        });
    }
    return argv.items;
}

const testing = std.testing;

test "the flags of the owner's VPS" {
    const flags = parseFlags(&.{
        "--global.checkNewVersion=false",
        "--api.insecure=true",
        "--entrypoints.web.address=:80",
        "--entrypoints.web.http.redirections.entryPoint.to=websecure",
        "--entrypoints.websecure.address=:443",
        "--providers.docker=true",
        "--providers.file.directory=/etc/traefik",
        "--certificatesresolvers.letsencrypt.acme.email=x@y",
        "--certificatesresolvers.letsencrypt.acme.storage=/etc/letsencrypt/acme.json",
    });
    try testing.expectEqualStrings("web", flags.http_entrypoint.?);
    try testing.expectEqualStrings("websecure", flags.https_entrypoint.?);
    try testing.expectEqualStrings("letsencrypt", flags.resolver.?);
    try testing.expectEqualStrings("/etc/traefik", flags.routes_dir.?);
    try testing.expect(flags.api);
    try testing.expect(flags.found());
    try testing.expect(flags.http_redirects);
}

test "a redirection is the HTTP entrypoint's, whatever order and case the flags come in" {
    try testing.expect(parseFlags(&.{ "--entryPoints.Web.HTTP.Redirections.EntryPoint.To=s", "--entrypoints.Web.address=:80" }).http_redirects);
    // Another entrypoint's redirection, or a name that only starts the same, is not its.
    try testing.expect(!parseFlags(&.{ "--entrypoints.web.address=:80", "--entrypoints.alt.http.redirections.entrypoint.to=s" }).http_redirects);
    try testing.expect(!parseFlags(&.{ "--entrypoints.web.address=:80", "--entrypoints.web2.http.redirections.entrypoint.to=s" }).http_redirects);
    try testing.expect(!parseFlags(&.{ "--entrypoints.web.address=:80", "--entrypoints.websecure.address=:443" }).http_redirects);
}

test "flags are case-insensitive, names are not" {
    const flags = parseFlags(&.{ "--entryPoints.Secure.address=0.0.0.0:443", "--certificatesResolvers.LE.acme.email=a" });
    try testing.expectEqualStrings("Secure", flags.https_entrypoint.?);
    try testing.expectEqualStrings("LE", flags.resolver.?);
}

test "a single route file, watching off, no API, no flags" {
    try testing.expect(parseFlags(&.{"--providers.file.filename=/a.yml"}).routes_file);
    try testing.expect(parseFlags(&.{"--providers.file.watch=false"}).watch_off);
    try testing.expect(!parseFlags(&.{"--api.insecure=false"}).api);
    try testing.expect(!parseFlags(&.{}).found());
}

fn settings(arena: *std.heap.ArenaAllocator, source: []const u8) !Flags {
    var failure: yaml.Failure = undefined;
    return parseSettings(try yaml.parseWith(arena.allocator(), source, &failure, .{ .foreign = true }));
}

test "a settings file with no routes folder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const flags = try settings(&arena,
        \\api:
        \\  dashboard: true
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
        \\      email: me@x
    );
    try testing.expectEqualStrings("http", flags.http_entrypoint.?);
    try testing.expectEqualStrings("https", flags.https_entrypoint.?);
    try testing.expectEqualStrings("letsencrypt", flags.resolver.?);
    try testing.expect(flags.routes_dir == null);
    try testing.expect(!flags.api);
}

test "a settings file with everything, in any case, among what it does not need" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const flags = try settings(&arena,
        \\---
        \\API:
        \\  insecure: true
        \\entrypoints:
        \\  web:
        \\    address: 0.0.0.0:80/tcp
        \\  secure:
        \\    address: ":443"
        \\    forwardedHeaders:
        \\      trustedIPs: ["10.0.0.0/8"]
        \\  call:
        \\    address: ":443/udp"
        \\providers:
        \\  file:
        \\    directory: /routes
        \\    watch: false
        \\  docker:
        \\    network: web
    );
    try testing.expectEqualStrings("web", flags.http_entrypoint.?);
    try testing.expectEqualStrings("secure", flags.https_entrypoint.?);
    try testing.expectEqualStrings("/routes", flags.routes_dir.?);
    try testing.expectEqualStrings("web", flags.docker_network.?);
    try testing.expect(flags.watch_off);
    try testing.expect(flags.api);
    try testing.expect(!flags.http_redirects);
}

test "a settings file whose HTTP entrypoint redirects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const flags = try settings(&arena,
        \\entryPoints:
        \\  websecure:
        \\    address: ":443"
        \\  web:
        \\    address: ":80"
        \\    http:
        \\      redirections:
        \\        entryPoint:
        \\          to: websecure
        \\          scheme: https
    );
    try testing.expect(flags.http_redirects);
}

test "a settings file with one route file, and the flag naming a settings file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try settings(&arena, "providers:\n  file:\n    filename: /a.yml\n")).routes_file);
    try testing.expectEqualStrings("/t.yml", parseFlags(&.{"--configFile=/t.yml"}).config_file.?);
}

test "image names" {
    try testing.expect(isTraefikImage("traefik"));
    try testing.expect(isTraefikImage("traefik:latest"));
    try testing.expect(isTraefikImage("registry.example:5000/x/traefik:3"));
    try testing.expect(!isTraefikImage("my-traefik-app:1"));
    try testing.expect(isFloating("traefik"));
    try testing.expect(isFloating("traefik:latest"));
    try testing.expect(!isFloating("traefik:3.6.6"));
}

test "what listens" {
    const listing =
        \\State  Recv-Q Send-Q Local Address:Port Peer Address:Port
        \\LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*
        \\LISTEN 0 4096 [::]:8080 [::]:*
        \\LISTEN 0 4096 *:443 *:*
    ;
    try testing.expect(listensOn(listing, 22));
    try testing.expect(listensOn(listing, 443));
    try testing.expect(!listensOn(listing, 80));
}

test "our own Traefik: pinned, without the Docker socket, and with a resolver only given an email" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bare = try ownRunCommand(a, "/r", "/a", null, &.{});
    const with_email = try ownRunCommand(a, "/r", "/a", "me@x", &.{});
    const line = try std.mem.join(a, " ", with_email);
    try testing.expect(std.mem.indexOf(u8, line, "traefik:3.6.6") != null);
    try testing.expect(std.mem.indexOf(u8, line, "docker.sock") == null);
    try testing.expect(std.mem.indexOf(u8, line, "/r:/etc/traefik/routes") != null);
    try testing.expect(std.mem.indexOf(u8, line, "acme.email=me@x") != null);
    const flags = parseFlags(with_email);
    try testing.expectEqualStrings("letsencrypt", flags.resolver.?);
    try testing.expect(parseFlags(bare).resolver == null);
}

test "our own Traefik with raw TCP ports: published, and an entrypoint each that we then find" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try ownRunCommand(a, "/r", "/a", null, &.{ 60005, 1883 });
    const line = try std.mem.join(a, " ", argv);
    try testing.expect(std.mem.indexOf(u8, line, "-p 60005:60005 -p 1883:1883 traefik:3.6.6") != null);
    const flags = parseFlags(argv);
    try testing.expectEqualStrings("tcp-60005", flags.entrypointOn(60005).?);
    try testing.expectEqualStrings("tcp-1883", flags.entrypointOn(1883).?);
    try testing.expectEqualStrings("web", flags.entrypointOn(80).?);
    try testing.expect(flags.entrypointOn(9) == null);
}

test "entrypoints by port, from flags and a settings file; UDP is not one" {
    const flags = parseFlags(&.{ "--entrypoints.autocgi.address=:60005", "--entrypoints.call.address=:5060/udp", "--entrypoints.sip.address=0.0.0.0:5061/tcp" });
    try testing.expectEqualStrings("autocgi", flags.entrypointOn(60005).?);
    try testing.expectEqualStrings("sip", flags.entrypointOn(5061).?);
    try testing.expect(flags.entrypointOn(5060) == null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const from_file = try settings(&arena,
        \\entryPoints:
        \\  autocgi:
        \\    address: ":60005"
    );
    try testing.expectEqualStrings("autocgi", from_file.entrypointOn(60005).?);
}
