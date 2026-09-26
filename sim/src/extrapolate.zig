//! Velocity extrapolation (lesson 5, §5.7): fill face velocities outside the
//! water, layer by layer, so particles near the surface sample sensible values.

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const Field = @import("grid.zig").Field;

pub const unknown: u8 = 0;
pub const known: u8 = 1;
/// Never read or written: faces fixed by a wall.
pub const blocked: u8 = 2;

/// Each layer, every unknown sample with at least one known neighbor (along
/// the 6 axis directions, in the same field) becomes the average of those
/// neighbors. `mask` is updated in place; `next` is scratch of the same size.
pub fn extrapolate(pool: Pool, field: Field, mask: []u8, next: []u8, layers: u32) void {
    const Ctx = struct {
        f: Field,
        mask: []const u8,
        next: []u8,

        fn run(ctx: @This(), _: usize, begin: usize, end: usize) void {
            const f = ctx.f;
            for (begin..end) |row| {
                const j = row % f.n[1];
                const k = row / f.n[1];
                for (0..f.n[0]) |i| {
                    const idx = f.index(i, j, k);
                    ctx.next[idx] = ctx.mask[idx];
                    if (ctx.mask[idx] != unknown) continue;
                    const cell = [3]usize{ i, j, k };
                    var sum: f32 = 0;
                    var count: u32 = 0;
                    for (0..3) |a| {
                        for ([2]i2{ -1, 1 }) |dir| {
                            if (dir < 0 and cell[a] == 0) continue;
                            if (dir > 0 and cell[a] + 1 >= f.n[a]) continue;
                            var nb = cell;
                            nb[a] = if (dir < 0) nb[a] - 1 else nb[a] + 1;
                            const ni = f.index(nb[0], nb[1], nb[2]);
                            if (ctx.mask[ni] == known) {
                                sum += f.data[ni];
                                count += 1;
                            }
                        }
                    }
                    if (count > 0) {
                        // Only unknown samples are written, and only known ones are read,
                        // so chunks never race.
                        f.data[idx] = sum / @as(f32, @floatFromInt(count));
                        ctx.next[idx] = known;
                    }
                }
            }
        }
    };
    for (0..layers) |_| {
        pool.forEach(field.n[1] * field.n[2], 8, Ctx{ .f = field, .mask = mask, .next = next }, Ctx.run);
        @memcpy(mask, next);
    }
}

test "extrapolation spreads known values outward one layer at a time" {
    const gpa = std.testing.allocator;
    const n = [3]usize{ 5, 1, 1 };
    const data = try gpa.alloc(f32, 5);
    defer gpa.free(data);
    const mask = try gpa.alloc(u8, 5);
    defer gpa.free(mask);
    const next = try gpa.alloc(u8, 5);
    defer gpa.free(next);
    @memcpy(data, &[_]f32{ 2, 0, 0, 0, 8 });
    @memcpy(mask, &[_]u8{ known, unknown, unknown, unknown, blocked });
    const f: Field = .{ .data = data, .n = n, .offset = .{ 0, 0, 0 } };
    extrapolate(Pool.serial(std.testing.io), f, mask, next, 2);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 2, 2, 2, 0, 8 }, data);
    try std.testing.expectEqualSlices(u8, &[_]u8{ known, known, known, unknown, blocked }, mask);
}
