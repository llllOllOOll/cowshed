const std = @import("std");
const cli = @import("cli/cli.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // No buffer: each step shows as it happens, also through a pipe. Streaming: to
    // a file, a positional writer would overwrite what a child process wrote there.
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &.{});
    const out = &stdout.interface;

    const code = try cli.run(arena, init.io, init.environ_map, out, @ptrCast(args[1..]));
    try out.flush();
    if (code != 0) std.process.exit(code);
}

test {
    _ = cli;
    _ = @import("cli/check.zig");
    _ = @import("cli/setup.zig");
    _ = @import("cli/deploy.zig");
    _ = @import("cli/lock.zig");
    _ = @import("cli/ops.zig");
    _ = @import("deploy/setup.zig");
    _ = @import("deploy/ops.zig");
    _ = @import("deploy/deploy.zig");
    _ = @import("deploy/lock.zig");
    _ = @import("proxy/detect.zig");
    _ = @import("proxy/route.zig");
    _ = @import("image/local.zig");
    _ = @import("image/send.zig");
    _ = @import("docker/commands.zig");
    _ = @import("proxy/traefik.zig");
    _ = @import("config/yaml.zig");
    _ = @import("config/Config.zig");
    _ = @import("config/secrets.zig");
    _ = @import("remote/Remote.zig");
    _ = @import("remote/process.zig");
    _ = @import("remote/Ssh.zig");
    _ = @import("remote/Fake.zig");
}
