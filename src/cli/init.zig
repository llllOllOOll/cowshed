//! `cowshed init`: starts a project with nothing of Cowshed's. It writes on this
//! machine only, reaches no server and never overwrites a file.

const std = @import("std");
const Config = @import("../config/Config.zig");
const check = @import("check.zig");
const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;

pub const Options = struct {
    /// The server. Without it, a name that cannot reach a real one.
    host: ?[]const u8 = null,
    /// Where the app answers. Without it, a name that cannot be a real one.
    domain: ?[]const u8 = null,
};

const SECRETS_PATH = ".cowshed/secrets";
const IGNORE_LINE = ".cowshed/secrets*";
const PLACEHOLDER_HOST = "server.example";
const PLACEHOLDER_DOMAIN = "app.example";
const DEFAULT_PORT = 80;
const MAX_FILE_BYTES = 1024 * 1024;

const SECRETS_TEMPLATE =
    \\# NAME=value lines, for the names under `env.secret` in config/deploy.yml.
    \\# Never in git. See docs/configuration.md.
    \\
;

const Facts = struct {
    service: []const u8,
    host: []const u8,
    domain: []const u8,
    port: u16,
};

/// In the current folder.
pub fn run(arena: Allocator, io: std.Io, out: *std.Io.Writer, options: Options) !bool {
    return runIn(arena, io, Dir.cwd(), out, options);
}

/// False when something is wrong; what is wrong has been written to `out`.
fn runIn(arena: Allocator, io: std.Io, dir: Dir, out: *std.Io.Writer, options: Options) !bool {
    if (exists(io, dir, check.DEFAULT_CONFIG_PATH)) {
        try out.print("stopped: {s} already exists; nothing was changed\n", .{check.DEFAULT_CONFIG_PATH});
        return false;
    }
    if (options.host) |host| {
        if (!isHostName(host)) {
            try out.print("stopped: `{s}` is not a server's name or address; nothing was changed\n", .{host});
            return false;
        }
    }
    if (options.domain) |domain| {
        if (!isHostName(domain)) {
            try out.print("stopped: `{s}` is not a domain; nothing was changed\n", .{domain});
            return false;
        }
    }

    const folder = try dir.realPathFileAlloc(io, ".", arena);
    const dockerfile = readOptional(arena, io, dir, "Dockerfile");
    const port = if (dockerfile) |text| exposedPort(text) else null;
    const facts: Facts = .{
        .service = try serviceName(arena, std.fs.path.basename(folder)),
        .host = options.host orelse PLACEHOLDER_HOST,
        .domain = options.domain orelse PLACEHOLDER_DOMAIN,
        .port = port orelse DEFAULT_PORT,
    };

    // What it writes must be what the rest of Cowshed reads.
    const text = try render(arena, facts);
    var problems: std.ArrayList(Config.Problem) = .empty;
    _ = Config.parse(arena, text, &problems) catch |err| switch (err) {
        error.InvalidConfig => {
            for (problems.items) |problem| try out.print("stopped: {s}; nothing was changed\n", .{problem.message});
            return false;
        },
        else => |e| return e,
    };

    try dir.createDirPath(io, "config");
    try dir.writeFile(io, .{ .sub_path = check.DEFAULT_CONFIG_PATH, .data = text });
    try out.print("wrote {s}: service {s}, port {d}\n", .{ check.DEFAULT_CONFIG_PATH, facts.service, facts.port });

    if (exists(io, dir, SECRETS_PATH)) {
        try out.print("kept {s}, already there\n", .{SECRETS_PATH});
    } else {
        try dir.createDirPath(io, ".cowshed");
        try dir.writeFile(io, .{ .sub_path = SECRETS_PATH, .data = SECRETS_TEMPLATE });
        try out.print("wrote {s}\n", .{SECRETS_PATH});
    }

    const ignore = readOptional(arena, io, dir, ".gitignore") orelse "";
    if (ignoresSecrets(ignore)) {
        try out.writeAll(".gitignore already keeps the secrets out of git\n");
    } else {
        const separator: []const u8 = if (ignore.len > 0 and ignore[ignore.len - 1] != '\n') "\n" else "";
        const updated = try std.fmt.allocPrint(arena, "{s}{s}{s}\n", .{ ignore, separator, IGNORE_LINE });
        try dir.writeFile(io, .{ .sub_path = ".gitignore", .data = updated });
        try out.print("added {s} to .gitignore\n", .{IGNORE_LINE});
    }

    if (dockerfile == null) {
        try out.writeAll("notice: no Dockerfile here, and a deploy builds from one\n");
    } else if (port == null) {
        try out.print("notice: the Dockerfile exposes no port: {d} assumed, see `proxy.app_port`\n", .{DEFAULT_PORT});
    }
    if (options.host == null) try out.print("to fill in: the server, now `{s}`\n", .{PLACEHOLDER_HOST});
    if (options.domain == null) try out.print("to fill in: the domain, now `{s}`\n", .{PLACEHOLDER_DOMAIN});
    try out.writeAll("to check: the app must answer 2xx on `proxy.healthcheck.path`\n");
    try out.writeAll("next: cowshed check --remote, cowshed setup --dry-run\n");
    return true;
}

fn render(arena: Allocator, facts: Facts) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\service: {[service]s}
        \\image: {[service]s}
        \\servers:
        \\  web:
        \\    hosts:
        \\      - {[host]s}
        \\ssh:
        \\  user: root
        \\proxy:
        \\  host: {[domain]s}
        \\  app_port: {[port]d}
        \\  ssl: true
        \\  # Needed only when `setup` has to install Traefik:
        \\  # acme_email: me@example.com
        \\  healthcheck:
        \\    path: /up  # Must answer 2xx before it gets traffic
        \\# What must outlive a version, such as a database file:
        \\# volumes:
        \\#   - /var/lib/{[service]s}:/data
        \\env:
        \\  clear:
        \\    # MODE: production
        \\  secret:
        \\    # - API_TOKEN  # From .cowshed/secrets
        \\
    , .{ .service = facts.service, .host = facts.host, .domain = facts.domain, .port = facts.port });
}

fn exists(io: std.Io, dir: Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn readOptional(arena: Allocator, io: std.Io, dir: Dir, path: []const u8) ?[]const u8 {
    return dir.readFileAlloc(io, path, arena, .limited(MAX_FILE_BYTES)) catch null;
}

/// A folder's name made valid: lower case, and `-` for anything else.
fn serviceName(arena: Allocator, folder: []const u8) Allocator.Error![]const u8 {
    const name = try arena.alloc(u8, folder.len);
    for (folder, name) |c, *to| {
        const lower = std.ascii.toLower(c);
        to.* = if (std.ascii.isAlphanumeric(lower)) lower else '-';
    }
    const trimmed = std.mem.trim(u8, name, "-");
    return if (trimmed.len > 0) trimmed else "app";
}

/// The port of the last `EXPOSE`, which is the final stage's; null without a number.
fn exposedPort(dockerfile: []const u8) ?u16 {
    var found: ?u16 = null;
    var lines = std.mem.splitScalar(u8, dockerfile, '\n');
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = words.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(first, "FROM") and !std.ascii.eqlIgnoreCase(first, "EXPOSE")) continue;
        // A new stage: what an earlier one exposed is not in the image.
        if (std.ascii.eqlIgnoreCase(first, "FROM")) {
            found = null;
            continue;
        }
        const word = words.next() orelse continue;
        const end = std.mem.indexOfScalar(u8, word, '/') orelse word.len;
        found = std.fmt.parseInt(u16, word[0..end], 10) catch found;
    }
    return found;
}

fn ignoresSecrets(gitignore: []const u8) bool {
    var lines = std.mem.splitScalar(u8, gitignore, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '/') line = line[1..];
        for ([_][]const u8{ IGNORE_LINE, SECRETS_PATH, ".cowshed", ".cowshed/", ".cowshed/*" }) |covers| {
            if (std.mem.eql(u8, line, covers)) return true;
        }
    }
    return false;
}

fn isHostName(text: []const u8) bool {
    if (text.len == 0 or text[0] == '-') return false;
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-') return false;
    }
    return true;
}

const testing = std.testing;

const Project = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    output: std.Io.Writer.Allocating = undefined,

    fn create() Project {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}) };
    }

    fn deinit(self: *Project) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn write(self: *Project, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn read(self: *Project, path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(testing.io, path, self.arena.allocator(), .limited(MAX_FILE_BYTES));
    }

    fn init(self: *Project, options: Options) !bool {
        const a = self.arena.allocator();
        self.output = .init(a);
        return runIn(a, testing.io, self.tmp.dir, &self.output.writer, options);
    }

    fn says(self: *Project, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.output.written(), text) == null) {
            std.debug.print("output:\n{s}\n", .{self.output.written()});
            return error.TestExpectedOutput;
        }
    }
};

test "a bare project: valid config, secrets kept out of git, what to fill in told" {
    var p = Project.create();
    defer p.deinit();
    try p.write("Dockerfile", "FROM a\nEXPOSE 8000\n");
    try testing.expect(try p.init(.{}));

    const a = p.arena.allocator();
    var problems: std.ArrayList(Config.Problem) = .empty;
    const config = try Config.parse(a, try p.read("config/deploy.yml"), &problems);
    try testing.expectEqualStrings(PLACEHOLDER_HOST, config.host);
    try testing.expectEqualStrings(PLACEHOLDER_DOMAIN, config.proxy.?.host);
    try testing.expectEqual(8000, config.proxy.?.app_port);
    try testing.expect(config.proxy.?.ssl);
    try testing.expectEqualStrings(config.service, config.image);

    try testing.expect(std.mem.indexOf(u8, try p.read(".gitignore"), IGNORE_LINE) != null);
    try testing.expect(std.mem.indexOf(u8, try p.read(SECRETS_PATH), "NAME=value") != null);
    try p.says("to fill in: the server");
    try p.says("to fill in: the domain");
}

test "the server and the domain, when given" {
    var p = Project.create();
    defer p.deinit();
    try p.write("Dockerfile", "FROM a\n");
    try testing.expect(try p.init(.{ .host = "1.2.3.4", .domain = "a.example.com" }));
    const text = try p.read("config/deploy.yml");
    try testing.expect(std.mem.indexOf(u8, text, "- 1.2.3.4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "host: a.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, p.output.written(), "to fill in") == null);
    try p.says("exposes no port");
}

test "nothing is overwritten" {
    var p = Project.create();
    defer p.deinit();
    try p.tmp.dir.createDirPath(testing.io, "config");
    try p.write("config/deploy.yml", "mine");
    try testing.expect(!try p.init(.{}));
    try testing.expectEqualStrings("mine", try p.read("config/deploy.yml"));
    try testing.expectError(error.FileNotFound, p.read(".gitignore"));
    try p.says("already exists");
}

test "existing secrets and .gitignore are kept" {
    var p = Project.create();
    defer p.deinit();
    try p.tmp.dir.createDirPath(testing.io, ".cowshed");
    try p.write(SECRETS_PATH, "A=1\n");
    try p.write(".gitignore", "node_modules");
    try testing.expect(try p.init(.{}));
    try testing.expectEqualStrings("A=1\n", try p.read(SECRETS_PATH));
    try testing.expectEqualStrings("node_modules\n" ++ IGNORE_LINE ++ "\n", try p.read(".gitignore"));
    try p.says("kept .cowshed/secrets");
    try p.says("no Dockerfile");
}

test "a name that could break the file is refused, with nothing written" {
    var p = Project.create();
    defer p.deinit();
    try testing.expect(!try p.init(.{ .host = "a\nnope: 1" }));
    try testing.expect(!try p.init(.{ .domain = "a b" }));
    try testing.expectError(error.FileNotFound, p.read("config/deploy.yml"));
    try testing.expectError(error.FileNotFound, p.read(".gitignore"));
}

test "the service from a folder's name" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{ .{ "My_App 2", "my-app-2" }, .{ "pbx", "pbx" }, .{ "__", "app" } };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        try testing.expectEqualStrings(case[1], try serviceName(arena.allocator(), case[0]));
    }
}

test "the port a Dockerfile exposes" {
    try testing.expectEqual(8000, exposedPort("FROM a\nEXPOSE 8000\n"));
    try testing.expectEqual(9000, exposedPort("from a\nexpose 9000/tcp 9001\n"));
    try testing.expectEqual(3000, exposedPort("FROM a\nEXPOSE 1\nFROM b\nEXPOSE 3000\n"));
    try testing.expectEqual(null, exposedPort("FROM a\nEXPOSE 1\nFROM b\n"));
    try testing.expectEqual(null, exposedPort("FROM a\nEXPOSE $PORT\n"));
}

test "what keeps the secrets out of git" {
    try testing.expect(ignoresSecrets("a\n.cowshed/secrets*\n"));
    try testing.expect(ignoresSecrets("/.cowshed/\n"));
    try testing.expect(!ignoresSecrets("secrets\n# .cowshed/secrets\n"));
}
