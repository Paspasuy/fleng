//! Geometric multigrid V-cycle (lesson 6, §6.4), used as the CG preconditioner.
//!
//! Every piece is chosen so the whole cycle is a symmetric linear operator,
//! which CG requires (lesson 6, §6.4 "Symmetry"):
//! - smoothing: damped Jacobi, the same number of sweeps before and after,
//!   starting from zero;
//! - prolongation P: trilinear interpolation between cell centers;
//! - restriction: ½·Pᵀ, the exact transpose of P (the ½ also accounts for the
//!   coarse cells being 2× larger; see `restrict`);
//! - coarsest level: a fixed number of Jacobi sweeps from zero.

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const Label = @import("grid.zig").Label;
const Poisson = @import("pressure.zig").Poisson;

const Level = struct {
    sys: Poisson,
    x: []f64,
    b: []f64,
    r: []f64,
    tmp: []f64,
};

pub const Multigrid = struct {
    levels: []Level,
    /// Damped Jacobi weight: 6/7 is the best smoother for the 3D 7-point stencil.
    omega: f64 = 6.0 / 7.0,
    sweeps: u32 = 2,
    coarsest_sweeps: u32 = 40,

    /// Builds the hierarchy for a fine grid of `n` cells, halving until the
    /// smallest dimension would drop below 4.
    pub fn init(gpa: std.mem.Allocator, n: [3]usize) !Multigrid {
        var dims: std.ArrayList([3]usize) = .empty;
        defer dims.deinit(gpa);
        try dims.append(gpa, n);
        while (true) {
            const last = dims.items[dims.items.len - 1];
            if (@min(last[0], last[1], last[2]) < 8) break;
            try dims.append(gpa, .{ (last[0] + 1) / 2, (last[1] + 1) / 2, (last[2] + 1) / 2 });
        }
        const levels = try gpa.alloc(Level, dims.items.len);
        var built: usize = 0;
        errdefer {
            for (levels[0..built], 0..) |*l, i| freeLevel(gpa, l, i);
            gpa.free(levels);
        }
        for (dims.items, 0..) |d, i| {
            const count = d[0] * d[1] * d[2];
            var l: Level = .{ .sys = .{ .n = d, .label = &.{}, .diag = &.{} }, .x = &.{}, .b = &.{}, .r = &.{}, .tmp = &.{} };
            // Level 0 borrows the fine system and the caller's x and b.
            if (i > 0) {
                l.sys.label = try gpa.alloc(Label, count);
                l.sys.diag = try gpa.alloc(f64, count);
                l.x = try gpa.alloc(f64, count);
                l.b = try gpa.alloc(f64, count);
            }
            l.r = try gpa.alloc(f64, count);
            l.tmp = try gpa.alloc(f64, count);
            levels[i] = l;
            built += 1;
        }
        return .{ .levels = levels };
    }

    pub fn deinit(mg: *Multigrid, gpa: std.mem.Allocator) void {
        for (mg.levels, 0..) |*l, i| freeLevel(gpa, l, i);
        gpa.free(mg.levels);
    }

    fn freeLevel(gpa: std.mem.Allocator, l: *Level, i: usize) void {
        if (i > 0) {
            gpa.free(l.sys.label);
            gpa.free(l.sys.diag);
            gpa.free(l.x);
            gpa.free(l.b);
        }
        gpa.free(l.r);
        gpa.free(l.tmp);
    }

    /// Call whenever the fine labels or diagonal change (every time step).
    /// Coarse labels (McAdams et al. 2010): AIR if any child is AIR, else
    /// FLUID if any child is FLUID, else SOLID. Coarse stencils are rebuilt
    /// from those labels (no ghost fluid on coarse levels).
    pub fn setup(mg: *Multigrid, fine: *const Poisson) void {
        mg.levels[0].sys = fine.*;
        for (1..mg.levels.len) |li| {
            const f = mg.levels[li - 1].sys;
            const c = &mg.levels[li].sys;
            const labels: []Label = @constCast(c.label);
            for (0..c.n[2]) |k| for (0..c.n[1]) |j| for (0..c.n[0]) |i| {
                var any_air = false;
                var any_fluid = false;
                for (0..2) |dk| for (0..2) |dj| for (0..2) |di| {
                    const fi = 2 * i + di;
                    const fj = 2 * j + dj;
                    const fk = 2 * k + dk;
                    if (fi >= f.n[0] or fj >= f.n[1] or fk >= f.n[2]) continue;
                    switch (f.label[f.cellIndex(fi, fj, fk)]) {
                        .air => any_air = true,
                        .fluid => any_fluid = true,
                        .solid => {},
                    }
                };
                labels[c.cellIndex(i, j, k)] = if (any_air) .air else if (any_fluid) .fluid else .solid;
            };
            for (0..c.n[2]) |k| for (0..c.n[1]) |j| for (0..c.n[0]) |i| {
                const ci = c.cellIndex(i, j, k);
                if (labels[ci] != .fluid) {
                    c.diag[ci] = 0;
                    continue;
                }
                const cell = [3]usize{ i, j, k };
                var d: f64 = 0;
                for (0..3) |a| for ([2]bool{ false, true }) |up| {
                    if (!up and cell[a] == 0) continue;
                    if (up and cell[a] + 1 >= c.n[a]) continue;
                    var nb = cell;
                    nb[a] = if (up) nb[a] + 1 else nb[a] - 1;
                    if (labels[c.cellIndex(nb[0], nb[1], nb[2])] != .solid) d += 1;
                };
                c.diag[ci] = d;
            };
        }
    }

    /// z = M⁻¹·r: one V-cycle starting from zero.
    pub fn vcycle(mg: *Multigrid, pool: Pool, r: []const f64, z: []f64) void {
        mg.levels[0].b = @constCast(r);
        mg.levels[0].x = z;
        mg.cycle(pool, 0);
    }

    fn cycle(mg: *Multigrid, pool: Pool, li: usize) void {
        const l = &mg.levels[li];
        if (li + 1 == mg.levels.len) {
            mg.smooth(pool, l, mg.coarsest_sweeps);
            return;
        }
        mg.smooth(pool, l, mg.sweeps);
        // r = b - A·x
        l.sys.apply(pool, l.x, l.tmp);
        for (l.r, l.b, l.tmp) |*ri, bi, ti| ri.* = bi - ti;
        const coarse = &mg.levels[li + 1];
        restrict(pool, l, coarse);
        mg.cycle(pool, li + 1);
        prolongAdd(pool, coarse, l);
        mg.smoothMore(pool, l, mg.sweeps);
    }

    /// `count` damped Jacobi sweeps starting from x = 0.
    fn smooth(mg: *Multigrid, pool: Pool, l: *Level, count: u32) void {
        // The first sweep from zero is just x = ω·b/diag.
        for (l.x, l.b, l.sys.diag, l.sys.label) |*xi, bi, di, lab| {
            xi.* = if (lab == .fluid and di > 0) mg.omega * bi / di else 0;
        }
        mg.smoothMore(pool, l, count - 1);
    }

    /// `count` damped Jacobi sweeps from the current x: x += ω·(b - A·x)/diag.
    fn smoothMore(mg: *Multigrid, pool: Pool, l: *Level, count: u32) void {
        for (0..count) |_| {
            l.sys.apply(pool, l.x, l.tmp);
            const Ctx = struct {
                l: *Level,
                omega: f64,
                fn f(c: @This(), i: usize) void {
                    const d = c.l.sys.diag[i];
                    if (c.l.sys.label[i] == .fluid and d > 0) c.l.x[i] += c.omega * (c.l.b[i] - c.l.tmp[i]) / d;
                }
            };
            pool.each(l.x.len, 8192, Ctx{ .l = l, .omega = mg.omega }, Ctx.f);
        }
    }
};

/// Trilinear weight between fine cell `i` and coarse cell `I` along one axis.
/// A fine cell center sits a quarter of a coarse cell from its parent's center:
/// weight 3/4 for the parent, 1/4 for the parent's neighbor on the same side.
inline fn weight1(i: usize, I: usize) f64 {
    const parent = i / 2;
    if (parent == I) return 0.75;
    const toward_low = i % 2 == 0;
    if (toward_low and parent >= 1 and parent - 1 == I) return 0.25;
    if (!toward_low and parent + 1 == I) return 0.25;
    return 0;
}

/// coarse.b = ½·Pᵀ·fine.r.
///
/// Why ½: the matrices are scaled by Δx² (lesson 5, §5.3), so a coarse cell's
/// equation is 4× a fine one's for the same smooth error. Pᵀ sums 8 children
/// worth of weight (weights per coarse cell add up to 8), so 4/8 = ½ turns the
/// sum into "4 × weighted average".
fn restrict(pool: Pool, fine: *const Level, coarse: *Level) void {
    const Ctx = struct {
        f: *const Level,
        c: *Level,
        fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
            const fs = ctx.f.sys;
            const cs = ctx.c.sys;
            for (begin..end) |row| {
                const J = row % cs.n[1];
                const K = row / cs.n[1];
                for (0..cs.n[0]) |I| {
                    const ci = cs.cellIndex(I, J, K);
                    if (cs.label[ci] != .fluid) {
                        ctx.c.b[ci] = 0;
                        continue;
                    }
                    const C = [3]usize{ I, J, K };
                    var lo: [3]usize = undefined;
                    var hi: [3]usize = undefined;
                    for (0..3) |a| {
                        lo[a] = (2 * C[a]) -| 1;
                        hi[a] = @min(2 * C[a] + 2, fs.n[a] - 1);
                    }
                    var s: f64 = 0;
                    for (lo[2]..hi[2] + 1) |k| for (lo[1]..hi[1] + 1) |j| for (lo[0]..hi[0] + 1) |i| {
                        const fi = fs.cellIndex(i, j, k);
                        if (fs.label[fi] != .fluid) continue;
                        s += weight1(i, I) * weight1(j, J) * weight1(k, K) * ctx.f.r[fi];
                    };
                    ctx.c.b[ci] = 0.5 * s;
                }
            }
        }
    };
    pool.forEach(coarse.sys.n[1] * coarse.sys.n[2], 2, Ctx{ .f = fine, .c = coarse }, Ctx.run);
}

/// fine.x += P·coarse.x, only on FLUID cells, reading only FLUID coarse cells.
fn prolongAdd(pool: Pool, coarse: *const Level, fine: *Level) void {
    const Ctx = struct {
        c: *const Level,
        f: *Level,
        fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
            const fs = ctx.f.sys;
            const cs = ctx.c.sys;
            for (begin..end) |row| {
                const j = row % fs.n[1];
                const k = row / fs.n[1];
                for (0..fs.n[0]) |i| {
                    const fi = fs.cellIndex(i, j, k);
                    if (fs.label[fi] != .fluid) continue;
                    const F = [3]usize{ i, j, k };
                    // Parent and the neighbor on the same side, per axis.
                    var cand: [3][2]?usize = undefined;
                    for (0..3) |a| {
                        const parent = F[a] / 2;
                        const nb: ?usize = if (F[a] % 2 == 0)
                            (if (parent >= 1) parent - 1 else null)
                        else
                            (if (parent + 1 < cs.n[a]) parent + 1 else null);
                        cand[a] = .{ parent, nb };
                    }
                    var s: f64 = 0;
                    for (cand[2]) |ck| for (cand[1]) |cj| for (cand[0]) |cii| {
                        const I = cii orelse continue;
                        const J = cj orelse continue;
                        const K = ck orelse continue;
                        const ci = cs.cellIndex(I, J, K);
                        if (cs.label[ci] != .fluid) continue;
                        s += weight1(i, I) * weight1(j, J) * weight1(k, K) * ctx.c.x[ci];
                    };
                    ctx.f.x[fi] += s;
                }
            }
        }
    };
    pool.forEach(fine.sys.n[1] * fine.sys.n[2], 4, Ctx{ .c = coarse, .f = fine }, Ctx.run);
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const Grid = @import("grid.zig").Grid;
const pressure = @import("pressure.zig");
const cg = @import("cg.zig");

/// A tank with a free surface and a floating blob, plus a random right-hand side.
const TestProblem = struct {
    grid: Grid,
    diag: []f64,
    b: []f64,

    fn init(gpa: std.mem.Allocator, n: [3]usize, seed: u64) !TestProblem {
        var g = try Grid.init(gpa, n, 1);
        errdefer g.deinit(gpa);
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        for (0..n[2]) |k| for (0..n[1]) |j| for (0..n[0]) |i| {
            const c = g.cellIndex(i, j, k);
            if (g.label[c] == .solid) continue;
            const pool_fluid = j < n[1] / 2;
            const dxb = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(n[0])) * 0.5;
            const dyb = @as(f32, @floatFromInt(j)) - @as(f32, @floatFromInt(n[1])) * 0.75;
            const blob = dxb * dxb + dyb * dyb < 4;
            const fluid = pool_fluid or blob;
            g.label[c] = if (fluid) .fluid else .air;
            g.phi[c] = if (fluid) -0.5 - rng.float(f32) * 0.4 else 0.1 + rng.float(f32) * 0.8;
        };
        const diag = try gpa.alloc(f64, g.cellCount());
        const b = try gpa.alloc(f64, g.cellCount());
        pressure.buildDiagonal(Pool.serial(testing.io), &g, diag, true);
        for (b, g.label) |*bi, l| bi.* = if (l == .fluid) rng.float(f64) - 0.5 else 0;
        return .{ .grid = g, .diag = diag, .b = b };
    }

    fn deinit(tp: *TestProblem, gpa: std.mem.Allocator) void {
        tp.grid.deinit(gpa);
        gpa.free(tp.diag);
        gpa.free(tp.b);
    }

    fn system(tp: *const TestProblem) Poisson {
        return .{ .n = tp.grid.n, .label = tp.grid.label, .diag = tp.diag };
    }
};

test "the V-cycle is a symmetric operator" {
    const gpa = testing.allocator;
    var tp = try TestProblem.init(gpa, .{ 20, 18, 16 }, 1);
    defer tp.deinit(gpa);
    const sys = tp.system();
    var mg = try Multigrid.init(gpa, sys.n);
    defer mg.deinit(gpa);
    mg.setup(&sys);
    const n = sys.cellCount();
    var prng = std.Random.DefaultPrng.init(8);
    const bufs = try gpa.alloc(f64, 4 * n);
    defer gpa.free(bufs);
    const x = bufs[0..n];
    const y = bufs[n .. 2 * n];
    const mx = bufs[2 * n .. 3 * n];
    const my = bufs[3 * n ..];
    for (x, y, sys.label) |*xi, *yi, l| {
        xi.* = if (l == .fluid) prng.random().float(f64) - 0.5 else 0;
        yi.* = if (l == .fluid) prng.random().float(f64) - 0.5 else 0;
    }
    const pool = Pool.serial(testing.io);
    mg.vcycle(pool, x, mx);
    mg.vcycle(pool, y, my);
    var x_my: f64 = 0;
    var y_mx: f64 = 0;
    for (0..n) |i| {
        x_my += x[i] * my[i];
        y_mx += y[i] * mx[i];
    }
    try testing.expectApproxEqRel(x_my, y_mx, 1e-10);
    try testing.expect(x_my != 0);
}

test "MGPCG and plain CG agree, and MGPCG needs far fewer iterations" {
    const gpa = testing.allocator;
    var tp = try TestProblem.init(gpa, .{ 34, 34, 34 }, 2);
    defer tp.deinit(gpa);
    const sys = tp.system();
    const n = sys.cellCount();
    var ws = try cg.Workspace.init(gpa, n);
    defer ws.deinit(gpa);
    var mg = try Multigrid.init(gpa, sys.n);
    defer mg.deinit(gpa);
    mg.setup(&sys);

    const x_cg = try gpa.alloc(f64, n);
    defer gpa.free(x_cg);
    const x_mg = try gpa.alloc(f64, n);
    defer gpa.free(x_mg);
    @memset(x_cg, 0);
    @memset(x_mg, 0);
    const pool: Pool = .{ .io = testing.io };
    const r_cg = cg.solve(pool, &sys, tp.b, x_cg, &ws, 1e-9, 5000, null);
    const r_mg = cg.solve(pool, &sys, tp.b, x_mg, &ws, 1e-9, 5000, &mg);
    try testing.expect(r_cg.converged and r_mg.converged);
    try testing.expect(r_mg.iterations * 3 < r_cg.iterations);

    var max_diff: f64 = 0;
    var max_x: f64 = 0;
    for (x_cg, x_mg) |a, b| {
        max_diff = @max(max_diff, @abs(a - b));
        max_x = @max(max_x, @abs(a));
    }
    try testing.expect(max_diff < 1e-6 * max_x);
}
