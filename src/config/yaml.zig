//! The YAML that deploy files use: maps, lists, scalars, comments and block
//! scalars. What it does not take (anchors, merges, flow collections, ERB) is
//! refused by line, not misread.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    none,
    scalar: []const u8,
    map: []const Entry,
    list: []const Item,

    pub fn get(self: Value, key: []const u8) ?Entry {
        if (self != .map) return null;
        for (self.map) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
    line: u32,
};

pub const Item = struct {
    value: Value,
    line: u32,
};

pub const Failure = struct {
    line: u32,
    message: []const u8,
};

const Line = struct {
    number: u32,
    indent: u32,
    /// Without its indentation and comment; empty when nothing is left.
    text: []const u8,
    raw: []const u8,
};

pub const Options = struct {
    /// For a file that is not ours, such as Traefik's: a flow collection stays as
    /// its text, and a `---` may open the file. Only what is read must be understood.
    foreign: bool = false,
};

/// Everything returned lives in `arena`. On `error.InvalidYaml`, `failure` says why.
pub fn parse(arena: Allocator, source: []const u8, failure: *Failure) (Allocator.Error || error{InvalidYaml})!Value {
    return parseWith(arena, source, failure, .{});
}

pub fn parseWith(arena: Allocator, source: []const u8, failure: *Failure, options: Options) (Allocator.Error || error{InvalidYaml})!Value {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 1;
    while (it.next()) |raw_line| : (number += 1) {
        const raw = std.mem.trimEnd(u8, raw_line, "\r");
        const indent = std.mem.indexOfNone(u8, raw, " ") orelse raw.len;
        try lines.append(arena, .{
            .number = number,
            .indent = @intCast(indent),
            .text = stripComment(raw[indent..]),
            .raw = raw,
        });
    }
    if (options.foreign) {
        for (lines.items) |*line| {
            if (line.text.len == 0) continue;
            if (std.mem.eql(u8, line.text, "---")) line.text = "";
            break;
        }
    }
    var parser: Parser = .{ .arena = arena, .lines = lines.items, .failure = failure, .keep_flow = options.foreign };
    try parser.checkUnsupported();
    if (!parser.skipToContent()) return .none;
    const root = parser.lines[parser.index].indent;
    const value = try parser.parseNode(root);
    if (parser.skipToContent()) return parser.fail(parser.lines[parser.index].number, "unexpected indentation");
    return value;
}

/// Removes a comment and trailing spaces. A `#` counts at the start or after a
/// space, outside quotes; a quote opens only after a space or at the start.
fn stripComment(text: []const u8) []const u8 {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote) |q| {
            if (c == '\\' and q == '"') {
                i += 1;
            } else if (c == q) {
                quote = null;
            }
            continue;
        }
        const at_start = i == 0 or text[i - 1] == ' ';
        if (c == '#' and at_start) return std.mem.trimEnd(u8, text[0..i], " ");
        if ((c == '"' or c == '\'') and at_start) quote = c;
    }
    return std.mem.trimEnd(u8, text, " ");
}

const Parser = struct {
    arena: Allocator,
    lines: []Line,
    failure: *Failure,
    keep_flow: bool = false,
    index: usize = 0,

    fn fail(self: *Parser, line: u32, message: []const u8) error{InvalidYaml} {
        self.failure.* = .{ .line = line, .message = message };
        return error.InvalidYaml;
    }

    fn checkUnsupported(self: *Parser) error{InvalidYaml}!void {
        for (self.lines) |line| {
            if (std.mem.indexOfScalar(u8, line.raw[0..line.indent], '\t') != null or
                (line.text.len > 0 and line.text[0] == '\t'))
            {
                return self.fail(line.number, "tabs are not allowed for indentation");
            }
            if (std.mem.startsWith(u8, line.text, "---") or std.mem.eql(u8, line.text, "...")) {
                return self.fail(line.number, "several documents are not supported");
            }
            if (std.mem.indexOf(u8, line.text, "<%") != null) {
                return self.fail(line.number, "ERB is not supported: use ${VAR}");
            }
        }
    }

    /// Moves to the next line with content; false at the end.
    fn skipToContent(self: *Parser) bool {
        while (self.index < self.lines.len) : (self.index += 1) {
            if (self.lines[self.index].text.len > 0) return true;
        }
        return false;
    }

    fn isDash(text: []const u8) bool {
        return std.mem.eql(u8, text, "-") or std.mem.startsWith(u8, text, "- ");
    }

    fn parseNode(self: *Parser, indent: u32) (Allocator.Error || error{InvalidYaml})!Value {
        if (isDash(self.lines[self.index].text)) return self.parseList(indent);
        return self.parseMap(indent);
    }

    fn parseMap(self: *Parser, indent: u32) (Allocator.Error || error{InvalidYaml})!Value {
        var entries: std.ArrayList(Entry) = .empty;
        while (self.skipToContent()) {
            const line = self.lines[self.index];
            if (line.indent < indent) break;
            if (line.indent > indent) return self.fail(line.number, "unexpected indentation");
            if (isDash(line.text)) break;
            const split = findColon(line.text) orelse return self.fail(line.number, "expected `key: value`");
            const key = try self.parseScalar(line.number, std.mem.trimEnd(u8, line.text[0..split], " "));
            for (entries.items) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return self.fail(line.number, "repeated key");
            }
            const rest = std.mem.trimStart(u8, line.text[split + 1 ..], " ");
            self.index += 1;
            const value = try self.parseValue(line.number, indent, rest);
            try entries.append(self.arena, .{ .key = key, .value = value, .line = line.number });
        }
        return .{ .map = entries.items };
    }

    fn parseValue(self: *Parser, number: u32, indent: u32, rest: []const u8) (Allocator.Error || error{InvalidYaml})!Value {
        if (rest.len == 0) {
            if (!self.skipToContent()) return .none;
            const next = self.lines[self.index];
            if (next.indent > indent) return self.parseNode(next.indent);
            // A list may sit at its key's own indentation.
            if (next.indent == indent and isDash(next.text)) return self.parseList(indent);
            return .none;
        }
        if (rest[0] == '|' or rest[0] == '>') return self.parseBlockScalar(number, indent, rest);
        return .{ .scalar = try self.parseScalar(number, rest) };
    }

    fn parseList(self: *Parser, indent: u32) (Allocator.Error || error{InvalidYaml})!Value {
        var items: std.ArrayList(Item) = .empty;
        while (self.skipToContent()) {
            const line = &self.lines[self.index];
            if (line.indent != indent or !isDash(line.text)) {
                if (line.indent > indent) return self.fail(line.number, "unexpected indentation");
                break;
            }
            const number = line.number;
            const after = line.text[1..];
            const rest = std.mem.trimStart(u8, after, " ");
            if (rest.len == 0) {
                self.index += 1;
                try items.append(self.arena, .{ .value = try self.parseValue(number, indent, ""), .line = number });
            } else if (findColon(rest) != null) {
                // A map starting on the dash's line: its keys align after the dash.
                line.indent = indent + 1 + @as(u32, @intCast(after.len - rest.len));
                line.text = rest;
                try items.append(self.arena, .{ .value = try self.parseMap(line.indent), .line = number });
            } else {
                self.index += 1;
                try items.append(self.arena, .{ .value = .{ .scalar = try self.parseScalar(number, rest) }, .line = number });
            }
        }
        return .{ .list = items.items };
    }

    fn parseBlockScalar(self: *Parser, number: u32, indent: u32, header: []const u8) (Allocator.Error || error{InvalidYaml})!Value {
        const folded = header[0] == '>';
        const chomp = header[1..];
        if (chomp.len > 1 or (chomp.len == 1 and chomp[0] != '-')) {
            return self.fail(number, "only |, >, |- and >- are supported");
        }
        var out: std.ArrayList(u8) = .empty;
        var block_indent: ?u32 = null;
        var pending_blank = false;
        while (self.index < self.lines.len) : (self.index += 1) {
            const line = self.lines[self.index];
            const blank = line.indent == line.raw.len;
            if (blank) {
                pending_blank = true;
                continue;
            }
            if (line.indent <= indent) break;
            const start = block_indent orelse line.indent;
            block_indent = start;
            if (line.indent < start) return self.fail(line.number, "block scalar's indentation went back");
            if (out.items.len > 0) {
                try out.append(self.arena, if (folded and !pending_blank) ' ' else '\n');
                if (pending_blank and !folded) try out.append(self.arena, '\n');
            }
            pending_blank = false;
            try out.appendSlice(self.arena, line.raw[start..]);
        }
        if (chomp.len == 0 and out.items.len > 0) try out.append(self.arena, '\n');
        return .{ .scalar = out.items };
    }

    fn parseScalar(self: *Parser, number: u32, text: []const u8) (Allocator.Error || error{InvalidYaml})![]const u8 {
        if (text.len == 0) return text;
        switch (text[0]) {
            '&', '*' => return self.fail(number, "anchors and aliases are not supported"),
            '[', '{' => {
                if (self.keep_flow) return text;
                if (text.len == 2 and (text[1] == ']' or text[1] == '}')) return self.fail(number, "write an empty collection as no value");
                return self.fail(number, "flow collections are not supported: use a block");
            },
            '"' => return self.parseDoubleQuoted(number, text),
            '\'' => {
                if (text.len < 2 or text[text.len - 1] != '\'') return self.fail(number, "unterminated quote");
                return std.mem.replaceOwned(u8, self.arena, text[1 .. text.len - 1], "''", "'");
            },
            else => {},
        }
        if (std.mem.eql(u8, text, "<<")) return self.fail(number, "merges are not supported");
        return text;
    }

    fn parseDoubleQuoted(self: *Parser, number: u32, text: []const u8) (Allocator.Error || error{InvalidYaml})![]const u8 {
        if (text.len < 2 or text[text.len - 1] != '"') return self.fail(number, "unterminated quote");
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < text.len - 1) : (i += 1) {
            if (text[i] != '\\') {
                try out.append(self.arena, text[i]);
                continue;
            }
            i += 1;
            if (i >= text.len - 1) return self.fail(number, "unterminated quote");
            try out.append(self.arena, switch (text[i]) {
                'n' => '\n',
                't' => '\t',
                '"', '\\', '/' => text[i],
                else => return self.fail(number, "unsupported escape in a quoted string"),
            });
        }
        return out.items;
    }
};

/// The colon ending a key: followed by a space or the end, outside a quoted key.
fn findColon(text: []const u8) ?usize {
    var start: usize = 0;
    if (text[0] == '"' or text[0] == '\'') {
        const close = std.mem.indexOfScalarPos(u8, text, 1, text[0]) orelse return null;
        start = close + 1;
        const after = std.mem.trimStart(u8, text[start..], " ");
        if (after.len == 0 or after[0] != ':') return null;
    }
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')) return i;
    }
    return null;
}

const testing = std.testing;

fn parseTest(arena: *std.heap.ArenaAllocator, source: []const u8) !Value {
    var failure: Failure = undefined;
    return parse(arena.allocator(), source, &failure);
}

fn expectFailure(source: []const u8, line: u32, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = undefined;
    try testing.expectError(error.InvalidYaml, parse(arena.allocator(), source, &failure));
    try testing.expectEqual(line, failure.line);
    try testing.expectEqualStrings(message, failure.message);
}

test "maps, lists and comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try parseTest(&arena,
        \\# a comment
        \\service: game # trailing
        \\servers:
        \\  web:
        \\    hosts:
        \\      - 1.2.3.4
        \\      - "5.6.7.8"
        \\empty:
        \\same_indent:
        \\- a
        \\- b
    );
    try testing.expectEqualStrings("game", value.get("service").?.value.scalar);
    const hosts = value.get("servers").?.value.get("web").?.value.get("hosts").?.value.list;
    try testing.expectEqual(2, hosts.len);
    try testing.expectEqualStrings("5.6.7.8", hosts[1].value.scalar);
    try testing.expectEqual(.none, std.meta.activeTag(value.get("empty").?.value));
    try testing.expectEqual(2, value.get("same_indent").?.value.list.len);
    try testing.expectEqual(2, value.get("service").?.line);
}

test "a scalar keeps its colons and backticks; a # inside a word or quotes is not a comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try parseTest(&arena,
        \\url: http://a.b:80/c#d
        \\rule: "Host(`a.b`) # kept"
        \\single: 'it''s'
        \\escaped: "a\"b\\c"
    );
    try testing.expectEqualStrings("http://a.b:80/c#d", value.get("url").?.value.scalar);
    try testing.expectEqualStrings("Host(`a.b`) # kept", value.get("rule").?.value.scalar);
    try testing.expectEqualStrings("it's", value.get("single").?.value.scalar);
    try testing.expectEqualStrings("a\"b\\c", value.get("escaped").?.value.scalar);
}

test "a map starting on a list's dash, and dotted keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try parseTest(&arena,
        \\items:
        \\  - name: a
        \\    port: 1
        \\  - name: b
        \\labels:
        \\  traefik.enable: "true"
    );
    const items = value.get("items").?.value.list;
    try testing.expectEqual(2, items.len);
    try testing.expectEqualStrings("1", items[0].value.get("port").?.value.scalar);
    try testing.expectEqualStrings("b", items[1].value.get("name").?.value.scalar);
    try testing.expectEqualStrings("true", value.get("labels").?.value.get("traefik.enable").?.value.scalar);
}

test "a list item with a colon but no space stays a scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try parseTest(&arena,
        \\secret:
        \\  - NAME:ALIAS
        \\  - /a/b:/c:ro
    );
    try testing.expectEqualStrings("NAME:ALIAS", value.get("secret").?.value.list[0].value.scalar);
    try testing.expectEqualStrings("/a/b:/c:ro", value.get("secret").?.value.list[1].value.scalar);
}

test "block scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try parseTest(&arena,
        \\folded: >
        \\  start --dev
        \\  --port 1
        \\literal: |-
        \\  one
        \\  # not a comment
        \\
        \\  two
        \\after: x
    );
    try testing.expectEqualStrings("start --dev --port 1\n", value.get("folded").?.value.scalar);
    try testing.expectEqualStrings("one\n# not a comment\n\ntwo", value.get("literal").?.value.scalar);
    try testing.expectEqualStrings("x", value.get("after").?.value.scalar);
}

test "what is not supported is refused by line" {
    try expectFailure("a: 1\nb: &x 2\n", 2, "anchors and aliases are not supported");
    try expectFailure("a: *x\n", 1, "anchors and aliases are not supported");
    try expectFailure("<<: x\n", 1, "merges are not supported");
    try expectFailure("a: [1, 2]\n", 1, "flow collections are not supported: use a block");
    try expectFailure("a: <%= ENV %>\n", 1, "ERB is not supported: use ${VAR}");
    try expectFailure("---\na: 1\n", 1, "several documents are not supported");
    try expectFailure("a: 1\na: 2\n", 2, "repeated key");
    try expectFailure("a: 1\n  b: 2\n", 2, "unexpected indentation");
    try expectFailure("just text\n", 1, "expected `key: value`");
    try expectFailure("a: \"open\n", 1, "unterminated quote");
    try expectFailure("\ta: 1\n", 1, "tabs are not allowed for indentation");
}

test "a foreign file: its flow collections stay text, and `---` may open it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var failure: Failure = undefined;
    const value = try parseWith(arena.allocator(), "# top\n---\na: [1, 2]\nb: {}\n", &failure, .{ .foreign = true });
    try testing.expectEqualStrings("[1, 2]", value.get("a").?.value.scalar);
    try testing.expectEqualStrings("{}", value.get("b").?.value.scalar);
    try testing.expectError(error.InvalidYaml, parseWith(arena.allocator(), "a: 1\n---\nb: 2\n", &failure, .{ .foreign = true }));
    try testing.expectError(error.InvalidYaml, parseWith(arena.allocator(), "a: &x 1\n", &failure, .{ .foreign = true }));
}

test "ERB in a comment is fine" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try parseTest(&arena, "# V: <%= ENV %>\na: 1\n");
    try testing.expectEqualStrings("1", value.get("a").?.value.scalar);
}

test "an empty file is no value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(.none, std.meta.activeTag(try parseTest(&arena, "\n# only this\n")));
}
