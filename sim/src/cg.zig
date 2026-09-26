//! Preconditioned Conjugate Gradient (lesson 6, §6.2): a smart downhill walk
//! on the energy bowl ½pᵀAp - bᵀp. With a multigrid V-cycle as the
//! preconditioner this is MGPCG (lesson 6, §6.5).

const std = @import("std");
const Pool = @import("pool.zig").Pool;
const Poisson = @import("pressure.zig").Poisson;
const Multigrid = @import("multigrid.zig").Multigrid;

pub const Workspace = struct {
    r: []f64,
    z: []f64,
    d: []f64,
    q: []f64,

    pub fn init(gpa: std.mem.Allocator, n: usize) !Workspace {
        var ws: Workspace = .{ .r = &.{}, .z = &.{}, .d = &.{}, .q = &.{} };
        errdefer ws.deinit(gpa);
        ws.r = try gpa.alloc(f64, n);
        ws.z = try gpa.alloc(f64, n);
        ws.d = try gpa.alloc(f64, n);
        ws.q = try gpa.alloc(f64, n);
        return ws;
    }

    pub fn deinit(ws: *Workspace, gpa: std.mem.Allocator) void {
        gpa.free(ws.r);
        gpa.free(ws.z);
        gpa.free(ws.d);
        gpa.free(ws.q);
    }
};

pub const Result = struct {
    iterations: u32,
    /// max|r| / max|b| when the solve stopped.
    relative_residual: f64,
    converged: bool,
};

const grain = 8192;

/// Solves A·x = b. `x` holds the initial guess (warm start) and receives the
/// answer. Stops when max|r| ≤ tolerance·max|b|. With `mg` set, one V-cycle is
/// the preconditioner M⁻¹; otherwise z = r (plain CG).
pub fn solve(
    pool: Pool,
    sys: *const Poisson,
    b: []const f64,
    x: []f64,
    ws: *Workspace,
    tolerance: f64,
    max_iterations: u32,
    mg: ?*Multigrid,
) Result {
    const n = sys.cellCount();
    const V = Vec{ .pool = pool, .n = n };

    // Only FLUID cells are unknowns; a warm start may hold values from cells
    // that were FLUID last step.
    V.maskToFluid(x, sys.label);
    const b_max = V.maxAbs(b);
    if (b_max == 0) {
        @memset(x, 0);
        return .{ .iterations = 0, .relative_residual = 0, .converged = true };
    }

    // r = b - A·x
    sys.apply(pool, x, ws.q);
    V.sub(b, ws.q, ws.r);
    var res = V.maxAbs(ws.r) / b_max;
    if (res <= tolerance) return .{ .iterations = 0, .relative_residual = res, .converged = true };

    precondition(pool, mg, ws.r, ws.z);
    @memcpy(ws.d, ws.z);
    var rho = V.dot(ws.r, ws.z);

    var it: u32 = 0;
    while (it < max_iterations) {
        it += 1;
        sys.apply(pool, ws.d, ws.q); //  q = A·d
        const alpha = rho / V.dot(ws.d, ws.q); // how far to go along d
        V.step(x, ws.r, ws.d, ws.q, alpha); // x += α·d,  r -= α·q
        res = V.maxAbs(ws.r) / b_max;
        if (res <= tolerance) return .{ .iterations = it, .relative_residual = res, .converged = true };
        precondition(pool, mg, ws.r, ws.z);
        const rho_new = V.dot(ws.r, ws.z);
        V.newDirection(ws.d, ws.z, rho_new / rho); // d = z + β·d
        rho = rho_new;
    }
    return .{ .iterations = it, .relative_residual = res, .converged = false };
}

fn precondition(pool: Pool, mg: ?*Multigrid, r: []const f64, z: []f64) void {
    if (mg) |m| m.vcycle(pool, r, z) else @memcpy(z, r);
}

/// Parallel vector kernels over all cells.
const Vec = struct {
    pool: Pool,
    n: usize,

    fn dot(v: Vec, a: []const f64, b: []const f64) f64 {
        const Ctx = struct {
            a: []const f64,
            b: []const f64,
            fn f(c: @This(), i: usize) f64 {
                return c.a[i] * c.b[i];
            }
        };
        return v.pool.sumEach(v.n, grain, Ctx{ .a = a, .b = b }, Ctx.f);
    }

    fn maxAbs(v: Vec, a: []const f64) f64 {
        const Ctx = struct {
            a: []const f64,
            fn f(c: @This(), i: usize) f64 {
                return @abs(c.a[i]);
            }
        };
        return v.pool.maxEach(v.n, grain, Ctx{ .a = a }, Ctx.f);
    }

    fn sub(v: Vec, a: []const f64, b: []const f64, out: []f64) void {
        const Ctx = struct {
            a: []const f64,
            b: []const f64,
            out: []f64,
            fn f(c: @This(), i: usize) void {
                c.out[i] = c.a[i] - c.b[i];
            }
        };
        v.pool.each(v.n, grain, Ctx{ .a = a, .b = b, .out = out }, Ctx.f);
    }

    fn step(v: Vec, x: []f64, r: []f64, d: []const f64, q: []const f64, alpha: f64) void {
        const Ctx = struct {
            x: []f64,
            r: []f64,
            d: []const f64,
            q: []const f64,
            alpha: f64,
            fn f(c: @This(), i: usize) void {
                c.x[i] += c.alpha * c.d[i];
                c.r[i] -= c.alpha * c.q[i];
            }
        };
        v.pool.each(v.n, grain, Ctx{ .x = x, .r = r, .d = d, .q = q, .alpha = alpha }, Ctx.f);
    }

    fn newDirection(v: Vec, d: []f64, z: []const f64, beta: f64) void {
        const Ctx = struct {
            d: []f64,
            z: []const f64,
            beta: f64,
            fn f(c: @This(), i: usize) void {
                c.d[i] = c.z[i] + c.beta * c.d[i];
            }
        };
        v.pool.each(v.n, grain, Ctx{ .d = d, .z = z, .beta = beta }, Ctx.f);
    }

    fn maskToFluid(v: Vec, x: []f64, label: []const @import("grid.zig").Label) void {
        const Ctx = struct {
            x: []f64,
            label: []const @import("grid.zig").Label,
            fn f(c: @This(), i: usize) void {
                if (c.label[i] != .fluid) c.x[i] = 0;
            }
        };
        v.pool.each(v.n, grain, Ctx{ .x = x, .label = label }, Ctx.f);
    }
};
