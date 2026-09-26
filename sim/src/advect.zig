//! Moving particles through the grid velocity field (lesson 4, §4.3).

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const Grid = @import("grid.zig").Grid;
const Particles = @import("particles.zig").Particles;

/// RK2 (midpoint): probe the velocity half a step ahead, then take the full
/// step with it. Particles are then pushed back inside the walls.
pub fn advect(pool: Pool, grid: *const Grid, particles: *Particles, dt: f32) void {
    const Ctx = struct {
        g: *const Grid,
        p: *Particles,
        dt: f32,
        fn f(ctx: @This(), i: usize) void {
            const x = ctx.p.position(i);
            const v1 = ctx.g.sampleVelocity(x);
            var mid: [3]f32 = undefined;
            for (0..3) |a| mid[a] = x[a] + 0.5 * ctx.dt * v1[a];
            const v2 = ctx.g.sampleVelocity(mid);
            var next: [3]f32 = undefined;
            for (0..3) |a| next[a] = x[a] + ctx.dt * v2[a];
            next = clampToInterior(ctx.g.*, next);
            for (0..3) |a| ctx.p.pos[a][i] = next[a];
        }
    };
    pool.each(particles.len, 2048, Ctx{ .g = grid, .p = particles, .dt = dt }, Ctx.f);
}

/// Keeps a position inside the box of non-wall cells, 0.01 cells from the walls.
pub fn clampToInterior(grid: Grid, pos: [3]f32) [3]f32 {
    var out = pos;
    const margin = 0.01 * grid.dx;
    for (0..3) |a| {
        const lo = grid.dx + margin;
        const hi = @as(f32, @floatFromInt(grid.n[a] - 1)) * grid.dx - margin;
        out[a] = std.math.clamp(pos[a], lo, hi);
    }
    return out;
}

test "RK2 keeps particles on their circles in a rigid rotation" {
    const gpa = std.testing.allocator;
    const n = 34;
    var g = try Grid.init(gpa, .{ n, n, 3 }, 1);
    defer g.deinit(gpa);
    // u = (-(y - c), x - c, 0): angular speed 1 around the center c.
    const c: f32 = @as(f32, @floatFromInt(n)) / 2;
    for (0..2) |a| {
        const f = g.vel[a];
        for (0..f.n[2]) |k| for (0..f.n[1]) |j| for (0..f.n[0]) |i| {
            const x = @as(f32, @floatFromInt(i)) + f.offset[0] - c;
            const y = @as(f32, @floatFromInt(j)) + f.offset[1] - c;
            f.data[f.index(i, j, k)] = if (a == 0) -y else x;
        };
    }
    var p: Particles = .{};
    defer p.deinit(gpa);
    try p.append(gpa, .{ c + 10, c, 1.5 }, .{ 0, 0, 0 });
    // Max speed 10 cells/s; dt = 0.1 is CFL number 1. One revolution = 2π s.
    const dt: f32 = 0.1;
    const steps: usize = @intFromFloat(@round(2 * std.math.pi / dt));
    for (0..steps) |_| advect(Pool.serial(std.testing.io), &g, &p, dt);
    const dx = p.pos[0][0] - c;
    const dy = p.pos[1][0] - c;
    const r = @sqrt(dx * dx + dy * dy);
    try std.testing.expectApproxEqRel(@as(f32, 10), r, 0.002);
}
