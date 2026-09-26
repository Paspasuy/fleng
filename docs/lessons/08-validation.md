# Lesson 8: validation, proving it's correct

Part of milestone 1 in [the water plan](../water-plan.md). Previous: [lesson 7, particles → water surface](07-surface-reconstruction.md). This is the last lesson before code.

A fluid simulation can look completely plausible and still be wrong: volume slowly leaks, energy appears from nowhere, pressure is off by half a cell. Your eyes won't catch it. Numbers will. Every test below has a known answer and a tolerance, and runs automatically (`make test`) from the headless runner.

## 8.1 Unit tests: one piece at a time

These catch bugs close to where they are, before they get lost in a full simulation.

| Test | What it checks | Catches |
|---|---|---|
| **Interpolation of a linear field** | Fill `u, v, w` from `u = (2x + y, …)`, sample at random points: trilinear interpolation must be exact for linear fields | Half-cell offset bugs (lesson 2, §2.5) |
| **Divergence of known fields** | `u = (x, −y, 0)` → 0 everywhere. `u = (x, y, z)` → 3 everywhere | Index and sign bugs in the divergence |
| **Stencil vs. matrix** | Apply the matrix-free `A` to a random `p` and compare with building `A` explicitly on a tiny grid | Boundary-condition mistakes (lesson 5, §5.4) |
| **Projection** | Random `u*` → project → max `|div|` below tolerance. Projecting a second time changes nothing (projection is idempotent) | Solver and update bugs |
| **Solver behavior** | CG residual decreases every iteration. One V-cycle cuts the residual by a roughly constant factor (≈ 0.1) regardless of grid size | Multigrid bugs, including a non-symmetric V-cycle |
| **APIC round trip** | A uniform or linear velocity field survives P2G → G2P exactly. Total linear and angular momentum `Σ m·v` and `Σ m·(x × v)` are unchanged by the transfers | Transfer and `C` matrix bugs (lesson 3) |
| **Advection** | Particles in a rigid rotation `u = (−y, x)` keep their radius over one revolution (RK2: ~0.1% drift at a reasonable Δt) | Wrong integration order, bad velocity sampling |

## 8.2 Scenario tests: the whole solver

### Still tank (hydrostatic)

A box half full of water, at rest. Run for 2 seconds of simulated time.

- **Velocity:** max particle speed stays near zero (tiny compared with `√(g·Δx)`). Any visible motion is a bug: parasitic currents.
- **Pressure:** matches `ρ·g·depth`. Without ghost fluid, expect up to a half-cell offset (lesson 5, §5.5). With it, the error should nearly vanish.
- **Volume:** constant.

This is the single most useful test. Most solver bugs make still water move.

### Volume conservation

Run a violent scene (dam break, drop into pool) and track the water volume every step, either by counting FLUID cells or by integrating the region where `φ < 0`. It should stay within a few percent. A steady drift means particles are clumping (lesson 7, §7.5) or the solver tolerance is too loose (lesson 6, §6.2).

### Dam break vs. experiment

A column of water is released at `t = 0` in a tank and collapses. The front's position over time has been measured experimentally:

- **Martin & Moyce (1952):** the classic dataset.
- **A common modern setup (Koshizuka & Oka, 1996):** a column 0.146 m wide and 0.292 m tall.

Published results are dimensionless: the front distance divided by the initial column width `a`, against time scaled by `√(g/a)` (check the exact scaling constant used by whichever paper you compare against). Plot the simulation on the same axes and compare. It won't match perfectly, but the shape and speed of the front should agree to within a few percent once the resolution is adequate.

### Energy should never grow

Without anything driving the flow, total energy `E = Σ ½·m·|v|² + Σ m·g·height` must never increase. It should slowly decrease (numerical and real viscosity). Log it every step: a rise, even a small one, points to advection (lesson 4) or transfer (lesson 3) problems.

### Convergence study

Run the same scene at 32³, 64³, and 128³, and measure an error (say, the dam-break front position vs. experiment, or the hydrostatic pressure error). A correct solver's error **shrinks at a steady rate** as the grid refines: halving each time for a first-order method, quartering for second order. If the error doesn't shrink, or shrinks erratically, something is wrong even if every picture looks fine. This is the most important habit in numerical simulation.

## 8.3 Measuring numerical viscosity

The **Taylor–Green vortex** is a grid of counter-rotating vortices with an exact solution: in 2D, the flow keeps its shape and its speed decays as `exp(−2ν·t)` (for the standard `[0, 2π]` periodic domain). It needs a periodic box full of fluid, no free surface.

It's the perfect tool for comparing transfer schemes (lesson 3). Set the physical viscosity `ν = 0`: any decay you measure is **numerical viscosity**. PIC will decay quickly, FLIP barely (but get noisy), APIC in between and clean. Fitting the decay rate turns "the water looks syrupy" into a number. When real viscosity is added later, this test also checks it.

## 8.4 Later: surface tension (accuracy mode)

Two classic tests for milestone 5 (VOF with surface tension):

- **Static drop (Laplace pressure):** a spherical drop of radius `R` at rest must have a pressure jump across its surface of `Δp = 2σ/R`, and stay perfectly still. Any motion is a parasitic current from bad curvature (see the [water overview](../water-simulation-overview.md) §2).
- **Oscillating drop (Rayleigh):** a slightly squashed drop oscillates with angular frequency `ω² = 8σ / (ρ·R³)` for the basic mode.

## 8.5 What to log every step

A small CSV row per step makes every problem visible later:

| Column | Why |
|---|---|
| time, Δt, substep count | Check CFL behavior (lesson 4) |
| max particle speed | Instabilities show up here first |
| max `|div|` after projection | Solver accuracy (lessons 5–6) |
| solver iterations | Performance, and a warning sign if it suddenly jumps |
| water volume | Volume drift (§8.2) |
| kinetic + potential energy | Energy must not grow (§8.2) |
| particle count, particles per FLUID cell | Clumping and gaps (lesson 7, §7.5) |

## 8.6 Check yourself

1. Why is the still tank the most useful single test?
2. Trilinear interpolation of a *linear* field must be exact. What bug does a failure usually mean?
3. In a convergence study, the error at 32³, 64³, 128³ is 0.08, 0.04, 0.02. What order is the method?
4. How can the Taylor–Green vortex measure numerical viscosity?

<details>
<summary>Answers</summary>

1. The correct answer is trivial (nothing moves, pressure = ρ·g·depth), and almost every bug in gravity, boundaries, projection, or transfers makes still water move.
2. A wrong half-cell offset for one of the staggered grids.
3. First order: the error halves each time the grid spacing halves.
4. With physical viscosity set to 0, the exact solution doesn't decay at all, so all measured decay is caused by the numerical method.

</details>
