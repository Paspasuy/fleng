//! C interface for embedding the simulation (see include/fleng_sim.h).
//! One handle is used from one thread at a time.

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const Workers = @import("pool.zig").Workers;
const simulation = @import("simulation.zig");
const scenes = @import("scenes.zig");
const surface = @import("surface.zig");

/// The library links libc (see build.zig), so memory comes from the host's malloc.
const gpa = std.heap.c_allocator;

/// Signal handling belongs to the host program. By default Zig gives each
/// thread it spawns an alternate signal stack and installs a segfault handler;
/// AddressSanitizer in the host then tries to free that stack as its own when
/// a worker thread exits, and aborts.
pub const std_options: std.Options = .{
    .signal_stack_size = null,
    .enable_segfault_handler = false,
};

const Handle = struct {
    /// Only its futex operations are used (by the worker pool).
    io_impl: std.Io.Threaded,
    workers: ?*Workers,
    sim: simulation.Simulation,
};

pub const FrameStats = extern struct {
    substeps: u32,
    iterations: u32,
    converged: u32,
};

/// Creates a scene ("still_tank", "dam_break", "drop") with `resolution` cells
/// across its x axis. `threads` = 0 uses every core. Returns null on failure.
export fn fs_create(scene: [*:0]const u8, resolution: c_int, threads: c_int) ?*Handle {
    return create(std.mem.span(scene), resolution, threads) catch null;
}

fn create(scene_name: []const u8, resolution: c_int, threads: c_int) !*Handle {
    const kind = std.meta.stringToEnum(scenes.Kind, scene_name) orelse return error.UnknownScene;
    if (resolution < 4) return error.BadResolution;
    const h = try gpa.create(Handle);
    errdefer gpa.destroy(h);
    h.io_impl = .init_single_threaded;
    const io = h.io_impl.io();

    const cores = std.Thread.getCpuCount() catch 1;
    const count: usize = if (threads > 0) @intCast(threads) else cores;
    h.workers = if (count > 1) try Workers.init(gpa, io, count - 1) else null;
    errdefer if (h.workers) |w| w.deinit();

    h.sim = try simulation.Simulation.init(gpa, .{ .io = io, .workers = h.workers }, scenes.params(kind, @intCast(resolution)));
    errdefer h.sim.deinit();
    try scenes.fill(&h.sim, kind);
    return h;
}

export fn fs_destroy(h: ?*Handle) void {
    const handle = h orelse return;
    handle.sim.deinit();
    if (handle.workers) |w| w.deinit();
    gpa.destroy(handle);
}

/// Advances by `frame_time` seconds of simulated time. Returns 0 on success.
export fn fs_advance(h: *Handle, frame_time: f32, stats: ?*FrameStats) c_int {
    const fs = h.sim.advanceFrame(frame_time) catch return -1;
    if (stats) |s| s.* = .{ .substeps = fs.substeps, .iterations = fs.iterations, .converged = @intFromBool(fs.all_converged) };
    return 0;
}

export fn fs_time(h: *const Handle) f64 {
    return h.sim.time;
}

/// Grid cells per axis (including the wall layer) and cell size in meters.
export fn fs_grid(h: *const Handle, dims: *[3]c_int, dx: *f32) void {
    for (0..3) |a| dims[a] = @intCast(h.sim.grid.n[a]);
    dx.* = h.sim.params.dx;
}

/// Size of the tank's inside in meters (the grid minus its wall layer).
export fn fs_interior(h: *const Handle, size: *[3]f32) void {
    size.* = h.sim.grid.interiorSize();
}

/// Writes the water surface as a signed distance in meters (negative inside)
/// at every cell center, x varying fastest: dims[0]·dims[1]·dims[2] floats.
export fn fs_copy_surface(h: *const Handle, out: [*]f32) void {
    const g = h.sim.grid;
    surface.redistance(g, g.phi, out[0..g.cellCount()]);
}

test "the C API runs a small scene" {
    const h = fs_create("drop", 16, 2) orelse return error.CreateFailed;
    defer fs_destroy(h);
    var stats: FrameStats = undefined;
    try std.testing.expectEqual(@as(c_int, 0), fs_advance(h, 1.0 / 60.0, &stats));
    try std.testing.expect(stats.substeps > 0 and stats.converged == 1);
    var dims: [3]c_int = undefined;
    var dx: f32 = undefined;
    fs_grid(h, &dims, &dx);
    const n: usize = @intCast(dims[0] * dims[1] * dims[2]);
    const phi = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(phi);
    fs_copy_surface(h, phi.ptr);
    var inside: usize = 0;
    for (phi) |p| {
        if (p < 0) inside += 1;
    }
    try std.testing.expect(inside > 0 and inside < n);
    try std.testing.expect(fs_create("nope", 16, 1) == null);
}
