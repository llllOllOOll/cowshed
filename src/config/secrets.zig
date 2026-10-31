//! The secrets file: `NAME=value` lines, with `$VAR`, `${VAR}` and `$(command)`.
//! Reading names runs nothing; only `resolve` expands values and runs commands.
//! A value prints as `[redacted]`, and no error carries one.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DEFAULT_PATH = ".cowshed/secrets";

pub const Secret = struct {
    name: []const u8,
    value: []const u8,

    pub fn format(self: Secret, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}=[redacted]", .{self.name});
    }
};

const Line = struct {
    name: []const u8,
    raw: []const u8,
};

fn parseLine(line: []const u8) ?Line {
    var text = std.mem.trim(u8, line, " \t\r");
    if (text.len == 0 or text[0] == '#') return null;
    if (std.mem.startsWith(u8, text, "export ")) text = std.mem.trimStart(u8, text["export ".len..], " ");
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    return .{ .name = std.mem.trimEnd(u8, text[0..equals], " "), .raw = std.mem.trimStart(u8, text[equals + 1 ..], " ") };
}

/// The names a file defines. Runs nothing and expands nothing.
pub fn names(arena: Allocator, source: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (parseLine(line)) |parsed| try out.append(arena, parsed.name);
    }
    return out.items;
}

/// The secret an `env.secret` entry reads: `NAME`, or `NAME:SECRET`.
pub fn sourceOf(entry: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return entry;
    return entry[colon + 1 ..];
}

pub fn targetOf(entry: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return entry;
    return entry[0..colon];
}

pub const Context = struct {
    userdata: *anyopaque,
    /// The environment's value, or null.
    getEnv: *const fn (userdata: *anyopaque, name: []const u8) ?[]const u8,
    /// Runs a command in a local shell and gives its stdout.
    shell: *const fn (userdata: *anyopaque, arena: Allocator, command: []const u8) anyerror![]const u8,
};

pub const Failure = union(enum) {
    /// `$VAR` used by `secret`, with `variable` set nowhere.
    missing_variable: struct { secret: []const u8, variable: []const u8 },
    /// The `$(...)` of `secret` failed. Its text may hold a secret: it is not kept.
    command_failed: struct { secret: []const u8 },
    /// `secret` is wanted and on no line.
    not_defined: struct { secret: []const u8 },
    /// `secret` has an opening without its end.
    unterminated: struct { secret: []const u8 },
};

pub const ResolveError = Allocator.Error || error{InvalidSecrets};

/// The value of each wanted secret, with those it uses: nothing else is expanded
/// or run, so a line this deploy does not need cannot fail it. A variable means
/// an earlier line of that name, or else the environment.
pub fn resolve(arena: Allocator, source: []const u8, wanted: []const []const u8, context: Context, failure: *Failure) ResolveError![]const Secret {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (parseLine(line)) |parsed| try lines.append(arena, parsed);
    }
    var out: std.ArrayList(Secret) = .empty;
    for (wanted) |name| {
        const value = try valueBefore(arena, lines.items, lines.items.len, name, context, failure) orelse {
            failure.* = .{ .not_defined = .{ .secret = name } };
            return error.InvalidSecrets;
        };
        try out.append(arena, .{ .name = name, .value = value });
    }
    return out.items;
}

/// The last definition of `name` among the first `count` lines: no cycle is possible.
fn valueBefore(arena: Allocator, lines: []const Line, count: usize, name: []const u8, context: Context, failure: *Failure) ResolveError!?[]const u8 {
    var i = count;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, lines[i].name, name)) return try expandLine(arena, lines, i, context, failure);
    }
    return null;
}

fn expandLine(arena: Allocator, lines: []const Line, index: usize, context: Context, failure: *Failure) ResolveError![]const u8 {
    const line = lines[index];
    var raw = line.raw;
    if (raw.len >= 2 and raw[0] == '\'' and raw[raw.len - 1] == '\'') return raw[1 .. raw.len - 1];
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw = raw[1 .. raw.len - 1];

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len and raw[i + 1] == '$') {
            try out.append(arena, '$');
            i += 2;
        } else if (c != '$' or i + 1 == raw.len) {
            try out.append(arena, c);
            i += 1;
        } else if (raw[i + 1] == '(') {
            const end = closingParen(raw, i + 1) orelse {
                failure.* = .{ .unterminated = .{ .secret = line.name } };
                return error.InvalidSecrets;
            };
            const result = context.shell(context.userdata, arena, raw[i + 2 .. end]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    failure.* = .{ .command_failed = .{ .secret = line.name } };
                    return error.InvalidSecrets;
                },
            };
            try out.appendSlice(arena, std.mem.trimEnd(u8, result, "\r\n"));
            i = end + 1;
        } else {
            const braced = raw[i + 1] == '{';
            const start = i + 1 + @intFromBool(braced);
            var end = start;
            while (end < raw.len and isNameChar(raw[end])) end += 1;
            if (braced and (end == raw.len or raw[end] != '}')) {
                failure.* = .{ .unterminated = .{ .secret = line.name } };
                return error.InvalidSecrets;
            }
            if (end == start) {
                try out.append(arena, '$');
                i += 1;
                continue;
            }
            const variable = raw[start..end];
            const value = try valueBefore(arena, lines, index, variable, context, failure) orelse context.getEnv(context.userdata, variable) orelse {
                failure.* = .{ .missing_variable = .{ .secret = line.name, .variable = variable } };
                return error.InvalidSecrets;
            };
            try out.appendSlice(arena, value);
            i = end + @intFromBool(braced);
        }
    }
    return out.items;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn closingParen(text: []const u8, open: usize) ?usize {
    var depth: u32 = 0;
    for (text[open..], open..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

const testing = std.testing;

const FakeContext = struct {
    shells: u32 = 0,

    fn getEnv(_: *anyopaque, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, name, "FROM_ENV")) "env-value" else null;
    }

    fn shell(userdata: *anyopaque, _: Allocator, command: []const u8) anyerror![]const u8 {
        const self: *FakeContext = @ptrCast(@alignCast(userdata));
        self.shells += 1;
        if (std.mem.eql(u8, command, "fail")) return error.CommandFailed;
        return "from-shell\n";
    }

    fn context(self: *FakeContext) Context {
        return .{ .userdata = self, .getEnv = getEnv, .shell = shell };
    }
};

test "names run nothing, and skip comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try names(arena.allocator(),
        \\# COMMENTED=$(never)
        \\A=$(would run)
        \\export B=1
        \\
    );
    try testing.expectEqual(2, found.len);
    try testing.expectEqualStrings("A", found[0]);
    try testing.expectEqualStrings("B", found[1]);
}

test "the forms of a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fake: FakeContext = .{};
    var failure: Failure = undefined;
    const found = try resolve(arena.allocator(),
        \\PLAIN=abc
        \\ENV=$FROM_ENV
        \\BRACED=x${FROM_ENV}y
        \\EARLIER=$PLAIN
        \\SHELL=$(cat f)
        \\DOUBLE="a $PLAIN"
        \\SINGLE='a $PLAIN'
        \\ESCAPED=\$PLAIN
        \\NESTED=$(echo $(date))
    , &.{ "PLAIN", "ENV", "BRACED", "EARLIER", "SHELL", "DOUBLE", "SINGLE", "ESCAPED", "NESTED" }, fake.context(), &failure);
    const expected = [_][]const u8{ "abc", "env-value", "xenv-valuey", "abc", "from-shell", "a abc", "a $PLAIN", "$PLAIN", "from-shell" };
    for (expected, found) |want, got| try testing.expectEqualStrings(want, got.value);
    try testing.expectEqual(2, fake.shells);
}

test "only what is wanted runs, and what it uses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fake: FakeContext = .{};
    var failure: Failure = undefined;
    const found = try resolve(arena.allocator(),
        \\# A=$(never, a comment)
        \\UNUSED=$(never either)
        \\BROKEN=$NOT_ANYWHERE
        \\USED=$(once)
        \\WANTED=x$USED
    , &.{"WANTED"}, fake.context(), &failure);
    try testing.expectEqualStrings("xfrom-shell", found[0].value);
    try testing.expectEqual(1, fake.shells);
}

test "a line sees earlier lines, not itself: no cycle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fake: FakeContext = .{};
    var failure: Failure = undefined;
    try testing.expectError(error.InvalidSecrets, resolve(arena.allocator(), "A=$A\n", &.{"A"}, fake.context(), &failure));
    try testing.expectEqualStrings("A", failure.missing_variable.variable);
}

test "failures name the secret, never a value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var fake: FakeContext = .{};
    var failure: Failure = undefined;
    const a = arena.allocator();
    try testing.expectError(error.InvalidSecrets, resolve(a, "A=$MISSING\n", &.{"A"}, fake.context(), &failure));
    try testing.expectEqualStrings("A", failure.missing_variable.secret);
    try testing.expectEqualStrings("MISSING", failure.missing_variable.variable);
    try testing.expectError(error.InvalidSecrets, resolve(a, "B=$(fail)\n", &.{"B"}, fake.context(), &failure));
    try testing.expectEqualStrings("B", failure.command_failed.secret);
    try testing.expectError(error.InvalidSecrets, resolve(a, "C=$(open\n", &.{"C"}, fake.context(), &failure));
    try testing.expectEqualStrings("C", failure.unterminated.secret);
    try testing.expectError(error.InvalidSecrets, resolve(a, "D=${open\n", &.{"D"}, fake.context(), &failure));
    try testing.expectEqualStrings("D", failure.unterminated.secret);
    try testing.expectError(error.InvalidSecrets, resolve(a, "", &.{"E"}, fake.context(), &failure));
    try testing.expectEqualStrings("E", failure.not_defined.secret);
}

test "a secret prints redacted" {
    const printed = try std.fmt.allocPrint(testing.allocator, "{f}", .{Secret{ .name = "A", .value = "hidden" }});
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings("A=[redacted]", printed);
}

test "an env.secret entry and its alias" {
    try testing.expectEqualStrings("A", sourceOf("A"));
    try testing.expectEqualStrings("A", targetOf("A"));
    try testing.expectEqualStrings("B", sourceOf("A:B"));
    try testing.expectEqualStrings("A", targetOf("A:B"));
}
