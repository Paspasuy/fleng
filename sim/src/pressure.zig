//! Pressure projection (lesson 5): the Poisson system A·p = b on FLUID cells,
//! and the pressure-gradient update that makes the velocity divergence-free.

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const Label = grid_mod.Label;

pub const theta_min: f32 = 0.01;

/// The 7-point Laplacian stencil, matrix-free (lesson 5, §5.3):
/// row c has `diag[c]` on the diagonal and -1 for each FLUID neighbor.
/// Only FLUID cells are unknowns; every other row is identically zero.
/// Neighbors outside the array count as SOLID.
pub const Poisson = struct {
    n: [3]usize,
    label: []const Label,
    diag: []f64,

    pub fn cellCount(sys: Poisson) usize {
        return sys.n[0] * sys.n[1] * sys.n[2];
    }

    pub inline fn cellIndex(sys: Poisson, i: usize, j: usize, k: usize) usize {
        return i + sys.n[0] * (j + sys.n[1] * k);
    }

    /// Σ x over the FLUID neighbors of cell (i, j, k).
    pub inline fn neighborSum(sys: Poisson, x: []const f64, i: usize, j: usize, k: usize) f64 {
        const c = sys.cellIndex(i, j, k);
        const sx = 1;
        const sy = sys.n[0];
        const sz = sys.n[0] * sys.n[1];
        var s: f64 = 0;
        if (i > 0 and sys.label[c - sx] == .fluid) s += x[c - sx];
        if (i + 1 < sys.n[0] and sys.label[c + sx] == .fluid) s += x[c + sx];
        if (j > 0 and sys.label[c - sy] == .fluid) s += x[c - sy];
        if (j + 1 < sys.n[1] and sys.label[c + sy] == .fluid) s += x[c + sy];
        if (k > 0 and sys.label[c - sz] == .fluid) s += x[c - sz];
        if (k + 1 < sys.n[2] and sys.label[c + sz] == .fluid) s += x[c + sz];
        return s;
    }

    /// out = A·x.
    pub fn apply(sys: *const Poisson, pool: Pool, x: []const f64, out: []f64) void {
        const Ctx = struct {
            sys: *const Poisson,
            x: []const f64,
            out: []f64,
            fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
                const s = ctx.sys;
                for (begin..end) |row| {
                    const j = row % s.n[1];
                    const k = row / s.n[1];
                    for (0..s.n[0]) |i| {
                        const c = s.cellIndex(i, j, k);
                        ctx.out[c] = if (s.label[c] == .fluid) s.diag[c] * ctx.x[c] - s.neighborSum(ctx.x, i, j, k) else 0;
                    }
                }
            }
        };
        pool.forEach(sys.n[1] * sys.n[2], 4, Ctx{ .sys = sys, .x = x, .out = out }, Ctx.run);
    }
};

/// Where the surface crosses between a FLUID cell and an AIR neighbor, as a
/// fraction of the distance between their centers (lesson 5, §5.6).
pub fn theta(phi_fluid: f32, phi_air: f32) f32 {
    const denom = phi_fluid - phi_air;
    if (!(phi_fluid < 0) or !(denom < 0)) return 1;
    return std.math.clamp(phi_fluid / denom, theta_min, 1);
}

/// Diagonal of the fine system from the cell labels (lesson 5, §5.4):
/// FLUID neighbor → 1, AIR neighbor → 1 (or 1/θ with ghost fluid), SOLID → 0.
pub fn buildDiagonal(pool: Pool, grid: *const Grid, diag: []f64, ghost_fluid: bool) void {
    const Ctx = struct {
        g: *const Grid,
        diag: []f64,
        ghost: bool,
        fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
            const g = ctx.g;
            for (begin..end) |row| {
                const j = row % g.n[1];
                const k = row / g.n[1];
                for (0..g.n[0]) |i| {
                    const c = g.cellIndex(i, j, k);
                    if (g.label[c] != .fluid) {
                        ctx.diag[c] = 0;
                        continue;
                    }
                    const cell = [3]usize{ i, j, k };
                    var d: f64 = 0;
                    for (0..3) |a| for ([2]bool{ false, true }) |up| {
                        // FLUID cells never touch the array edge (walls are SOLID).
                        var nb = cell;
                        nb[a] = if (up) nb[a] + 1 else nb[a] - 1;
                        const nc = g.cellIndex(nb[0], nb[1], nb[2]);
                        switch (g.label[nc]) {
                            .fluid => d += 1,
                            .air => d += if (ctx.ghost) 1 / @as(f64, theta(g.phi[c], g.phi[nc])) else 1,
                            .solid => {},
                        }
                    };
                    ctx.diag[c] = d;
                }
            }
        }
    };
    pool.forEach(grid.n[1] * grid.n[2], 4, Ctx{ .g = grid, .diag = diag, .ghost = ghost_fluid }, Ctx.run);
}

/// b_c = -(ρ Δx² / Δt) · div*_c on FLUID cells, 0 elsewhere.
pub fn buildRhs(pool: Pool, grid: *const Grid, b: []f64, density: f32, dt: f32) void {
    const Ctx = struct {
        g: *const Grid,
        b: []f64,
        scale: f64,
        fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
            const g = ctx.g;
            for (begin..end) |row| {
                const j = row % g.n[1];
                const k = row / g.n[1];
                for (0..g.n[0]) |i| {
                    const c = g.cellIndex(i, j, k);
                    ctx.b[c] = if (g.label[c] == .fluid) -ctx.scale * g.divergence(i, j, k) else 0;
                }
            }
        }
    };
    const scale = @as(f64, density) * grid.dx * grid.dx / dt;
    pool.forEach(grid.n[1] * grid.n[2], 4, Ctx{ .g = grid, .b = b, .scale = scale }, Ctx.run);
}

/// u ← u - (Δt/ρ)·(p_high - p_low)/Δx on faces between FLUID–FLUID and
/// FLUID–AIR cells. Faces touching SOLID keep the wall's velocity. With ghost
/// fluid, an AIR side uses the extrapolated pressure p_fluid·(1 - 1/θ).
pub fn applyPressureGradient(pool: Pool, grid: *Grid, p: []const f64, density: f32, dt: f32, ghost_fluid: bool) void {
    for (0..3) |a| {
        const Ctx = struct {
            g: *Grid,
            p: []const f64,
            a: usize,
            scale: f64,
            ghost: bool,
            fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
                const g = ctx.g;
                const f = g.vel[ctx.a];
                for (begin..end) |row| {
                    const j = row % f.n[1];
                    const k = row / f.n[1];
                    for (0..f.n[0]) |i| {
                        const cells = g.faceCells(ctx.a, i, j, k);
                        const lo = cells[0] orelse continue;
                        const hi = cells[1] orelse continue;
                        const l_lo = g.label[lo];
                        const l_hi = g.label[hi];
                        if (l_lo == .solid or l_hi == .solid) continue;
                        if (l_lo != .fluid and l_hi != .fluid) continue;
                        const p_lo = ctx.side(lo, hi);
                        const p_hi = ctx.side(hi, lo);
                        const fi = f.index(i, j, k);
                        f.data[fi] -= @floatCast(ctx.scale * (p_hi - p_lo));
                    }
                }
            }
            /// Pressure on cell `c`'s side of the face shared with `other`.
            fn side(ctx: @This(), c: usize, other: usize) f64 {
                if (ctx.g.label[c] == .fluid) return ctx.p[c];
                if (!ctx.ghost) return 0;
                const th = theta(ctx.g.phi[other], ctx.g.phi[c]);
                return ctx.p[other] * (1 - 1 / @as(f64, th));
            }
        };
        const f = grid.vel[a];
        const scale = @as(f64, dt) / (@as(f64, density) * grid.dx);
        pool.forEach(f.n[1] * f.n[2], 4, Ctx{ .g = grid, .p = p, .a = a, .scale = scale, .ghost = ghost_fluid }, Ctx.run);
    }
}

/// Largest |div u| over FLUID cells: should be ~0 right after projection.
pub fn maxDivergence(pool: Pool, grid: *const Grid) f64 {
    const Ctx = struct {
        g: *const Grid,
        fn cell(ctx: @This(), c: usize) f64 {
            const g = ctx.g;
            if (g.label[c] != .fluid) return 0;
            const i = c % g.n[0];
            const j = (c / g.n[0]) % g.n[1];
            const k = c / (g.n[0] * g.n[1]);
            return @abs(g.divergence(i, j, k));
        }
    };
    return pool.maxEach(grid.cellCount(), 8192, Ctx{ .g = grid }, Ctx.cell);
}

/// Sets every face that touches a SOLID cell to the wall velocity (0: walls are static).
pub fn enforceSolidFaces(pool: Pool, grid: *Grid) void {
    for (0..3) |a| {
        const Ctx = struct {
            g: *Grid,
            a: usize,
            fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
                const f = ctx.g.vel[ctx.a];
                for (begin..end) |row| {
                    const j = row % f.n[1];
                    const k = row / f.n[1];
                    for (0..f.n[0]) |i| {
                        if (ctx.g.isSolidFace(ctx.a, i, j, k)) f.data[f.index(i, j, k)] = 0;
                    }
                }
            }
        };
        const f = grid.vel[a];
        pool.forEach(f.n[1] * f.n[2], 8, Ctx{ .g = grid, .a = a }, Ctx.run);
    }
}

// ---------------------------------------------------------------------------

test "the stencil is symmetric and positive definite" {
    const gpa = std.testing.allocator;
    var g = try Grid.init(gpa, .{ 9, 8, 7 }, 0.1);
    defer g.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(4);
    const rng = prng.random();
    // Random interior labels and level set values consistent with them.
    for (g.label, g.phi) |*l, *phi| {
        if (l.* == .solid) continue;
        const fluid = rng.float(f32) < 0.7;
        l.* = if (fluid) .fluid else .air;
        phi.* = if (fluid) -rng.float(f32) * 0.1 else rng.float(f32) * 0.1 + 1e-3;
    }
    const n = g.cellCount();
    const diag = try gpa.alloc(f64, n);
    defer gpa.free(diag);
    const pool = Pool.serial(std.testing.io);
    buildDiagonal(pool, &g, diag, true);
    const sys: Poisson = .{ .n = g.n, .label = g.label, .diag = diag };

    const x = try gpa.alloc(f64, n);
    defer gpa.free(x);
    const y = try gpa.alloc(f64, n);
    defer gpa.free(y);
    const ax = try gpa.alloc(f64, n);
    defer gpa.free(ax);
    const ay = try gpa.alloc(f64, n);
    defer gpa.free(ay);
    for (x, y, g.label) |*xi, *yi, l| {
        xi.* = if (l == .fluid) rng.float(f64) - 0.5 else 0;
        yi.* = if (l == .fluid) rng.float(f64) - 0.5 else 0;
    }
    sys.apply(pool, x, ax);
    sys.apply(pool, y, ay);
    var x_ay: f64 = 0;
    var y_ax: f64 = 0;
    var x_ax: f64 = 0;
    for (0..n) |i| {
        x_ay += x[i] * ay[i];
        y_ax += y[i] * ax[i];
        x_ax += x[i] * ax[i];
    }
    try std.testing.expectApproxEqRel(x_ay, y_ax, 1e-12);
    try std.testing.expect(x_ax > 0);
}
