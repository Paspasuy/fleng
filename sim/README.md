# fleng-sim

Water simulation core for fleng: APIC particles on a MAC grid with an MGPCG
pressure solve, written in Zig 0.16. No graphics dependencies. This is
milestone 1 of [the water plan](../docs/water-plan.md); the algorithms are
explained step by step in [docs/lessons](../docs/lessons/).

## Build and run

```sh
cd sim
zig build test                          # unit tests (Debug, ~5 s)
zig build -Doptimize=ReleaseFast        # → zig-out/bin/fleng-sim
./zig-out/bin/fleng-sim run --scene drop --res 48
./zig-out/bin/fleng-sim validate        # lesson 8 scenario checks (~2 min; --quick ~20 s)
```

`fleng-sim run` prints one line per frame: substeps, pressure-solver
iterations, leftover divergence, water volume, and energy. Options:

| Option | Meaning | Default |
|---|---|---|
| `--scene NAME` | `still_tank`, `dam_break`, `drop` | `drop` |
| `--res N` | cells across the scene's x axis | 48 |
| `--seconds S`, `--fps F` | simulated time, output frame rate | 1, 60 |
| `--solver NAME` | `mgpcg` or `cg` (lesson 6) | `mgpcg` |
| `--transfer NAME` | `apic`, `pic`, `flip` (lesson 3) | `apic` |
| `--cfl C` | max cells a particle moves per substep (lesson 4) | 0.5 |
| `--no-ghost` | disable ghost fluid (lesson 5, §5.6) | on |
| `--threads 1` | single-threaded (results are bit-identical either way) | all cores |
| `--csv PATH` | per-frame statistics as CSV | |
| `--dump DIR` | level set φ of every frame, for rendering later | |

`--dump` writes `DIR/phi_NNNN.bin`: the bytes `FLPHI1\0\0`, then `nx ny nz`
(u32) and `dx` (f32), then `nx·ny·nz` f32 values, x varying fastest,
little-endian. φ is negative inside the water.

## Using it from C or C++

`zig build` also produces `zig-out/lib/libfleng_sim.a`, with the interface in
[include/fleng_sim.h](include/fleng_sim.h): create a scene, advance it frame by
frame, and copy out the water surface as a signed distance field. fleng's
Makefile builds and links it (see `src/water.hpp`). The library links libc and
leaves signal handling to the host program.

## Code map

| File | Lesson | What it does |
|---|---|---|
| `simulation.zig` | 1, 4 | One time step, frames of CFL substeps, energy/volume measurements |
| `grid.zig` | 2 | MAC grid, staggered fields, trilinear sampling, divergence |
| `particles.zig` | 2, 3 | Particles (SoA), seeding, counting sort by cell, colored parallel scatter |
| `transfer.zig` | 3 | P2G / G2P for PIC, FLIP, APIC with the quadratic B-spline |
| `advect.zig` | 4 | RK2 particle advection, keeping particles inside the walls |
| `pressure.zig` | 5 | Matrix-free Poisson stencil, ghost fluid, right-hand side, pressure-gradient update |
| `extrapolate.zig` | 5 | Velocity extrapolation into the air |
| `cg.zig` | 6 | (Preconditioned) Conjugate Gradient |
| `multigrid.zig` | 6 | Symmetric geometric multigrid V-cycle (the MGPCG preconditioner) |
| `surface.zig` | 7 | Zhu–Bridson level set from particles, FLUID/AIR labels, redistancing by fast sweeping |
| `validate.zig` | 8 | Scenario checks |
| `scenes.zig` | | Still tank, dam break, drop |
| `pool.zig` | | Deterministic parallel-for on a persistent worker pool |
| `main.zig` | | Command-line runner |
| `capi.zig` | | C interface for the engine |

## Measured results (MacBook Air M4, ReleaseFast)

`fleng-sim validate` passes all checks. Highlights:

- **Still tank:** pressure matches ρ·g·depth to 0.02–0.03·ρgΔx, and the error
  shrinks with resolution (2.89 → 1.96 → 0.57 Pa at 16³, 32³, 64³). Without
  ghost fluid the error is 0.50·ρgΔx: exactly the half-cell offset derived in
  lesson 5, §5.5. Volume change: 0.000%.
- **Dam break:** total energy never increases; the surge front stays below
  Ritter's theoretical limit 2√(g·h0).
- **Determinism:** multi-threaded and single-threaded runs are bit-identical.

Drop scene (4 cm ball into a 10 cm pool), per 60 Hz output frame:

| Grid | Particles | Time per frame | Substeps | MGPCG iterations | Plain CG iterations |
|---|---|---|---|---|---|
| 34³ | 90 k | 0.14 s | 5.8 | 11 | 193 |
| 50³ | 304 k | 0.63 s | 9.0 | 11 | 335 |
| 66³ | 720 k | 2.1 s | 12.9 | 12 | 621 |

MGPCG's iteration count stays flat while plain CG's grows with the grid
(lesson 6, §6.5). This is the "slow" and "bake" end of the trade-off; "live"
needs smaller grids or the later CUDA backend.

## Where the code departs from the lessons, and why

- **P2G and the level set scatter from particles** instead of gathering per
  grid sample (lesson 3, §3.6 suggested starting with a gather). Profiling
  showed gathering rescans 36–125 cells per sample. The scatter is made
  race-free and deterministic by coloring blocks of 4×4 grid rows in 4
  passes (`Particles.forEachBlockColored`).
- **Level set kernel radius 1.5Δx, particle radius 0.42Δx** (lesson 7 used
  about 2Δx). Both values were calibrated so a flat water surface lands within
  ±0.04 cells of the true boundary (test "flat slab"); 1.5Δx is as accurate as
  2Δx and ~2.4× cheaper.
- **Default CFL number 0.5**, not 1. At CFL 1 the drop scene gained 0.06–0.18%
  spurious energy during its splash; at 0.5 none was measurable.
- **Extrapolation after projection overrides one layer of particle-touched
  air faces** (lesson 5, §5.7 extended). Particles slightly above the level set
  put weight on air faces that receive gravity but no pressure; keeping those
  velocities made still water jitter forever (kinetic energy stuck at
  ~3·10⁻⁶ J). With the override it decays. Faces farther out keep their
  particle velocity, so spray still flies ballistically.
- **Kinetic energy includes APIC's affine part** ½·m·(Δx²/4)·|C|², which the
  lessons didn't mention: rotation stored in C can turn into visible velocity,
  so it has to be counted when checking that energy never grows.
- **The pressure solve runs in f64** (fields and particles are f32), so the
  solver can reach tight tolerances.

## Known limits

- No surface tension: APIC is right when drops are centimeters, not millimeters
  (milestone 5 adds VOF with surface tension).
- Walls are the domain box only; obstacles come in milestone 2.
- Some bookkeeping (sorting, masks) is still single-threaded.
- Dam break front positions are printed (dimensionless) but not yet compared
  against the Martin & Moyce data; that needs the published table.
