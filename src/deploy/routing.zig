//! Health asked through Traefik, and a route file switched to a container: what a
//! deploy does for the app and a boot for an accessory with `proxy`.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Remote = @import("../remote/Remote.zig");
const docker = @import("../docker/commands.zig");
const detect = @import("../proxy/detect.zig");
const route = @import("../proxy/route.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = Remote.Error || Writer.Error;

/// How long Traefik gets to show a route. A change took up to 2.3 s when tested.
pub const CONFIRM_LIMIT_S = 15;
/// How often a wait says it is still waiting.
pub const PROGRESS_EVERY_S = 5;
const TRAEFIK_API = "http://127.0.0.1:8080/api/http/services";
const TRAEFIK_TCP_API = "http://127.0.0.1:8080/api/tcp/services";
const WRITE_ROUTE = "cat > \"$1/.$2.tmp\" && mv \"$1/.$2.tmp\" \"$1/$2\"";
const READ_ROUTE = "cat \"$1/$2\"";
pub const REMOVE_ROUTE = "rm -f \"$1/$2\"";
/// Files in the folder naming our router, ours aside: an earlier one would win.
const FIND_CLASH =
    \\cd "$1" && for f in *; do [ "$f" = "$2" ] || ! grep -q "$3:" "$f" 2>/dev/null || echo "$f"; done
;

pub const Context = struct {
    arena: Allocator,
    remote: Remote,
    out: *Writer,

    fn say(self: Context, comptime format: []const u8, args: anytype) Writer.Error!void {
        try self.out.print(format ++ "\n", args);
        try self.out.flush();
    }

    fn ask(self: Context, argv: []const []const u8) Remote.Error!Remote.Result {
        return self.remote.run(self.arena, .{ .argv = argv });
    }

    fn wait(self: Context, seconds: u32) Remote.Error!void {
        _ = try self.ask(&.{ "sleep", try std.fmt.allocPrint(self.arena, "{d}", .{seconds}) });
    }

    fn inTraefik(self: Context, traefik: detect.Traefik, script: []const u8, args: []const []const u8, stdin: ?[]const u8) Remote.Error!Remote.Result {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.arena, &.{ "docker", "exec", "-i", traefik.id, "sh", "-c", script, "sh" });
        try argv.appendSlice(self.arena, args);
        return self.remote.run(self.arena, .{ .argv = argv.items, .stdin = stdin });
    }
};

/// What a route sends where.
pub const Target = struct {
    /// Names its file and router: the service, or `<service>-<accessory>`.
    key: []const u8,
    proxy: Config.Proxy,
    container: []const u8,
};

pub fn isRunning(ctx: Context, name: []const u8) Remote.Error!bool {
    const state = try ctx.ask(try docker.containerState(ctx.arena, name));
    return state.ok() and std.mem.startsWith(u8, state.stdout, "true");
}

/// Asks its health path from inside Traefik, as traffic will reach it, until it
/// answers 2xx, exits or `limit_s` passes.
pub fn healthy(ctx: Context, traefik: detect.Traefik, name: []const u8, proxy: Config.Proxy, limit_s: u32) Error!bool {
    const health = proxy.health;
    const url = try std.fmt.allocPrint(ctx.arena, "http://{s}:{d}{s}", .{ name, proxy.app_port, health.path });
    try ctx.say("health: asking {s}, up to {d} s", .{ url, limit_s });
    const timeout = try std.fmt.allocPrint(ctx.arena, "{d}", .{health.timeout_s});
    var waited: u32 = 0;
    while (waited < limit_s) : (waited += health.interval_s) {
        if (!try isRunning(ctx, name)) {
            try ctx.say("health: {s} exited", .{name});
            return false;
        }
        const probe = try ctx.ask(&.{ "docker", "exec", traefik.id, "wget", "-q", "-O", "/dev/null", "-T", timeout, url });
        if (probe.ok()) return true;
        try ctx.wait(health.interval_s);
        const passed = waited + health.interval_s;
        if (passed % PROGRESS_EVERY_S < health.interval_s) {
            try ctx.say("health: not yet, {d} of {d} s", .{ passed, limit_s });
        }
    }
    return false;
}

/// Writes the route to `target.container` and waits for Traefik to take it. If it
/// does not, the route as it was is put back.
pub fn switchTo(ctx: Context, traefik: detect.Traefik, target: Target) Error!bool {
    const proxy = target.proxy;
    const file = try route.fileName(ctx.arena, target.key);
    const router = try route.routerName(ctx.arena, target.key);

    const clash = try ctx.inTraefik(traefik, FIND_CLASH, &.{ traefik.routes_dir, file, router }, null);
    const clashing = std.mem.trim(u8, clash.stdout, "\r\n ");
    if (clashing.len > 0) {
        try ctx.say("stopped: `{s}` in Traefik's folder also names the router `{s}`: an earlier file would win", .{ clashing, router });
        return false;
    }

    const previous = try ctx.inTraefik(traefik, READ_ROUTE, &.{ traefik.routes_dir, file }, null);
    const text = try route.render(ctx.arena, .{
        .service = target.key,
        .host = proxy.host,
        .container = target.container,
        .port = proxy.app_port,
        .entrypoint = if (proxy.ssl) traefik.https_entrypoint.? else traefik.http_entrypoint.?,
        .resolver = if (proxy.ssl) traefik.resolver else null,
        // Detection has already refused `ssl_redirect: false` with no HTTP entrypoint.
        .http_from = if (proxy.ssl) traefik.http_entrypoint else null,
        .redirect = proxy.ssl_redirect,
        .tcp = traefik.tcp,
    });
    try ctx.say("switch: writing the route {s}", .{file});
    const written = try ctx.inTraefik(traefik, WRITE_ROUTE, &.{ traefik.routes_dir, file }, text);
    if (!written.ok()) {
        try ctx.say("stopped: could not write the route: {s}", .{std.mem.trimEnd(u8, written.stderr, "\r\n")});
        return false;
    }

    if (!traefik.api) {
        // Nothing to ask. The longest change seen when tested took 2.3 s.
        try ctx.say("notice: Traefik's API is off: the switch is not confirmed", .{});
        try ctx.wait(3);
        return true;
    }
    try ctx.say("switch: waiting for Traefik to take it, up to {d} s", .{CONFIRM_LIMIT_S});
    if (try takenEverywhere(ctx, traefik, target.key, router, target.container)) {
        try ctx.say("switch: traffic goes to {s}", .{target.container});
        return true;
    }

    // What failed is thrown away next, so the route must not point at it.
    try ctx.say("switch: not taken, putting the route back", .{});
    if (previous.ok()) {
        _ = try ctx.inTraefik(traefik, WRITE_ROUTE, &.{ traefik.routes_dir, file }, previous.stdout);
    } else {
        _ = try ctx.inTraefik(traefik, REMOVE_ROUTE, &.{ traefik.routes_dir, file }, null);
    }
    try ctx.say("stopped: Traefik did not take the new route within {d} s. A broken file in `{s}` blocks every change there, and only Traefik's log says which: the route was put back", .{ CONFIRM_LIMIT_S, traefik.routes_dir });
    return false;
}

pub fn removeRoute(ctx: Context, traefik: detect.Traefik, key: []const u8) Error!bool {
    const file = try route.fileName(ctx.arena, key);
    const removed = try ctx.inTraefik(traefik, REMOVE_ROUTE, &.{ traefik.routes_dir, file }, null);
    return removed.ok();
}

/// The HTTP service, then each TCP one, sending to the container.
fn takenEverywhere(ctx: Context, traefik: detect.Traefik, key: []const u8, router: []const u8, name: []const u8) Error!bool {
    if (!try showsRoute(ctx, traefik, try std.fmt.allocPrint(ctx.arena, TRAEFIK_API ++ "/{s}@file", .{router}), name)) return false;
    for (traefik.tcp) |tcp| {
        const service = try route.tcpServiceName(ctx.arena, key, tcp.port);
        if (!try showsRoute(ctx, traefik, try std.fmt.allocPrint(ctx.arena, TRAEFIK_TCP_API ++ "/{s}@file", .{service}), name)) return false;
    }
    return true;
}

fn showsRoute(ctx: Context, traefik: detect.Traefik, url: []const u8, name: []const u8) Error!bool {
    var waited: u32 = 0;
    while (waited < CONFIRM_LIMIT_S) : (waited += 1) {
        const shown = try ctx.ask(&.{ "docker", "exec", traefik.id, "wget", "-qO-", url });
        if (shown.ok() and std.mem.indexOf(u8, shown.stdout, name) != null) return true;
        try ctx.wait(1);
        if (waited > 0 and waited % PROGRESS_EVERY_S == 0) {
            try ctx.say("switch: not yet, {d} of {d} s", .{ waited, CONFIRM_LIMIT_S });
        }
    }
    return false;
}
