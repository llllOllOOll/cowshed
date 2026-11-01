//! A copy of what a command says, on this machine, for commands that change a server.
//! It holds what Cowshed says on the screen, so what never reaches the screen never
//! reaches it. A build's own output goes straight to the screen and is not in it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Writes to the screen and the file. A file that stops working does not stop the
/// command: it is the screen that counts.
pub const Log = struct {
    writer: Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    screen: *Writer,
    io: std.Io,
    file: ?std.Io.File = null,
    file_writer: std.Io.File.Writer = undefined,
    path: []const u8 = "",

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Log = @alignCast(@fieldParentPtr("writer", w));
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.both(bytes);
            total += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.both(pattern);
            total += pattern.len;
        }
        return total;
    }

    fn both(self: *Log, bytes: []const u8) Writer.Error!void {
        try self.screen.writeAll(bytes);
        if (self.file == null) return;
        self.file_writer.interface.writeAll(bytes) catch self.closeFile();
    }

    fn closeFile(self: *Log) void {
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }

    /// Says where the copy is, and closes it.
    pub fn close(self: *Log) Writer.Error!void {
        if (self.file != null) try self.writer.print("log: {s}\n", .{self.path});
        self.closeFile();
    }
};

/// Without a usable folder it tells so, and only the screen gets the output.
pub fn open(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map, screen: *Writer, service: []const u8, command: []const u8) !*Log {
    const log = try arena.create(Log);
    log.* = .{ .screen = screen, .io = io };
    const folder = try folderOf(arena, environ) orelse {
        try screen.writeAll("notice: no HOME, so no log on this machine\n");
        return log;
    };
    const seconds = std.Io.Clock.real.now(io).toSeconds();
    const path = try std.fmt.allocPrint(arena, "{s}/{s}-{s}-{s}.log", .{ folder, service, command, try stamp(arena, seconds) });
    std.Io.Dir.cwd().createDirPath(io, folder) catch |err| {
        try screen.print("notice: no log on this machine: {s}: {t}\n", .{ folder, err });
        return log;
    };
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        try screen.print("notice: no log on this machine: {s}: {t}\n", .{ path, err });
        return log;
    };
    log.file = file;
    log.file_writer = file.writerStreaming(io, &.{});
    log.path = path;
    return log;
}

fn folderOf(arena: Allocator, environ: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (environ.get("XDG_STATE_HOME")) |state| return try std.fmt.allocPrint(arena, "{s}/cowshed/logs", .{state});
    const home = environ.get("HOME") orelse return null;
    return try std.fmt.allocPrint(arena, "{s}/.local/state/cowshed/logs", .{home});
}

fn stamp(arena: Allocator, seconds: i64) Allocator.Error![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

const testing = std.testing;

test "what the screen gets, the file gets, and it says where" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var environ = std.process.Environ.Map.init(a);
    try environ.put("XDG_STATE_HOME", try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}));

    var screen: Writer.Allocating = .init(a);
    const log = try open(a, testing.io, &environ, &screen.writer, "app", "setup");
    try log.writer.print("one {d}\n", .{1});
    try log.writer.writeAll("two\n");
    try log.writer.splatByteAll('-', 3);
    const path = log.path;
    try log.close();

    try testing.expect(std.mem.indexOf(u8, path, "/cowshed/logs/app-setup-") != null);
    const expected = try std.fmt.allocPrint(a, "one 1\ntwo\n---log: {s}\n", .{path});
    try testing.expectEqualStrings(expected, screen.written());
    const saved = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1024));
    try testing.expectEqualStrings(expected, saved);
}

test "no folder: the screen still gets it all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ = std.process.Environ.Map.init(a);
    var screen: Writer.Allocating = .init(a);
    const log = try open(a, testing.io, &environ, &screen.writer, "app", "setup");
    try log.writer.writeAll("kept\n");
    try log.close();
    try testing.expectEqualStrings("notice: no HOME, so no log on this machine\nkept\n", screen.written());
}

test "the time in a file's name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("20261101T155645Z", try stamp(arena.allocator(), 1793548605));
}
