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

    // Static library with a C interface (include/fleng_sim.h) for the C++ engine.
    const lib = b.addLibrary(.{
        .name = "fleng_sim",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            // Embedded in a C/C++ program: allocate with malloc and create threads
            // with pthreads, so the host's tools (sanitizers, profilers) see them.
            .link_libc = true,
        }),
    });
    // The C++ linker doesn't know Zig's runtime helpers, so ship them inside.
    lib.bundle_compiler_rt = true;
    b.installArtifact(lib);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{ .root_module = sim });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const capi_tests = b.addTest(.{ .root_module = lib.root_module });
    test_step.dependOn(&b.addRunArtifact(capi_tests).step);
}
