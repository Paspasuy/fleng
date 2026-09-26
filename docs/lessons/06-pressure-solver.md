# Lesson 6: solving the pressure equation (CG, then multigrid)

Part of milestone 1 in [the water plan](../water-plan.md). Previous: [lesson 5, pressure projection](05-pressure-projection.md). Next: [lesson 7, particles → water surface](07-surface-reconstruction.md).

Lesson 5 turned incompressibility into `A · p = b`: one unknown per FLUID cell, 7-point stencil, symmetric and positive definite. At 128³ that's up to 2 million unknowns, solved every substep. This is usually the most expensive part of the whole simulation, so the method matters a lot.

## 6.1 Why the simple approaches fail

**Direct solvers** (Gaussian elimination / Cholesky, see the [FEM overview](../fem-overview.md) §4.6) create **fill-in**: zeros in `A` become non-zeros during factoring. For a 3D grid, memory and time explode. And the water shape changes every step, so the factorization can't be reused.

**Jacobi iteration** is the simplest iterative method. For each cell, solve its own equation as if the neighbors were right:

```
p_c ← ( b_c + Σ_(FLUID n) p_n ) / N_c
```

It's trivially parallel. But each iteration moves information only one cell. A pressure change at the bottom of a 128-cell-deep tank needs at least 128 iterations just to *reach* the surface, and in practice convergence takes on the order of `N²` iterations for `N` cells across: tens of thousands at 128³.

Jacobi isn't useless, though. It's excellent at killing **zigzag (high-frequency) errors**, where neighboring cells are wrong in opposite directions, because averaging neighbors cancels them in a few iterations. It's terrible at **smooth errors**, where a whole region is wrong by roughly the same amount, because averaging a smooth error changes almost nothing. Multigrid (§6.4) is built on exactly this observation.

## 6.2 Conjugate Gradient (CG)

Solving `A·p = b` for a symmetric positive definite `A` is equivalent to finding the lowest point of the bowl-shaped "energy" `E(p) = ½·pᵀAp − bᵀp`. **Steepest descent** walks downhill, but zigzags in long narrow valleys. **CG** chooses each new direction so it doesn't undo progress made in earlier directions (the directions are "A-conjugate"). In exact arithmetic it reaches the answer in at most `n` steps, and in practice it gets close much sooner.

```
r = b − A·p                 // residual: how wrong we are
z = M⁻¹·r                   // preconditioning (§6.3); plain CG uses z = r
d = z
ρ = r·z
loop:
    q = A·d                  // one stencil application
    α = ρ / (d·q)            // how far to go along d
    p += α·d
    r −= α·q
    if max|r| < tolerance: stop
    z = M⁻¹·r
    ρ_new = r·z
    d = z + (ρ_new / ρ)·d    // new direction, conjugate to the previous ones
    ρ = ρ_new
```

**Cost per iteration:** one stencil application (`A·d`), two dot products, and three vector updates. All of it is streaming through memory, so it's memory-bandwidth bound, like everything in the [FEM overview](../fem-overview.md) §4.7.

**Iteration count** grows with the square root of the **condition number** of `A`. For this Laplacian that ends up proportional to `N`, the number of cells across. At 128³ that's hundreds of iterations.

**Stopping rule:** stop when the largest remaining residual is small relative to the largest entry of `b` (for example, `10⁻⁶` of it). The leftover residual is directly the leftover divergence, so the tolerance decides how compressible the water can look. Too loose and the water slowly loses volume.

**Warm start:** use the previous step's pressure as the initial guess. Pressure changes slowly between substeps, so this saves iterations for free.

## 6.3 Preconditioning

Instead of `A·p = b`, CG can solve the equivalent `M⁻¹·A·p = M⁻¹·b`, where `M` approximates `A` but is cheap to invert. A good `M` makes the problem "rounder" and cuts iterations dramatically. That's the `z = M⁻¹·r` line above.

| Preconditioner | Idea | Verdict |
|---|---|---|
| **Jacobi** | `M` = the diagonal of `A` | Almost free, but helps little here (the diagonal is nearly constant) |
| **MIC(0)** (Modified Incomplete Cholesky) | An approximate factorization that skips all fill-in | The classic choice in Bridson's book: a solid improvement, but inherently sequential, bad for many threads and GPUs |
| **Multigrid V-cycle** | One multigrid pass (below) serves as `M⁻¹` | The modern choice: iteration count nearly independent of resolution, and fully parallel |

## 6.4 Multigrid

**Idea:** smooth errors are hard to fix on a fine grid, but on a grid 2× coarser, the same error looks twice as zigzaggy, which is exactly what smoothing is good at. So fix each kind of error on the grid where it's easy.

**Two-grid cycle:**

1. **Pre-smooth:** a few Jacobi-style sweeps on the fine grid. Zigzag errors die, smooth ones remain.
2. **Compute the residual** `r = b − A·p`: what's still wrong.
3. **Restrict:** average `r` down onto a grid with 2× larger cells (8 fine cells → 1 coarse cell).
4. **Solve on the coarse grid** for the correction `e` in `A_coarse·e = r_coarse`. There are 8× fewer unknowns, and the smooth error is now "rougher", so it's cheap.
5. **Prolongate:** interpolate `e` back up to the fine grid and add it: `p += e`.
6. **Post-smooth:** a few more sweeps to clean up the zigzag the interpolation introduced.

**V-cycle:** step 4 does the same thing recursively. Fine → coarser → coarser → … → a tiny grid (solved with many smoothing sweeps), then back up. The total work is about `1 + 1/8 + 1/64 + … ≈ 8/7` of the finest level, so a V-cycle costs only a few fine-grid sweeps.

**Details that matter for water:**

- **Labels on coarse grids:** each coarse cell gets a label from its 8 children. A common rule (McAdams et al. 2010): AIR if any child is AIR, otherwise FLUID if any child is FLUID, otherwise SOLID.
- **Smoother:** damped Jacobi, `p ← p + ω·(Jacobi update − p)`, with `ω = 6/7` for the 3D 7-point stencil. Or **red–black Gauss–Seidel**: color cells like a 3D checkerboard and update all reds, then all blacks. That's graph coloring again, same as in FEM assembly.
- **Extra smoothing near the surface:** the stencil changes abruptly at the FLUID/AIR boundary, and a few extra sweeps just there help a lot.
- **Symmetry:** used as a CG preconditioner, the V-cycle must be symmetric (same number of pre- and post-smoothing sweeps, restriction the transpose of prolongation). Otherwise CG can break down.

## 6.5 MGPCG: putting it together

**MGPCG** (Multigrid-Preconditioned Conjugate Gradient, McAdams et al. 2010) is CG from §6.2 with one V-cycle as `M⁻¹`. Multigrid does the heavy lifting on smooth errors; CG mops up whatever the V-cycle handles poorly, such as irregular water shapes.

Typical orders of magnitude for a free-surface solve at 128³ (actual numbers depend on the shape and the tolerance):

| Method | Iterations | Grows with resolution? |
|---|---|---|
| Plain CG | hundreds to ~1000 | yes, ∝ N |
| MIC(0)-preconditioned CG | ~50–100 | yes, but slower |
| MGPCG | ~10–20 | barely |

Each MGPCG iteration costs more (a V-cycle), but far fewer iterations win, and the gap grows with resolution. Every part is a stencil sweep or a reduction, so it parallelizes cleanly across CPU threads now and maps onto CUDA later.

**Plan for the code:** start with plain CG. It's short, easy to verify, and correct. Then add the multigrid preconditioner as a separate step and check that the answer doesn't change, only the iteration count.

## 6.6 Check yourself

1. Why is Jacobi alone slow on a 128-cell-deep tank?
2. What does one CG iteration cost, in terms of passes over the grid?
3. Why does a smooth error become easier to remove on a coarser grid?
4. Why must the V-cycle be symmetric when used inside CG?

<details>
<summary>Answers</summary>

1. Information moves one cell per iteration, and smooth errors barely change under neighbor averaging. Convergence takes on the order of `N²` iterations.
2. One stencil application, two dot products (global reductions), and three vector updates: a handful of streaming passes over memory.
3. Relative to the cell size, the error changes twice as fast on the coarse grid, so it looks more "zigzag", which is what smoothing kills quickly.
4. CG's guarantees rely on the preconditioned problem staying symmetric positive definite. An asymmetric `M⁻¹` can make CG stall or diverge.

</details>
