# Simulating water: a drop falling into a pool

## 1. The equations

Water at everyday speeds follows the **incompressible Navier–Stokes (NS) equations**:

```
ρ (∂u/∂t + (u·∇)u) = −∇p + μ∇²u + ρg + f_surface     ← momentum (Newton's 2nd law per fluid parcel)
∇·u = 0                                              ← incompressibility (volume never changes)
```

| Term | Meaning |
|---|---|
| `u` | Velocity at every point (the main unknown) |
| `ρ ∂u/∂t` | Change of velocity over time (density × acceleration) |
| `(u·∇)u` | **Advection**: the flow carries its own velocity along. This is the nonlinear term, source of turbulence and splashes |
| `−∇p` | Pressure pushes fluid from high to low pressure |
| `μ∇²u` | **Viscosity**: internal friction that smooths velocity differences |
| `ρg` | Gravity |
| `f_surface` | **Surface tension**, acting only at the water–air interface. Proportional to the surface's **curvature**; it's what makes drops round |
| `∇·u = 0` | What flows into any tiny volume must flow out |

**Pressure isn't a physical input here.** It's whatever value makes `∇·u = 0` true. Computing it means solving a **Poisson equation** `∇²p = (something from u)` over the whole domain, every time step. That's a huge sparse linear system `K·p = b`: exactly the CG + multigrid machinery from [fem-overview.md](fem-overview.md). **It's usually the most expensive step.**

### What a drop impact looks like in numbers

A 2 mm drop falling 0.5 m hits at about 3 m/s. Four dimensionless numbers decide which physics dominates:

| Number | Formula | Value | Meaning |
|---|---|---|---|
| **Re** (Reynolds) | ρUD/μ | ~6000 | Inertia ≫ viscosity: viscosity barely matters, except in thin sheets |
| **We** (Weber) | ρU²D/σ | ~270 | Inertia vs surface tension. Above ~100 you get a splash crown and secondary droplets |
| **Fr** (Froude) | U²/(gD) | ~460 | Gravity is irrelevant during impact, but matters for the later jet and cavity collapse |
| **Bo** (Bond) | ρgD²/σ | ~0.5 | Surface tension and gravity are comparable at drop size |

**Surface tension must be simulated well**, which is the hard part. The crown's sheets are tens of µm thick, the pool is centimeters wide: about a 1000:1 range of scales. A uniform grid fine enough everywhere would need roughly 2000³ = **8 billion cells**. That's why modern methods focus on **adaptivity**: putting resolution only where the interface is.

## 2. The four hard problems

1. **Incompressibility:** the global pressure solve every step. Everything is coupled to everything else.
2. **Tracking the interface:** where the water ends. It changes topology constantly: the crown breaks into droplets, air bubbles get trapped, the jet pinches off.
3. **Surface tension:** needs accurate curvature of the interface. Errors create **parasitic currents**, fake whirlpools that can blow up the simulation.
4. **Time step limits:**
   - **CFL** (Courant–Friedrichs–Lewy) condition: fluid may not move more than about one cell per step.
   - **Capillary constraint:** `Δt < √(ρ Δx³ / 2πσ)`, where σ is the surface-tension coefficient. It shrinks with cell size as Δx^1.5, so halving the cell size means about 2.8× more time steps. At µm scales, this is brutal.
   - **Air:** real two-phase flow has a 1000:1 density ratio between water and air, which destabilizes many solvers. The cheaper option is to ignore the air ("free surface" only), but then trapped bubbles are lost.

## 3. Method families

### A. Grid methods (Eulerian): FVM and finite differences

"Eulerian" means the grid stays fixed and the fluid flows through it.

**FVM (Finite Volume Method):** split space into cells. Each cell stores its average velocity, pressure, and so on. Every step, compute the **fluxes** through each face (how much mass or momentum crosses it), then update: `new = old + inflow − outflow`. Whatever leaves one cell enters its neighbor *exactly*, so mass and momentum are conserved to machine precision. That's why fluids use FVM rather than FEM: FEM approximates *functions*, FVM balances *quantities*. On regular grids, FVM and finite differences are often nearly the same code.

**Time stepping: the projection method (Chorin, 1968).** Standard for incompressible flow:

1. **Advect:** move velocity along the flow. Semi-Lagrangian, or higher-order schemes like WENO (Weighted Essentially Non-Oscillatory).
2. **Add forces:** gravity, viscosity, surface tension.
3. **Solve the pressure Poisson equation** (the expensive part).
4. **Subtract the pressure gradient.** Velocity is now divergence-free.

Velocities live on cell faces and pressure at cell centers, a **staggered MAC grid** (Marker-And-Cell). That layout avoids checkerboard pressure artifacts.

**Tracking the interface** (the choice that matters most for splashes):

| Method | Idea | Pros | Cons |
|---|---|---|---|
| **VOF** (Volume Of Fluid) | Each cell stores the fraction filled with water (0…1). The surface is rebuilt geometrically in each cell as a flat slice (**PLIC**, Piecewise Linear Interface Calculation) | Mass conserved exactly; handles breakup naturally | Curvature is hard to extract from a step-like fraction field |
| **Level set** | Store the **signed distance** to the surface (negative inside, positive outside). The surface is where it equals 0 | Smooth, and curvature is easy | Slowly loses mass; thin sheets vanish |
| **CLSVOF** | VOF and level set combined | Both strengths | More code |
| **Front tracking** | An explicit triangle mesh of the surface moves with the flow | Most accurate curvature | Topology changes (breakup) are very painful |

**Surface tension:**

- **CSF** (Continuum Surface Force, Brackbill 1992): smears the force over a few cells.
- **Height functions** (Popinet): compute curvature from VOF column sums. The accurate modern choice, which keeps parasitic currents tiny.

**Adaptive octree AMR (Adaptive Mesh Refinement):** cells split into 8 children near the interface and merge where nothing happens. This is **the state of the art for drop impact research**. Instead of 8 billion cells you use a few million, fine only at the surface.

- **Basilisk** (by Stéphane Popinet): C, octree AMR, VOF + height functions, MPI. Most published drop-splash simulations use it or its predecessor Gerris. It even ships drop-impact examples.
- **OpenFOAM** (`interFoam` solver): unstructured-mesh FVM + VOF, industry-standard, CPU/MPI. Less accurate for fine surface-tension physics.

### B. Particle methods (Lagrangian): SPH

**SPH** (Smoothed Particle Hydrodynamics): water is a cloud of particles, each carrying mass and velocity. Quantities at a point are weighted averages over nearby particles (a smoothing "kernel"). There's no grid and no interface tracking: wherever particles are is water. Splashes and droplets come for free.

| Variant | How pressure works | Use |
|---|---|---|
| **WCSPH** (Weakly Compressible SPH) | Water is made slightly squishy: pressure comes from local density, so no Poisson solve. Fully explicit, tiny time steps | Engineering (waves on ships, dam breaks). **DualSPHysics** runs it on GPUs |
| **IISPH / DFSPH** (Implicit Incompressible / Divergence-Free SPH) | An iterative pressure solve over the particles | Graphics and VFX. **SPlisHSPlasH** library |

**Pros:** trivially handles violent splashing, and GPU-friendly (each particle only talks to neighbors).
**Cons:** noisy pressure, surface tension is hard and inaccurate, you need lots of particles for smooth surfaces, and it's weaker for quantitative science.

### C. Hybrid particle + grid: PIC / FLIP / APIC, MPM

Particles carry the fluid, so there's no numerical smearing and splashes look sharp. Every step, velocities are transferred to a grid, the pressure is solved there, and results go back to the particles.

- **PIC** (Particle-In-Cell): stable but viscous-looking.
- **FLIP** (FLuid-Implicit-Particle): lively but noisy.
- **APIC** (Affine PIC, 2015): the modern best of both.
- **MPM** (Material Point Method): the same idea generalized to snow, sand, and mud.

**This is how Hollywood water is made** (Houdini FLIP). It looks great, but it's not accurate for splash physics.

### D. Lattice Boltzmann (LBM): the GPU speed champion

LBM doesn't simulate the NS equations directly. It simulates **particle statistics**: each lattice node stores 19 numbers (**D3Q19**: 3D, 19 velocity directions), the probability of molecules moving in each direction. Every step has two phases:

1. **Stream:** each value moves to the neighbor in its direction. Pure memory copy.
2. **Collide:** values at each node relax toward equilibrium. Local math only (**BGK / TRT / MRT** are the collision models, from simple to more stable).

Mathematically this reproduces Navier–Stokes. **There's no Poisson solve and no global coupling**: every operation is local, so it maps perfectly onto GPUs and multiple GPUs.

- **Free-surface LBM:** tracks a VOF-like fill level per cell and handles the air as a boundary. Surface tension is supported.
- **FluidX3D** (Moritz Lehmann): open-source (source-available, free for non-commercial use), OpenCL, runs on an M4 Mac and an RTX 4060 Ti alike. It stores data as FP16 to fit hundreds of millions of cells on one consumer GPU. The author published **raindrop-impact studies** done with it.

**Cons:** weakly compressible (fine for water at these speeds), uniform grids use a lot of memory, and real two-phase flow with air is hard.

### Which to use

| Goal | Best choice |
|---|---|
| Physically accurate splash (crown, jet, bubble ring) | **Basilisk** (adaptive VOF), or **FluidX3D** (GPU LBM) |
| Maximum GPU performance, writing your own | **Free-surface LBM** in CUDA |
| Classical CFD skills for engineering | **FVM projection + VOF + multigrid** |
| Pretty and real-time-ish (games, VFX) | **FLIP/APIC** or **DFSPH** |

## 4. High-performance techniques

1. **Memory bandwidth is the limit**, just like FEM's SpMV. Stencil updates and LBM streaming do little math per byte, so what matters:
   - **Structure-of-arrays** layout: all `u_x` values contiguous, then all `u_y`, …, so GPU threads read memory in coalesced chunks.
   - **Store in FP16/FP32, compute in FP32:** FluidX3D's trick, halving the memory traffic.
   - **Kernel fusion:** do advect + forces + stream in one pass instead of re-reading memory 3 times.
   - **In-place streaming** (the "Esoteric Twist" / "Esoteric Pull" schemes for LBM): one copy of the lattice instead of two, 2× less memory.
2. **Pressure solve: geometric multigrid, matrix-free.** On a regular grid you never store a matrix; the Laplacian stencil is just "6 neighbors − 6× center". **MGPCG** (Multigrid-Preconditioned CG, McAdams et al. 2010) is the standard: iteration count doesn't grow with resolution, and it's all stencil ops, ideal for GPUs. On structured grids it's much faster than AMG.
3. **Sparse / adaptive storage:**
   - **Octree AMR:** Basilisk; **p4est** (a scalable octree library for thousands of MPI ranks).
   - **Sparse block grids:** **OpenVDB** and its GPU version **NanoVDB**, or **SPGrid**. Only allocate 8³ blocks near water.
   - **Narrow band:** only simulate a thin shell of cells around the surface (graphics).
4. **Multi-GPU and clusters:** domain decomposition with halo exchange, exactly as in the FEM overview.
   - LBM and explicit SPH scale almost perfectly: only neighbor communication, no global reductions.
   - Projection methods pay for the global Poisson solve: `MPI_Allreduce` in CG, plus coarse multigrid levels.
5. **Adaptive time stepping:** compute Δt each step from the CFL and capillary limits. Don't use a fixed step.
6. **Rendering:**
   - **Marching cubes** turns the level set or VOF field into a triangle mesh.
   - **Direct ray marching:** a level set *is* a signed distance field, exactly what fleng's raymarcher already renders.

## 5. Learning path

1. **2D "Stable Fluids"** (Stam 1999): smoke on a grid, projection + Jacobi/CG pressure solve. About 300 lines, and it teaches the core loop.
2. **2D free surface:** add a level set or FLIP particles, and drop a blob into a tank.
3. **3D on GPU (CUDA):** geometric multigrid for pressure. Or switch to **free-surface LBM** if raw speed is the goal.
4. **Surface tension:** VOF + height functions (hardest, most physical) or the LBM surface-tension model.
5. **Scaling:** sparse grids / AMR, then multi-GPU with MPI halo exchange.

Reading:

- **Bridson, *Fluid Simulation for Computer Graphics*:** the best programmer-oriented intro (grids, FLIP, level sets, pressure solve).
- **Tryggvason, Scardovelli & Zaleski, *Direct Numerical Simulations of Gas–Liquid Multiphase Flows*:** the VOF and front-tracking bible for accurate drop physics.
- **Krüger et al., *The Lattice Boltzmann Method: Principles and Practice*:** the standard LBM book.
- **Basilisk's website:** drop-impact examples.
- **FluidX3D's GitHub page:** setups and performance data.

## 6. Glossary

| | |
|---|---|
| **NS** | Navier–Stokes equations |
| **Re / We / Fr / Bo** | Reynolds / Weber / Froude / Bond numbers |
| **CFL** | Courant–Friedrichs–Lewy time-step condition |
| **MAC grid** | Marker-And-Cell: velocities on faces, pressure at centers |
| **WENO** | Weighted Essentially Non-Oscillatory, a high-order advection scheme |
| **VOF / PLIC / CLSVOF** | Volume Of Fluid / Piecewise Linear Interface Calculation / Coupled Level Set + VOF |
| **CSF** | Continuum Surface Force (surface-tension model) |
| **AMR** | Adaptive Mesh Refinement |
| **SPH / WCSPH / IISPH / DFSPH** | Smoothed Particle Hydrodynamics and its weakly compressible / implicit incompressible / divergence-free variants |
| **PIC / FLIP / APIC / MPM** | Particle-In-Cell / FLuid-Implicit-Particle / Affine PIC / Material Point Method |
| **LBM / D3Q19** | Lattice Boltzmann Method / 3D lattice with 19 directions |
| **BGK / TRT / MRT** | LBM collision models: single / two / multiple relaxation times (simple → more stable) |
| **MGPCG** | Multigrid-Preconditioned Conjugate Gradient |
| **DNS** | Direct Numerical Simulation: resolving all scales, no turbulence model |
