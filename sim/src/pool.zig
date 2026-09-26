//! Deterministic parallel-for with a persistent worker pool.
//!
//! Work over `0..n` is cut into chunks whose boundaries depend only on `n` and
//! the call site's grain size, never on how many threads exist. Reductions
//! (sums, maxima) combine per-chunk results in chunk order, so the simulation
//! produces bit-identical numbers on 1 thread or 10.
//!
//! The solver dispatches thousands of small jobs per time step (every CG
//! iteration is several), so dispatch must be cheap: workers spin briefly,
//! then sleep on a futex, and a job costs at most one wake-all.

const std = @import("std");
const Io = std.Io;

pub const max_chunks = 64;

pub const Pool = struct {
    io: Io,
    /// null runs every chunk on the calling thread, in order. Same results, slower.
    workers: ?*Workers = null,

    pub fn serial(io: Io) Pool {
        return .{ .io = io };
    }

    /// Calls `body(ctx, chunk, begin, end)` for each chunk of `0..n`.
    /// `grain` is the smallest amount of work worth giving its own chunk.
    pub fn forEach(
        pool: Pool,
        n: usize,
        grain: usize,
        ctx: anytype,
        comptime body: fn (@TypeOf(ctx), usize, usize, usize) void,
    ) void {
        const chunks = chunkCount(n, grain);
        const w = pool.workers orelse {
            for (0..chunks) |c| {
                const r = chunkRange(n, chunks, c);
                body(ctx, c, r[0], r[1]);
            }
            return;
        };
        if (chunks <= 1) {
            if (chunks == 1) body(ctx, 0, 0, n);
            return;
        }
        const Erased = struct {
            ctx: @TypeOf(ctx),
            n: usize,
            chunks: usize,
            fn run(ptr: *const anyopaque, c: usize) void {
                const e: *const @This() = @ptrCast(@alignCast(ptr));
                const r = chunkRange(e.n, e.chunks, c);
                body(e.ctx, c, r[0], r[1]);
            }
        };
        const erased: Erased = .{ .ctx = ctx, .n = n, .chunks = chunks };
        w.dispatch(&erased, Erased.run, @intCast(chunks));
    }

    /// Calls `f(ctx, i)` for every i in 0..n.
    pub fn each(pool: Pool, n: usize, grain: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize) void) void {
        const Wrap = struct {
            fn run(c: @TypeOf(ctx), _: usize, begin: usize, end: usize) void {
                for (begin..end) |i| f(c, i);
            }
        };
        pool.forEach(n, grain, ctx, Wrap.run);
    }

    /// Sum of `chunkSum(ctx, begin, end)` over all chunks, added in chunk order.
    pub fn sum(pool: Pool, n: usize, grain: usize, ctx: anytype, comptime chunkSum: fn (@TypeOf(ctx), usize, usize) f64) f64 {
        var partial: [max_chunks]f64 = undefined;
        pool.reduce(n, grain, ctx, chunkSum, &partial);
        var total: f64 = 0;
        for (partial[0..chunkCount(n, grain)]) |p| total += p;
        return total;
    }

    /// Largest value of `chunkMax(ctx, begin, end)` over all chunks (0 when n == 0).
    pub fn max(pool: Pool, n: usize, grain: usize, ctx: anytype, comptime chunkMax: fn (@TypeOf(ctx), usize, usize) f64) f64 {
        var partial: [max_chunks]f64 = undefined;
        pool.reduce(n, grain, ctx, chunkMax, &partial);
        var best: f64 = 0;
        for (partial[0..chunkCount(n, grain)]) |p| best = @max(best, p);
        return best;
    }

    /// Σ f(ctx, i) over 0..n, deterministic.
    pub fn sumEach(pool: Pool, n: usize, grain: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize) f64) f64 {
        const Wrap = struct {
            fn run(c: @TypeOf(ctx), begin: usize, end: usize) f64 {
                var s: f64 = 0;
                for (begin..end) |i| s += f(c, i);
                return s;
            }
        };
        return pool.sum(n, grain, ctx, Wrap.run);
    }

    /// max f(ctx, i) over 0..n (0 when n == 0).
    pub fn maxEach(pool: Pool, n: usize, grain: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), usize) f64) f64 {
        const Wrap = struct {
            fn run(c: @TypeOf(ctx), begin: usize, end: usize) f64 {
                var m: f64 = 0;
                for (begin..end) |i| m = @max(m, f(c, i));
                return m;
            }
        };
        return pool.max(n, grain, ctx, Wrap.run);
    }

    fn reduce(pool: Pool, n: usize, grain: usize, ctx: anytype, comptime chunkFn: fn (@TypeOf(ctx), usize, usize) f64, partial: *[max_chunks]f64) void {
        const Args = struct { ctx: @TypeOf(ctx), partial: *[max_chunks]f64 };
        const Wrap = struct {
            fn run(args: Args, c: usize, begin: usize, end: usize) void {
                args.partial[c] = chunkFn(args.ctx, begin, end);
            }
        };
        pool.forEach(n, grain, Args{ .ctx = ctx, .partial = partial }, Wrap.run);
    }
};

pub fn chunkCount(n: usize, grain: usize) usize {
    if (n == 0) return 0;
    const g = @max(grain, 1);
    return @min(max_chunks, (n + g - 1) / g);
}

fn chunkRange(n: usize, chunks: usize, c: usize) [2]usize {
    return .{ n * c / chunks, n * (c + 1) / chunks };
}

/// Background threads that execute the chunks of one job at a time, together
/// with the thread that dispatched it.
pub const Workers = struct {
    io: Io,
    threads: []std.Thread,
    gpa: std.mem.Allocator,

    /// High 32 bits: job generation. Low 32 bits: next unclaimed chunk.
    /// Claiming a chunk is a compare-and-swap on the whole word, so a worker
    /// still holding an old generation can never claim a newer job's chunk.
    ticket: std.atomic.Value(u64) = .init(0),
    /// Job descriptions, double-buffered by generation parity: while job G+1
    /// is being written, a late worker may still be reading slot G's fields.
    slots: [2]Slot = .{ .{}, .{} },
    /// Generation number workers sleep on.
    generation: std.atomic.Value(u32) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    shutdown: std.atomic.Value(bool) = .init(false),

    const Slot = struct {
        run: *const fn (*const anyopaque, usize) void = undefined,
        ctx: *const anyopaque = undefined,
        /// Read by workers before they know whether the slot is current, so atomic.
        chunks: std.atomic.Value(u32) = .init(0),
        finished: std.atomic.Value(u32) = .init(0),
    };

    const spin_limit = 20_000;

    /// Starts `count` worker threads (use CPU count - 1; the caller is the last one).
    pub fn init(gpa: std.mem.Allocator, io: Io, count: usize) !*Workers {
        const w = try gpa.create(Workers);
        errdefer gpa.destroy(w);
        w.* = .{ .io = io, .threads = try gpa.alloc(std.Thread, count), .gpa = gpa };
        var started: usize = 0;
        errdefer {
            w.stop();
            for (w.threads[0..started]) |t| t.join();
            gpa.free(w.threads);
        }
        for (w.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerMain, .{w});
            started += 1;
        }
        return w;
    }

    pub fn deinit(w: *Workers) void {
        w.stop();
        for (w.threads) |t| t.join();
        w.gpa.free(w.threads);
        w.gpa.destroy(w);
    }

    fn stop(w: *Workers) void {
        w.shutdown.store(true, .seq_cst);
        _ = w.generation.fetchAdd(1, .seq_cst);
        w.io.futexWake(u32, &w.generation.raw, std.math.maxInt(u32));
    }

    fn dispatch(w: *Workers, ctx: *const anyopaque, run: *const fn (*const anyopaque, usize) void, chunks: u32) void {
        const gen: u32 = @intCast(w.ticket.load(.monotonic) >> 32);
        const next = gen +% 1;
        const slot = &w.slots[next & 1];
        slot.run = run;
        slot.ctx = ctx;
        slot.chunks.store(chunks, .monotonic);
        slot.finished.store(0, .monotonic);
        // Publishing the ticket makes the slot visible to anyone who reads it.
        w.ticket.store(@as(u64, next) << 32, .release);
        w.generation.store(next, .seq_cst);
        if (w.sleepers.load(.seq_cst) > 0) w.io.futexWake(u32, &w.generation.raw, std.math.maxInt(u32));

        w.work();
        // Wait for chunks still running on other threads.
        var spins: u32 = 0;
        while (true) {
            const done = slot.finished.load(.acquire);
            if (done == chunks) break;
            if (spins < spin_limit) {
                spins += 1;
                std.atomic.spinLoopHint();
            } else {
                w.io.futexWaitUncancelable(u32, &slot.finished.raw, done);
            }
        }
    }

    /// Claims and runs chunks of the current job until none are left.
    fn work(w: *Workers) void {
        var t = w.ticket.load(.acquire);
        while (true) {
            const gen: u32 = @intCast(t >> 32);
            const chunk: u32 = @truncate(t);
            const slot = &w.slots[gen & 1];
            if (chunk >= slot.chunks.load(.monotonic)) return;
            if (w.ticket.cmpxchgWeak(t, t + 1, .acq_rel, .acquire)) |actual| {
                t = actual;
                continue;
            }
            // Claimed: the ticket still carried our generation, so the slot is current.
            slot.run(slot.ctx, chunk);
            if (slot.finished.fetchAdd(1, .acq_rel) + 1 == slot.chunks.load(.monotonic)) {
                w.io.futexWake(u32, &slot.finished.raw, 1);
            }
            t = w.ticket.load(.acquire);
        }
    }

    fn workerMain(w: *Workers) void {
        var seen: u32 = w.generation.load(.seq_cst);
        while (true) {
            // Spin briefly: the next job usually arrives within microseconds.
            var spins: u32 = 0;
            while (w.generation.load(.acquire) == seen and spins < spin_limit) : (spins += 1) {
                std.atomic.spinLoopHint();
            }
            if (w.generation.load(.seq_cst) == seen) {
                _ = w.sleepers.fetchAdd(1, .seq_cst);
                if (w.generation.load(.seq_cst) == seen) {
                    w.io.futexWaitUncancelable(u32, &w.generation.raw, seen);
                }
                _ = w.sleepers.fetchSub(1, .seq_cst);
            }
            seen = w.generation.load(.seq_cst);
            if (w.shutdown.load(.seq_cst)) return;
            w.work();
        }
    }
};

test "parallel and serial reductions are bit-identical" {
    const gpa = std.testing.allocator;
    const data = try gpa.alloc(f64, 100_000);
    defer gpa.free(data);
    var prng = std.Random.DefaultPrng.init(1);
    for (data) |*d| d.* = prng.random().float(f64) * 1e6;

    const Ctx = struct {
        data: []const f64,
        fn chunkSum(ctx: @This(), begin: usize, end: usize) f64 {
            var s: f64 = 0;
            for (ctx.data[begin..end]) |d| s += d;
            return s;
        }
    };
    const ctx: Ctx = .{ .data = data };
    const workers = try Workers.init(gpa, std.testing.io, 3);
    defer workers.deinit();
    const par: Pool = .{ .io = std.testing.io, .workers = workers };
    const ser = Pool.serial(std.testing.io);
    const expected = ser.sum(data.len, 1000, ctx, Ctx.chunkSum);
    // Many back-to-back jobs exercise the generation handoff.
    for (0..2000) |_| try std.testing.expectEqual(expected, par.sum(data.len, 1000, ctx, Ctx.chunkSum));
}

test "every chunk runs exactly once" {
    const gpa = std.testing.allocator;
    const workers = try Workers.init(gpa, std.testing.io, 4);
    defer workers.deinit();
    const pool: Pool = .{ .io = std.testing.io, .workers = workers };
    var hits: [max_chunks]std.atomic.Value(u32) = undefined;
    for (&hits) |*h| h.* = .init(0);
    const Ctx = struct {
        hits: *[max_chunks]std.atomic.Value(u32),
        fn run(ctx: @This(), c: usize, _: usize, _: usize) void {
            _ = ctx.hits[c].fetchAdd(1, .monotonic);
        }
    };
    const rounds = 5000;
    for (0..rounds) |r| pool.forEach(max_chunks * (1 + r % 3), 1, Ctx{ .hits = &hits }, Ctx.run);
    for (hits) |h| try std.testing.expectEqual(@as(u32, rounds), h.load(.monotonic));
}
