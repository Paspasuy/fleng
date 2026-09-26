//! Particles → water surface (lesson 7). Zhu & Bridson's level set at cell
//! centers, then FLUID/AIR labels from its sign (lesson 7, §7.6).

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const Grid = @import("grid.zig").Grid;
const Particles = @import("particles.zig").Particles;

pub const Params = struct {
    /// Particle radius, in cells. Calibrated so a flat layer's surface lands on the
    /// true water boundary (see the "flat slab" test).
    radius: f32 = default_radius,
    /// How far particles influence the average, in cells. 1.5 is as accurate as
    /// 2 here (after recalibrating `radius`) and about 2.4× cheaper.
    kernel_radius: f32 = 1.5,
};

pub const default_radius = 0.42;

/// Per-cell accumulators for `computePhi`.
pub const Workspace = struct {
    sum_w: []f32,
    sum_x: [3][]f32,

    pub fn init(gpa: std.mem.Allocator, cells: usize) !Workspace {
        var ws: Workspace = .{ .sum_w = &.{}, .sum_x = .{ &.{}, &.{}, &.{} } };
        errdefer ws.deinit(gpa);
        ws.sum_w = try gpa.alloc(f32, cells);
        for (&ws.sum_x) |*a| a.* = try gpa.alloc(f32, cells);
        return ws;
    }

    pub fn deinit(ws: *Workspace, gpa: std.mem.Allocator) void {
        gpa.free(ws.sum_w);
        for (ws.sum_x) |a| gpa.free(a);
    }
};

/// φ at every cell center:
///   x̄ = Σ k(|x - x_p| / R) x_p / Σ k,   φ = |x - x̄| - r,   k(s) = max(0, 1 - s²)³
/// Cells with no particle within R get φ = R (a safe, positive underestimate).
/// Each particle scatters into the cell centers within R (colored, so no races).
/// Particles must be sorted by cell.
pub fn computePhi(pool: Pool, grid: *Grid, particles: *const Particles, params: Params, ws: *Workspace) void {
    std.debug.assert(params.kernel_radius <= 2); // the coloring allows writes 2 cells away
    @memset(ws.sum_w, 0);
    for (ws.sum_x) |a| @memset(a, 0);

    const Scatter = struct {
        g: *const Grid,
        p: *const Particles,
        ws: *Workspace,
        kernel_radius: f32,
        fn run(ctx: @This(), first: usize, last: usize) void {
            const g = ctx.g;
            const R = ctx.kernel_radius * g.dx;
            const inv_r2 = 1 / (R * R);
            for (first..last) |pi| {
                const x = ctx.p.position(pi);
                // Cell centers (c + ½)·Δx within R of the particle.
                var lo: [3]usize = undefined;
                var hi: [3]usize = undefined;
                for (0..3) |a| {
                    const f = x[a] / g.dx - 0.5;
                    const top: f32 = @floatFromInt(g.n[a] - 1);
                    lo[a] = @intFromFloat(std.math.clamp(@ceil(f - ctx.kernel_radius), 0, top));
                    hi[a] = @intFromFloat(std.math.clamp(@floor(f + ctx.kernel_radius), 0, top));
                }
                for (lo[2]..hi[2] + 1) |k| for (lo[1]..hi[1] + 1) |j| for (lo[0]..hi[0] + 1) |i| {
                    const c = g.cellCenter(i, j, k);
                    var d2: f32 = 0;
                    for (0..3) |a| d2 += (c[a] - x[a]) * (c[a] - x[a]);
                    const s2 = d2 * inv_r2;
                    if (s2 >= 1) continue;
                    const t = 1 - s2;
                    const w = t * t * t;
                    const ci = g.cellIndex(i, j, k);
                    ctx.ws.sum_w[ci] += w;
                    for (0..3) |a| ctx.ws.sum_x[a][ci] += w * x[a];
                };
            }
        }
    };
    particles.forEachBlockColored(pool, grid.*, 4, Scatter{ .g = grid, .p = particles, .ws = ws, .kernel_radius = params.kernel_radius }, Scatter.run);

    const Finish = struct {
        g: *Grid,
        ws: *const Workspace,
        params: Params,
        fn f(ctx: @This(), ci: usize) void {
            const g = ctx.g;
            const R = ctx.params.kernel_radius * g.dx;
            const w = ctx.ws.sum_w[ci];
            if (g.label[ci] == .solid or w == 0) {
                g.phi[ci] = R;
                return;
            }
            const i = ci % g.n[0];
            const j = (ci / g.n[0]) % g.n[1];
            const k = ci / (g.n[0] * g.n[1]);
            const x = g.cellCenter(i, j, k);
            var d2: f32 = 0;
            for (0..3) |a| {
                const d = x[a] - ctx.ws.sum_x[a][ci] / w;
                d2 += d * d;
            }
            g.phi[ci] = @min(@sqrt(d2) - ctx.params.radius * g.dx, R);
        }
    };
    pool.each(grid.cellCount(), 8192, Finish{ .g = grid, .ws = ws, .params = params }, Finish.f);
}

/// Non-solid cells become FLUID where φ < 0 and AIR elsewhere.
pub fn labelCells(grid: *Grid) void {
    for (grid.label, grid.phi) |*l, phi| {
        if (l.* == .solid) continue;
        l.* = if (phi < 0) .fluid else .air;
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Height where φ crosses zero in the column (i, k), by linear interpolation
/// between cell centers.
fn surfaceHeight(g: Grid, i: usize, k: usize) ?f32 {
    for (1..g.n[1] - 1) |j| {
        const a = g.phi[g.cellIndex(i, j - 1, k)];
        const b = g.phi[g.cellIndex(i, j, k)];
        if (a < 0 and b >= 0) {
            const y0 = (@as(f32, @floatFromInt(j)) - 0.5) * g.dx;
            return y0 + g.dx * a / (a - b);
        }
    }
    return null;
}

fn slabSurfaceError(radius: f32, jitter: f32) !f32 {
    const gpa = testing.allocator;
    var g = try Grid.init(gpa, .{ 12, 16, 12 }, 1);
    defer g.deinit(gpa);
    var p: Particles = .{};
    defer p.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(21);
    const water_top: f32 = 7;
    try p.seed(gpa, g, .{ .box = .{ .min = .{ 0, 0, 0 }, .max = .{ 12, water_top, 12 } } }, .{ 0, 0, 0 }, prng.random(), jitter);
    try p.sortByCell(gpa, g);
    var ws = try Workspace.init(gpa, g.cellCount());
    defer ws.deinit(gpa);
    computePhi(Pool.serial(testing.io), &g, &p, .{ .radius = radius }, &ws);
    var worst: f32 = 0;
    for (3..9) |k| for (3..9) |i| {
        const h = surfaceHeight(g, i, k) orelse return error.NoSurface;
        worst = @max(worst, @abs(h - water_top));
    };
    return worst;
}

test "flat slab: the surface sits on the true water boundary" {
    try testing.expect(try slabSurfaceError(default_radius, 0) < 0.05);
    // Random jitter makes the surface slightly bumpy, but it stays within a fraction of a cell.
    try testing.expect(try slabSurfaceError(default_radius, 1) < 0.15);
}

test "sphere: the surface radius matches the seeded radius" {
    const gpa = testing.allocator;
    var g = try Grid.init(gpa, .{ 24, 24, 24 }, 1);
    defer g.deinit(gpa);
    var p: Particles = .{};
    defer p.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(2);
    const radius: f32 = 7;
    try p.seed(gpa, g, .{ .sphere = .{ .center = .{ 12, 12, 12 }, .radius = radius } }, .{ 0, 0, 0 }, prng.random(), 0);
    try p.sortByCell(gpa, g);
    var ws = try Workspace.init(gpa, g.cellCount());
    defer ws.deinit(gpa);
    computePhi(Pool.serial(testing.io), &g, &p, .{}, &ws);
    // Along the +x axis from the center (cell 12 center is at 12.5).
    for (12..23) |i| {
        const a = g.phi[g.cellIndex(i, 12, 12)];
        const b = g.phi[g.cellIndex(i + 1, 12, 12)];
        if (a < 0 and b >= 0) {
            const x = @as(f32, @floatFromInt(i)) + 0.5 + a / (a - b);
            const r = @sqrt((x - 12) * (x - 12) + 0.5 * 0.5 + 0.5 * 0.5);
            try testing.expectApproxEqAbs(radius, r, 0.35);
            return;
        }
    }
    return error.NoSurface;
}
