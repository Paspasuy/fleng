//! Particles carry the water (lesson 1, §1.2): position, velocity, and APIC's
//! affine matrix C (lesson 3, §3.5), stored as structure-of-arrays.

const std = @import("std");
const Grid = @import("grid.zig").Grid;

/// Initial water shapes, described by signed distance (negative inside).
pub const Shape = union(enum) {
    box: struct { min: [3]f32, max: [3]f32 },
    sphere: struct { center: [3]f32, radius: f32 },

    pub fn sdf(s: Shape, p: [3]f32) f32 {
        switch (s) {
            .box => |b| {
                var outside: f32 = 0;
                var inside: f32 = -std.math.inf(f32);
                for (0..3) |a| {
                    const d = @max(b.min[a] - p[a], p[a] - b.max[a]);
                    outside += @max(d, 0) * @max(d, 0);
                    inside = @max(inside, d);
                }
                return if (outside > 0) @sqrt(outside) else inside;
            },
            .sphere => |s_| {
                var d2: f32 = 0;
                for (0..3) |a| d2 += (p[a] - s_.center[a]) * (p[a] - s_.center[a]);
                return @sqrt(d2) - s_.radius;
            },
        }
    }
};

pub const Particles = struct {
    len: usize = 0,
    capacity: usize = 0,
    pos: [3][]f32 = .{ &.{}, &.{}, &.{} },
    vel: [3][]f32 = .{ &.{}, &.{}, &.{} },
    /// c[a][b] = ∂v_a/∂x_b around the particle. Zero for PIC and FLIP.
    c: [3][3][]f32 = .{ .{ &.{}, &.{}, &.{} }, .{ &.{}, &.{}, &.{} }, .{ &.{}, &.{}, &.{} } },

    /// After `sortByCell`, the particles of cell `ci` are `cell_start[ci]..cell_start[ci + 1]`.
    cell_start: []u32 = &.{},
    /// Scratch for sorting.
    order: []u32 = &.{},
    tmp: []f32 = &.{},

    pub fn deinit(p: *Particles, gpa: std.mem.Allocator) void {
        for (p.arrays()) |arr| gpa.free(arr.*);
        gpa.free(p.cell_start);
        gpa.free(p.order);
        gpa.free(p.tmp);
        p.* = .{};
    }

    /// All 15 per-particle float arrays, for code that treats them uniformly.
    fn arrays(p: *Particles) [15]*[]f32 {
        var out: [15]*[]f32 = undefined;
        var n: usize = 0;
        for (&p.pos) |*a| {
            out[n] = a;
            n += 1;
        }
        for (&p.vel) |*a| {
            out[n] = a;
            n += 1;
        }
        for (&p.c) |*row| for (row) |*a| {
            out[n] = a;
            n += 1;
        };
        return out;
    }

    fn ensureCapacity(p: *Particles, gpa: std.mem.Allocator, needed: usize) !void {
        if (needed <= p.capacity) return;
        const cap = @max(needed, p.capacity * 3 / 2 + 1024);
        for (p.arrays()) |arr| arr.* = try gpa.realloc(arr.*, cap);
        p.order = try gpa.realloc(p.order, cap);
        p.tmp = try gpa.realloc(p.tmp, cap);
        p.capacity = cap;
    }

    pub fn append(p: *Particles, gpa: std.mem.Allocator, pos: [3]f32, vel: [3]f32) !void {
        try p.ensureCapacity(gpa, p.len + 1);
        const i = p.len;
        for (0..3) |a| {
            p.pos[a][i] = pos[a];
            p.vel[a][i] = vel[a];
            for (0..3) |b| p.c[a][b][i] = 0;
        }
        p.len += 1;
    }

    /// Fills `shape` with particles: each cell is split into 2×2×2 sub-cells,
    /// and every sub-cell whose jittered sample point lies inside the shape
    /// (and inside the non-solid part of the grid) gets one particle.
    /// That's 8 particles per full cell (lesson 2, §2.6).
    pub fn seed(p: *Particles, gpa: std.mem.Allocator, grid: Grid, shape: Shape, vel: [3]f32, rng: std.Random, jitter: f32) !void {
        const half = grid.dx / 2;
        for (1..grid.n[2] - 1) |k| for (1..grid.n[1] - 1) |j| for (1..grid.n[0] - 1) |i| {
            if (grid.label[grid.cellIndex(i, j, k)] == .solid) continue;
            for (0..2) |sc| for (0..2) |sb| for (0..2) |sa| {
                const sub = [3]usize{ sa, sb, sc };
                const cell = [3]usize{ i, j, k };
                var pos: [3]f32 = undefined;
                for (0..3) |a| {
                    const r = 0.5 + jitter * (rng.float(f32) - 0.5);
                    pos[a] = @as(f32, @floatFromInt(cell[a])) * grid.dx + (@as(f32, @floatFromInt(sub[a])) + r) * half;
                }
                if (shape.sdf(pos) < 0) try p.append(gpa, pos, vel);
            };
        };
    }

    /// Counting sort by cell index. Afterwards particles in the same cell are
    /// contiguous in memory, and `cell_start` tells where each cell's run begins.
    pub fn sortByCell(p: *Particles, gpa: std.mem.Allocator, grid: Grid) !void {
        const cells = grid.cellCount();
        if (p.cell_start.len != cells + 1) {
            p.cell_start = try gpa.realloc(p.cell_start, cells + 1);
        }
        const start = p.cell_start;
        @memset(start, 0);
        // order[] temporarily holds each particle's cell index.
        for (0..p.len) |i| {
            const ci = cellOf(grid, .{ p.pos[0][i], p.pos[1][i], p.pos[2][i] });
            p.order[i] = @intCast(ci);
            start[ci + 1] += 1;
        }
        for (1..cells + 1) |ci| start[ci] += start[ci - 1];

        // Destination slot for each particle, stable within a cell.
        const cursor = try gpa.dupe(u32, start[0..cells]);
        defer gpa.free(cursor);
        for (0..p.len) |i| {
            const ci = p.order[i];
            p.order[i] = cursor[ci];
            cursor[ci] += 1;
        }
        for (p.arrays()) |arr| {
            const src = arr.*[0..p.len];
            for (src, 0..) |value, i| p.tmp[p.order[i]] = value;
            @memcpy(src, p.tmp[0..p.len]);
        }
    }

    /// Race-free parallel scatter (lesson 3, §3.6, "coloring"). Rows of cells
    /// (fixed y and z) are grouped into blocks of `block`×`block` rows; blocks
    /// run in 4 passes by (y-block parity, z-block parity), so blocks running
    /// at the same time are at least `block` rows apart. A body that writes at
    /// most 2 cells away from its particles' cells therefore never races when
    /// `block` ≥ 4. Calls `body(ctx, first, last)` for each row's particle range.
    /// The order of writes to any one sample is fixed, so results are deterministic.
    pub fn forEachBlockColored(
        p: *const Particles,
        pool: @import("pool.zig").Pool,
        grid: Grid,
        block: usize,
        ctx: anytype,
        comptime body: fn (@TypeOf(ctx), usize, usize) void,
    ) void {
        std.debug.assert(block >= 4);
        const blocks_y = (grid.n[1] + block - 1) / block;
        const blocks_z = (grid.n[2] + block - 1) / block;
        const Pass = struct {
            p: *const Particles,
            grid: Grid,
            block: usize,
            color_y: usize,
            color_z: usize,
            per_z: usize, // same-color blocks along y
            inner: @TypeOf(ctx),
            fn run(pass: @This(), _: usize, begin: usize, end: usize) void {
                const g = pass.grid;
                for (begin..end) |b| {
                    const by = 2 * (b % pass.per_z) + pass.color_y;
                    const bz = 2 * (b / pass.per_z) + pass.color_z;
                    const j0 = by * pass.block;
                    const k0 = bz * pass.block;
                    for (k0..@min(k0 + pass.block, g.n[2])) |k| for (j0..@min(j0 + pass.block, g.n[1])) |j| {
                        const row = g.cellIndex(0, j, k);
                        body(pass.inner, pass.p.cell_start[row], pass.p.cell_start[row + g.n[0]]);
                    };
                }
            }
        };
        for (0..2) |cz| for (0..2) |cy| {
            const per_z = (blocks_y + 1 - cy) / 2;
            const count_z = (blocks_z + 1 - cz) / 2;
            const pass: Pass = .{ .p = p, .grid = grid, .block = block, .color_y = cy, .color_z = cz, .per_z = per_z, .inner = ctx };
            pool.forEach(per_z * count_z, 1, pass, Pass.run);
        };
    }

    pub fn cellOf(grid: Grid, pos: [3]f32) usize {
        var idx: [3]usize = undefined;
        for (0..3) |a| {
            const f = pos[a] / grid.dx;
            const top: f32 = @floatFromInt(grid.n[a] - 1);
            idx[a] = @intFromFloat(std.math.clamp(f, 0, top));
        }
        return grid.cellIndex(idx[0], idx[1], idx[2]);
    }

    pub fn position(p: Particles, i: usize) [3]f32 {
        return .{ p.pos[0][i], p.pos[1][i], p.pos[2][i] };
    }

    pub fn velocity(p: Particles, i: usize) [3]f32 {
        return .{ p.vel[0][i], p.vel[1][i], p.vel[2][i] };
    }
};

test "seeding a full box gives 8 particles per cell, and sorting groups them" {
    const gpa = std.testing.allocator;
    var g = try Grid.init(gpa, .{ 6, 6, 6 }, 1);
    defer g.deinit(gpa);
    var p: Particles = .{};
    defer p.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(3);
    // Interior is cells 1..4 on each axis: 4³ = 64 cells.
    try p.seed(gpa, g, .{ .box = .{ .min = .{ 1, 1, 1 }, .max = .{ 5, 5, 5 } } }, .{ 0, 0, 0 }, prng.random(), 1);
    try std.testing.expectEqual(@as(usize, 64 * 8), p.len);

    try p.sortByCell(gpa, g);
    for (1..5) |k| for (1..5) |j| for (1..5) |i| {
        const ci = g.cellIndex(i, j, k);
        try std.testing.expectEqual(@as(u32, 8), p.cell_start[ci + 1] - p.cell_start[ci]);
        for (p.cell_start[ci]..p.cell_start[ci + 1]) |pi| {
            try std.testing.expectEqual(ci, Particles.cellOf(g, p.position(pi)));
        }
    };
}
