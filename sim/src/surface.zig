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

/// Rebuilds a true signed distance from a level set that is only accurate
/// next to the surface (lesson 7, §7.4): Zhu–Bridson gives about -r deep
/// inside the water, which would make rays crawl through it.
///
/// 1. Cells with a neighbor of the opposite sign locate the surface. Their
///    distance is rebuilt from where φ changes sign: Zhu–Bridson's φ changes
///    only ~0.6 per unit of distance across the surface, and a renderer that
///    trusts it as a distance steps too little and misjudges how deep a point is.
/// 2. Every other cell gets the distance through them from fast sweeping
///    (Zhao 2005), which solves |∇φ| = 1 with upwind differences in 8 sweep
///    directions.
/// `phi` and `out` have the grid's cell layout; `out` may not alias `phi`.
pub fn redistance(grid: Grid, phi: []const f32, out: []f32) void {
    const n = grid.n;
    const h = grid.dx;
    const far = std.math.floatMax(f32);
    // Work on |φ|, with the band next to the surface fixed.
    for (0..n[2]) |k| for (0..n[1]) |j| for (0..n[0]) |i| {
        const c = grid.cellIndex(i, j, k);
        out[c] = if (nextToSurface(grid, phi, i, j, k)) surfaceDistance(grid, phi, i, j, k) else far;
    };
    for (0..2) |_| {
        for (0..8) |dir| {
            for (0..n[2]) |kk| for (0..n[1]) |jj| for (0..n[0]) |ii| {
                const i = if (dir & 1 == 0) ii else n[0] - 1 - ii;
                const j = if (dir & 2 == 0) jj else n[1] - 1 - jj;
                const k = if (dir & 4 == 0) kk else n[2] - 1 - kk;
                const c = grid.cellIndex(i, j, k);
                if (nextToSurface(grid, phi, i, j, k)) continue;
                // Smallest neighbor distance along each axis, sorted a ≤ b ≤ c.
                var m = [3]f32{
                    axisMin(out, c, i, n[0], 1),
                    axisMin(out, c, j, n[1], n[0]),
                    axisMin(out, c, k, n[2], n[0] * n[1]),
                };
                std.mem.sort(f32, &m, {}, std.sort.asc(f32));
                if (m[0] == far) continue;
                // Largest d with Σ max(d - m_i, 0)² = h², using as few axes as possible.
                var d = m[0] + h;
                if (d > m[1]) {
                    d = 0.5 * (m[0] + m[1] + @sqrt(@max(2 * h * h - (m[0] - m[1]) * (m[0] - m[1]), 0)));
                    if (d > m[2]) {
                        const s = m[0] + m[1] + m[2];
                        const q = m[0] * m[0] + m[1] * m[1] + m[2] * m[2] - h * h;
                        d = (s + @sqrt(@max(s * s - 3 * q, 0))) / 3;
                    }
                }
                out[c] = @min(out[c], d);
            };
        }
    }
    for (out, phi) |*o, p| {
        if (p < 0) o.* = -o.*;
    }
}

/// Distance from a cell next to the surface to the surface. Along each axis,
/// linear interpolation toward the neighbor closer to the surface puts the
/// crossing a fraction θ of a cell away (θ > 1 means beyond the neighbor, on
/// axes without a sign change); for a locally flat surface the perpendicular
/// distance d satisfies 1/d² = Σ 1/θ². Only ratios of φ are used, so it doesn't
/// matter how φ is scaled, and only neighbors nearer the surface, where
/// Zhu–Bridson's values are trustworthy.
fn surfaceDistance(grid: Grid, phi: []const f32, i: usize, j: usize, k: usize) f32 {
    const c = grid.cellIndex(i, j, k);
    const cell = [3]usize{ i, j, k };
    const stride = [3]usize{ 1, grid.n[0], grid.n[0] * grid.n[1] };
    var inv2: f32 = 0;
    for (0..3) |a| {
        var theta = std.math.floatMax(f32);
        for ([2]bool{ false, true }) |up| {
            if (!up and cell[a] == 0) continue;
            if (up and cell[a] + 1 >= grid.n[a]) continue;
            const nb = if (up) c + stride[a] else c - stride[a];
            // Positive only if |φ| shrinks (or changes sign) toward the neighbor.
            const t = phi[c] / (phi[c] - phi[nb]);
            if (t > 0) theta = @min(theta, t);
        }
        if (theta < std.math.floatMax(f32)) {
            const t = @max(theta, 1e-3);
            inv2 += 1 / (t * t);
        }
    }
    return grid.dx / @sqrt(inv2);
}

fn nextToSurface(grid: Grid, phi: []const f32, i: usize, j: usize, k: usize) bool {
    const c = grid.cellIndex(i, j, k);
    const inside = phi[c] < 0;
    const cell = [3]usize{ i, j, k };
    const stride = [3]usize{ 1, grid.n[0], grid.n[0] * grid.n[1] };
    for (0..3) |a| {
        if (cell[a] > 0 and (phi[c - stride[a]] < 0) != inside) return true;
        if (cell[a] + 1 < grid.n[a] and (phi[c + stride[a]] < 0) != inside) return true;
    }
    return false;
}

inline fn axisMin(u: []const f32, c: usize, coord: usize, len: usize, stride: usize) f32 {
    var m = std.math.floatMax(f32);
    if (coord > 0) m = @min(m, u[c - stride]);
    if (coord + 1 < len) m = @min(m, u[c + stride]);
    return m;
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

test "redistancing recovers true distances deep inside and far outside" {
    const gpa = testing.allocator;
    var g = try Grid.init(gpa, .{ 32, 32, 32 }, 1);
    defer g.deinit(gpa);
    const exact = try gpa.alloc(f32, g.cellCount());
    defer gpa.free(exact);
    const out = try gpa.alloc(f32, g.cellCount());
    defer gpa.free(out);
    // A sphere of radius 9; mimic Zhu–Bridson: accurate near the surface,
    // flattening out at -0.42 inside and clamped to 1.5 outside.
    for (0..32) |k| for (0..32) |j| for (0..32) |i| {
        const x = g.cellCenter(i, j, k);
        const d = @sqrt((x[0] - 16) * (x[0] - 16) + (x[1] - 16) * (x[1] - 16) + (x[2] - 16) * (x[2] - 16)) - 9;
        const c = g.cellIndex(i, j, k);
        exact[c] = d;
        g.phi[c] = std.math.clamp(d, -0.42, 1.5);
    };
    redistance(g, g.phi, out);
    // Fast sweeping is first-order: measured here, it's within 10% of the true
    // distance and overestimates by at most ~8%. The renderer steps 0.9× the
    // distance so an overestimate can't carry a ray through the surface.
    var rel: f32 = 0;
    var rel_over: f32 = 0;
    for (exact, out) |e, o| {
        if (@abs(e) <= 1) continue;
        rel = @max(rel, @abs(o - e) / @abs(e));
        rel_over = @max(rel_over, (@abs(o) - @abs(e)) / @abs(e));
    }
    try testing.expect(rel < 0.12);
    // The renderer marches 0.9× the distance, which absorbs up to 1/0.9 - 1 ≈ 11%.
    try testing.expect(rel_over < 0.1);
    // The cell at the center is 8.13 cells deep; Zhu–Bridson alone would say 0.42.
    const center = g.cellIndex(16, 16, 16);
    try testing.expect(out[center] < -7);
}

test "redistancing turns a squashed field into distances near the surface too" {
    const gpa = testing.allocator;
    var g = try Grid.init(gpa, .{ 32, 32, 32 }, 1);
    defer g.deinit(gpa);
    const out = try gpa.alloc(f32, g.cellCount());
    defer gpa.free(out);
    // Like Zhu–Bridson near the surface: the right zero set, but φ changing
    // only 0.6 per unit of distance.
    for (0..32) |k| for (0..32) |j| for (0..32) |i| {
        const x = g.cellCenter(i, j, k);
        const d = @sqrt((x[0] - 16) * (x[0] - 16) + (x[1] - 16) * (x[1] - 16) + (x[2] - 16) * (x[2] - 16)) - 9;
        g.phi[g.cellIndex(i, j, k)] = 0.6 * d;
    };
    redistance(g, g.phi, out);
    var worst: f32 = 0;
    for (0..32) |k| for (0..32) |j| for (0..32) |i| {
        const x = g.cellCenter(i, j, k);
        const d = @sqrt((x[0] - 16) * (x[0] - 16) + (x[1] - 16) * (x[1] - 16) + (x[2] - 16) * (x[2] - 16)) - 9;
        if (@abs(d) < 2) worst = @max(worst, @abs(out[g.cellIndex(i, j, k)] - d));
    };
    // Within 2 cells of the surface the result is a real distance (0.6× before).
    try testing.expect(worst < 0.15);
}
