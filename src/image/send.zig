//! Sends an image, only what the server lacks: `docker save` gives an OCI layout,
//! whose blobs are named by their digest (docs/spikes.md, Sending an image). The
//! server needs only Docker, `tar` and `sha256sum`.

const std = @import("std");
const Remote = @import("../remote/Remote.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const LIST_BLOBS =
    \\mkdir -p "$HOME/.cowshed/blobs/sha256" && ls "$HOME/.cowshed/blobs/sha256"
;
/// Written before sending, so collecting old blobs never takes these.
const RECORD_BLOBS =
    \\mkdir -p "$HOME/.cowshed/images/$1" && cat > "$HOME/.cowshed/images/$1/$2.blobs"
;
/// Arrives under a temporary name, checked against its digest, then takes its own.
const RECEIVE_BLOB =
    \\d="$HOME/.cowshed/blobs/sha256"; t="$d/.$1.tmp"
    \\if cat > "$t" && printf '%s  %s\n' "$1" "$t" | sha256sum -c - >/dev/null; then mv "$t" "$d/$1"; else rm -f "$t"; exit 1; fi
;
const RECEIVE_METADATA =
    \\mkdir -p "$HOME/.cowshed/stage/$1" && cat > "$HOME/.cowshed/stage/$1/$2"
;
/// The digests on stdin. Hard links, so the tar holds them with no second copy.
const LOAD =
    \\s="$HOME/.cowshed/stage/$1"
    \\mkdir -p "$s/blobs/sha256" || exit 1
    \\while read -r digest; do ln "$HOME/.cowshed/blobs/sha256/$digest" "$s/blobs/sha256/$digest" || exit 1; done
    \\cd "$s" && tar -cf - . | docker load
    \\code=$?
    \\cd "$HOME" && rm -rf "$s"
    \\exit $code
;
const METADATA = [_][]const u8{ "index.json", "manifest.json", "oci-layout" };
const MEGABYTE = 1000 * 1000;
const KILOBYTE = 1000;

const Blob = struct { digest: []const u8, size: u64 };

const Size = struct {
    bytes: u64,

    pub fn format(self: Size, writer: *Writer) Writer.Error!void {
        if (self.bytes >= MEGABYTE) return writer.print("{d} MB", .{self.bytes / MEGABYTE});
        if (self.bytes >= KILOBYTE) return writer.print("{d} KB", .{self.bytes / KILOBYTE});
        try writer.print("{d} bytes", .{self.bytes});
    }
};

pub const Sender = struct {
    io: std.Io,
    /// The folder `local.save` made.
    folder: []const u8,
    tag: []const u8,
    service: []const u8,
    version: []const u8,

    pub fn send(ptr: *anyopaque, arena: Allocator, remote: Remote, out: *Writer) anyerror!bool {
        const self: *Sender = @ptrCast(@alignCast(ptr));
        return self.sendTo(arena, remote, out);
    }

    fn sendTo(self: Sender, arena: Allocator, remote: Remote, out: *Writer) !bool {
        try out.writeAll("image: asking what the server already has\n");
        const listed = try remote.run(arena, .{ .argv = &.{ "sh", "-c", LIST_BLOBS } });
        if (!listed.ok()) return fail(out, "could not list the server's blobs", listed);

        const blobs_path = try std.fs.path.join(arena, &.{ self.folder, "blobs", "sha256" });
        var dir = try std.Io.Dir.cwd().openDir(self.io, blobs_path, .{ .iterate = true });
        defer dir.close(self.io);

        var digests: std.ArrayList(u8) = .empty;
        var missing: std.ArrayList(Blob) = .empty;
        var total: u64 = 0;
        var to_send: u64 = 0;
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const digest = try arena.dupe(u8, entry.name);
            try digests.appendSlice(arena, digest);
            try digests.append(arena, '\n');
            const size = (try dir.statFile(self.io, digest, .{})).size;
            total += size;
            if (!contains(listed.stdout, digest)) {
                try missing.append(arena, .{ .digest = digest, .size = size });
                to_send += size;
            }
        }

        const recorded = try remote.run(arena, .{ .argv = &.{ "sh", "-c", RECORD_BLOBS, "sh", self.service, self.version }, .stdin = digests.items });
        if (!recorded.ok()) return fail(out, "could not record the image's blobs", recorded);

        try out.print("image: {d} of {d} MB to send\n", .{ to_send / MEGABYTE, total / MEGABYTE });
        try out.flush();
        for (missing.items, 1..) |blob, position| {
            try out.print("image: sending part {d} of {d}, {f}\n", .{ position, missing.items.len, Size{ .bytes = blob.size } });
            const received = try remote.run(arena, .{
                .argv = &.{ "sh", "-c", RECEIVE_BLOB, "sh", blob.digest },
                .stdin_path = try std.fs.path.join(arena, &.{ blobs_path, blob.digest }),
            });
            if (!received.ok()) return fail(out, "a blob did not arrive whole", received);
        }

        for (METADATA) |name| {
            const path = try std.fs.path.join(arena, &.{ self.folder, name });
            const received = try remote.run(arena, .{
                .argv = &.{ "sh", "-c", RECEIVE_METADATA, "sh", self.version, name },
                .stdin_path = path,
            });
            if (!received.ok()) return fail(out, "could not send the image's description", received);
        }

        try out.writeAll("image: loading it on the server\n");
        const loaded = try remote.run(arena, .{ .argv = &.{ "sh", "-c", LOAD, "sh", self.version }, .stdin = digests.items });
        if (!loaded.ok()) return fail(out, "`docker load` failed", loaded);
        return true;
    }
};

fn contains(listing: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), name)) return true;
    }
    return false;
}

fn fail(out: *Writer, what: []const u8, result: Remote.Result) Writer.Error!bool {
    try out.print("stopped: {s}: {s}\n", .{ what, std.mem.trimEnd(u8, result.stderr, "\r\n") });
    return false;
}

const testing = std.testing;
const Fake = @import("../remote/Fake.zig");

const HasTwoBlobs = struct {
    tmp: std.testing.TmpDir,
    folder: []const u8,

    fn make(a: Allocator) !HasTwoBlobs {
        var tmp = testing.tmpDir(.{});
        try tmp.dir.createDirPath(testing.io, "blobs/sha256");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "blobs/sha256/aaaa", .data = "1234" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "blobs/sha256/bbbb", .data = "56" });
        for (METADATA) |name| try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "{}" });
        return .{ .tmp = tmp, .folder = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    }
};

test "sends only what the server lacks, records all, and loads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var blobs = try HasTwoBlobs.make(a);
    defer blobs.tmp.cleanup();
    var fake = Fake.init(a);
    try fake.on("ls \"$HOME/.cowshed/blobs/sha256\"", .{ .result = .{ .exit_code = 0, .stdout = "aaaa\nother\n" } });

    var output: Writer.Allocating = .init(a);
    const sender: Sender = .{ .io = testing.io, .folder = blobs.folder, .tag = "app:v1", .service = "app", .version = "v1" };
    try testing.expect(try sender.sendTo(a, fake.remote(), &output.writer));

    try testing.expect(fake.ran("sha256sum -c - >/dev/null; then mv \"$t\" \"$d/$1\"; else rm -f \"$t\"; exit 1; fi sh bbbb"));
    try testing.expect(!fake.ran("exit 1; fi sh aaaa"));
    const record = fake.calls.items[fake.position(".blobs").?];
    try testing.expect(std.mem.indexOf(u8, record.stdin.?, "aaaa\n") != null);
    try testing.expect(std.mem.indexOf(u8, record.stdin.?, "bbbb\n") != null);
    const load = fake.calls.items[fake.position("docker load").?];
    try testing.expect(std.mem.indexOf(u8, load.stdin.?, "aaaa\n") != null);
    try testing.expect(fake.position(".blobs").? < fake.position("sh bbbb").?);
    try testing.expect(fake.position("sh bbbb").? < fake.position("docker load").?);
}

test "a blob that does not arrive whole stops it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var blobs = try HasTwoBlobs.make(a);
    defer blobs.tmp.cleanup();
    var fake = Fake.init(a);
    try fake.on("sha256sum", .{ .result = .{ .exit_code = 1, .stderr = "checksum" } });
    var output: Writer.Allocating = .init(a);
    const sender: Sender = .{ .io = testing.io, .folder = blobs.folder, .tag = "t", .service = "app", .version = "v1" };
    try testing.expect(!try sender.sendTo(a, fake.remote(), &output.writer));
    try testing.expect(std.mem.indexOf(u8, output.written(), "did not arrive whole") != null);
    try testing.expect(!fake.ran("docker load"));
}
