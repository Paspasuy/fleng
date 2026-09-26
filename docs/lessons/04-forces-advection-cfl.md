# Lesson 4: gravity, moving particles, choosing Δt

Part of milestone 1 in [the water plan](../water-plan.md). Previous: [lesson 3, particles ↔ grid](03-particles-and-grid.md). Next: [lesson 5, pressure projection](05-pressure-projection.md).

This lesson covers the "easy" parts of the time step (lesson 1): adding gravity (step 4), moving the particles (step 8), and choosing how big a step to take (step 1).

## 4.1 Gravity

After P2G, add gravity to every grid velocity that belongs to the fluid:

```
for each v-face touching a FLUID cell:     // gravity points along −y
    v += g_y · Δt                           // g_y = −9.81 m/s²
```

Only the component along gravity changes, so with `g = (0, −9.81, 0)` only the `v` grid is touched.

It happens *before* the pressure solve on purpose: gravity tries to push the water down into the floor and into itself, and the pressure solve (lesson 5) cancels exactly the part that would compress it. That's how the still tank stays still.

Other body forces (a fan, a rotating reference frame, a "wind" slider in the playground) go in the same place, the same way.

## 4.2 Viscosity: why we skip it for water

The viscous term `ν∇²u` smooths velocity differences. For water, `ν ≈ 10⁻⁶ m²/s`. Over one cell of `Δx = 5 mm`, viscosity would need about `Δx²/ν ≈ 25 s` to smooth things noticeably. Meanwhile the numerical viscosity of even APIC at this resolution is much larger. **At these scales, real water viscosity is invisible, and adding it changes nothing.**

It matters for thick liquids (honey: `ν ≈ 10⁻² m²/s`, 10,000× water). The simple explicit update `u += ν·Δt·∇²u` is only stable when `Δt < Δx² / (6ν)`: for honey at `Δx = 5 mm` that's `0.4 ms`, forcing tiny time steps. Thick liquids need an **implicit** viscosity solve, another sparse linear system like pressure. That's a later playground feature.

## 4.3 Moving the particles (advection)

After the pressure solve, the grid holds a divergence-free velocity field. Each particle moves through it for `Δt`.

### Forward Euler, and why it fails

The obvious step:

```
x_p ← x_p + Δt · u(x_p)
```

Test it on a rigid rotation `u = (−y, x)` (angular speed 1, particles should move in circles). Each Euler step moves along the *tangent* of the circle, which always points slightly outward. The radius grows by `√(1 + Δt²)` per step. With `Δt = 0.1`, one full revolution takes 63 steps:

```
radius after one revolution ≈ 1.01^(63/2) ≈ 1.37       (should be 1.00)
```

Particles spiral outward: swirls fling themselves apart and gain energy from nowhere.

### Runge–Kutta 2 (midpoint)

Look ahead half a step, then use the velocity *there*:

```
v1    = u(x_p)                      // velocity here
x_mid = x_p + ½Δt · v1              // half-step probe
v2    = u(x_mid)                    // velocity at the midpoint
x_p  ← x_p + Δt · v2                // full step with the better velocity
```

Same rotation test: the radius grows by `√(1 + Δt⁴/4) ≈ 1.000025` per step, **about 1.0008 after a full revolution**: 450× less error for one extra velocity lookup. RK3 is a common upgrade with even less drift; RK2 is a good start.

`u(x)` is the grid interpolation from lesson 2. That's why the grid velocity must be valid even slightly outside the water: a particle near the surface may probe into an AIR cell. **Velocity extrapolation** (lesson 5, §5.7) fills those cells.

### Keeping particles out of walls

After moving, a particle may end up inside a SOLID cell or outside the box. Push it back:

- **Box walls:** clamp the position to stay at least a small margin (say `0.01·Δx`) inside.
- **Obstacles with an SDF** (fleng's objects, later): if `φ_solid(x) < 0`, move the particle along the SDF's gradient by `−φ_solid(x)` plus the margin.

## 4.4 Choosing Δt: the CFL condition

**CFL** (Courant–Friedrichs–Lewy): no particle should move more than about one cell per step.

```
Δt ≤ C · Δx / u_max            C ≈ 1 (the "CFL number")
```

**Why:**

- Interpolation and RK2 assume the velocity changes little over one step. Crossing several cells breaks that.
- A fast particle could jump right through a thin wall.
- The pressure solve only "sees" the flow on the grid; particles skipping cells lose that information.

`u_max` is the largest particle speed right now. Because gravity accelerates things *during* the step, a common safety term (from Bridson's book) is:

```
u_max = max_p |v_p| + √(5 · Δx · |g|)
```

### Frames vs. substeps

Rendering wants a frame every 1/60 s. The simulation takes as many CFL-sized **substeps** as needed to get there:

```
t = 0
while t < frame_time:
    dt = cfl_dt()
    remaining = frame_time − t
    if dt >= remaining:        dt = remaining          // land exactly on the frame
    else if 2·dt > remaining:  dt = remaining / 2      // avoid a tiny last step
    step(dt)
    t += dt
```

## 4.5 What this means for cost

A 5 cm blob dropped from 20 cm hits the pool at `√(2·g·h) ≈ 2 m/s`.

Using `u_max = 2 m/s` (the gravity safety term adds a bit more):

| Grid (30 cm tank) | Δx | Max Δt (C = 1) | Substeps per 60 Hz frame |
|---|---|---|---|
| 64³ | 4.7 mm | 2.4 ms | ~7 |
| 128³ | 2.3 mm | 1.2 ms | ~14 |
| 256³ | 1.2 mm | 0.6 ms | ~28 |

**Halving `Δx` costs 16×:** 8× more cells, and 2× more steps because of CFL. That's why the plan has "slow" and "bake" modes, and why doubling resolution is such a big decision.

## 4.6 Check yourself

1. Why does gravity go before the pressure solve, not after?
2. A particle moves at 3 m/s on a grid with `Δx = 5 mm`. What's the largest Δt at CFL number 1 (ignoring the gravity safety term)?
3. Forward Euler makes rotating particles spiral outward. Does the error go away if you just take smaller steps?
4. Why must the grid velocity be defined in AIR cells near the surface?

<details>
<summary>Answers</summary>

1. The pressure solve must cancel whatever part of gravity would compress the water. After it, the velocity must already include gravity, or the water would be compressed at the end of every step.
2. `0.005 / 3 ≈ 1.7 ms`.
3. It shrinks (per revolution, the radius error is roughly proportional to Δt), but it never disappears and it always adds energy. RK2 has much smaller error at the same Δt.
4. RK2 probes the velocity at a midpoint, and G2P samples grid velocities around each particle. Near the surface, those lookups land in AIR cells.

</details>
