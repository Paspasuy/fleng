# Lesson 7: turning particles into a water surface

Part of milestone 1 in [the water plan](../water-plan.md). Previous: [lesson 6, solving the pressure equation](06-pressure-solver.md). Next: [lesson 8, validation](08-validation.md).

The particles *are* the water, but they're just points. Two things need an actual surface:

- **Rendering:** fleng's raymarcher draws signed distance fields (SDFs). The water needs one.
- **Ghost fluid** (lesson 5, §5.6) needs the surface position between cells, from the same field.

The goal: a **level set** `φ` on a grid: the signed distance to the water surface, **negative inside the water**, positive outside, 0 exactly on the surface.

## 7.1 Naive: a union of balls

Treat each particle as a small sphere of radius `r` and take the closest one:

```
φ(x) = min_p |x − x_p| − r
```

It's correct in the sense that it wraps the particles, but the surface is visibly **bumpy**: rendered with refraction, it looks like a pile of glass beads, not water. Even a perfectly flat pool looks like bubble wrap.

## 7.2 Zhu & Bridson: average first, then measure

**Zhu & Bridson (2005)** smooth things out by blending nearby particles *before* measuring distance. Around each grid point `x`, within a search radius `R` (1.5–2 cell widths; the code uses 1.5 with particle radius 0.42 cells, calibrated so a flat surface lands on the true water boundary):

```
k(s)  = max(0, 1 − s²)³                       smooth weight, 1 at the center, 0 at distance R
w_p   = k(|x − x_p| / R)
x̄    = Σ w_p · x_p / Σ w_p                     weighted average particle position
r̄    = Σ w_p · r_p / Σ w_p                     weighted average radius
φ(x)  = |x − x̄| − r̄
```

**Why it works:** under a flat layer of particles, `x̄` sits in the middle of the layer directly below `x`, so the distance changes smoothly with height and the surface comes out flat. One particle alone still gives a sphere, which is what an isolated droplet should look like.

**Known weakness:** in concave corners (inside a crease or where a jet meets the pool), the averaged center can land outside the particles and create small bumps or holes. Two well-known improvements for later:

- **Solenthaler et al. (2007):** detect and fix exactly those cases.
- **Anisotropic kernels (Yu & Turk 2013):** each particle's influence becomes an ellipsoid stretched along the local particle layer, computed from the neighbors' spread. Thin sheets stay thin and sharp, and flat surfaces are flatter. This is what makes splash crowns look right.

Start with Zhu–Bridson; it's short and good enough to see water.

## 7.3 Computing it efficiently

- **Loop over particles, not grid points:** each particle adds its weight to the grid points within `R`. Keep running sums of `Σ w`, `Σ w·x_p`, `Σ w·r_p` per grid point, then finish `φ` per point. That's a P2G-style scatter again, so the same parallel tricks apply (lesson 3, §3.6).
- **The surface grid can be finer than the simulation grid.** For example, simulate at 64³ but build the surface at 128³: rendering looks sharper at little extra cost, since this runs once per rendered frame, not every substep.

## 7.4 Making it a usable SDF

The formula is only a true distance close to the surface, within about `R`:

- **Deep inside the water:** particles surround the grid point on all sides, so `x̄ ≈ x` and `φ ≈ −r̄`. The sign is right (inside), but the magnitude is tiny instead of the real depth.
- **Far out in the air:** no particles within `R`, so there's nothing to average. Set `φ` to a positive value **clamped to about `R`**.

A raymarcher steps forward by `|φ|` each time (sphere tracing), so `φ` must never *overestimate* the true distance, or rays could jump through the surface. Both cases above are underestimates, so they're safe, just slow: rays crawl in steps of `r̄` through deep water and `R` through empty air. Refracted rays travel *inside* the water, so the crawl matters. The fix is to rebuild a true distance field from the surface with **fast sweeping** or **fast marching**: start from the values near the surface and propagate distances outward in both directions, one layer of cells at a time.

**Optional smoothing:** a few passes of gentle smoothing (moving each `φ` value slightly toward its neighbors' average) remove the last bumps. Limit how much any value can change (say, a fraction of a cell), or thin features and small droplets melt away.

## 7.5 Particle count: keeping the water "full"

Particles bunch up in some places and spread out in others, especially after splashes:

- **Too few particles in a FLUID cell:** gaps appear in the surface, and the cell might get labeled AIR, losing volume.
- **Too many:** wasted work, and extra volume if particle spacing matters.

The usual fix is **reseeding**: add particles to underpopulated fluid cells (with velocities from the grid) and remove some from overcrowded ones, keeping between about 4 and 16 per cell. It has to be done carefully, because adding and removing particles changes mass and momentum a little. The lesson 8 volume test will show whether it's needed.

## 7.6 Better cell labels

The FLUID/AIR labeling from lesson 2 ("contains a particle") is crude: one stray particle turns a cell into FLUID. With `φ` available there's a better rule: **a cell is FLUID if `φ < 0` at its center.** It's smoother, and it matches the surface the ghost fluid method and the renderer see.

## 7.7 Rendering, briefly (milestone 2 covers it)

- **Upload `φ` as a 3D float texture.** Sampling it with trilinear filtering gives a smooth distance anywhere.
- **Sphere-trace** inside the texture's box, like the other fleng objects.
- **Normal** = the normalized gradient of `φ`, from central differences.
- **Water material:**
  - Refraction with index 1.33 (fleng already refracts).
  - **Fresnel** (Schlick's approximation): more reflection at grazing angles.
  - **Beer–Lambert absorption:** color fades as `exp(−σ_a · distance traveled inside water)`, with a slightly stronger absorption for red, giving deep water its blue-green tint.
- **Spray and foam:** particles far from the bulk can be drawn as tiny droplets or foam instead of being part of the surface. A later polish step.

## 7.8 Check yourself

1. Why does the union-of-balls surface look bumpy even for a perfectly flat pool?
2. Under a flat particle layer, where does Zhu–Bridson's average center `x̄` end up for a grid point just above the layer?
3. Why clamp `φ` in empty regions to about `R` instead of leaving a huge value?
4. Why should surface smoothing be limited?

<details>
<summary>Answers</summary>

1. Each particle contributes its own sphere, and the surface follows each ball's curve between particles.
2. Directly below it, in the middle of the layer: so `φ` varies smoothly with height and the surface is flat.
3. A raymarcher steps by `φ`. A too-large value (an overestimate of the real distance) could make a ray jump through the surface. A clamp keeps it an underestimate.
4. Smoothing shrinks and rounds everything: thin sheets and small droplets would disappear and the water would lose volume.

</details>
