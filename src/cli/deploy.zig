//! `cowshed deploy`: what happens on this machine before the core takes over, and
//! the look from outside after it.

const std = @import("std");
const Config = @import("../config/Config.zig");
const secrets = @import("../config/secrets.zig");
const Ssh = @import("../remote/Ssh.zig");
const core = @import("../deploy/deploy.zig");
const local = @import("../image/local.zig");
const send = @import("../image/send.zig");
const check = @import("check.zig");
const log_file = @import("log.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    config_path: []const u8 = check.DEFAULT_CONFIG_PATH,
    /// Above the config's own `secrets`.
    secrets_path: ?[]const u8 = null,
    dirty: bool = false,
    /// Deploys even if nothing changed.
    force: bool = false,
    /// Runs the config's backup and migration before the new version.
    migrate: bool = false,
    /// Builds and sends the version, and starts nothing.
    stage: bool = false,
};

const MAX_SECRETS_BYTES = 1024 * 1024;
const MAX_NEW_SHOWN = 20;

const SecretsContext = struct {
    io: std.Io,
    environ: *const std.process.Environ.Map,
    /// From `env_file`, `NAME=value` joined by NUL.
    loaded: []const u8 = "",

    /// What is already in the environment wins.
    fn getEnv(ptr: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *SecretsContext = @ptrCast(@alignCast(ptr));
        if (self.environ.get(name)) |value| return value;
        return valueIn(self.loaded, name);
    }

    fn shell(ptr: *anyopaque, arena: Allocator, command: []const u8) anyerror![]const u8 {
        const self: *SecretsContext = @ptrCast(@alignCast(ptr));
        return local.shell(arena, self.io, command);
    }
};

/// False when something is wrong; what is wrong has been written to `out`.
pub fn run(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, screen: *std.Io.Writer, options: Options) !bool {
    const config = try check.readConfig(arena, io, screen, options.config_path) orelse return false;
    const log = try log_file.open(arena, io, environ, screen, config.service, "deploy");
    defer log.close() catch {};
    const out = &log.writer;
    for (config.notices) |notice| try out.print("notice: {s}\n", .{notice});
    if (config.accessories.len > 0) try out.writeAll("notice: accessories are left as they are: `cowshed accessory boot` starts them\n");

    if (options.stage and options.migrate) {
        try out.writeAll("stopped: `--stage` starts nothing, so it runs no migration: stage, try it with `cowshed exec`, then `cowshed deploy --migrate`\n");
        return false;
    }
    if (options.migrate and config.migrate == null) {
        try out.writeAll("stopped: `--migrate` needs `migrate` in the config: nothing changed\n");
        return false;
    }
    if (!options.migrate and !options.stage and config.migrate != null) {
        try out.writeAll("notice: no `--migrate`: no backup and no migration. If this version has one, deploy with it\n");
    }

    var ssh: Ssh = .{ .io = io, .user = config.ssh.user, .host = config.host, .port = config.ssh.port, .keys = config.ssh.keys };

    // From what is committed, unless asked for what is here as it is.
    const clean = !options.dirty;
    var made_from: ?[]const u8 = null;
    var sources: []const local.Source = &.{};
    var version: []const u8 = undefined;
    if (clean) {
        switch (try local.readSources(arena, io, config.sources, config.branch)) {
            .failed => |why| {
                try out.print("stopped: {s}\n", .{why});
                return false;
            },
            .sources => |found| sources = found,
        }
        version = sources[0].short;
        made_from = try local.fingerprint(arena, sources);
        for (sources) |source| {
            try out.print("source: {s} at {s}, last changed in {s}\n", .{ source.name, source.short, source.touched });
            if (source.uncommitted > 0) {
                try out.print("notice: {s} has {d} files that differ here: they are not part of this deploy\n", .{ source.name, source.uncommitted });
                const shown = @min(source.untracked.len, MAX_NEW_SHOWN);
                for (source.untracked[0..shown]) |path| try out.print("notice: new, not in git, left out: {s}\n", .{path});
                if (source.untracked.len > shown) try out.print("notice: and {d} more new ones: see `git status`\n", .{source.untracked.len - shown});
            }
        }
        const live = core.liveFrom(arena, ssh.remote(), config.service, made_from.?) catch |err| {
            try out.print("server {s}: {t}: {s}\n", .{ config.host, err, ssh.connection_error });
            return false;
        };
        if (live and options.stage) {
            try out.print("nothing to stage: what runs was made from {s}\n", .{made_from.?});
            return true;
        }
        if (live and !options.force) {
            try out.print("nothing changed: what runs was made from {s}. `--force` to deploy it again\n", .{made_from.?});
            return true;
        }
    } else {
        version = local.dirtyVersion(arena, io) orelse {
            try out.writeAll("stopped: a version comes from git: this is no repository with a commit\n");
            return false;
        };
        try out.writeAll("notice: --dirty: building this folder as it is, what git ignores included unless .dockerignore leaves it out\n");
    }

    // Before anything slow, and nothing reaches the server if one is missing. A
    // version only staged has no container to give them to.
    const resolved = if (options.stage) &.{} else try resolveSecrets(arena, io, environ, out, config, config.env.secret, options.secrets_path orelse config.secrets orelse secrets.DEFAULT_PATH) orelse return false;

    var build_folder: ?[]const u8 = null;
    if (clean) {
        try out.writeAll("copies: making clean copies of the sources\n");
        build_folder = try local.prepareCopies(arena, io, environ, config.service, sources) orelse {
            try out.writeAll("stopped: could not make clean copies of the sources\n");
            return false;
        };
    }

    if (config.builder.before) |command| {
        try out.print("build: {s}\n", .{command});
        try out.flush();
        if (!try local.runBefore(arena, io, command, version, build_folder)) {
            try out.writeAll("stopped: `builder.before` failed\n");
            return false;
        }
    }
    const tag = try std.fmt.allocPrint(arena, "{s}:{s}", .{ config.image, version });
    try out.print("build: {s}\n", .{tag});
    try out.flush();
    if (!try local.build(arena, io, config.builder, config.service, tag, build_folder)) {
        try out.writeAll("stopped: the image did not build\n");
        return false;
    }
    const folder = local.save(arena, io, tag) orelse {
        try out.writeAll("stopped: could not save the image\n");
        return false;
    };
    defer local.removeFolder(arena, io, folder);

    var sender: send.Sender = .{ .io = io, .folder = folder, .tag = tag, .service = config.service, .version = version };
    const done = core.run(arena, ssh.remote(), out, .{
        .config = config,
        .version = version,
        .sources = made_from,
        .who = local.who(arena, io, environ),
        .secrets = resolved,
        .image = .{ .ptr = &sender, .sendFn = send.Sender.send },
        .migrate = options.migrate,
        .stage = options.stage,
    }) catch |err| switch (err) {
        error.ConnectionFailed, error.TransportFailed => {
            try out.print("server {s}: {t}: {s}. See `cowshed lock status`\n", .{ config.host, err, ssh.connection_error });
            return false;
        },
        else => |e| return e,
    };
    if (done) try lookFromOutside(arena, io, out, config);
    return done;
}

/// `entries` as the config writes them (`NAME` or `NAME:SOURCE`): the app's, or an
/// accessory's.
pub fn resolveSecrets(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, out: *std.Io.Writer, config: Config, entries: []const []const u8, path: []const u8) !?[]const core.Secret {
    if (entries.len == 0) return &.{};
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(MAX_SECRETS_BYTES)) catch |err| {
        try out.print("stopped: {s}: {t}\n", .{ path, err });
        return null;
    };
    var wanted: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| try wanted.append(arena, secrets.sourceOf(entry));

    var context_state: SecretsContext = .{ .io = io, .environ = environ };
    if (config.env_file) |written| {
        const env_path = try local.expandHome(arena, environ, written);
        std.Io.Dir.cwd().access(io, env_path, .{}) catch {
            try out.print("stopped: `env_file` {s} is not there\n", .{env_path});
            return null;
        };
        context_state.loaded = try local.loadEnvFile(arena, io, env_path) orelse {
            try out.print("stopped: `env_file` {s} failed when run by `sh`\n", .{env_path});
            return null;
        };
        try out.print("secrets: variables from {s}\n", .{env_path});
    }
    var failure: secrets.Failure = undefined;
    const values = secrets.resolve(arena, source, wanted.items, .{
        .userdata = &context_state,
        .getEnv = SecretsContext.getEnv,
        .shell = SecretsContext.shell,
    }, &failure) catch |err| switch (err) {
        error.InvalidSecrets => {
            switch (failure) {
                .missing_variable => |f| try out.print("stopped: secret `{s}` uses `${s}`, which is not set\n", .{ f.secret, f.variable }),
                .command_failed => |f| try out.print("stopped: the command of secret `{s}` failed\n", .{f.secret}),
                .not_defined => |f| try out.print("stopped: secret `{s}` is not in {s}\n", .{ f.secret, path }),
                .unterminated => |f| try out.print("stopped: secret `{s}` has an opening without its end\n", .{f.secret}),
            }
            return null;
        },
        else => |e| return e,
    };
    var out_secrets: std.ArrayList(core.Secret) = .empty;
    for (entries, values) |entry, value| {
        try out_secrets.append(arena, .{ .name = secrets.targetOf(entry), .value = value.value });
    }
    return out_secrets.items;
}

fn valueIn(loaded: []const u8, name: []const u8) ?[]const u8 {
    var entries = std.mem.splitScalar(u8, loaded, 0);
    while (entries.next()) |entry| {
        const equals = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..equals], name)) return entry[equals + 1 ..];
    }
    return null;
}

/// Told, not fatal: DNS or a first certificate may take longer than this looks.
fn lookFromOutside(arena: Allocator, io: std.Io, out: *std.Io.Writer, config: Config) !void {
    const proxy = config.proxy orelse return;
    const scheme: []const u8 = if (proxy.ssl) "https" else "http";
    const url = try std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ scheme, proxy.host, proxy.health.path });
    if (local.askOutside(arena, io, url)) |status| {
        try out.print("from outside: {s} -> {s}\n", .{ url, status });
    } else {
        try out.print("notice: from outside: {s} did not answer\n", .{url});
    }
}

test "a variable from an env file, by its whole name" {
    const loaded = "AB=1\x00A=two=2\x00";
    try std.testing.expectEqualStrings("two=2", valueIn(loaded, "A").?);
    try std.testing.expectEqualStrings("1", valueIn(loaded, "AB").?);
    try std.testing.expect(valueIn(loaded, "B") == null);
}
