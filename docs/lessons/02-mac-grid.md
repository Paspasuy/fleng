# Lesson 2: the MAC grid

Part of milestone 1 in [the water plan](../water-plan.md). Previous: [lesson 1, one time step](01-one-time-step.md). Next: [lesson 3, particles ↔ grid](03-particles-and-grid.md).

The grid is APIC's scratchpad: gravity, walls, and pressure all happen on it (steps 3–6 of the time step in lesson 1). This lesson is about *where* each number lives on the grid, and why that choice matters so much.

## 2.1 The basic grid

Split the simulation box into `nx × ny × nz` cubic cells, each `Δx` wide. Cell `(i, j, k)` spans

```
x ∈ [i·Δx, (i+1)·Δx],   y ∈ [j·Δx, (j+1)·Δx],   z ∈ [k·Δx, (k+1)·Δx]
```

and its center is at `((i+½)Δx, (j+½)Δx, (k+½)Δx)`.

We use SI units throughout: meters, seconds, kg/m³. Example: a 30 cm tank with 64 cells per side has `Δx ≈ 4.7 mm`. Anything smaller than 2–3 cells can't be represented. A 5 cm blob (about 10 cells across) is fine; a 2 mm raindrop is smaller than one cell and simply can't exist at this resolution.

## 2.2 The obvious layout, and why it fails

The obvious choice: store velocity `(u, v, w)` and pressure `p` all at cell centers (a **collocated** grid). To get the pressure force you need the derivative `∂p/∂x`, and the natural centered estimate at cell `i` uses its two neighbors:

```
∂p/∂x at cell i  ≈  (p[i+1] − p[i−1]) / (2Δx)
```

It never looks at `p[i]` itself. Now take a "checkerboard" pressure:

```
p:        +1   −1   +1   −1   +1
∂p/∂x:          0    0    0          ← (+1 − +1) / 2Δx = 0 everywhere
```

A wildly oscillating pressure produces **zero force**. The solver can't see it, so nothing ever corrects it, and it grows into garbage. The same blind spot hits the divergence `∇·u`. This is the classic **checkerboard instability** of collocated grids.

## 2.3 The fix: staggering (MAC grid)

The **MAC grid** (Marker-And-Cell, Harlow & Welch 1965) puts each quantity where it's naturally used:

- **Pressure `p`:** at cell **centers**.
- **`u`** (x-velocity): at the centers of the cell faces **perpendicular to x** (left and right faces).
- **`v`** (y-velocity): on faces perpendicular to y (bottom and top).
- **`w`** (z-velocity): on faces perpendicular to z (front and back).

In 2D, one cell looks like this:

```
              v[i][j+1]
         +-------↑-------+
         |               |
 u[i][j] →    p[i][j]    → u[i+1][j]
         |               |
         +-------↑-------+
              v[i][j]
```

**Indexing convention:** `u[i][j][k]` sits on the *left* face of cell `(i, j, k)`, between cells `i−1` and `i`, at position `(i·Δx, (j+½)Δx, (k+½)Δx)`. Likewise `v[i][j][k]` is on the bottom face and `w[i][j][k]` on the back face.

A row of `nx` cells has `nx + 1` faces, so the array sizes are:

| Array | Size |
|---|---|
| `p` | `nx × ny × nz` |
| `u` | `(nx+1) × ny × nz` |
| `v` | `nx × (ny+1) × nz` |
| `w` | `nx × ny × (nz+1)` |

### Why this is exactly right

**A face velocity is a flux.** `u[i+1][j][k]` times the face area is how much water per second crosses the right face of cell `(i, j, k)`. That's the finite-volume view from the [water overview](../water-simulation-overview.md): each cell balances what flows in and out.

**Divergence** of a cell is its net outflow, using only its own six faces, one cell apart:

```
div[i][j][k] = ( u[i+1][j][k] − u[i][j][k]
               + v[i][j+1][k] − v[i][j][k]
               + w[i][j][k+1] − w[i][j][k] ) / Δx
```

**Pressure gradient** at a face uses the two cells on either side, one cell apart:

```
(∂p/∂x) at face u[i][j][k] = (p[i][j][k] − p[i−1][j][k]) / Δx
```

That's exactly where `u` lives, so the pressure force lands directly on the velocity it corrects. Redo the checkerboard: `(−1 − (+1)) / Δx = −2/Δx`, a large force. The solver sees it and removes it. Both derivatives now span one cell instead of two, which also makes them twice as accurate.

## 2.4 Worked example: reading divergence

A 2D cell with `Δx = 0.1 m`:

```
                v_top = 0
          +---------↑---------+
  u_left  |                   |  u_right
  = 2 m/s →                   → = 1 m/s
          +---------↑---------+
                v_bottom = 0
```

```
div = (u_right − u_left + v_top − v_bottom) / Δx = (1 − 2 + 0 − 0) / 0.1 = −10 1/s
```

Negative divergence: more water enters than leaves, so the cell is being **compressed**. Water can't compress, so the pressure solve (lesson 5) will raise this cell's pressure until it pushes enough water out to make `div = 0`. For example, it could slow `u_left` and speed up `u_right` until both are 1.5 m/s.

If instead `u_left = u_right = 2`, then `div = 0`: water just passes through, and no correction is needed.

## 2.5 Velocity at any point: interpolation

Particles sit anywhere, not on faces. Steps 7 and 8 of the time step need the full velocity vector at an arbitrary point `x`. Each component is interpolated **separately, from its own grid**, because each one lives at different positions.

**1D linear interpolation:** between samples `a` (at 0) and `b` (at 1), at fraction `t`, the value is `a + t·(b − a)`.

**3D trilinear interpolation:** do that along x for 4 pairs, then along y for 2, then along z once, using the 8 surrounding samples.

For `u`, which lives at integer x and half-integer y and z (in units of `Δx`), convert the world position to "u-grid index space" first:

```
sample_u(x, y, z):
    fx = x / Δx                 // u lives at i·Δx in x
    fy = y / Δx − 0.5           // but at (j+½)·Δx in y
    fz = z / Δx − 0.5           // and (k+½)·Δx in z
    i = floor(fx);  tx = fx − i
    j = floor(fy);  ty = fy − j
    k = floor(fz);  tz = fz − k
    // 8 neighbors u[i..i+1][j..j+1][k..k+1], blended with weights from tx, ty, tz
    return trilinear(u, i, j, k, tx, ty, tz)
```

`sample_v` shifts x and z by −0.5 instead, and `sample_w` shifts x and y. Getting these half-cell offsets wrong is the most common MAC grid bug: everything still runs, but the water drifts or feels subtly wrong.

A useful special case: the velocity at a cell *center* is the average of its two faces, e.g. `u_center = (u[i] + u[i+1]) / 2`.

## 2.6 Cell labels: FLUID, AIR, SOLID

Each step (step 3 in lesson 1), every cell gets a label:

| Label | Meaning | What the solver does there |
|---|---|---|
| **FLUID** | Contains at least one particle | Pressure is an unknown to solve for |
| **AIR** | Empty | Pressure = 0 (atmospheric reference): the **free surface** condition |
| **SOLID** | Tank wall or obstacle | No flow through it: the face velocity equals the wall's velocity (0 for a static wall) |

- **Faces follow from cells:** a face velocity is an unknown only if it touches a FLUID cell and neither side is SOLID. Faces against SOLID are fixed.
- **Tank walls:** surround the domain with one layer of SOLID cells, which makes the box closed.
- **Obstacles later:** fleng's cuboids and spheres already have signed distance functions, so a cell becomes SOLID when the SDF at its center is negative.

Typically each FLUID cell starts with **8 particles** (2×2×2, randomly jittered). The FLUID/AIR label is a coarse, all-or-nothing picture of where the surface is. The pressure solve can refine it with the exact surface position (the "ghost fluid" method), which comes up in lessons 5 and 7.

## 2.7 Memory layout

Store each field as a flat 1D array (structure-of-arrays), with x varying fastest:

```
index(i, j, k) = i + nx · (j + ny · k)             // for p and labels
index_u(i, j, k) = i + (nx+1) · (j + ny · k)       // u has nx+1 entries along x
```

Neighbors are then fixed offsets: `+1` in x, `+nx` in y, `+nx·ny` in z. x-neighbors are next to each other in memory, z-neighbors are far apart. That matters for cache performance later.

Rough memory cost with 4-byte floats, for `u, v, w, p` plus labels:

| Grid | Cells | Memory |
|---|---|---|
| 64³ | 262 k | ~5 MB |
| 128³ | 2.1 M | ~35 MB |
| 256³ | 16.8 M | ~290 MB |

The pressure solver adds a few more arrays of the same size (lesson 6). Even 256³ fits comfortably in the M4's 16 GB; the limit is time, not memory.

## 2.8 Check yourself

1. For a `10 × 20 × 30` grid, what size is the `w` array?
2. Where in space does `u[3][5][7]` live?
3. A cell has `u_left = 2`, `u_right = 1`, all `v` and `w` zero, and `Δx = 0.1`. Is it being compressed or expanded?
4. Why can't the collocated grid see a checkerboard pressure?

<details>
<summary>Answers</summary>

1. `10 × 20 × 31`: one extra along z.
2. At `(3Δx, 5.5Δx, 7.5Δx)`: integer in x (it's on an x-face), half-integer in y and z.
3. Compressed: `div = (1 − 2)/0.1 = −10 1/s`. More flows in than out.
4. Its centered difference at cell `i` uses only `p[i−1]` and `p[i+1]`, which are equal in a checkerboard, so the computed gradient is 0.

</details>
