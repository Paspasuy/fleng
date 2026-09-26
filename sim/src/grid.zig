//! The MAC grid (lesson 2): pressure-side data at cell centers, each velocity
//! component on the faces perpendicular to it.

const std = @import("std");

pub const Label = enum(u8) { air, fluid, solid };

/// One 3D array of samples plus where those samples sit inside a cell.
/// Sample (i, j, k) lives at ((i + offset[0])·dx, (j + offset[1])·dx, (k + offset[2])·dx).
pub const Field = struct {
    data: []f32,
    n: [3]usize,
    offset: [3]f32,

    pub inline fn index(f: Field, i: usize, j: usize, k: usize) usize {
        return i + f.n[0] * (j + f.n[1] * k);
    }

    pub inline fn at(f: Field, i: usize, j: usize, k: usize) f32 {
        return f.data[f.index(i, j, k)];
    }

    pub fn len(f: Field) usize {
        return f.n[0] * f.n[1] * f.n[2];
    }

    /// Trilinear interpolation (lesson 2, §2.5) at world position `pos`.
    /// Positions outside the samples are clamped to the nearest edge.
    pub fn sample(f: Field, pos: [3]f32, inv_dx: f32) f32 {
        var base: [3]usize = undefined;
        var t: [3]f32 = undefined;
        inline for (0..3) |a| {
            const top: f32 = @floatFromInt(f.n[a] - 1);
            const g = std.math.clamp(pos[a] * inv_dx - f.offset[a], 0, top);
            const b: usize = @min(@as(usize, @intFromFloat(g)), f.n[a] - 2);
            base[a] = b;
            t[a] = g - @as(f32, @floatFromInt(b));
        }
        const i = base[0];
        const j = base[1];
        const k = base[2];
        // 4 lerps along x, 2 along y, 1 along z.
        const c00 = lerp(f.at(i, j, k), f.at(i + 1, j, k), t[0]);
        const c10 = lerp(f.at(i, j + 1, k), f.at(i + 1, j + 1, k), t[0]);
        const c01 = lerp(f.at(i, j, k + 1), f.at(i + 1, j, k + 1), t[0]);
        const c11 = lerp(f.at(i, j + 1, k + 1), f.at(i + 1, j + 1, k + 1), t[0]);
        return lerp(lerp(c00, c10, t[1]), lerp(c01, c11, t[1]), t[2]);
    }
};

inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + t * (b - a);
}

pub const Grid = struct {
    /// Cells per axis, including the one-cell SOLID wall layer on every side.
    n: [3]usize,
    dx: f32,
    /// vel[0] = u on x-faces, vel[1] = v on y-faces, vel[2] = w on z-faces.
    vel: [3]Field,
    label: []Label,
    /// Signed distance to the water surface at cell centers, negative inside (lesson 7).
    phi: []f32,

    pub fn init(gpa: std.mem.Allocator, n: [3]usize, dx: f32) !Grid {
        std.debug.assert(n[0] >= 3 and n[1] >= 3 and n[2] >= 3);
        var g: Grid = .{ .n = n, .dx = dx, .vel = undefined, .label = &.{}, .phi = &.{} };
        errdefer g.deinit(gpa);
        for (0..3) |a| g.vel[a] = .{ .data = &.{}, .n = undefined, .offset = undefined };
        for (0..3) |a| {
            var dims = n;
            dims[a] += 1;
            var offset: [3]f32 = .{ 0.5, 0.5, 0.5 };
            offset[a] = 0;
            g.vel[a] = .{ .data = try gpa.alloc(f32, dims[0] * dims[1] * dims[2]), .n = dims, .offset = offset };
            @memset(g.vel[a].data, 0);
        }
        g.label = try gpa.alloc(Label, g.cellCount());
        g.phi = try gpa.alloc(f32, g.cellCount());
        @memset(g.phi, 3 * dx);
        for (0..n[2]) |k| for (0..n[1]) |j| for (0..n[0]) |i| {
            const wall = i == 0 or j == 0 or k == 0 or i == n[0] - 1 or j == n[1] - 1 or k == n[2] - 1;
            g.label[g.cellIndex(i, j, k)] = if (wall) .solid else .air;
        };
        return g;
    }

    pub fn deinit(g: *Grid, gpa: std.mem.Allocator) void {
        for (&g.vel) |*f| gpa.free(f.data);
        gpa.free(g.label);
        gpa.free(g.phi);
    }

    pub inline fn cellCount(g: Grid) usize {
        return g.n[0] * g.n[1] * g.n[2];
    }

    pub inline fn cellIndex(g: Grid, i: usize, j: usize, k: usize) usize {
        return i + g.n[0] * (j + g.n[1] * k);
    }

    /// Size of the fluid region: the box inside the wall layer.
    pub fn interiorSize(g: Grid) [3]f32 {
        var s: [3]f32 = undefined;
        for (0..3) |a| s[a] = @as(f32, @floatFromInt(g.n[a] - 2)) * g.dx;
        return s;
    }

    /// Cell center in world coordinates.
    pub fn cellCenter(g: Grid, i: usize, j: usize, k: usize) [3]f32 {
        return .{
            (@as(f32, @floatFromInt(i)) + 0.5) * g.dx,
            (@as(f32, @floatFromInt(j)) + 0.5) * g.dx,
            (@as(f32, @floatFromInt(k)) + 0.5) * g.dx,
        };
    }

    /// Velocity at any point: each component from its own staggered field.
    pub fn sampleVelocity(g: Grid, pos: [3]f32) [3]f32 {
        const inv_dx = 1 / g.dx;
        return .{ g.vel[0].sample(pos, inv_dx), g.vel[1].sample(pos, inv_dx), g.vel[2].sample(pos, inv_dx) };
    }

    /// Net outflow of cell (i, j, k) per unit volume (lesson 2, §2.3).
    pub fn divergence(g: Grid, i: usize, j: usize, k: usize) f32 {
        const u = g.vel[0];
        const v = g.vel[1];
        const w = g.vel[2];
        return (u.at(i + 1, j, k) - u.at(i, j, k) +
            v.at(i, j + 1, k) - v.at(i, j, k) +
            w.at(i, j, k + 1) - w.at(i, j, k)) / g.dx;
    }

    /// The two cells a face separates: face (i, j, k) of component `a` lies
    /// between cell (i, j, k) - e_a ("low") and cell (i, j, k) ("high").
    /// Faces on the outer boundary have only one cell; the missing side is null.
    pub fn faceCells(g: Grid, a: usize, i: usize, j: usize, k: usize) [2]?usize {
        const idx = [3]usize{ i, j, k };
        const low: ?usize = if (idx[a] == 0) null else blk: {
            var c = idx;
            c[a] -= 1;
            break :blk g.cellIndex(c[0], c[1], c[2]);
        };
        const high: ?usize = if (idx[a] == g.n[a]) null else g.cellIndex(i, j, k);
        return .{ low, high };
    }

    /// A face touching a SOLID cell (or the outside) has its velocity fixed by the wall.
    pub fn isSolidFace(g: Grid, a: usize, i: usize, j: usize, k: usize) bool {
        const cells = g.faceCells(a, i, j, k);
        for (cells) |c| {
            if (c == null or g.label[c.?] == .solid) return true;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------

test "trilinear sampling reproduces linear fields exactly" {
    const gpa = std.testing.allocator;
    var g = try Grid.init(gpa, .{ 8, 7, 6 }, 0.1);
    defer g.deinit(gpa);
    // Fill every component with the same linear function of its own sample positions.
    const lin = struct {
        fn f(p: [3]f32) f32 {
            return 2 * p[0] - 3 * p[1] + 0.5 * p[2] + 1;
        }
    };
    for (&g.vel) |*field| {
        for (0..field.n[2]) |k| for (0..field.n[1]) |j| for (0..field.n[0]) |i| {
            const pos = [3]f32{
                (@as(f32, @floatFromInt(i)) + field.offset[0]) * g.dx,
                (@as(f32, @floatFromInt(j)) + field.offset[1]) * g.dx,
                (@as(f32, @floatFromInt(k)) + field.offset[2]) * g.dx,
            };
            field.data[field.index(i, j, k)] = lin.f(pos);
        };
    }
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    for (0..200) |_| {
        // Stay one cell away from the edges, where clamping kicks in.
        const pos = [3]f32{ 0.1 + rng.float(f32) * 0.6, 0.1 + rng.float(f32) * 0.5, 0.1 + rng.float(f32) * 0.4 };
        const v = g.sampleVelocity(pos);
        for (v) |c| try std.testing.expectApproxEqAbs(lin.f(pos), c, 1e-4);
    }
}

test "divergence of known fields" {
    const gpa = std.testing.allocator;
    var g = try Grid.init(gpa, .{ 6, 6, 6 }, 0.5);
    defer g.deinit(gpa);
    const Case = struct { scale: [3]f32, expected: f32 };
    // u = (x, -y, 0) is divergence-free; u = (x, y, z) has divergence 3.
    for ([_]Case{ .{ .scale = .{ 1, -1, 0 }, .expected = 0 }, .{ .scale = .{ 1, 1, 1 }, .expected = 3 } }) |case| {
        for (&g.vel, 0..) |*field, a| {
            for (0..field.n[2]) |k| for (0..field.n[1]) |j| for (0..field.n[0]) |i| {
                const coord = [3]usize{ i, j, k };
                const x = (@as(f32, @floatFromInt(coord[a])) + field.offset[a]) * g.dx;
                field.data[field.index(i, j, k)] = case.scale[a] * x;
            };
        }
        for (0..6) |k| for (0..6) |j| for (0..6) |i| {
            try std.testing.expectApproxEqAbs(case.expected, g.divergence(i, j, k), 1e-5);
        };
    }
}
