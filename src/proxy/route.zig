//! An app's route, one file holding its routers and service, so a switch is one
//! rename (docs/spikes.md says why each setting is here).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Above a labelled router of the same rule, for an app moving from labels.
const PRIORITY = 1000;
/// Without this, Traefik's pool keeps idle connections to the old container for
/// about 95 s, and draining could not tell them from real ones.
const IDLE_TIMEOUT = "3s";

pub const Route = struct {
    service: []const u8,
    host: []const u8,
    container: []const u8,
    port: u16,
    /// Where it answers: the HTTPS entrypoint when `resolver` is set, else HTTP.
    entrypoint: []const u8,
    resolver: ?[]const u8 = null,
    /// With TLS, the HTTP entrypoint answering too: redirecting to HTTPS, or
    /// with `redirect` off, reaching the app as plain HTTP.
    http_from: ?[]const u8 = null,
    redirect: bool = true,
};

pub fn fileName(arena: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "cowshed-{s}.yml", .{service});
}

pub fn routerName(arena: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "cowshed-{s}", .{service});
}

pub fn render(arena: Allocator, route: Route) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    renderTo(&out.writer, route) catch return error.OutOfMemory;
    return out.written();
}

fn renderTo(w: *std.Io.Writer, route: Route) std.Io.Writer.Error!void {
    const name = route.service;
    try w.print(
        \\http:
        \\  routers:
        \\    cowshed-{s}:
        \\      rule: "Host(`{s}`)"
        \\      entryPoints:
        \\        - {s}
        \\      service: cowshed-{s}
        \\      priority: {d}
        \\
    , .{ name, route.host, route.entrypoint, name, PRIORITY });
    if (route.resolver) |resolver| {
        try w.print(
            \\      tls:
            \\        certResolver: {s}
            \\
        , .{resolver});
    }
    if (route.http_from) |entrypoint| {
        try w.print(
            \\    cowshed-{s}-http:
            \\      rule: "Host(`{s}`)"
            \\      entryPoints:
            \\        - {s}
            \\
        , .{ name, route.host, entrypoint });
        if (route.redirect) {
            try w.print(
                \\      middlewares:
                \\        - cowshed-{s}-redirect
                \\
            , .{name});
        }
        try w.print(
            \\      service: cowshed-{s}
            \\      priority: {d}
            \\
        , .{ name, PRIORITY });
        if (route.redirect) {
            try w.print(
                \\  middlewares:
                \\    cowshed-{s}-redirect:
                \\      redirectScheme:
                \\        scheme: https
                \\        permanent: true
                \\
            , .{name});
        }
    }
    try w.print(
        \\  services:
        \\    cowshed-{s}:
        \\      loadBalancer:
        \\        serversTransport: cowshed-{s}
        \\        servers:
        \\          - url: http://{s}:{d}
        \\  serversTransports:
        \\    cowshed-{s}:
        \\      forwardingTimeouts:
        \\        idleConnTimeout: {s}
        \\
    , .{ name, name, route.container, route.port, name, IDLE_TIMEOUT });
}

const testing = std.testing;
const yaml = @import("../config/yaml.zig");

test "a plain route is valid YAML, and has what matters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try render(a, .{ .service = "s", .host = "a.example", .container = "s-web-1", .port = 80, .entrypoint = "web" });
    var failure: yaml.Failure = undefined;
    const http = (try yaml.parse(a, text, &failure)).get("http").?.value;
    const router = http.get("routers").?.value.get("cowshed-s").?.value;
    try testing.expectEqualStrings("Host(`a.example`)", router.get("rule").?.value.scalar);
    try testing.expectEqualStrings("1000", router.get("priority").?.value.scalar);
    try testing.expect(router.get("tls") == null);
    try testing.expect(http.get("middlewares") == null);
    const balancer = http.get("services").?.value.get("cowshed-s").?.value.get("loadBalancer").?.value;
    try testing.expectEqualStrings("http://s-web-1:80", balancer.get("servers").?.value.list[0].value.get("url").?.value.scalar);
    const transport = http.get("serversTransports").?.value.get("cowshed-s").?.value;
    try testing.expectEqualStrings("3s", transport.get("forwardingTimeouts").?.value.get("idleConnTimeout").?.value.scalar);
}

test "with TLS and a redirect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try render(a, .{ .service = "s", .host = "h", .container = "c", .port = 1, .entrypoint = "websecure", .resolver = "le", .http_from = "web" });
    var failure: yaml.Failure = undefined;
    const http = (try yaml.parse(a, text, &failure)).get("http").?.value;
    const routers = http.get("routers").?.value;
    try testing.expectEqualStrings("le", routers.get("cowshed-s").?.value.get("tls").?.value.get("certResolver").?.value.scalar);
    try testing.expectEqualStrings("web", routers.get("cowshed-s-http").?.value.get("entryPoints").?.value.list[0].value.scalar);
    try testing.expectEqualStrings("cowshed-s-redirect", routers.get("cowshed-s-http").?.value.get("middlewares").?.value.list[0].value.scalar);
    try testing.expect(http.get("middlewares").?.value.get("cowshed-s-redirect") != null);
}

test "with TLS and plain HTTP to the app as well" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try render(a, .{ .service = "s", .host = "h", .container = "c", .port = 1, .entrypoint = "websecure", .resolver = "le", .http_from = "web", .redirect = false });
    var failure: yaml.Failure = undefined;
    const http = (try yaml.parse(a, text, &failure)).get("http").?.value;
    const routers = http.get("routers").?.value;
    try testing.expectEqualStrings("le", routers.get("cowshed-s").?.value.get("tls").?.value.get("certResolver").?.value.scalar);
    const plain = routers.get("cowshed-s-http").?.value;
    try testing.expectEqualStrings("web", plain.get("entryPoints").?.value.list[0].value.scalar);
    try testing.expectEqualStrings("cowshed-s", plain.get("service").?.value.scalar);
    try testing.expect(plain.get("middlewares") == null);
    try testing.expect(plain.get("tls") == null);
    try testing.expect(http.get("middlewares") == null);
}
