//! fleng water simulation core. See docs/lessons/ for the algorithms.

pub const pool = @import("pool.zig");
pub const grid = @import("grid.zig");
pub const particles = @import("particles.zig");
pub const transfer = @import("transfer.zig");
pub const surface = @import("surface.zig");
pub const extrapolate = @import("extrapolate.zig");
pub const pressure = @import("pressure.zig");
pub const cg = @import("cg.zig");
pub const multigrid = @import("multigrid.zig");
pub const advect = @import("advect.zig");
pub const simulation = @import("simulation.zig");
pub const scenes = @import("scenes.zig");
pub const validate = @import("validate.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
