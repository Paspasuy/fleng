const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The simulation core: pure Zig, no graphics dependencies.
    const sim = b.addModule("sim", .{
        .root_source_file = b.path("src/sim.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Headless runner: `zig build run -- run --scene dam_break`.
    const exe = b.addExecutable(.{
        .name = "fleng-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sim", .module = sim }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the headless simulation runner").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = sim });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
