//! Built-in scenes. Sizes are in meters; the grid adds a one-cell wall layer
//! around the given interior.

const std = @import("std");
const simulation = @import("simulation.zig");
const Simulation = simulation.Simulation;
const Params = simulation.Params;

pub const Kind = enum {
    /// A box half full of still water: must stay still (lesson 8, §8.2).
    still_tank,
    /// A 0.146 × 0.292 m water column collapsing in a 0.584 m tank
    /// (the Koshizuka & Oka setup, lesson 8, §8.2).
    dam_break,
    /// A 4 cm ball of water falling into a 10 cm deep pool.
    drop,
};

pub const Spec = struct {
    /// Interior size in meters.
    size: [3]f32,
};

pub fn spec(kind: Kind) Spec {
    return switch (kind) {
        .still_tank => .{ .size = .{ 0.2, 0.2, 0.2 } },
        .dam_break => .{ .size = .{ 0.584, 0.35, 0.146 } },
        .drop => .{ .size = .{ 0.3, 0.3, 0.3 } },
    };
}

pub const dam_break_column = [2]f32{ 0.146, 0.292 };
pub const still_tank_depth: f32 = 0.1;

/// Default parameters with `resolution` cells across the scene's x axis.
pub fn params(kind: Kind, resolution: usize) Params {
    const size = spec(kind).size;
    const dx = size[0] / @as(f32, @floatFromInt(resolution));
    var cells: [3]usize = undefined;
    for (0..3) |a| cells[a] = @as(usize, @intFromFloat(@round(size[a] / dx))) + 2;
    return .{ .cells = cells, .dx = dx };
}

/// Adds the scene's water to a freshly created simulation.
pub fn fill(sim: *Simulation, kind: Kind) !void {
    const dx = sim.params.dx;
    const size = sim.grid.interiorSize();
    const o = dx; // interior origin, past the wall layer
    switch (kind) {
        .still_tank => try sim.addWater(.{ .box = .{
            .min = .{ o, o, o },
            .max = .{ o + size[0], o + still_tank_depth, o + size[2] },
        } }, .{ 0, 0, 0 }, 1),
        .dam_break => try sim.addWater(.{ .box = .{
            .min = .{ o, o, o },
            .max = .{ o + dam_break_column[0], o + dam_break_column[1], o + size[2] },
        } }, .{ 0, 0, 0 }, 1),
        .drop => {
            try sim.addWater(.{ .box = .{
                .min = .{ o, o, o },
                .max = .{ o + size[0], o + 0.1, o + size[2] },
            } }, .{ 0, 0, 0 }, 1);
            try sim.addWater(.{ .sphere = .{
                .center = .{ o + size[0] / 2, o + 0.2, o + size[2] / 2 },
                .radius = 0.04,
            } }, .{ 0, 0, 0 }, 2);
        },
    }
}
