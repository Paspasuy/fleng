//! One APIC time step (lesson 1, §1.4), and frames made of CFL substeps (lesson 4, §4.4).

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const particles_mod = @import("particles.zig");
const Particles = particles_mod.Particles;
const Shape = particles_mod.Shape;
const transfer = @import("transfer.zig");
const surface = @import("surface.zig");
const extrap = @import("extrapolate.zig");
const pressure = @import("pressure.zig");
const cg = @import("cg.zig");
const Multigrid = @import("multigrid.zig").Multigrid;
const advect = @import("advect.zig");

pub const Solver = enum { cg, mgpcg };

pub const Params = struct {
    /// Cells per axis, including the one-cell wall layer on each side.
    cells: [3]usize,
    dx: f32,
    density: f32 = 1000,
    gravity: [3]f32 = .{ 0, -9.81, 0 },
    /// CFL number (lesson 4, §4.4): at most this many cells per substep.
    /// Time-stepping error shows up as spurious energy gain in violent flows:
    /// in the drop scene it measured 0.06% (32 cells) and 0.18% (48 cells) of
    /// the total at CFL 1, and none at 0.5 or 0.25. 0.5 costs 2× the substeps of 1.
    cfl: f32 = 0.5,
    transfer: transfer.Scheme = .apic,
    flip_ratio: f32 = 0.97,
    solver: Solver = .mgpcg,
    /// Relative residual max|r| / max|b| the pressure solve must reach.
    tolerance: f64 = 1e-6,
    max_iterations: u32 = 2000,
    ghost_fluid: bool = true,
    extrapolation_layers: u32 = 4,
    surface: surface.Params = .{},
};

pub const StepStats = struct {
    dt: f32 = 0,
    iterations: u32 = 0,
    residual: f64 = 0,
    converged: bool = true,
    /// Largest |div u| over FLUID cells right after projection, in 1/s.
    max_divergence: f64 = 0,
};

pub const FrameStats = struct {
    substeps: u32 = 0,
    iterations: u32 = 0,
    worst_residual: f64 = 0,
    all_converged: bool = true,
    max_divergence: f64 = 0,
};

pub const Measurements = struct {
    particles: usize,
    fluid_cells: usize,
    /// FLUID cells × Δx³.
    volume: f64,
    /// Translational plus APIC affine kinetic energy.
    kinetic_energy: f64,
    /// Relative to the tank floor.
    potential_energy: f64,
    max_speed: f64,
};

pub const Simulation = struct {
    gpa: std.mem.Allocator,
    pool: Pool,
    params: Params,
    grid: Grid,
    particles: Particles = .{},
    time: f64 = 0,

    /// Σ w per face sample from the last P2G (grid mass / particle mass).
    weight: [3][]f32,
    /// Grid velocity before forces and pressure: what FLIP subtracts.
    old: [3][]f32,
    mask: [3][]u8,
    mask_next: [3][]u8,
    diag: []f64,
    rhs: []f64,
    /// Kept between steps as the warm start for the next solve.
    pressure: []f64,
    workspace: cg.Workspace,
    multigrid: Multigrid,
    surface_ws: surface.Workspace,

    pub fn init(gpa: std.mem.Allocator, pool: Pool, params: Params) !Simulation {
        var grid = try Grid.init(gpa, params.cells, params.dx);
        errdefer grid.deinit(gpa);
        const n = grid.cellCount();
        var s: Simulation = .{
            .gpa = gpa,
            .pool = pool,
            .params = params,
            .grid = grid,
            .weight = undefined,
            .old = undefined,
            .mask = undefined,
            .mask_next = undefined,
            .diag = try gpa.alloc(f64, n),
            .rhs = try gpa.alloc(f64, n),
            .pressure = try gpa.alloc(f64, n),
            .workspace = try cg.Workspace.init(gpa, n),
            .multigrid = try Multigrid.init(gpa, params.cells),
            .surface_ws = try surface.Workspace.init(gpa, n),
        };
        for (0..3) |a| {
            const len = grid.vel[a].len();
            s.weight[a] = try gpa.alloc(f32, len);
            s.old[a] = try gpa.alloc(f32, len);
            s.mask[a] = try gpa.alloc(u8, len);
            s.mask_next[a] = try gpa.alloc(u8, len);
        }
        @memset(s.pressure, 0);
        return s;
    }

    pub fn deinit(s: *Simulation) void {
        const gpa = s.gpa;
        for (0..3) |a| {
            gpa.free(s.weight[a]);
            gpa.free(s.old[a]);
            gpa.free(s.mask[a]);
            gpa.free(s.mask_next[a]);
        }
        gpa.free(s.diag);
        gpa.free(s.rhs);
        gpa.free(s.pressure);
        s.workspace.deinit(gpa);
        s.multigrid.deinit(gpa);
        s.surface_ws.deinit(gpa);
        s.particles.deinit(gpa);
        s.grid.deinit(gpa);
    }

    /// Fills `shape` with water moving at `velocity`.
    pub fn addWater(s: *Simulation, shape: Shape, velocity: [3]f32, seed: u64) !void {
        var prng = std.Random.DefaultPrng.init(seed);
        try s.particles.seed(s.gpa, s.grid, shape, velocity, prng.random(), 1);
        // Labels and φ for the initial state, so measurements work before the first step.
        try s.particles.sortByCell(s.gpa, s.grid);
        surface.computePhi(s.pool, &s.grid, &s.particles, s.params.surface, &s.surface_ws);
        surface.labelCells(&s.grid);
    }

    /// Largest Δt allowed by the CFL condition (lesson 4, §4.4).
    pub fn stableDt(s: *const Simulation) f32 {
        const g = s.params.gravity;
        const g_len = @sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
        const u_max: f32 = @as(f32, @floatCast(s.maxSpeed())) + @sqrt(5 * s.params.dx * g_len);
        return s.params.cfl * s.params.dx / u_max;
    }

    /// Advances by exactly `frame_time`, in as many CFL substeps as needed.
    pub fn advanceFrame(s: *Simulation, frame_time: f32) !FrameStats {
        var stats: FrameStats = .{};
        var t: f32 = 0;
        while (t < frame_time) {
            var dt = s.stableDt();
            const remaining = frame_time - t;
            if (dt >= remaining) {
                dt = remaining; // land exactly on the frame
            } else if (2 * dt > remaining) {
                dt = remaining / 2; // avoid a tiny last step
            }
            const st = try s.step(dt);
            stats.substeps += 1;
            stats.iterations += st.iterations;
            stats.worst_residual = @max(stats.worst_residual, st.residual);
            stats.all_converged = stats.all_converged and st.converged;
            stats.max_divergence = @max(stats.max_divergence, st.max_divergence);
            t += dt;
        }
        return stats;
    }

    /// One time step (lesson 1, §1.4).
    pub fn step(s: *Simulation, dt: f32) !StepStats {
        const pool = s.pool;
        const g = &s.grid;
        var stats: StepStats = .{ .dt = dt };

        // Where is the water? Level set from particles, then labels (lesson 7).
        try s.particles.sortByCell(s.gpa, s.grid);
        surface.computePhi(pool, g, &s.particles, s.params.surface, &s.surface_ws);
        surface.labelCells(g);

        // P2G (lesson 3), then fill faces no particle reached (lesson 5, §5.7).
        transfer.particlesToGrid(pool, g, &s.particles, &s.weight, s.params.transfer);
        s.buildMask(.particles_only);
        s.extrapolateAll();
        pressure.enforceSolidFaces(pool, g);
        if (s.params.transfer == .flip) {
            for (0..3) |a| @memcpy(s.old[a], g.vel[a].data);
        }

        // Body forces (lesson 4, §4.1).
        for (0..3) |a| {
            const dv = s.params.gravity[a] * dt;
            if (dv != 0) for (g.vel[a].data) |*u| {
                u.* += dv;
            };
        }
        pressure.enforceSolidFaces(pool, g);

        // Pressure projection (lessons 5 and 6).
        pressure.buildDiagonal(pool, g, s.diag, s.params.ghost_fluid);
        pressure.buildRhs(pool, g, s.rhs, s.params.density, dt);
        const sys: pressure.Poisson = .{ .n = g.n, .label = g.label, .diag = s.diag };
        var mg: ?*Multigrid = null;
        if (s.params.solver == .mgpcg) {
            s.multigrid.setup(&sys);
            mg = &s.multigrid;
        }
        const result = cg.solve(pool, &sys, s.rhs, s.pressure, &s.workspace, s.params.tolerance, s.params.max_iterations, mg);
        stats.iterations = result.iterations;
        stats.residual = result.relative_residual;
        stats.converged = result.converged;
        pressure.applyPressureGradient(pool, g, s.pressure, s.params.density, dt, s.params.ghost_fluid);
        stats.max_divergence = pressure.maxDivergence(pool, g);

        // Extend the new velocity into the air, so particles near the surface read
        // valid values (lesson 5, §5.7). The first layer overrides faces that only
        // particles above the level set touched: they got gravity but no pressure,
        // and keeping them makes still water jitter forever. Beyond that layer,
        // faces with particles are spray and keep their own ballistic velocity.
        s.buildMask(.fluid_only);
        s.extrapolateLayers(1);
        s.markParticleFacesKnown();
        s.extrapolateLayers(s.params.extrapolation_layers - 1);
        pressure.enforceSolidFaces(pool, g);

        // G2P (lesson 3), then move particles (lesson 4).
        transfer.gridToParticles(pool, g, &s.particles, &s.old, s.params.transfer, s.params.flip_ratio);
        advect.advect(pool, g, &s.particles, dt);

        s.time += dt;
        return stats;
    }

    const MaskMode = enum { particles_only, fluid_only };

    /// known: a particle contributed to the face (before projection), or the
    /// face borders a FLUID cell (after projection). blocked: the face touches a wall.
    fn buildMask(s: *Simulation, mode: MaskMode) void {
        const g = &s.grid;
        for (0..3) |a| {
            const f = g.vel[a];
            for (0..f.n[2]) |k| for (0..f.n[1]) |j| for (0..f.n[0]) |i| {
                const fi = f.index(i, j, k);
                const m = &s.mask[a][fi];
                if (g.isSolidFace(a, i, j, k)) {
                    m.* = extrap.blocked;
                    continue;
                }
                const is_known = switch (mode) {
                    .particles_only => s.weight[a][fi] > 0,
                    .fluid_only => blk: {
                        const cells = g.faceCells(a, i, j, k);
                        break :blk g.label[cells[0].?] == .fluid or g.label[cells[1].?] == .fluid;
                    },
                };
                m.* = if (is_known) extrap.known else extrap.unknown;
            };
        }
    }

    fn extrapolateAll(s: *Simulation) void {
        s.extrapolateLayers(s.params.extrapolation_layers);
    }

    fn extrapolateLayers(s: *Simulation, layers: u32) void {
        for (0..3) |a| {
            extrap.extrapolate(s.pool, s.grid.vel[a], s.mask[a], s.mask_next[a], layers);
        }
    }

    /// Faces still unknown but touched by particles keep their P2G velocity.
    fn markParticleFacesKnown(s: *Simulation) void {
        for (0..3) |a| {
            for (s.mask[a], s.weight[a]) |*m, w| {
                if (m.* == extrap.unknown and w > 0) m.* = extrap.known;
            }
        }
    }

    pub fn particleMass(s: *const Simulation) f64 {
        const dx: f64 = s.params.dx;
        return @as(f64, s.params.density) * dx * dx * dx / 8;
    }

    pub fn maxSpeed(s: *const Simulation) f64 {
        const Ctx = struct {
            p: *const Particles,
            fn f(c: @This(), i: usize) f64 {
                const v = c.p.velocity(i);
                return @sqrt(@as(f64, v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
            }
        };
        return s.pool.maxEach(s.particles.len, 8192, Ctx{ .p = &s.particles }, Ctx.f);
    }

    pub fn measure(s: *const Simulation) Measurements {
        const m = s.particleMass();
        var kinetic: f64 = 0;
        var potential: f64 = 0;
        var max_speed: f64 = 0;
        const floor = s.params.dx; // the interior starts after the wall layer
        // APIC particles also move affinely around their center: for the quadratic
        // B-spline that motion carries ½·m·(Δx²/4)·|C|² of kinetic energy (Jiang et al.
        // 2015). Rotation stored in C can turn into visible velocity and back, so
        // both parts must be counted. C is zero for PIC and FLIP.
        const affine_scale: f64 = @as(f64, s.params.dx) * s.params.dx / 4;
        for (0..s.particles.len) |i| {
            const v = s.particles.velocity(i);
            const x = s.particles.position(i);
            const v2: f64 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
            var c2: f64 = 0;
            for (0..3) |a| for (0..3) |b| {
                const c: f64 = s.particles.c[a][b][i];
                c2 += c * c;
            };
            kinetic += 0.5 * m * (v2 + affine_scale * c2);
            max_speed = @max(max_speed, @sqrt(v2));
            // Potential energy is -m g·x, measured from the floor.
            for (0..3) |a| {
                const h: f64 = if (a == 1) x[a] - floor else x[a];
                potential -= m * s.params.gravity[a] * h;
            }
        }
        var fluid: usize = 0;
        for (s.grid.label) |l| {
            if (l == .fluid) fluid += 1;
        }
        const dx: f64 = s.params.dx;
        return .{
            .particles = s.particles.len,
            .fluid_cells = fluid,
            .volume = @as(f64, @floatFromInt(fluid)) * dx * dx * dx,
            .kinetic_energy = kinetic,
            .potential_energy = potential,
            .max_speed = max_speed,
        };
    }
};
