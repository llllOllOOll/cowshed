//! Text edits for giving a running Traefik a routes folder, and what its neighbours'
//! labels say. Edits are by line, so an owner's comments and order stay. Runs nothing.

const std = @import("std");
const traefik = @import("traefik.zig");
const yaml = @import("../config/yaml.zig");
const Allocator = std.mem.Allocator;

const DEFAULT_INDENT = 2;

const Line = struct { start: usize, end: usize, indent: usize, text: []const u8 };

fn linesOf(arena: Allocator, source: []const u8) Allocator.Error![]const Line {
    var out: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (start < source.len) {
        const newline = std.mem.indexOfScalarPos(u8, source, start, '\n');
        const end = if (newline) |i| i + 1 else source.len;
        const raw = source[start .. newline orelse source.len];
        const indent = std.mem.indexOfNone(u8, raw, " ") orelse raw.len;
        var text = raw[indent..];
        if (text.len > 0 and text[0] == '#') text = "";
        try out.append(arena, .{ .start = start, .end = end, .indent = indent, .text = std.mem.trimEnd(u8, text, " \r") });
        start = end;
    }
    return out.items;
}

/// A key's value on its own line, ignoring a comment: null when it is not this key.
fn valueOf(text: []const u8, key: []const u8) ?[]const u8 {
    if (text.len <= key.len or text[key.len] != ':') return null;
    if (!std.ascii.eqlIgnoreCase(text[0..key.len], key)) return null;
    const rest = std.mem.trim(u8, text[key.len + 1 ..], " ");
    return if (rest.len > 0 and rest[0] == '#') "" else rest;
}

fn insertAt(arena: Allocator, source: []const u8, at: usize, text: []const u8) Allocator.Error![]const u8 {
    const separator: []const u8 = if (at > 0 and source[at - 1] != '\n') "\n" else "";
    return std.mem.concat(arena, u8, &.{ source[0..at], separator, text, source[at..] });
}

fn spaces(arena: Allocator, count: usize) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, count);
    @memset(out, ' ');
    return out;
}

/// The indentation of what stands under line `index`, or null if nothing does.
fn childIndent(lines: []const Line, index: usize) ?usize {
    const parent = lines[index].indent;
    for (lines[index + 1 ..]) |line| {
        if (line.text.len == 0) continue;
        return if (line.indent > parent) line.indent else null;
    }
    return null;
}

/// Traefik's settings with a file provider on `folder` and its API reachable from
/// inside its network. Null when this file's shape cannot take it safely.
pub fn editSettings(arena: Allocator, source: []const u8, folder: []const u8) Allocator.Error!?[]const u8 {
    var text = source;

    var lines = try linesOf(arena, text);
    var providers: ?usize = null;
    for (lines, 0..) |line, i| {
        if (line.indent != 0) continue;
        if (valueOf(line.text, "providers")) |value| {
            if (value.len > 0) return null;
            providers = i;
        }
    }
    if (providers) |i| {
        const child = childIndent(lines, i) orelse DEFAULT_INDENT;
        const block = try std.fmt.allocPrint(arena, "{s}file:\n{s}directory: {s}\n", .{ try spaces(arena, child), try spaces(arena, child * 2), folder });
        text = try insertAt(arena, text, lines[i].end, block);
    } else {
        const block = try std.fmt.allocPrint(arena, "providers:\n  file:\n    directory: {s}\n", .{folder});
        text = try insertAt(arena, text, text.len, block);
    }

    lines = try linesOf(arena, text);
    var api: ?usize = null;
    for (lines, 0..) |line, i| {
        if (line.indent != 0) continue;
        if (valueOf(line.text, "api")) |value| {
            if (value.len > 0) return null;
            api = i;
        }
    }
    if (api) |i| {
        const child = childIndent(lines, i) orelse DEFAULT_INDENT;
        var j = i + 1;
        while (j < lines.len) : (j += 1) {
            const line = lines[j];
            if (line.text.len == 0) continue;
            if (line.indent <= lines[i].indent) break;
            if (valueOf(line.text, "insecure") != null) {
                const replaced = try std.fmt.allocPrint(arena, "{s}insecure: true\n", .{try spaces(arena, line.indent)});
                text = try std.mem.concat(arena, u8, &.{ text[0..line.start], replaced, text[line.end..] });
                return checked(arena, source, text, folder);
            }
        }
        text = try insertAt(arena, text, lines[i].end, try std.fmt.allocPrint(arena, "{s}insecure: true\n", .{try spaces(arena, child)}));
    } else {
        text = try insertAt(arena, text, text.len, "api:\n  insecure: true\n");
    }
    return checked(arena, source, text, folder);
}

/// What was added reads back as meant, and everything else reads as before.
fn checked(arena: Allocator, source: []const u8, edited: []const u8, folder: []const u8) Allocator.Error!?[]const u8 {
    var failure: yaml.Failure = undefined;
    const before = traefik.parseSettings(yaml.parseWith(arena, source, &failure, .{ .foreign = true }) catch return null);
    const after = traefik.parseSettings(yaml.parseWith(arena, edited, &failure, .{ .foreign = true }) catch return null);
    if (!after.api) return null;
    if (!std.mem.eql(u8, after.routes_dir orelse return null, folder)) return null;
    if (!same(before.http_entrypoint, after.http_entrypoint)) return null;
    if (!same(before.https_entrypoint, after.https_entrypoint)) return null;
    if (!same(before.resolver, after.resolver)) return null;
    if (!same(before.docker_network, after.docker_network)) return null;
    return edited;
}

fn same(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// A Compose file with `volume` added to a service's existing list. Null when the
/// service or the list is not found as plain block YAML.
pub fn editCompose(arena: Allocator, source: []const u8, service: []const u8, volume: []const u8) Allocator.Error!?[]const u8 {
    const lines = try linesOf(arena, source);
    var services: ?usize = null;
    for (lines, 0..) |line, i| {
        if (line.indent == 0 and valueOf(line.text, "services") != null) services = i;
    }
    const top = services orelse return null;
    const service_indent = childIndent(lines, top) orelse return null;

    var found: ?usize = null;
    for (lines[top + 1 ..], top + 1..) |line, i| {
        if (line.text.len == 0) continue;
        if (line.indent <= lines[top].indent) break;
        if (line.indent == service_indent and exact(line.text, service)) found = i;
    }
    const own = found orelse return null;
    const body_indent = childIndent(lines, own) orelse return null;

    var i = own + 1;
    while (i < lines.len) : (i += 1) {
        const line = lines[i];
        if (line.text.len == 0) continue;
        if (line.indent <= service_indent) return null;
        if (line.indent != body_indent) continue;
        const value = valueOf(line.text, "volumes") orelse continue;
        if (value.len > 0) return null;
        return try addItem(arena, source, lines, i, volume);
    }
    return null;
}

fn exact(text: []const u8, key: []const u8) bool {
    const value = valueOf(text, key) orelse return false;
    return value.len == 0 and std.mem.startsWith(u8, text, key);
}

fn addItem(arena: Allocator, source: []const u8, lines: []const Line, key: usize, volume: []const u8) Allocator.Error!?[]const u8 {
    var item_indent: ?usize = null;
    var last = key;
    for (lines[key + 1 ..], key + 1..) |line, i| {
        if (line.text.len == 0) continue;
        const is_item = std.mem.startsWith(u8, line.text, "- ");
        if (item_indent) |indent| {
            if (line.indent < indent or (line.indent == indent and !is_item)) break;
        } else {
            if (!is_item or line.indent < lines[key].indent) return null;
            item_indent = line.indent;
        }
        last = i;
    }
    const indent = item_indent orelse return null;
    const text = try std.fmt.allocPrint(arena, "{s}- \"{s}\"\n", .{ try spaces(arena, indent), volume });
    return try insertAt(arena, source, lines[last].end, text);
}

pub const Labelled = struct {
    /// Router names, each as Traefik's Docker provider names them.
    routers: []const []const u8,
    hosts: []const []const u8,
};

/// From the `key=value` lines of the labels of containers Traefik serves. Only
/// routers' rules are looked at: other labels may hold secrets.
pub fn parseLabels(arena: Allocator, labels: []const u8) Allocator.Error!Labelled {
    const prefix = "traefik.http.routers.";
    const suffix = ".rule=";
    var routers: std.ArrayList([]const u8) = .empty;
    var hosts: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, labels, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const at = std.mem.indexOf(u8, line, suffix) orelse continue;
        try routers.append(arena, try std.fmt.allocPrint(arena, "{s}@docker", .{line[prefix.len..at]}));
        var rule = line[at + suffix.len ..];
        while (std.mem.indexOf(u8, rule, "Host(`")) |start| {
            rule = rule[start + 6 ..];
            const end = std.mem.indexOfScalar(u8, rule, '`') orelse break;
            const host = rule[0..end];
            rule = rule[end..];
            for (hosts.items) |known| {
                if (std.mem.eql(u8, known, host)) break;
            } else try hosts.append(arena, host);
        }
    }
    return .{ .routers = routers.items, .hosts = hosts.items };
}

/// A host's answer after, against before: no worse, as far as a status can say.
pub fn stillAnswers(before: []const u8, after: []const u8) bool {
    if (std.mem.eql(u8, before, after)) return true;
    return after.len == 3 and (after[0] == '2' or after[0] == '3');
}

const testing = std.testing;

const SERVER_SETTINGS =
    \\api:
    \\  dashboard: true
    \\
    \\entryPoints:
    \\  http:
    \\    address: ":80"
    \\  https:
    \\    address: ":443"
    \\
    \\providers:
    \\  docker:
    \\    # Only what asks to be served
    \\    exposedByDefault: false
    \\
    \\certificatesResolvers:
    \\  letsencrypt:
    \\    acme:
    \\      email: me@x
    \\
;

test "settings: the folder and the API added, all else as it was" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edited = (try editSettings(a, SERVER_SETTINGS, "/routes")).?;
    try testing.expect(std.mem.indexOf(u8, edited, "api:\n  insecure: true\n  dashboard: true\n") != null);
    try testing.expect(std.mem.indexOf(u8, edited, "providers:\n  file:\n    directory: /routes\n  docker:\n    # Only what asks to be served\n") != null);
    try testing.expect(std.mem.indexOf(u8, edited, "email: me@x") != null);
}

test "settings: sections missing, another indentation, API off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const none = (try editSettings(a, "entryPoints:\n  web:\n    address: \":80\"", "/r")).?;
    try testing.expect(std.mem.indexOf(u8, none, "\nproviders:\n  file:\n    directory: /r\napi:\n  insecure: true\n") != null);
    const wide = (try editSettings(a, "providers:\n    docker: {}\napi:\n    insecure: false\n", "/r")).?;
    try testing.expect(std.mem.indexOf(u8, wide, "providers:\n    file:\n        directory: /r\n    docker: {}") != null);
    try testing.expect(std.mem.indexOf(u8, wide, "api:\n    insecure: true\n") != null);
    try testing.expect(std.mem.indexOf(u8, wide, "false") == null);
}

test "settings: what cannot be edited safely is left" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try editSettings(a, "providers: {docker: {}}\n", "/r")) == null);
    try testing.expect((try editSettings(a, "api: {}\n", "/r")) == null);
    try testing.expect((try editSettings(a, "a: &x 1\n", "/r")) == null);
}

const SERVER_COMPOSE =
    \\networks:
    \\  web:
    \\    external: true
    \\
    \\services:
    \\  traefik:
    \\    image: traefik:latest
    \\    volumes:
    \\      - /var/run/docker.sock:/var/run/docker.sock:ro
    \\      - ./traefik/acme.json:/acme.json
    \\    labels:
    \\      - "traefik.enable=true"
    \\
    \\  db:
    \\    image: postgres
    \\    volumes:
    \\      - data:/var/lib/data
    \\volumes:
    \\  data:
    \\
;

test "compose: added to that service's list only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edited = (try editCompose(a, SERVER_COMPOSE, "traefik", "/h:/c")).?;
    try testing.expect(std.mem.indexOf(u8, edited, "./traefik/acme.json:/acme.json\n      - \"/h:/c\"\n    labels:") != null);
    try testing.expectEqual(SERVER_COMPOSE.len + "      - \"/h:/c\"\n".len, edited.len);
}

test "compose: a list at its key's indentation, and what is not there" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const flat = (try editCompose(a, "services:\n  t:\n    volumes:\n    - a:/b\n    ports:\n    - 1:1\n", "t", "/h:/c")).?;
    try testing.expect(std.mem.indexOf(u8, flat, "    - a:/b\n    - \"/h:/c\"\n    ports:") != null);
    try testing.expect((try editCompose(a, SERVER_COMPOSE, "nope", "/h:/c")) == null);
    try testing.expect((try editCompose(a, "services:\n  t:\n    image: a\n  u:\n    volumes:\n      - a:/b\n", "t", "/h:/c")) == null);
}

test "labels: routers and hosts, nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try parseLabels(arena.allocator(),
        \\traefik.enable=true
        \\traefik.http.routers.a.rule=Host(`a.example`) && Path(`/ws`)
        \\traefik.http.routers.a.tls=true
        \\traefik.http.routers.b.rule=Host(`b.example`) || Host(`a.example`)
        \\traefik.http.middlewares.m.basicauth.users=secret
    );
    try testing.expectEqual(2, found.routers.len);
    try testing.expectEqualStrings("b@docker", found.routers[1]);
    try testing.expectEqual(2, found.hosts.len);
    try testing.expectEqualStrings("b.example", found.hosts[1]);
}

test "a host still answers" {
    try testing.expect(stillAnswers("404", "404"));
    try testing.expect(stillAnswers("200", "302"));
    try testing.expect(stillAnswers("000", "200"));
    try testing.expect(!stillAnswers("200", "502"));
    try testing.expect(!stillAnswers("200", "404"));
    try testing.expect(!stillAnswers("200", "000"));
}
