//! Scenario validation (lesson 8, §8.2): whole-solver runs with known answers.
//! Every check prints its measured value next to its limit, pass or fail.

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const simulation = @import("simulation.zig");
const Simulation = simulation.Simulation;
const scenes = @import("scenes.zig");

const Report = struct {
    out: *std.Io.Writer,
    failures: u32 = 0,

    fn check(r: *Report, passed: bool, comptime fmt: []const u8, args: anytype) !void {
        if (!passed) r.failures += 1;
        try r.out.print("  {s}  " ++ fmt ++ "\n", .{if (passed) "PASS" else "FAIL"} ++ args);
        try r.out.flush();
    }

    fn note(r: *Report, comptime fmt: []const u8, args: anytype) !void {
        try r.out.print("        " ++ fmt ++ "\n", args);
        try r.out.flush();
    }
};

pub fn run(gpa: std.mem.Allocator, pool: Pool, out: *std.Io.Writer, quick: bool) !bool {
    var r: Report = .{ .out = out };
    try hydrostatic(gpa, pool, &r, quick);
    try damBreak(gpa, pool, &r, quick);
    try determinism(gpa, pool, &r);
    try out.print("\n{s}: {d} check(s) failed\n", .{ if (r.failures == 0) "OK" else "FAILED", r.failures });
    return r.failures == 0;
}

// ---------------------------------------------------------------------------
// Still tank: nothing may move, and pressure must be ρ·g·depth.

const HydroResult = struct {
    dx: f64,
    max_speed: f64,
    /// Largest |p - ρ g depth| over FLUID cells, in Pa.
    pressure_error: f64,
    volume_ratio: f64,
    max_div_dt: f64,
    converged: bool,
};

fn runStillTank(gpa: std.mem.Allocator, pool: Pool, res: usize, ghost: bool, seconds: f32) !HydroResult {
    var params = scenes.params(.still_tank, res);
    params.ghost_fluid = ghost;
    var s = try Simulation.init(gpa, pool, params);
    defer s.deinit();
    try scenes.fill(&s, .still_tank);
    const v0 = s.measure().volume;
    var max_div_dt: f64 = 0;
    var converged = true;
    const frames: usize = @intFromFloat(@round(seconds * 60));
    for (0..frames) |_| {
        const fs = try s.advanceFrame(1.0 / 60.0);
        max_div_dt = @max(max_div_dt, fs.max_divergence / 60 / @as(f64, @floatFromInt(fs.substeps)));
        converged = converged and fs.all_converged;
    }
    const m = s.measure();
    const g = &s.grid;
    const rho: f64 = params.density;
    const gy: f64 = -params.gravity[1];
    const surface: f64 = params.dx + scenes.still_tank_depth;
    var worst: f64 = 0;
    for (0..g.n[2]) |k| for (0..g.n[1]) |j| for (0..g.n[0]) |i| {
        const c = g.cellIndex(i, j, k);
        if (g.label[c] != .fluid) continue;
        const y: f64 = g.cellCenter(i, j, k)[1];
        worst = @max(worst, @abs(s.pressure[c] - rho * gy * (surface - y)));
    };
    return .{
        .dx = params.dx,
        .max_speed = m.max_speed,
        .pressure_error = worst,
        .volume_ratio = m.volume / v0,
        .max_div_dt = max_div_dt,
        .converged = converged,
    };
}

fn hydrostatic(gpa: std.mem.Allocator, pool: Pool, r: *Report, quick: bool) !void {
    try r.out.writeAll("\nStill tank (0.2 m box, 0.1 m deep, 2 s): water must stay still, p = ρ·g·depth\n");
    const resolutions: []const usize = if (quick) &.{ 16, 32 } else &.{ 16, 32, 64 };
    var prev_error: ?f64 = null;
    for (resolutions) |res| {
        const h = try runStillTank(gpa, pool, res, true, 2);
        const rho_g_dx = 1000 * 9.81 * h.dx;
        const speed_scale = @sqrt(9.81 * h.dx);
        try r.note("{d}³ (Δx = {d:.2} mm):", .{ res, h.dx * 1000 });
        try r.check(h.max_speed < 0.01 * speed_scale, "max particle speed {e:.2} m/s < 1% of √(gΔx) = {e:.2}", .{ h.max_speed, 0.01 * speed_scale });
        try r.check(h.pressure_error < 0.25 * rho_g_dx, "pressure error {d:.2} Pa = {d:.3}·ρgΔx < 0.25·ρgΔx", .{ h.pressure_error, h.pressure_error / rho_g_dx });
        try r.check(@abs(h.volume_ratio - 1) < 0.01, "volume change {d:.3}% < 1%", .{(h.volume_ratio - 1) * 100});
        try r.check(h.max_div_dt < 1e-5, "max |div u|·Δt after projection {e:.2} < 1e-5", .{h.max_div_dt});
        try r.check(h.converged, "every pressure solve converged", .{});
        if (prev_error) |pe| {
            try r.check(h.pressure_error < pe, "pressure error shrinks with resolution ({d:.2} Pa → {d:.2} Pa)", .{ pe, h.pressure_error });
        }
        prev_error = h.pressure_error;
    }
    // Lesson 5, §5.5–5.6: without ghost fluid the surface sits half a cell high.
    const res = resolutions[1];
    const with = try runStillTank(gpa, pool, res, true, 0.25);
    const without = try runStillTank(gpa, pool, res, false, 0.25);
    const rho_g_dx = 1000 * 9.81 * with.dx;
    try r.check(with.pressure_error < 0.5 * without.pressure_error, "ghost fluid at least halves the pressure error at {d}³: {d:.3} vs {d:.3}·ρgΔx without", .{ res, with.pressure_error / rho_g_dx, without.pressure_error / rho_g_dx });
}

// ---------------------------------------------------------------------------
// Dam break: energy must never grow, the front can't outrun shallow-water theory.

fn damBreak(gpa: std.mem.Allocator, pool: Pool, r: *Report, quick: bool) !void {
    const res: usize = if (quick) 32 else 48;
    const seconds: f32 = 0.6;
    const fps: f32 = 50;
    try r.out.print("\nDam break ({d} cells along the tank, 0.146 × 0.292 m column, {d:.1} s)\n", .{ res, seconds });
    const params = scenes.params(.dam_break, res);
    var s = try Simulation.init(gpa, pool, params);
    defer s.deinit();
    try scenes.fill(&s, .dam_break);

    const a: f64 = scenes.dam_break_column[0];
    const h0: f64 = scenes.dam_break_column[1];
    const tank: f64 = s.grid.interiorSize()[0];
    const start = s.measure();
    const e0 = start.kinetic_energy + start.potential_energy;
    var prev_e = e0;
    var rise: f64 = 0;
    var min_volume: f64 = 1;
    var max_front_speed: f64 = 0;
    var prev_front = frontPosition(&s);
    var converged = true;
    var max_div_dt: f64 = 0;
    var particles_constant = true;
    try r.note("front position (Z = x/a) vs time (T = t·√(g/a)), to compare with experiments:", .{});
    const frames: usize = @intFromFloat(@round(seconds * fps));
    for (1..frames + 1) |frame| {
        const fs = try s.advanceFrame(1 / fps);
        converged = converged and fs.all_converged;
        max_div_dt = @max(max_div_dt, fs.max_divergence / fps / @as(f64, @floatFromInt(fs.substeps)));
        const m = s.measure();
        particles_constant = particles_constant and m.particles == start.particles;
        const e = m.kinetic_energy + m.potential_energy;
        if (e > prev_e) rise += e - prev_e;
        prev_e = e;
        min_volume = @min(min_volume, m.volume / start.volume);
        const front = frontPosition(&s);
        // Only before the surge reaches the far wall.
        if (front < tank - 2 * params.dx) max_front_speed = @max(max_front_speed, (front - prev_front) * fps);
        prev_front = front;
        if (frame % 5 == 0) try r.note("  T = {d:.2}  Z = {d:.2}", .{ s.time * @sqrt(9.81 / a), front / a });
    }
    const final = s.measure();
    try r.check(rise < 0.01 * e0, "energy never grows: total increase {d:.4} J < 1% of {d:.3} J (energy fell to {d:.3} J)", .{ rise, e0, final.kinetic_energy + final.potential_energy });
    const ritter = 2 * @sqrt(9.81 * h0);
    try r.check(max_front_speed <= ritter, "front speed {d:.2} m/s ≤ 2√(g·h0) = {d:.2} m/s (Ritter's frictionless shallow-water limit)", .{ max_front_speed, ritter });
    try r.check(particles_constant, "particle count unchanged ({d})", .{start.particles});
    try r.check(min_volume > 0.9, "FLUID-cell volume stays above 90% (min {d:.1}%)", .{min_volume * 100});
    try r.note("(FLUID-cell volume under-counts thin sheets and spray; the particles themselves conserve mass exactly)", .{});
    try r.check(max_div_dt < 1e-5, "max |div u|·Δt after projection {e:.2} < 1e-5", .{max_div_dt});
    try r.check(converged, "every pressure solve converged", .{});
}

/// Farthest particle from the column's starting wall, measured from the interior's edge.
fn frontPosition(s: *const Simulation) f64 {
    var x: f64 = 0;
    for (s.particles.pos[0][0..s.particles.len]) |px| x = @max(x, px);
    return x - s.params.dx;
}

// ---------------------------------------------------------------------------
// The thread pool promises bit-identical results with any number of threads.

fn determinism(gpa: std.mem.Allocator, pool: Pool, r: *Report) !void {
    try r.out.writeAll("\nDeterminism (drop scene, 24 cells, 10 frames)\n");
    const params = scenes.params(.drop, 24);
    var a = try Simulation.init(gpa, pool, params);
    defer a.deinit();
    var b = try Simulation.init(gpa, Pool.serial(pool.io), params);
    defer b.deinit();
    try scenes.fill(&a, .drop);
    try scenes.fill(&b, .drop);
    for (0..10) |_| {
        _ = try a.advanceFrame(1.0 / 60.0);
        _ = try b.advanceFrame(1.0 / 60.0);
    }
    var identical = a.particles.len == b.particles.len;
    if (identical) for (0..3) |ax| {
        identical = identical and std.mem.eql(f32, a.particles.pos[ax][0..a.particles.len], b.particles.pos[ax][0..b.particles.len]);
        identical = identical and std.mem.eql(f32, a.particles.vel[ax][0..a.particles.len], b.particles.vel[ax][0..b.particles.len]);
    };
    try r.check(identical, "multi-threaded and single-threaded runs are bit-identical", .{});
}
