# Lesson 3: particles ↔ grid (PIC, FLIP, APIC)

Part of milestone 1 in [the water plan](../water-plan.md). Previous: [lesson 2, the MAC grid](02-mac-grid.md). Next: [lesson 4, forces, advection, CFL](04-forces-advection-cfl.md).

Every time step, velocity makes a round trip: particles → grid (**P2G**, step 2 in lesson 1), the grid does gravity and pressure, then grid → particles (**G2P**, step 7). How that round trip is done decides whether the water looks alive or like syrup.

## 3.1 What a particle stores

| Field | Meaning |
|---|---|
| `x_p` | Position (3 floats) |
| `v_p` | Velocity (3 floats) |
| `C_p` | APIC only: a 3×3 matrix describing how velocity *varies around* the particle (§3.5) |
| `m_p` | Mass. All particles are equal: with 8 particles per cell, `m_p = ρ·Δx³ / 8` |

## 3.2 Weights: which grid samples a particle talks to

A particle only interacts with grid samples near it, through **weights** `w_ip` (grid sample `i`, particle `p`). The weights come from a **kernel**, a bump function of the distance, measured in cells. Weights over all samples always sum to 1.

**Linear ("tent") kernel:** `N(r) = 1 − |r|` for `|r| < 1`, else 0. Two samples per axis, so 2³ = 8 in 3D. This is exactly trilinear interpolation from lesson 2.

**Quadratic B-spline:** three samples per axis, 3³ = 27 in 3D. Smoother, and the standard choice for APIC and MPM:

```
N(r) = 3/4 − r²              for |r| < 1/2
     = 1/2 · (3/2 − |r|)²     for 1/2 ≤ |r| < 3/2
     = 0                      otherwise
```

In code, for a particle at fractional grid coordinate `f` along one axis (in the component's own index space, with the lesson 2 half-cell offsets):

```
base = floor(f − 0.5)          // leftmost of the 3 samples
t    = f − base                // in [0.5, 1.5)
w0 = 0.5 · (1.5 − t)²
w1 = 0.75 − (t − 1)²
w2 = 0.5 · (t − 0.5)²
```

The 3D weight is the product of the three 1D weights: `w = wx[a] · wy[b] · wz[c]`.

**The MAC grid twist:** `u`, `v` and `w` live on different grids, so each velocity component does its own transfer, with its own sample positions and weights. It's the same code three times, with different offsets.

## 3.3 PIC: plain averaging

**P2G:** each grid sample gets the mass-weighted average of nearby particle velocities:

```
u_i = Σ_p w_ip · m_p · v_p  /  Σ_p w_ip · m_p
```

The denominator is the **grid mass** `m_i`. Samples with zero mass have no nearby particles; they're not part of the fluid.

**G2P:** each particle takes the interpolated grid velocity:

```
v_p = Σ_i w_ip · u_i
```

### Why PIC turns water into syrup

A 1D example with `Δx = 1`, the linear kernel, two grid nodes at `x = 0` and `x = 1`, and two particles sitting in the stretching flow `v = x`:

```
particle 1:  x = 0.25,  v = 0.25
particle 2:  x = 0.75,  v = 0.75
```

P2G, with weights `(0.75, 0.25)` for particle 1 and `(0.25, 0.75)` for particle 2:

```
u_0 = 0.75·0.25 + 0.25·0.75 = 0.375
u_1 = 0.25·0.25 + 0.75·0.75 = 0.625
```

G2P:

```
v_1 = 0.75·0.375 + 0.25·0.625 = 0.4375     (was 0.25)
v_2 = 0.25·0.375 + 0.75·0.625 = 0.5625     (was 0.75)
```

The velocity *difference* between the particles dropped from 0.5 to 0.125. **75% of the stretching motion vanished in one round trip**, and this happens every step. Rotations and swirls die the same way. It's pure numerical viscosity.

The root cause: there are many more particle velocities (8 per cell × 3 components) than grid velocities (3 per cell). Squeezing through the grid and back throws information away.

## 3.4 FLIP: transfer only the change

**FLIP** keeps each particle's own velocity and only adds what the grid *changed* this step:

```
v_p ← v_p + Σ_i w_ip · (u_i_new − u_i_old)
```

where `u_old` is the grid right after P2G and `u_new` is after gravity and pressure. In the example above, nothing changed on the grid, so both particles keep 0.25 and 0.75 exactly.

**The problem:** motion the grid can't see is never corrected. Suppose neighboring particles in one cell have velocities `+1, −1, +1, −1`. The grid averages that to 0, the pressure solve sees nothing, and FLIP adds 0 back: the jitter persists forever and grows. FLIP water looks lively but noisy and speckled.

The traditional fix is a blend, `v = 0.97·FLIP + 0.03·PIC`: a little PIC damping to kill the noise. It works, but the blend factor is a hand-tuned knob.

## 3.5 APIC: carry the local velocity field

**APIC** (Affine Particle-In-Cell, Jiang et al. 2015) gives each particle a **local linear velocity field** instead of a single velocity:

```
velocity near particle p:   v(x) ≈ v_p + C_p · (x − x_p)
```

`C_p` is a 3×3 matrix, essentially the velocity gradient around the particle. It describes rotation, shear, and stretching. A spinning blob of particles has a `C` that encodes the spin.

**P2G:** each particle contributes the velocity of *its local field at the grid sample's position*:

```
m_i · u_i = Σ_p w_ip · m_p · ( v_p + C_p · (x_i − x_p) )
m_i       = Σ_p w_ip · m_p
```

**G2P:** velocity as in PIC, plus a new `C_p` rebuilt from the grid:

```
v_p = Σ_i w_ip · u_i
C_p = (4 / Δx²) · Σ_i w_ip · u_i · (x_i − x_p)ᵀ          (quadratic B-spline)
C_p = Σ_i u_i · (∇w_ip)ᵀ                                 (linear kernel)
```

On the MAC grid, each component `a ∈ {x, y, z}` gets its own row of `C` from its own grid, so particles effectively store three vectors `c_x, c_y, c_z`.

### The same example, with APIC

The particles carry `C = 1` (the gradient of `v = x`). P2G:

```
node 0:  particle 1 gives 0.25 + 1·(0 − 0.25) = 0
         particle 2 gives 0.75 + 1·(0 − 0.75) = 0          → u_0 = 0
node 1:  particle 1 gives 0.25 + 1·(1 − 0.25) = 1
         particle 2 gives 0.75 + 1·(1 − 0.75) = 1          → u_1 = 1
```

The grid now holds the exact field `v = x`. G2P gives back `v_1 = 0.75·0 + 0.25·1 = 0.25` and `v_2 = 0.25·0 + 0.75·1 = 0.75`: **exactly the original velocities.** And the linear-kernel formula rebuilds `C = (−1)·0 + (+1)·1 = 1`.

### Why APIC is the default choice

- **Uniform and linear motion survive the round trip exactly** (what we just saw).
- **Angular momentum is conserved exactly** by the transfers, so swirls don't decay artificially.
- **No FLIP noise:** anything the grid can't represent is filtered out, like PIC. But what the grid *can* represent (including rotation and shear) isn't lost.
- **No tuning knob.**

## 3.6 Parallel transfers

- **G2P is a gather:** each particle reads nearby grid samples. Every particle is independent, so it's trivially parallel.
- **P2G is a scatter:** many particles *add* into the same grid sample. Two threads writing the same sample at once is a race condition, exactly like FEM assembly. Fixes:
  - **Atomic adds:** simple, slow-ish on CPU.
  - **Coloring:** split space into blocks and process blocks that can't overlap in parallel, then the next color.
  - **Sort particles by cell, then gather:** each grid sample loops over particles in nearby cells. No writes conflict. This is also what makes the CUDA version fast.

The code started with the sorted gather, which is deterministic (same result every run). Profiling showed each face sample rescanning 36 cells of particles, so it switched to a scatter made race-free by coloring: blocks of 4×4 grid rows run in 4 passes, and blocks running at the same time are too far apart to touch the same samples. The order of writes to each sample is still fixed, so it stays deterministic (`Particles.forEachBlockColored` in [sim/](../../sim/)).

## 3.7 Check yourself

1. With 8 particles per cell and `ρ = 1000 kg/m³`, `Δx = 0.01 m`, what's `m_p`?
2. In the PIC example, what happens to the particle velocities after many round trips?
3. Why doesn't FLIP damp the `+1, −1, +1, −1` jitter?
4. A blob of particles rotates rigidly. Which method keeps it spinning best, and why?

<details>
<summary>Answers</summary>

1. `1000 · 0.01³ / 8 = 1.25·10⁻⁴ kg` (0.125 g).
2. They converge toward their common average, 0.5. The stretching motion is erased entirely.
3. The grid averages it to zero, so the grid change is zero, and FLIP adds zero back.
4. APIC: `C_p` stores the rotation, P2G writes it onto the grid, G2P reads it back, and angular momentum is conserved by the transfer.

</details>
