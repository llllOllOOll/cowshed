//! A project's `config/deploy.yml`, what Cowshed needs to deploy it. An
//! option Cowshed does not know is refused by name, never ignored.

const std = @import("std");
const yaml = @import("yaml.zig");
const Allocator = std.mem.Allocator;
const Config = @This();

pub const DEFAULT_ROLE = "web";
const DEFAULT_SSH_USER = "root";
const DEFAULT_SSH_PORT = 22;
const DEFAULT_APP_PORT = 80;
const DEFAULT_HEALTH_PATH = "/up";
const DEFAULT_HEALTH_INTERVAL_S = 1;
const DEFAULT_HEALTH_TIMEOUT_S = 5;
const DEFAULT_DEPLOY_TIMEOUT_S = 30;
const DEFAULT_DRAIN_TIMEOUT_S = 30;
const DEFAULT_CONTEXT = ".";
const DEFAULT_DOCKERFILE = "Dockerfile";

pub const Pair = struct { name: []const u8, value: []const u8 };

pub const Env = struct {
    clear: []const Pair = &.{},
    /// `NAME`, or `NAME:SECRET` to read it from another secret.
    secret: []const []const u8 = &.{},
};

pub const Health = struct {
    path: []const u8 = DEFAULT_HEALTH_PATH,
    interval_s: u32 = DEFAULT_HEALTH_INTERVAL_S,
    timeout_s: u32 = DEFAULT_HEALTH_TIMEOUT_S,
};

pub const Proxy = struct {
    host: []const u8,
    app_port: u16 = DEFAULT_APP_PORT,
    ssl: bool = false,
    ssl_redirect: bool = true,
    forward_headers: ?bool = null,
    health: Health = .{},
    /// Only when `cowshed setup` installs Traefik: Let's Encrypt asks for it.
    acme_email: ?[]const u8 = null,
};

pub const Ssh = struct {
    user: []const u8 = DEFAULT_SSH_USER,
    port: u16 = DEFAULT_SSH_PORT,
    keys: []const []const u8 = &.{},
};

pub const Builder = struct {
    arch: ?[]const u8 = null,
    context: []const u8 = DEFAULT_CONTEXT,
    dockerfile: []const u8 = DEFAULT_DOCKERFILE,
    /// A command run on this machine first, which produces the context.
    before: ?[]const u8 = null,
};

pub const Accessory = struct {
    name: []const u8,
    image: []const u8,
    host: []const u8,
    port: ?[]const u8 = null,
    cmd: ?[]const u8 = null,
    env: Env = .{},
    files: []const []const u8 = &.{},
    directories: []const []const u8 = &.{},
    volumes: []const []const u8 = &.{},
    proxy: ?Proxy = null,
};

service: []const u8,
image: []const u8,
role: []const u8 = DEFAULT_ROLE,
host: []const u8,
cmd: ?[]const u8 = null,
labels: []const Pair = &.{},
/// `/on/server:/in/container` or `name:/in/container`, with `:ro` and such after.
/// What it holds is never Cowshed's: nothing here removes it.
volumes: []const []const u8 = &.{},
cpus: ?[]const u8 = null,
memory: ?[]const u8 = null,
env: Env = .{},
proxy: ?Proxy = null,
ssh: Ssh = .{},
builder: Builder = .{},
deploy_timeout_s: u32 = DEFAULT_DEPLOY_TIMEOUT_S,
drain_timeout_s: u32 = DEFAULT_DRAIN_TIMEOUT_S,
/// A container from before Cowshed, stopped once its traffic has moved.
replaces: ?[]const u8 = null,
/// The secrets file, if not the default.
secrets: ?[]const u8 = null,
/// A shell file setting the variables the secrets file reads. It runs on this machine.
env_file: ?[]const u8 = null,
/// Builds from this branch, whatever is checked out here. HEAD otherwise.
branch: ?[]const u8 = null,
/// What makes up the project besides this folder, also from other repositories,
/// relative to here. Copied clean like it, and part of knowing whether it changed.
sources: []const []const u8 = &.{},
accessories: []const Accessory = &.{},
/// What was read and has no effect here (`registry`, `boot`), to tell the user.
notices: []const []const u8 = &.{},

pub const Problem = struct {
    line: u32,
    message: []const u8,
};

/// Everything lives in `arena`. On `error.InvalidConfig`, `problems` lists them all.
pub fn parse(arena: Allocator, source: []const u8, problems: *std.ArrayList(Problem)) (Allocator.Error || error{InvalidConfig})!Config {
    var failure: yaml.Failure = undefined;
    const root = yaml.parse(arena, source, &failure) catch |err| switch (err) {
        error.InvalidYaml => {
            try problems.append(arena, .{ .line = failure.line, .message = failure.message });
            return error.InvalidConfig;
        },
        else => |e| return e,
    };
    var reader: Reader = .{ .arena = arena, .problems = problems };
    const config = try reader.read(root);
    if (problems.items.len > 0) return error.InvalidConfig;
    return config;
}

const Reader = struct {
    arena: Allocator,
    problems: *std.ArrayList(Problem),
    notices: std.ArrayList([]const u8) = .empty,

    fn problem(self: *Reader, line: u32, comptime format: []const u8, args: anytype) Allocator.Error!void {
        try self.problems.append(self.arena, .{
            .line = line,
            .message = try std.fmt.allocPrint(self.arena, format, args),
        });
    }

    fn checkKeys(self: *Reader, value: yaml.Value, line: u32, path: []const u8, allowed: []const []const u8) Allocator.Error!void {
        if (value == .none) return;
        if (value != .map) return self.problem(line, "`{s}` must be a map", .{path});
        for (value.map) |entry| {
            for (allowed) |name| {
                if (std.mem.eql(u8, entry.key, name)) break;
            } else {
                const separator: []const u8 = if (path.len > 0) "." else "";
                try self.problem(entry.line, "unknown option `{s}{s}{s}`", .{ path, separator, entry.key });
            }
        }
    }

    fn string(self: *Reader, parent: yaml.Value, key: []const u8, path: []const u8) Allocator.Error!?[]const u8 {
        const entry = parent.get(key) orelse return null;
        switch (entry.value) {
            .scalar => |text| return text,
            .none => return null,
            else => {
                try self.problem(entry.line, "`{s}.{s}` must be a single value", .{ path, key });
                return null;
            },
        }
    }

    fn required(self: *Reader, parent: yaml.Value, key: []const u8, path: []const u8, line: u32) Allocator.Error![]const u8 {
        if (try self.string(parent, key, path)) |text| return text;
        const separator: []const u8 = if (path.len > 0) "." else "";
        try self.problem(line, "`{s}{s}{s}` is required", .{ path, separator, key });
        return "";
    }

    fn number(self: *Reader, comptime T: type, parent: yaml.Value, key: []const u8, path: []const u8, default: T) Allocator.Error!T {
        const text = (try self.string(parent, key, path)) orelse return default;
        return std.fmt.parseInt(T, text, 10) catch {
            try self.problem(parent.get(key).?.line, "`{s}.{s}` must be a number", .{ path, key });
            return default;
        };
    }

    fn boolean(self: *Reader, parent: yaml.Value, key: []const u8, path: []const u8) Allocator.Error!?bool {
        const text = (try self.string(parent, key, path)) orelse return null;
        if (std.mem.eql(u8, text, "true")) return true;
        if (std.mem.eql(u8, text, "false")) return false;
        try self.problem(parent.get(key).?.line, "`{s}.{s}` must be true or false", .{ path, key });
        return null;
    }

    fn strings(self: *Reader, parent: yaml.Value, key: []const u8, path: []const u8) Allocator.Error![]const []const u8 {
        const entry = parent.get(key) orelse return &.{};
        if (entry.value == .none) return &.{};
        if (entry.value != .list) {
            try self.problem(entry.line, "`{s}.{s}` must be a list", .{ path, key });
            return &.{};
        }
        var out: std.ArrayList([]const u8) = .empty;
        for (entry.value.list) |item| {
            if (item.value != .scalar) {
                try self.problem(item.line, "`{s}.{s}` must be a list of single values", .{ path, key });
                continue;
            }
            try out.append(self.arena, item.value.scalar);
        }
        return out.items;
    }

    fn pairs(self: *Reader, value: yaml.Value, line: u32, path: []const u8) Allocator.Error![]const Pair {
        if (value == .none) return &.{};
        if (value != .map) {
            try self.problem(line, "`{s}` must be a map", .{path});
            return &.{};
        }
        var out: std.ArrayList(Pair) = .empty;
        for (value.map) |entry| {
            if (entry.value != .scalar) {
                try self.problem(entry.line, "`{s}.{s}` must be a single value", .{ path, entry.key });
                continue;
            }
            try out.append(self.arena, .{ .name = entry.key, .value = entry.value.scalar });
        }
        return out.items;
    }

    fn readEnv(self: *Reader, parent: yaml.Value, path: []const u8) Allocator.Error!Env {
        const entry = parent.get("env") orelse return .{};
        const value = entry.value;
        const env_path = try std.fmt.allocPrint(self.arena, "{s}env", .{path});
        // Without `clear` or `secret`, the whole map is the clear variables.
        if (value.get("clear") == null and value.get("secret") == null) {
            return .{ .clear = try self.pairs(value, entry.line, env_path) };
        }
        try self.checkKeys(value, entry.line, env_path, &.{ "clear", "secret" });
        var env: Env = .{ .secret = try self.strings(value, "secret", env_path) };
        if (value.get("clear")) |clear| {
            env.clear = try self.pairs(clear.value, clear.line, try std.fmt.allocPrint(self.arena, "{s}.clear", .{env_path}));
        }
        return env;
    }

    fn readProxy(self: *Reader, parent: yaml.Value, path: []const u8) Allocator.Error!?Proxy {
        const entry = parent.get("proxy") orelse return null;
        const value = entry.value;
        const proxy_path = try std.fmt.allocPrint(self.arena, "{s}proxy", .{path});
        try self.checkKeys(value, entry.line, proxy_path, &.{ "host", "app_port", "ssl", "ssl_redirect", "forward_headers", "healthcheck", "acme_email" });
        var proxy: Proxy = .{
            .host = try self.required(value, "host", proxy_path, entry.line),
            .app_port = try self.number(u16, value, "app_port", proxy_path, DEFAULT_APP_PORT),
            .ssl = (try self.boolean(value, "ssl", proxy_path)) orelse false,
            .ssl_redirect = (try self.boolean(value, "ssl_redirect", proxy_path)) orelse true,
            .forward_headers = try self.boolean(value, "forward_headers", proxy_path),
            .acme_email = try self.string(value, "acme_email", proxy_path),
        };
        if (value.get("healthcheck")) |health| {
            const health_path = try std.fmt.allocPrint(self.arena, "{s}.healthcheck", .{proxy_path});
            try self.checkKeys(health.value, health.line, health_path, &.{ "path", "interval", "timeout" });
            proxy.health = .{
                .path = (try self.string(health.value, "path", health_path)) orelse DEFAULT_HEALTH_PATH,
                .interval_s = try self.number(u32, health.value, "interval", health_path, DEFAULT_HEALTH_INTERVAL_S),
                .timeout_s = try self.number(u32, health.value, "timeout", health_path, DEFAULT_HEALTH_TIMEOUT_S),
            };
        }
        return proxy;
    }

    fn readAccessory(self: *Reader, entry: yaml.Entry) Allocator.Error!Accessory {
        const value = entry.value;
        const path = try std.fmt.allocPrint(self.arena, "accessories.{s}", .{entry.key});
        try self.checkKeys(value, entry.line, path, &.{ "image", "host", "port", "cmd", "env", "files", "directories", "volumes", "proxy" });
        return .{
            .name = entry.key,
            .image = try self.required(value, "image", path, entry.line),
            .host = try self.required(value, "host", path, entry.line),
            .port = try self.string(value, "port", path),
            .cmd = try self.string(value, "cmd", path),
            .env = try self.readEnv(value, try std.fmt.allocPrint(self.arena, "{s}.", .{path})),
            .files = try self.strings(value, "files", path),
            .directories = try self.strings(value, "directories", path),
            .volumes = try self.strings(value, "volumes", path),
            .proxy = try self.readProxy(value, try std.fmt.allocPrint(self.arena, "{s}.", .{path})),
        };
    }

    fn read(self: *Reader, root: yaml.Value) Allocator.Error!Config {
        try self.checkKeys(root, 1, "", &.{
            "service",        "image",         "servers",  "registry", "builder", "env",
            "proxy",          "ssh",           "boot",     "cpus",     "memory",  "accessories",
            "deploy_timeout", "drain_timeout", "replaces", "secrets",  "branch",  "secrets",
            "sources",        "volumes",       "env_file",
        });

        var config: Config = .{
            .service = try self.required(root, "service", "", 1),
            .image = try self.required(root, "image", "", 1),
            .host = "",
            .cpus = try self.string(root, "cpus", ""),
            .memory = try self.string(root, "memory", ""),
            .replaces = try self.string(root, "replaces", ""),
            .secrets = try self.string(root, "secrets", ""),
            .env_file = try self.string(root, "env_file", ""),
            .branch = try self.string(root, "branch", ""),
            .sources = try self.strings(root, "sources", ""),
            .volumes = try self.strings(root, "volumes", ""),
            .env = try self.readEnv(root, ""),
            .proxy = try self.readProxy(root, ""),
            .deploy_timeout_s = try self.number(u32, root, "deploy_timeout", "", DEFAULT_DEPLOY_TIMEOUT_S),
            .drain_timeout_s = try self.number(u32, root, "drain_timeout", "", DEFAULT_DRAIN_TIMEOUT_S),
        };
        try self.readServers(root, &config);
        try self.checkNames(root, config);
        if (root.get("volumes")) |entry| {
            if (entry.value == .list) {
                for (entry.value.list, 0..) |item, i| {
                    if (i < config.volumes.len and !isVolume(config.volumes[i])) {
                        try self.problem(item.line, "a volume is `/on/server:/in/container` or `name:/in/container`, with `:ro`, `:rw`, `:z` or `:Z` after: `{s}`", .{config.volumes[i]});
                    }
                }
            }
        }

        if (root.get("ssh")) |ssh| {
            try self.checkKeys(ssh.value, ssh.line, "ssh", &.{ "user", "port", "keys" });
            config.ssh = .{
                .user = (try self.string(ssh.value, "user", "ssh")) orelse DEFAULT_SSH_USER,
                .port = try self.number(u16, ssh.value, "port", "ssh", DEFAULT_SSH_PORT),
                .keys = try self.strings(ssh.value, "keys", "ssh"),
            };
        }
        if (root.get("builder")) |builder| {
            try self.checkKeys(builder.value, builder.line, "builder", &.{ "arch", "context", "dockerfile", "before" });
            config.builder = .{
                .arch = try self.string(builder.value, "arch", "builder"),
                .context = (try self.string(builder.value, "context", "builder")) orelse DEFAULT_CONTEXT,
                .dockerfile = (try self.string(builder.value, "dockerfile", "builder")) orelse DEFAULT_DOCKERFILE,
                .before = try self.string(builder.value, "before", "builder"),
            };
        }
        if (root.get("accessories")) |accessories| {
            if (accessories.value == .map) {
                var out: std.ArrayList(Accessory) = .empty;
                for (accessories.value.map) |entry| try out.append(self.arena, try self.readAccessory(entry));
                config.accessories = out.items;
            } else if (accessories.value != .none) {
                try self.problem(accessories.line, "`accessories` must be a map", .{});
            }
        }
        if (root.get("registry") != null) {
            try self.notices.append(self.arena, "`registry` is ignored: images go directly to the server");
        }
        if (root.get("boot") != null) {
            try self.notices.append(self.arena, "`boot` is ignored: there is one host");
        }
        config.notices = self.notices.items;
        return config;
    }

    /// These reach container names, file names and routing rules.
    fn checkNames(self: *Reader, root: yaml.Value, config: Config) Allocator.Error!void {
        if (config.service.len > 0 and !isSafeName(config.service)) {
            try self.problem(root.get("service").?.line, "`service` may have only letters, digits, `-`, `_` and `.`", .{});
        }
        if (config.proxy) |proxy| {
            if (proxy.host.len > 0 and !isSafeName(proxy.host)) {
                try self.problem(root.get("proxy").?.line, "`proxy.host` must be one host name", .{});
            }
            if (proxy.forward_headers != null) {
                try self.notices.append(self.arena, "`proxy.forward_headers` is ignored: Traefik sets those headers");
            }
        }
    }

    fn readServers(self: *Reader, root: yaml.Value, config: *Config) Allocator.Error!void {
        const servers = root.get("servers") orelse {
            try self.problem(1, "`servers` is required", .{});
            return;
        };
        // `servers:` may be the list of hosts itself.
        if (servers.value == .list) {
            config.host = try self.oneHost(servers.value.list, servers.line);
            return;
        }
        if (servers.value != .map or servers.value.map.len == 0) {
            try self.problem(servers.line, "`servers` must name a role and its hosts", .{});
            return;
        }
        if (servers.value.map.len > 1) {
            try self.problem(servers.line, "more than one role is not supported yet", .{});
            return;
        }
        const role = servers.value.map[0];
        config.role = role.key;
        const path = try std.fmt.allocPrint(self.arena, "servers.{s}", .{role.key});
        if (role.value == .list) {
            config.host = try self.oneHost(role.value.list, role.line);
            return;
        }
        try self.checkKeys(role.value, role.line, path, &.{ "hosts", "labels", "cmd" });
        const hosts = role.value.get("hosts") orelse {
            try self.problem(role.line, "`{s}.hosts` is required", .{path});
            return;
        };
        if (hosts.value != .list) {
            try self.problem(hosts.line, "`{s}.hosts` must be a list", .{path});
            return;
        }
        config.host = try self.oneHost(hosts.value.list, hosts.line);
        config.cmd = try self.string(role.value, "cmd", path);
        if (role.value.get("labels")) |labels| {
            config.labels = try self.pairs(labels.value, labels.line, try std.fmt.allocPrint(self.arena, "{s}.labels", .{path}));
        }
    }

    fn oneHost(self: *Reader, hosts: []const yaml.Item, line: u32) Allocator.Error![]const u8 {
        if (hosts.len != 1) {
            try self.problem(line, "exactly one host is supported for now, found {d}", .{hosts.len});
            return "";
        }
        if (hosts[0].value != .scalar) {
            try self.problem(hosts[0].line, "a host must be a single value", .{});
            return "";
        }
        return hosts[0].value.scalar;
    }
};

/// Whether a deploy builds from clean copies, rather than this folder as it is.
/// Both sides are required: a container path alone would be a volume no version
/// finds again. A relative path or `~` would not mean what it seems on the server.
fn isVolume(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, ':');
    const source = parts.next().?;
    const target = parts.next() orelse return false;
    if (source.len == 0 or target.len < 2 or target[0] != '/') return false;
    if (source[0] != '/' and !isSafeName(source)) return false;
    if (source[0] == '.') return false;
    if (parts.next()) |options| {
        if (parts.next() != null) return false;
        var each = std.mem.splitScalar(u8, options, ',');
        while (each.next()) |option| {
            for ([_][]const u8{ "ro", "rw", "z", "Z" }) |known| {
                if (std.mem.eql(u8, option, known)) break;
            } else return false;
        }
    }
    return true;
}

pub fn isSafeName(name: []const u8) bool {
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return name.len > 0;
}

const testing = std.testing;

const GAME =
    \\service: arena
    \\image: seven/arena
    \\servers:
    \\  web:
    \\    hosts:
    \\      - spiderme.org
    \\    cmd: --port 7790
    \\    labels:
    \\      traefik.enable: "true"
    \\proxy:
    \\  host: arena.spiderme.org
    \\  app_port: 7790
    \\  ssl: true
    \\  healthcheck:
    \\    path: /
    \\    interval: 2
    \\env:
    \\  clear:
    \\    PORT: 7790
    \\  secret:
    \\    - TOKEN
    \\    - DB_PASSWORD:POSTGRES_PASSWORD
    \\ssh:
    \\  user: seven
    \\  keys:
    \\    - ~/.ssh/id
    \\builder:
    \\  before: tools/stage.sh
    \\  context: out
    \\cpus: 2
    \\memory: 1g
    \\drain_timeout: 10
    \\registry:
    \\  username: me
    \\  password:
    \\    - REGISTRY_PASSWORD
    \\
;

fn expectProblem(source: []const u8, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    try testing.expectError(error.InvalidConfig, parse(arena.allocator(), source, &problems));
    for (problems.items) |found| {
        if (std.mem.eql(u8, found.message, message)) return;
    }
    std.debug.print("got: {any}\n", .{problems.items});
    return error.TestExpectedProblem;
}

const MINIMAL = "service: a\nimage: b\nservers:\n  - h\n";

test "a whole config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    const config = try parse(arena.allocator(), GAME, &problems);
    try testing.expectEqualStrings("arena", config.service);
    try testing.expectEqualStrings("web", config.role);
    try testing.expectEqualStrings("spiderme.org", config.host);
    try testing.expectEqualStrings("--port 7790", config.cmd.?);
    try testing.expectEqualStrings("traefik.enable", config.labels[0].name);
    try testing.expectEqual(7790, config.proxy.?.app_port);
    try testing.expect(config.proxy.?.ssl);
    try testing.expectEqualStrings("/", config.proxy.?.health.path);
    try testing.expectEqual(2, config.proxy.?.health.interval_s);
    try testing.expectEqual(5, config.proxy.?.health.timeout_s);
    try testing.expectEqualStrings("PORT", config.env.clear[0].name);
    try testing.expectEqualStrings("DB_PASSWORD:POSTGRES_PASSWORD", config.env.secret[1]);
    try testing.expectEqualStrings("seven", config.ssh.user);
    try testing.expectEqualStrings("tools/stage.sh", config.builder.before.?);
    try testing.expectEqualStrings("1g", config.memory.?);
    try testing.expectEqual(10, config.drain_timeout_s);
    try testing.expectEqual(30, config.deploy_timeout_s);
    try testing.expectEqual(1, config.notices.len);
}

test "the defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    const config = try parse(arena.allocator(), MINIMAL, &problems);
    try testing.expectEqualStrings("h", config.host);
    try testing.expectEqualStrings("root", config.ssh.user);
    try testing.expectEqual(22, config.ssh.port);
    try testing.expectEqualStrings(".", config.builder.context);
    try testing.expect(config.proxy == null);
}

test "a project in a monorepo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    const config = try parse(arena.allocator(), MINIMAL ++ "branch: main\nsources:\n  - .\n  - ../../engine\n", &problems);
    try testing.expectEqualStrings("main", config.branch.?);
    try testing.expect(config.secrets == null);
    try testing.expectEqualStrings("../../engine", config.sources[1]);
}

test "an env without clear or secret is all clear" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    const config = try parse(arena.allocator(), MINIMAL ++ "env:\n  A: 1\n", &problems);
    try testing.expectEqualStrings("A", config.env.clear[0].name);
    try testing.expectEqualStrings("1", config.env.clear[0].value);
}

test "volumes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    const config = try parse(arena.allocator(), MINIMAL ++ "volumes:\n  - /srv/a b:/data\n  - named:/data2:ro\n  - /x:/y:ro,Z\n", &problems);
    try testing.expectEqual(3, config.volumes.len);
    try testing.expectEqualStrings("/srv/a b:/data", config.volumes[0]);
    for ([_][]const u8{ "/data", "./a:/data", "~/a:/data", "../a:/data", "a/b:/data", ":/data", "/a:data", "/a:/", "/a:/b:nope", "/a:/b:ro:z" }) |bad| {
        const source = try std.fmt.allocPrint(arena.allocator(), MINIMAL ++ "volumes:\n  - \"{s}\"\n", .{bad});
        problems = .empty;
        try testing.expectError(error.InvalidConfig, parse(arena.allocator(), source, &problems));
        try testing.expect(std.mem.indexOf(u8, problems.items[0].message, "a volume is") != null);
    }
    try expectProblem(MINIMAL ++ "volumes: /a:/b\n", "`.volumes` must be a list");
}

test "an accessory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    const config = try parse(arena.allocator(), MINIMAL ++
        \\accessories:
        \\  db:
        \\    image: postgres
        \\    host: h
        \\    port: 127.0.0.1:5432:5432
        \\    env:
        \\      secret:
        \\        - POSTGRES_PASSWORD
        \\    directories:
        \\      - data:/var/lib/postgresql/data
        \\    proxy:
        \\      host: db.example
    , &problems);
    const db = config.accessories[0];
    try testing.expectEqualStrings("db", db.name);
    try testing.expectEqualStrings("POSTGRES_PASSWORD", db.env.secret[0]);
    try testing.expectEqualStrings("db.example", db.proxy.?.host);
}

test "an unknown option is refused by its whole name" {
    try expectProblem(MINIMAL ++ "nope:\n  - a\n", "unknown option `nope`");
    try expectProblem(MINIMAL ++ "proxy:\n  host: a\n  buffering: 1\n", "unknown option `proxy.buffering`");
    try expectProblem(MINIMAL ++ "proxy:\n  host: a\n  healthcheck:\n    cmd: x\n", "unknown option `proxy.healthcheck.cmd`");
    try expectProblem("service: a\nimage: b\nservers:\n  web:\n    hosts:\n      - h\n    options: 1\n", "unknown option `servers.web.options`");
    try expectProblem(MINIMAL ++ "accessories:\n  db:\n    image: a\n    host: h\n    roles: 1\n", "unknown option `accessories.db.roles`");
}

test "what is required, and wrong values" {
    try expectProblem("image: b\nservers:\n  - h\n", "`service` is required");
    try expectProblem("service: a\nservers:\n  - h\n", "`image` is required");
    try expectProblem("service: a\nimage: b\n", "`servers` is required");
    try expectProblem(MINIMAL ++ "proxy:\n  ssl: true\n", "`proxy.host` is required");
    try expectProblem(MINIMAL ++ "proxy:\n  host: a\n  app_port: x\n", "`proxy.app_port` must be a number");
    try expectProblem(MINIMAL ++ "proxy:\n  host: a\n  ssl: yes\n", "`proxy.ssl` must be true or false");
}

test "names that reach commands and rules" {
    try expectProblem("service: a b\nimage: i\nservers:\n  - h\n", "`service` may have only letters, digits, `-`, `_` and `.`");
    try expectProblem(MINIMAL ++ "proxy:\n  host: a`b\n", "`proxy.host` must be one host name");
}

test "several hosts or roles are refused for now" {
    try expectProblem("service: a\nimage: b\nservers:\n  - h\n  - i\n", "exactly one host is supported for now, found 2");
    try expectProblem("service: a\nimage: b\nservers:\n  web:\n    - h\n  job:\n    - h\n", "more than one role is not supported yet");
}

test "every problem is reported at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    try testing.expectError(error.InvalidConfig, parse(arena.allocator(), "image: b\nfoo: 1\n", &problems));
    try testing.expectEqual(3, problems.items.len);
}

test "bad YAML reaches the problems with its line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var problems: std.ArrayList(Problem) = .empty;
    try testing.expectError(error.InvalidConfig, parse(arena.allocator(), "service: a\nb: &x 1\n", &problems));
    try testing.expectEqual(2, problems.items[0].line);
}
