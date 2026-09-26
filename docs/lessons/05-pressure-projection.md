# Lesson 5: pressure projection

Part of milestone 1 in [the water plan](../water-plan.md). Previous: [lesson 4, forces, advection, CFL](04-forces-advection-cfl.md). Next: [lesson 6, solving the pressure equation](06-pressure-solver.md).

This is the heart of the solver: step 6 of the time step (lesson 1). After gravity, the grid velocity `u*` compresses the water in places. Projection finds the pressure that removes exactly that compression and nothing else.

## 5.1 What pressure is here

In this solver, pressure is not an input and not a thermodynamic quantity computed from temperature and density. It's **whatever push is needed to keep the water incompressible**. Mathematically it's a Lagrange multiplier for the constraint `∇·u = 0`. Physically it's the fluid's reaction: squeeze water and it pushes back exactly as hard as needed.

## 5.2 Deriving the pressure equation

We want new velocities that differ from `u*` only by a pressure push:

```
u_new = u* − (Δt/ρ) · ∇p           (the pressure term of Navier–Stokes, applied for Δt)
```

and that are divergence-free:

```
∇·u_new = 0
```

Take the divergence of the first line and set it to zero:

```
∇·u* − (Δt/ρ) · ∇²p = 0      →      ∇²p = (ρ/Δt) · ∇·u*
```

This is a **Poisson equation**: the Laplacian of `p` is known (from how much `u*` compresses each cell), and we solve for `p`. Then plug `p` back into the first line.

## 5.3 On the MAC grid

Everything from lesson 2 now fits together.

**The update on each face:** for the face between cells `L` (left) and `R` (right):

```
u_face ← u*_face − (Δt / ρ) · (p_R − p_L) / Δx
```

**The equation for each FLUID cell `c`:** write the new divergence of `c` using its six faces, substitute the update above, and set it to zero. After rearranging:

```
(Δt / (ρ Δx²)) · ( N_c · p_c − Σ_n p_n ) = − div*_c
```

- `div*_c` is the divergence of `u*` in cell `c` (lesson 2's formula).
- `Σ_n` runs over the neighbors `n` that are FLUID.
- `N_c` is the number of neighbors that are **not SOLID**.

Collecting this for every FLUID cell gives a linear system `A · p = b`, one unknown per FLUID cell. With the constant `Δt/(ρΔx²)` moved into `b`:

- **Diagonal** of row `c`: `N_c`.
- **Off-diagonals:** `−1` for each FLUID neighbor.
- **Right-hand side:** `b_c = −(ρ Δx² / Δt) · div*_c`.

This is the **7-point Laplacian stencil**: each cell talks to itself and its 6 neighbors. It's never stored as a matrix. `A · x` is computed on the fly by looking at the neighbors (matrix-free).

## 5.4 Boundary conditions

The neighbor's label decides how it enters the stencil:

| Neighbor | Condition | In the stencil |
|---|---|---|
| **FLUID** | Unknown pressure | Counts in `N_c`, and `−1` off-diagonal |
| **AIR** | `p = 0` (free surface, **Dirichlet** condition) | Counts in `N_c`, but no off-diagonal: its `p` is known to be 0 |
| **SOLID** | No flow through the wall: the face velocity is fixed to the wall's velocity (**Neumann** condition) | Doesn't count at all. The face isn't updated by pressure, and `div*_c` uses the wall's velocity on that face |

Examples:

- A cell deep inside the water: 6 FLUID neighbors → diagonal 6, six `−1`s.
- A cell on the tank floor with AIR above: 4 FLUID sides, SOLID below (ignored), AIR above (diagonal only) → diagonal 5, four `−1`s.

**Moving obstacles:** a SOLID face gets the obstacle's velocity instead of 0, and the water gets pushed out of the way automatically.

**The singular case:** if a blob of FLUID touches no AIR (a completely full, closed tank), pressure is only defined up to a constant. `A` is singular and the solver can drift. Fix it by removing the average of `p` (and of `b`) each iteration. With a free surface this rarely happens.

## 5.5 Worked example: the still water column

A vertical column of three FLUID cells, SOLID floor below, AIR above, everything at rest. Gravity (lesson 4) sets every face touching fluid to `v* = −gΔt` (downward), except the floor face, which is fixed at 0:

```
        AIR          p = 0
  ───── f3 ─────     v* = −gΔt
        c2
  ───── f2 ─────     v* = −gΔt
        c1
  ───── f1 ─────     v* = −gΔt
        c0
  ───── f0 ─────     v  = 0 (floor)
       SOLID
```

Divergences (outflow up minus inflow from below, over `Δx`): `div*_c0 = (−gΔt − 0)/Δx = −gΔt/Δx`, and 0 for `c1` and `c2` (same velocity in and out).

With `s = Δt/(ρΔx²)`, the three equations (1D, so only up and down neighbors) are:

```
c0:  s · (1·p0 − p1)        = gΔt/Δx        SOLID below doesn't count, so N = 1
c1:  s · (2·p1 − p0 − p2)   = 0
c2:  s · (2·p2 − p1)        = 0             AIR above: counts in N, p = 0
```

From `c2`: `p1 = 2·p2`. From `c1`: `p0 = 3·p2`. From `c0`: `s·p2 = gΔt/Δx`, so:

```
p2 = ρ·g·Δx,    p1 = 2·ρ·g·Δx,    p0 = 3·ρ·g·Δx
```

**That's hydrostatic pressure, ρ·g·depth,** found by the solver without being told about it. Check the new face velocities: at `f1`, `−gΔt − (Δt/ρ)·(p1 − p0)/Δx = −gΔt + gΔt = 0`. The same happens at `f2` and `f3`. **The water stays perfectly still.**

One detail: depth here is measured from the AIR cell's *center*, one cell above `c2`'s center. The real surface is at `c2`'s top face, half a cell lower. The pressure is off by `½·ρ·g·Δx`. The ghost fluid method fixes that.

## 5.6 Ghost fluid: putting the surface in the right place

Treating a whole AIR cell as `p = 0` at its center puts the surface up to half a cell off. With a signed distance `φ` to the surface (lesson 7; negative inside water), we know where it actually crosses between a FLUID cell `c` and its AIR neighbor `a`:

```
θ = φ_c / (φ_c − φ_a)          fraction of the way from c's center to a's center, in (0, 1)
```

The **ghost fluid method** (Gibou et al. 2002) replaces the AIR neighbor's contribution of `1` to the diagonal with `1/θ`. The closer the surface is to the cell center, the stronger it pulls the pressure toward 0. Clamp `θ` to at least about 0.01 so the diagonal can't blow up.

It's a small change with a big visual payoff: the surface stops "stair-stepping" with the grid, and small ripples and waves behave correctly.

## 5.7 After the solve

1. **Update face velocities** with the pressure gradient, only on faces between FLUID–FLUID or FLUID–AIR cells. Faces touching SOLID keep the wall's velocity.
2. **Extrapolate velocity into the air.** Faces between two AIR cells have no meaningful velocity, but G2P and RK2 (lesson 4) will sample there. Fill them layer by layer, outward from the fluid: each unknown face takes the average of its known neighbors. 2–4 layers is enough, since particles move at most about a cell per step.
3. **Sanity check:** the maximum `|div|` over FLUID cells should now be close to 0 (limited by how accurately the linear system was solved, lesson 6). Log it every step; it's the first thing to look at when something goes wrong.

## 5.8 Check yourself

1. A FLUID cell has 3 FLUID neighbors, 2 AIR neighbors, and 1 SOLID neighbor. What's its diagonal entry, and how many `−1`s are in its row?
2. In the water column example, what would the pressure be in a 10-cell-deep column, at the bottom cell?
3. Why doesn't a SOLID neighbor count in the diagonal?
4. The surface lies 0.2 of the way from a FLUID cell's center to its AIR neighbor's center. What does the ghost fluid method use for that neighbor's diagonal contribution?

<details>
<summary>Answers</summary>

1. Diagonal 5 (everything but SOLID), and 3 `−1`s (FLUID neighbors only).
2. `10·ρ·g·Δx`: depth measured from the AIR cell center, 10 cells up.
3. The face between them is fixed to the wall's velocity; pressure doesn't change it. That face drops out of the equation entirely.
4. `1/θ = 1/0.2 = 5`, instead of 1.

</details>
