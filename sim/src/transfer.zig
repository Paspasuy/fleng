//! Particle ↔ grid transfers (lesson 3): PIC, FLIP, and APIC with the
//! quadratic B-spline kernel, done separately for each staggered component.

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const Field = grid_mod.Field;
const Particles = @import("particles.zig").Particles;

pub const Scheme = enum { pic, flip, apic };

/// Kernel weights of one particle for one staggered component (lesson 3, §3.2):
/// the 3×3×3 samples starting at `base`, with weight w[0][x]·w[1][y]·w[2][z],
/// and the offset x_i - x_p (in cells) of each sample along each axis.
const Stencil = struct {
    base: [3]usize,
    w: [3][3]f32,
    dist: [3][3]f32,

    /// Particles stay at least 0.01 cells inside the walls (advect.clampToInterior),
    /// which keeps all 27 samples inside the field's arrays.
    fn init(field: Field, pos: [3]f32, inv_dx: f32) Stencil {
        var st: Stencil = undefined;
        for (0..3) |b| {
            const x = pos[b] * inv_dx - field.offset[b];
            const bf = @floor(x - 0.5);
            const t = x - bf;
            std.debug.assert(bf >= 0 and @as(usize, @intFromFloat(bf)) + 2 < field.n[b]);
            st.base[b] = @intFromFloat(bf);
            st.w[b] = .{ 0.5 * (1.5 - t) * (1.5 - t), 0.75 - (t - 1) * (t - 1), 0.5 * (t - 0.5) * (t - 0.5) };
            st.dist[b] = .{ -t, 1 - t, 2 - t };
        }
        return st;
    }
};

/// P2G: every particle adds to the 27 samples around it, per component:
///   u_i = Σ_p w_ip (v_p + C_p (x_i - x_p)) / Σ_p w_ip        (APIC; C = 0 for PIC/FLIP)
/// `weight[a]` receives Σ w_ip per sample: the grid mass divided by particle mass.
/// Particles must be sorted by cell; the scatter is colored so it never races.
pub fn particlesToGrid(pool: Pool, grid: *Grid, particles: *const Particles, weight: *const [3][]f32, scheme: Scheme) void {
    for (0..3) |a| {
        @memset(grid.vel[a].data, 0);
        @memset(weight[a], 0);
    }
    const Ctx = struct {
        grid: *Grid,
        p: *const Particles,
        weight: *const [3][]f32,
        affine: bool,

        fn run(ctx: @This(), first: usize, last: usize) void {
            const g = ctx.grid;
            const p = ctx.p;
            const inv_dx = 1 / g.dx;
            for (first..last) |pi| {
                const pos = p.position(pi);
                for (0..3) |a| {
                    const f = g.vel[a];
                    const st = Stencil.init(f, pos, inv_dx);
                    const v = p.vel[a][pi];
                    // C_p (x_i - x_p) = Σ_b C[a][b]·dist_b·Δx
                    var c: [3]f32 = .{ 0, 0, 0 };
                    if (ctx.affine) {
                        for (0..3) |b| c[b] = p.c[a][b][pi] * g.dx;
                    }
                    for (0..3) |oz| for (0..3) |oy| {
                        const row = f.index(st.base[0], st.base[1] + oy, st.base[2] + oz);
                        const wyz = st.w[1][oy] * st.w[2][oz];
                        const vyz = v + c[1] * st.dist[1][oy] + c[2] * st.dist[2][oz];
                        for (0..3) |ox| {
                            const wt = st.w[0][ox] * wyz;
                            f.data[row + ox] += wt * (vyz + c[0] * st.dist[0][ox]);
                            ctx.weight[a][row + ox] += wt;
                        }
                    };
                }
            }
        }
    };
    particles.forEachBlockColored(pool, grid.*, 4, Ctx{ .grid = grid, .p = particles, .weight = weight, .affine = scheme == .apic }, Ctx.run);

    // Momentum → velocity: divide by mass.
    for (0..3) |a| {
        const Div = struct {
            u: []f32,
            w: []const f32,
            fn f(ctx: @This(), i: usize) void {
                ctx.u[i] = if (ctx.w[i] > 0) ctx.u[i] / ctx.w[i] else 0;
            }
        };
        pool.each(grid.vel[a].len(), 8192, Div{ .u = grid.vel[a].data, .w = weight[a] }, Div.f);
    }
}

/// G2P. Each particle reads the 3×3×3 samples around it in every component:
///   PIC/APIC: v_p = Σ w_ip u_i
///   APIC:     C_p = (4/Δx²) Σ w_ip u_i (x_i - x_p)ᵀ
///   FLIP:     v_p = ratio·(v_p + Σ w_ip (u_i - u_old_i)) + (1 - ratio)·PIC
pub fn gridToParticles(pool: Pool, grid: *const Grid, particles: *Particles, old: *const [3][]f32, scheme: Scheme, flip_ratio: f32) void {
    const Ctx = struct {
        grid: *const Grid,
        p: *Particles,
        old: *const [3][]f32,
        scheme: Scheme,
        flip_ratio: f32,

        fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
            const g = ctx.grid;
            const p = ctx.p;
            const inv_dx = 1 / g.dx;
            for (begin..end) |pi| {
                const pos = p.position(pi);
                for (0..3) |a| {
                    const f = g.vel[a];
                    const st = Stencil.init(f, pos, inv_dx);
                    var pic: f32 = 0;
                    var delta: f32 = 0;
                    var grad: [3]f32 = .{ 0, 0, 0 };
                    for (0..3) |oz| for (0..3) |oy| {
                        const row = f.index(st.base[0], st.base[1] + oy, st.base[2] + oz);
                        const wyz = st.w[1][oy] * st.w[2][oz];
                        for (0..3) |ox| {
                            const wt = st.w[0][ox] * wyz;
                            const u = f.data[row + ox];
                            pic += wt * u;
                            if (ctx.scheme == .flip) delta += wt * (u - ctx.old[a][row + ox]);
                            if (ctx.scheme == .apic) {
                                grad[0] += wt * u * st.dist[0][ox];
                                grad[1] += wt * u * st.dist[1][oy];
                                grad[2] += wt * u * st.dist[2][oz];
                            }
                        }
                    };
                    // The 27 weights always sum to 1: no normalization needed.
                    switch (ctx.scheme) {
                        .pic, .apic => p.vel[a][pi] = pic,
                        .flip => p.vel[a][pi] = ctx.flip_ratio * (p.vel[a][pi] + delta) + (1 - ctx.flip_ratio) * pic,
                    }
                    for (0..3) |b| {
                        // (4/Δx²)·Σ w u (x_i - x_p), with (x_i - x_p) = dist·Δx.
                        p.c[a][b][pi] = if (ctx.scheme == .apic) 4 * grad[b] * inv_dx else 0;
                    }
                }
            }
        }
    };
    const ctx: Ctx = .{ .grid = grid, .p = particles, .old = old, .scheme = scheme, .flip_ratio = flip_ratio };
    pool.forEach(particles.len, 2048, ctx, Ctx.run);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn allocWeights(gpa: std.mem.Allocator, g: Grid) ![3][]f32 {
    var w: [3][]f32 = undefined;
    for (0..3) |a| w[a] = try gpa.alloc(f32, g.vel[a].len());
    return w;
}

test "APIC round trip preserves an affine velocity field exactly" {
    const gpa = testing.allocator;
    var g = try Grid.init(gpa, .{ 12, 12, 12 }, 0.1);
    defer g.deinit(gpa);
    var p: Particles = .{};
    defer p.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(11);
    // Away from the walls, so every particle sees all 27 samples.
    try p.seed(gpa, g, .{ .box = .{ .min = .{ 0.35, 0.35, 0.35 }, .max = .{ 0.85, 0.85, 0.85 } } }, .{ 0, 0, 0 }, prng.random(), 1);
    const offset = [3]f32{ 0.3, -0.2, 0.1 };
    const B = [3][3]f32{ .{ 0.5, -1, 0.2 }, .{ 1, 0.1, -0.3 }, .{ 0.4, 0.7, -0.6 } };
    for (0..p.len) |i| for (0..3) |a| {
        p.vel[a][i] = offset[a];
        for (0..3) |b| {
            p.vel[a][i] += B[a][b] * p.pos[b][i];
            p.c[a][b][i] = B[a][b];
        }
    };
    const expected_v = try gpa.dupe(f32, p.vel[1][0..p.len]);
    defer gpa.free(expected_v);

    const w = try allocWeights(gpa, g);
    defer for (w) |x| gpa.free(x);
    const pool = Pool.serial(testing.io);
    try p.sortByCell(gpa, g);
    particlesToGrid(pool, &g, &p, &w, .apic);
    // Refill the expected values after sorting reordered the particles.
    for (0..p.len) |i| {
        var v = offset[1];
        for (0..3) |b| v += B[1][b] * p.pos[b][i];
        expected_v[i] = v;
    }
    gridToParticles(pool, &g, &p, &w, .apic, 0);
    for (0..p.len) |i| {
        try testing.expectApproxEqAbs(expected_v[i], p.vel[1][i], 1e-4);
        for (0..3) |a| for (0..3) |b| try testing.expectApproxEqAbs(B[a][b], p.c[a][b][i], 1e-3);
    }
}

test "PIC loses the same affine motion that APIC keeps" {
    const gpa = testing.allocator;
    var g = try Grid.init(gpa, .{ 12, 12, 12 }, 0.1);
    defer g.deinit(gpa);
    var p: Particles = .{};
    defer p.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(5);
    try p.seed(gpa, g, .{ .box = .{ .min = .{ 0.35, 0.35, 0.35 }, .max = .{ 0.85, 0.85, 0.85 } } }, .{ 0, 0, 0 }, prng.random(), 1);
    try p.sortByCell(gpa, g);
    // Stretching flow v_x = x - 0.6 (lesson 3, §3.3), PIC carries no C.
    for (0..p.len) |i| p.vel[0][i] = p.pos[0][i] - 0.6;
    const spread = struct {
        fn f(q: Particles) f32 {
            var lo: f32 = std.math.inf(f32);
            var hi: f32 = -std.math.inf(f32);
            for (q.vel[0][0..q.len]) |v| {
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
            return hi - lo;
        }
    }.f;
    const before = spread(p);
    const w = try allocWeights(gpa, g);
    defer for (w) |x| gpa.free(x);
    const pool = Pool.serial(testing.io);
    for (0..5) |_| {
        particlesToGrid(pool, &g, &p, &w, .pic);
        gridToParticles(pool, &g, &p, &w, .pic, 0);
    }
    try testing.expect(spread(p) < 0.9 * before);
}

test "P2G conserves linear momentum" {
    const gpa = testing.allocator;
    var g = try Grid.init(gpa, .{ 12, 12, 12 }, 0.1);
    defer g.deinit(gpa);
    var p: Particles = .{};
    defer p.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(9);
    const rng = prng.random();
    try p.seed(gpa, g, .{ .sphere = .{ .center = .{ 0.6, 0.6, 0.6 }, .radius = 0.25 } }, .{ 0, 0, 0 }, rng, 1);
    for (0..p.len) |i| for (0..3) |a| {
        p.vel[a][i] = rng.float(f32) * 2 - 1;
        for (0..3) |b| p.c[a][b][i] = rng.float(f32) * 2 - 1;
    };
    try p.sortByCell(gpa, g);
    const w = try allocWeights(gpa, g);
    defer for (w) |x| gpa.free(x);
    particlesToGrid(Pool.serial(testing.io), &g, &p, &w, .apic);
    for (0..3) |a| {
        var particle_momentum: f64 = 0;
        for (p.vel[a][0..p.len]) |v| particle_momentum += v;
        var grid_momentum: f64 = 0;
        for (g.vel[a].data, w[a]) |u, wt| grid_momentum += u * wt;
        try testing.expectApproxEqRel(particle_momentum, grid_momentum, 1e-4);
    }
}
