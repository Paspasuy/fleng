# Lesson 1: one time step of water

Part of milestone 1 in [the water plan](../water-plan.md). Next: [lesson 2, the MAC grid](02-mac-grid.md).

## 1.1 The equation again, in "per-mass" form

Divide the momentum equation by density ρ. Leave out surface tension for now; APIC ignores it:

```
Du/Dt = −(1/ρ)∇p + ν∇²u + g          ν = μ/ρ  ("kinematic viscosity")
∇·u  = 0
```

`Du/Dt` is the **material derivative**: the acceleration of one specific blob of water as you *follow it*. Written from a fixed grid point's point of view, it expands to `∂u/∂t + (u·∇)u`:

- `∂u/∂t`: how velocity changes at a fixed point in space.
- `(u·∇)u`: extra change because *different* water keeps arriving at that point.

**Key insight:** if your unknowns are particles that *move with the water*, you're already following the blob. The awkward advection term `(u·∇)u` disappears: moving the particles *is* advection. What's left is plain Newton's law per particle: acceleration = pressure force + friction + gravity.

## 1.2 Why use both particles and a grid

| Job | Particles are good at it? | Grid good at it? |
|---|---|---|
| Carrying water around (advection) | ✅ just move them, nothing gets blurred | ❌ values smear out (see below) |
| Knowing where water is (splashes, drops) | ✅ particles are the water | ⚠️ needs interface tracking |
| Pressure: "who pushes on whom" | ❌ neighbors are irregular, hard to set up | ✅ each cell has exactly 6 neighbors, a clean linear system |
| Derivatives (∇p, ∇·u) | ❌ messy | ✅ simple differences between neighbors |

**Why grids smear.** Take a 1D row of cells holding a sharp "dye" pulse, with the flow moving it half a cell per step. A grid can only store values *at cells*, so each step it has to interpolate between neighbors:

```
step 0:  0     0     1     0     0
step 1:  0     0    .5    .5     0
step 2:  0     0   .25   .50   .25
step 3:  0     0  .125  .375  .375  .125
```

The pulse spreads and flattens, and it never recovers. This is **numerical diffusion**: it looks like extra viscosity that doesn't exist physically. Water turns into syrup and small splashes die. A particle carrying "1" just moves half a cell each step and stays sharp forever.

So APIC splits the work: **particles carry the water and its velocity; the grid is a temporary scratchpad for forces and pressure.**

## 1.3 Operator splitting: one term at a time

Solving all terms of the equation together is hard. **Operator splitting** applies them *one after another*, each as if the others didn't exist:

```
u  →  [advect]  →  [+ gravity]  →  [+ viscosity]  →  [pressure: remove compression]  →  u_new
```

Each sub-step is simple. The price is a small error that shrinks as Δt shrinks, and it's the standard approach in almost every fluid solver.

## 1.4 The APIC time step

Each step turns the particles' state into the next state, using the grid in between:

```
1. dt ← choose from CFL          (no particle may move > ~1 cell)          lesson 4
2. P2G: particles → grid          (splat particle velocities onto grid)     lesson 3
3. mark cells: FLUID / AIR / SOLID (which cells contain particles)          lesson 2
4. grid velocity += g · dt         (gravity)                                lesson 4
5. solid walls: velocity into a wall ← 0                                    lesson 5
6. PRESSURE PROJECTION            (make ∇·u = 0 on the grid)                lessons 5–6
7. G2P: grid → particles          (particles take back their velocity + a small
                                   "local rotation/stretch" matrix C)       lesson 3
8. advect: move particles through the grid velocity field for dt           lesson 4
```

Mapping back to the equation:

| Term | Where it happens |
|---|---|
| `Du/Dt` (following the blob) | Step 8: particles move |
| `g` | Step 4 |
| `ν∇²u` | Skipped for now: water's viscosity is tiny at these scales. It's an optional extra step, added later |
| `−(1/ρ)∇p` and `∇·u = 0` | Step 6: one step does both. The pressure is exactly what's needed to cancel compression |

## 1.5 What APIC's "A" adds

In plain **PIC** (Particle-In-Cell), steps 2 and 7 average velocities between particles and grid. Averaging loses detail, so the water looks viscous and swirls die out. **FLIP** transfers only the *change* in velocity: lively, but noisy. **APIC** (Affine PIC) gives each particle a small 3×3 matrix `C` describing how velocity varies *around* it (rotation, shear, stretch), so almost nothing is lost in the round trip, without FLIP's noise. That's lesson 3.

## 1.6 Try it in your head

Picture a cube of water at rest in a tank, then step 4 adds gravity: every cell's velocity becomes "downward by g·dt". The bottom row of water tries to move *into the floor*, and upper cells move down into the ones below: the water is being compressed. Step 6 finds the pressure that pushes back exactly enough to cancel that. The water stays still, and the pressure it found grows with depth: **p = ρ·g·depth**, hydrostatic pressure, discovered automatically. That's one of the lesson 8 tests.
