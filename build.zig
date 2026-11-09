const std = @import("std");

/// What `cowshed version` says: a release passes its tag's number with
/// `-Dversion`; any other build is the next release's number marked `-dev`.
const DEV_VERSION = @import("build.zig.zon").version ++ "-dev";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "The release's version, as in its tag without the v") orelse DEV_VERSION;
    if (std.SemanticVersion.parse(version)) |_| {} else |_| {
        std.log.err("-Dversion: `{s}` is not a version such as 1.2.3", .{version});
        std.process.exit(1);
    }

    const strip = b.option(bool, "strip", "Leave out the debug information, as a release does");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    module.addOptions("build_options", options);

    const exe = b.addExecutable(.{ .name = "cowshed", .root_module = module });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run cowshed").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
