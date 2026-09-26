//! Headless runner: `fleng-sim run ...` simulates a scene and prints per-frame
//! statistics; `fleng-sim validate` runs the lesson 8 scenario checks.

const std = @import("std");
const Io = std.Io;
const sim = @import("sim");

const usage =
    \\usage:
    \\  fleng-sim run [options]      simulate a scene, print one line per frame
    \\  fleng-sim validate [--quick] run the lesson 8 scenario checks
    \\
    \\run options:
    \\  --scene NAME       still_tank | dam_break | drop        (default drop)
    \\  --res N            cells across the scene's x axis       (default 48)
    \\  --seconds S        simulated time                        (default 0.5)
    \\  --fps F            output frames per second              (default 60)
    \\  --solver NAME      mgpcg | cg                            (default mgpcg)
    \\  --transfer NAME    apic | pic | flip                     (default apic)
    \\  --cfl C            max cells a particle moves per substep (default 0.5)
    \\  --no-ghost         disable the ghost fluid method
    \\  --threads 1        run single-threaded (default: all cores)
    \\  --csv PATH         also write per-frame statistics as CSV
    \\  --dump DIR         write the level set φ of every frame to DIR/phi_NNNN.bin
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage);
        return;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "run")) {
        runCommand(gpa, io, out, args[2..]) catch |err| switch (err) {
            error.BadArgument => {
                try out.writeAll(usage);
                try out.flush();
                std.process.exit(2);
            },
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "validate")) {
        var quick = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--quick")) quick = true;
        }
        const workers = try startWorkers(gpa, io);
        defer workers.deinit();
        const ok = try sim.validate.run(gpa, .{ .io = io, .workers = workers }, out, quick);
        try out.flush();
        if (!ok) std.process.exit(1);
    } else {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    }
}

/// One worker per core besides the calling thread.
fn startWorkers(gpa: std.mem.Allocator, io: Io) !*sim.pool.Workers {
    const cores = std.Thread.getCpuCount() catch 1;
    return sim.pool.Workers.init(gpa, io, @max(cores, 2) - 1);
}

const RunOptions = struct {
    scene: sim.scenes.Kind = .drop,
    res: usize = 48,
    seconds: f32 = 1,
    fps: f32 = 60,
    solver: sim.simulation.Solver = .mgpcg,
    transfer: sim.transfer.Scheme = .apic,
    cfl: f32 = 0.5,
    ghost: bool = true,
    parallel: bool = true,
    csv: ?[]const u8 = null,
    dump: ?[]const u8 = null,
};

fn parseRunOptions(out: *Io.Writer, args: []const [:0]const u8) !RunOptions {
    var o: RunOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--no-ghost")) {
            o.ghost = false;
            continue;
        }
        if (i + 1 >= args.len) {
            try out.print("missing value for {s}\n", .{a});
            return error.BadArgument;
        }
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--scene")) {
            o.scene = std.meta.stringToEnum(sim.scenes.Kind, v) orelse return badValue(out, a, v);
        } else if (std.mem.eql(u8, a, "--res")) {
            o.res = std.fmt.parseInt(usize, v, 10) catch return badValue(out, a, v);
            if (o.res < 4) return badValue(out, a, v);
        } else if (std.mem.eql(u8, a, "--seconds")) {
            o.seconds = std.fmt.parseFloat(f32, v) catch return badValue(out, a, v);
        } else if (std.mem.eql(u8, a, "--fps")) {
            o.fps = std.fmt.parseFloat(f32, v) catch return badValue(out, a, v);
            if (!(o.fps > 0)) return badValue(out, a, v);
        } else if (std.mem.eql(u8, a, "--solver")) {
            o.solver = std.meta.stringToEnum(sim.simulation.Solver, v) orelse return badValue(out, a, v);
        } else if (std.mem.eql(u8, a, "--transfer")) {
            o.transfer = std.meta.stringToEnum(sim.transfer.Scheme, v) orelse return badValue(out, a, v);
        } else if (std.mem.eql(u8, a, "--cfl")) {
            o.cfl = std.fmt.parseFloat(f32, v) catch return badValue(out, a, v);
            if (!(o.cfl > 0)) return badValue(out, a, v);
        } else if (std.mem.eql(u8, a, "--threads")) {
            if (!std.mem.eql(u8, v, "1")) return badValue(out, a, v);
            o.parallel = false;
        } else if (std.mem.eql(u8, a, "--csv")) {
            o.csv = v;
        } else if (std.mem.eql(u8, a, "--dump")) {
            o.dump = v;
        } else {
            try out.print("unknown option {s}\n", .{a});
            return error.BadArgument;
        }
    }
    return o;
}

fn badValue(out: *Io.Writer, name: []const u8, value: []const u8) error{ BadArgument, WriteFailed } {
    try out.print("bad value for {s}: {s}\n", .{ name, value });
    return error.BadArgument;
}

fn runCommand(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const [:0]const u8) !void {
    const o = try parseRunOptions(out, args);
    var params = sim.scenes.params(o.scene, o.res);
    params.solver = o.solver;
    params.transfer = o.transfer;
    params.ghost_fluid = o.ghost;
    params.cfl = o.cfl;
    const workers: ?*sim.pool.Workers = if (o.parallel) try startWorkers(gpa, io) else null;
    defer if (workers) |w| w.deinit();
    const pool: sim.pool.Pool = .{ .io = io, .workers = workers };

    var s = try sim.simulation.Simulation.init(gpa, pool, params);
    defer s.deinit();
    try sim.scenes.fill(&s, o.scene);

    const start = s.measure();
    try out.print("scene {s}: {d}x{d}x{d} cells, dx = {d:.2} mm, {d} particles, solver {s}, transfer {s}{s}\n", .{
        @tagName(o.scene),                    params.cells[0], params.cells[1],    params.cells[2],
        params.dx * 1000,                     start.particles, @tagName(o.solver), @tagName(o.transfer),
        if (o.ghost) ", ghost fluid" else "",
    });
    try out.writeAll("frame   time  substeps  iters/step  max|div|·dt  volume   E_kin(J)   E_total(J)   ms/frame\n");
    try out.flush();

    var csv_file: ?Io.File = null;
    var csv_buf: [4096]u8 = undefined;
    var csv_writer: Io.File.Writer = undefined;
    if (o.csv) |path| {
        csv_file = try Io.Dir.cwd().createFile(io, path, .{});
        csv_writer = .init(csv_file.?, io, &csv_buf);
        try csv_writer.interface.writeAll("frame,time,substeps,iterations,max_div_dt,all_converged,volume,particles,fluid_cells,kinetic,potential,max_speed,ms\n");
    }
    defer if (csv_file) |f| {
        csv_writer.interface.flush() catch {};
        f.close(io);
    };
    if (o.dump) |dir| try Io.Dir.cwd().createDirPath(io, dir);

    const frame_time = 1 / o.fps;
    const frames: usize = @intFromFloat(@round(o.seconds * o.fps));
    for (1..frames + 1) |frame| {
        const t0 = Io.Timestamp.now(io, .awake);
        const fs = try s.advanceFrame(frame_time);
        const ms = @as(f64, @floatFromInt(t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds)) / 1e6;
        const m = s.measure();
        // Divergence times the substep is the fraction of volume a cell gains or loses per step.
        const div_dt = fs.max_divergence * frame_time / @as(f64, @floatFromInt(fs.substeps));
        const iters = @as(f64, @floatFromInt(fs.iterations)) / @as(f64, @floatFromInt(fs.substeps));
        try out.print("{d:5} {d:6.3} {d:9} {d:11.1} {e:12.2} {d:6.3} {e:10.3} {e:12.5} {d:10.1}{s}\n", .{
            frame,                   s.time,           fs.substeps,                           iters, div_dt,
            m.volume / start.volume, m.kinetic_energy, m.kinetic_energy + m.potential_energy, ms,    if (fs.all_converged) "" else "  (solver did not converge)",
        });
        try out.flush();
        if (csv_file != null) {
            try csv_writer.interface.print("{d},{d},{d},{d},{e},{d},{e},{d},{d},{e},{e},{e},{d}\n", .{
                frame,         s.time,                         fs.substeps,        fs.iterations,
                div_dt,        @intFromBool(fs.all_converged), m.volume,           m.particles,
                m.fluid_cells, m.kinetic_energy,               m.potential_energy, m.max_speed,
                ms,
            });
        }
        if (o.dump) |dir| try dumpPhi(io, dir, frame, &s.grid);
    }
}

/// Binary level set dump: "FLPHI1\0\0", nx, ny, nz (u32), dx (f32), then
/// nx·ny·nz f32 values with x varying fastest. All little-endian.
fn dumpPhi(io: Io, dir: []const u8, frame: usize, g: *const sim.grid.Grid) !void {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buf, "{s}/phi_{d:0>4}.bin", .{ dir, frame });
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1 << 16]u8 = undefined;
    var w: Io.File.Writer = .init(file, io, &buf);
    const iw = &w.interface;
    try iw.writeAll("FLPHI1\x00\x00");
    for (g.n) |n| try iw.writeInt(u32, @intCast(n), .little);
    try iw.writeInt(u32, @bitCast(g.dx), .little);
    comptime std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
    try iw.writeAll(std.mem.sliceAsBytes(g.phi));
    try iw.flush();
}
