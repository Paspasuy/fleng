# fleng docs

Background reading and plans, mostly around adding physics-based water to the engine.

| File | What it covers |
|---|---|
| [performance-macos.md](performance-macos.md) | Why fleng runs slower on a MacBook Air M4 than on an RTX 4060 Ti, and what could speed it up |
| [fem-overview.md](fem-overview.md) | The Finite Element Method from zero: problems it solves, the full low-level pipeline, GPUs, MPI, glossary |
| [water-simulation-overview.md](water-simulation-overview.md) | Simulating water: Navier–Stokes, grid / particle / hybrid / Lattice Boltzmann methods, high-performance techniques |
| [water-plan.md](water-plan.md) | Architecture and milestones for water in fleng |
| [lessons/](lessons/) | Step-by-step lessons for milestone 1 (APIC solver), one concept per lesson |
| [../sim/](../sim/) | The milestone 1 code (Zig): solver, validation, headless runner |

## Lessons

1. [One time step of water](lessons/01-one-time-step.md)
2. [The MAC grid: where numbers live on the grid](lessons/02-mac-grid.md)
3. [Particles ↔ grid: PIC, FLIP, APIC](lessons/03-particles-and-grid.md)
4. [Gravity, moving particles, choosing Δt (CFL)](lessons/04-forces-advection-cfl.md)
5. [Pressure projection: the heart of incompressibility](lessons/05-pressure-projection.md)
6. [Solving the pressure equation: CG, then multigrid](lessons/06-pressure-solver.md)
7. [Turning particles into a water surface](lessons/07-surface-reconstruction.md)
8. [Validation: proving it's correct](lessons/08-validation.md)
