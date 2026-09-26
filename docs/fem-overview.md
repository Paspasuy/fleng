# FEM from zero

## 1. The idea in one paragraph

Physics is written as **PDEs**: equations that say how something (temperature, displacement, pressure) changes from point to point. For a cube or a sphere you can solve them with pen and paper. For a real part, like a car bracket with holes and fillets, you can't. **FEM** (Finite Element Method) cuts the shape into thousands to billions of tiny simple pieces (**elements**: triangles, tetrahedra, cubes). Inside each piece, the unknown field is approximated by a simple function, such as a linear ramp. Each piece gives a few small equations, and gluing them all together gives one huge system of linear equations:

```
K · u = f
```

`u` is the unknowns you want (like the displacement of every mesh point), `f` is the loads (forces, heat sources), and `K` is the "stiffness matrix" (how the pieces are connected). **Almost all the hard computing in FEM is building and solving that system.**

## 2. What problems it solves

| Field | Question | Examples |
|---|---|---|
| Structural mechanics | Where does it bend, where does it break? | Bridges, aircraft wings, phone drop tests, bone implants |
| Heat transfer | How hot does it get, and where? | CPU coolers, engines, battery packs |
| Electromagnetics | How do fields and currents spread? | Electric motors, antennas, MRI coils, transformers |
| Acoustics / vibration | At which frequencies does it resonate? | Speakers, car cabins, turbine blades |
| Fluids | How does it flow? | Blood flow, aerodynamics (though **CFD**, Computational Fluid Dynamics, more often uses **FVM**, the Finite Volume Method) |
| Geomechanics | Will it hold? | Dams, tunnels, oil reservoirs, earthquakes |
| Multiphysics | Several of the above, coupled | A motor heats up, expands, and changes its magnetic field |

The same physics comes in several flavors, and each one changes the computation:

- **Static:** one solve of `K·u = f`. For example: the load on a shelf.
- **Dynamic / transient:** many solves, one per time step. For example: a car crash, or a part heating up over time.
- **Eigenvalue (modal):** find the natural vibration frequencies by solving `K·x = λ·M·x`, where M is the mass matrix. For example: whether the bridge will shake at walking frequency.
- **Nonlinear:** K depends on u, because the material yields, parts come into contact, or deformations are large. You then solve repeatedly with Newton's method.

## 3. A worked example you can do by hand

A steel rod is fixed to a wall on the left and pulled with force F = 1 on the right. Cut it into 3 elements and 4 nodes:

```
wall |==[e1]==●==[e2]==●==[e3]==●  → F=1
     node0   node1   node2   node3
```

Each element acts like a spring. Its 2×2 **element stiffness matrix** (with stiffness 1) says "the force at each end depends on how much the two ends move relative to each other":

```
k_e = [ 1 -1 ]
      [-1  1 ]
```

**Assembly:** add each element's small matrix into the big one, at the rows and columns of its two nodes. Nodes shared by two elements get contributions from both:

```
      n0  n1  n2  n3
K = [  1  -1   0   0 ]   ← only e1 touches node0
    [ -1   2  -1   0 ]   ← e1 + e2 both touch node1
    [  0  -1   2  -1 ]
    [  0   0  -1   1 ]
```

**Boundary condition:** node 0 is welded to the wall, so u0 = 0. Delete its row and column:

```
[  2 -1  0 ] [u1]   [0]
[ -1  2 -1 ] [u2] = [0]
[  0 -1  1 ] [u3]   [1]
```

**Solve:** u1 = 1, u2 = 2, u3 = 3. The rod stretches evenly, which is correct.

That's the whole method. A real model differs only in scale and detail:

- **Size:** 10 million nodes instead of 4, with 3 unknowns each in 3D (x, y, z displacement).
- **Elements:** 3D bricks and tetrahedra instead of springs.
- **Sparsity:** the key property survives. Each row of K has non-zeros only for the node's neighbors: about 81 in a 3D hex mesh, out of 30 million columns. K is **sparse**, almost all zeros.

## 4. The low-level pipeline, stage by stage

### 4.1 Meshing

Geometry (a CAD file) is split into elements. Tetrahedra fit any shape automatically. Hexahedra (bricks) are more accurate per unknown but hard to generate. Tools: **Gmsh** (open source), commercial meshers. Mesh quality matters: long thin "sliver" elements ruin accuracy and slow down solvers. Each node carries **DOFs** (Degrees of Freedom), meaning unknowns: 1 per node for temperature, 3 for displacement in 3D.

### 4.2 Shape functions and element order

Inside an element, the field is interpolated from its nodes with **shape (basis) functions**. **Linear** (order 1) means straight ramps between nodes. **Higher order** (p = 2, 3, …) adds nodes on edges and faces and uses curved polynomials: much more accurate per element, but more work per element. This choice drives the GPU strategy later (§5).

### 4.3 Element integrals

The small matrix `k_e` isn't written by hand. It's an integral over the element (roughly, the material stiffness times the shape functions' derivatives). It's computed with **numerical quadrature**:

1. Evaluate the integrand at a few carefully chosen **quadrature points** inside the element.
2. Multiply each value by a weight and add them up.

Every element is mapped from a perfect **reference element** (a unit cube). The **Jacobian** of that mapping corrects for the real element's size and distortion. All of this is dense, local, and independent per element, which makes it ideal for parallel hardware.

### 4.4 Assembly

Scatter-add every `k_e` into the global K, as in the rod example.

- **Parallel hazard:** two elements sharing a node write to the same entry of K at the same time, a race condition.
- **Fixes:** atomic adds, **graph coloring** (process groups of elements that share no nodes, one color at a time), or assembling per node instead of per element.

### 4.5 Sparse storage: CSR

You can't store a 30M × 30M dense matrix: that's 7 petabytes. **CSR** (Compressed Sparse Row) stores only the non-zeros:

```
values:   [ 2 -1 | -1  2 -1 | -1  1 ]   ← non-zero numbers, row by row
col_idx:  [ 0  1 |  0  1  2 |  1  2 ]   ← which column each one is in
row_ptr:  [ 0, 2, 5, 7 ]                ← where each row starts in values
```

Real size: 30M rows × 81 non-zeros × 12 bytes (8 for an FP64 value + 4 for the index) ≈ **29 GB**. That's why GPU memory size matters for FEM.

### 4.6 Solving `K·u = f`: usually 70–90% of runtime

**Direct solvers** (**LU** factorization, or **Cholesky** when K is symmetric) do exact Gaussian elimination, cleverly reordered.

- **Pros:** robust, and they always work.
- **Cons:** **fill-in**. Factoring creates non-zeros where K had zeros. In 3D, memory and time explode (roughly n² time), so they're impractical beyond a few million unknowns.
- **Libraries:** MUMPS and PARDISO on CPU, **cuDSS** (NVIDIA's CUDA Direct Sparse Solver) on GPU.

**Iterative solvers** start with a guess and improve it repeatedly.

- **Methods:** **CG** (Conjugate Gradient) for symmetric positive-definite K, which covers most structural and heat problems. **GMRES** (Generalized Minimal RESidual) for general matrices.
- **Cost of one iteration:** mostly one **SpMV** (Sparse Matrix-Vector multiply, `K·x`) plus a few dot products.
- **Memory:** only K plus a few vectors. Scales to billions of unknowns.
- **The catch:** the number of iterations depends on the matrix's **condition number** (how "stretched" the problem is). Fine meshes and mixed materials (steel next to rubber) make it huge, and CG can then need tens of thousands of iterations.

**Preconditioners** fix that. You solve an easier, equivalent problem `P⁻¹·K·u = P⁻¹·f`, where P approximates K but is cheap to invert:

- **Jacobi:** P = the diagonal of K. Trivially parallel, weak.
- **ILU** (Incomplete LU): an LU factorization that throws away most of the fill-in. Decent, but hard to parallelize.
- **Multigrid:** the gold standard. Errors that are smooth over large areas converge slowly on a fine mesh but quickly on a coarse one. So you solve on a hierarchy of coarser and coarser versions and combine the results. Iteration count stays nearly constant no matter how big the mesh gets.
  - **Geometric multigrid** needs an explicit set of coarser meshes.
  - **AMG** (Algebraic MultiGrid) builds the coarse levels automatically from the numbers in K. Libraries: **hypre** (from LLNL, Lawrence Livermore National Laboratory) and **AmgX** (NVIDIA's GPU AMG).

### 4.7 Why FEM on a GPU is limited by memory bandwidth, not FLOPS

- **The arithmetic:** SpMV reads each non-zero once (12 bytes) and does 2 floating-point operations with it (a multiply and an add). That's about 0.17 FLOP per byte.
- **What it means for a 4060 Ti:** at 288 GB/s the ceiling is about 50 **GFLOPS**, whatever the card's advertised 22 **TFLOPS**. The compute units sit idle waiting for memory.
- **Consequence:** for classic FEM, the **GB/s** figure on the spec sheet matters far more than the TFLOPS figure. That's why data-center GPUs with HBM (High Bandwidth Memory, 2–8 TB/s) are so much faster at this.

### 4.8 Nonlinear problems and time stepping

- **Newton's method** (for nonlinear problems):
  1. Linearize around the current guess.
  2. Solve `K·Δu = residual`.
  3. Update, and repeat until converged, typically 5–20 linear solves.
- **Explicit time stepping** (crash simulation, explosions): no big linear solve at all, just "force → acceleration → new position" per node, per tiny time step. Millions of steps, embarrassingly parallel, perfect for GPUs.
- **Implicit time stepping** (slow processes like heat or creep): large time steps, but a full linear solve every step.

### 4.9 Eigenvalue problems

Vibration modes need the lowest few eigenvalues of a huge sparse matrix. Algorithms: **Lanczos**, and **LOBPCG** (Locally Optimal Block Preconditioned Conjugate Gradient). Both are built from SpMVs plus preconditioners.

### 4.10 Post-processing

Compute derived quantities (stress from displacement), then visualize. The standard tool is **ParaView**.

## 5. Matrix-free methods: the modern GPU approach

For higher-order elements (p ≥ 2), K gets very dense per row and storing it is wasteful. **Matrix-free** (or **partial assembly**) methods never build K. Every time the solver needs `K·x`, they recompute each element's contribution on the fly from the mesh and shape functions. This swaps memory traffic for arithmetic: exactly what GPUs have in excess. It turns a bandwidth-bound problem into a compute-bound one and can be 10× faster than CSR SpMV at high order. **MFEM** and **libCEED** are built around this.

## 6. Precision: FP32 vs FP64

- **FP32** (32-bit float) has about 7 significant digits. **FP64** (64-bit double) has about 16.
- A solve loses roughly log₁₀(condition number) digits. FEM condition numbers of 10⁶–10¹⁰ wipe out FP32 entirely, hence "FEM needs FP64".
- **The hardware problem:** consumer and workstation NVIDIA cards run FP64 at 1/64 of FP32 speed.
- **Why it matters less than it sounds:** SpMV is bandwidth-bound anyway (§4.7), so slow FP64 math often barely matters.
- **The standard trick for the rest:** **mixed precision / iterative refinement**. Do the heavy solving in FP32, compute the error (residual) in FP64, and correct. You get FP64 accuracy at mostly FP32 cost.

## 7. Scaling across GPUs and nodes

**Domain decomposition:**

1. Split the mesh into chunks, one per MPI rank or GPU, using **METIS** or **ParMETIS** (its parallel version). These graph partitioners balance element counts while minimizing the boundary between chunks.
2. Each rank owns its nodes and keeps read-only copies of its neighbors' boundary nodes: **ghost (halo) nodes**.

**Every CG iteration then needs two kinds of communication:**

1. **Halo exchange** before each SpMV: `MPI_Isend`/`MPI_Irecv` with neighbor ranks only. Cheap, and it scales well.
2. **Dot products** → `MPI_Allreduce` across *all* ranks, 2–3 times per iteration. This is latency-bound and is what kills scaling at thousands of GPUs.

**Hardware and software details:**

- **CUDA-aware MPI** lets you pass GPU memory pointers directly to MPI calls, with no copying through CPU RAM. It's typically implemented via **UCX** (Unified Communication X, the transport layer under OpenMPI).
- **Interconnects**, fastest to slowest:
  - **NVLink:** NVIDIA's direct GPU-to-GPU link inside one machine. Data-center cards only; the RTX 5000/6000 Ada don't have it.
  - **PCIe:** the normal motherboard slot bus. Slower.
  - **InfiniBand:** the fast, low-latency network between machines in a cluster.
- **AMG preconditioners are the hardest part to scale:** the coarse levels become tiny, so communication dominates.

## 8. Hardware and software for an FEM project

Linux + NVIDIA is the right base: CUDA and nearly every GPU FEM library target it first. A Mac is fine for writing code and CPU-side testing.

**The trap: FP64.** FEM stiffness matrices often need double precision. The RTX 4060 Ti, the RTX 5000/6000 Ada, and the RTX PRO 6000 Blackwell all run FP64 at about 1/64 of their FP32 speed. If a solver needs FP64 everywhere, the real target is data-center cards (A100, H100, B200), usually rented rather than owned. Two things soften this:

- **Sparse solvers are limited by memory bandwidth, not FLOPs** (§4.7). What matters is bandwidth and memory size: the 4060 Ti has 288 GB/s and 8–16 GB, the RTX 6000 Ada 960 GB/s and 48 GB, the RTX PRO 6000 Blackwell 96 GB.
- **Mixed precision** (§6) gets most of the FP32 speed while keeping FP64 accuracy.

**Don't write the solver from scratch.** Build on:

- **PETSc** or **MFEM**: both run on CUDA and scale across GPUs and nodes with MPI.
- **hypre** or **AmgX** for algebraic multigrid preconditioners.
- **cuDSS** for direct sparse solves on the GPU.
- **Gmsh** for meshing, **METIS/ParMETIS** for splitting the mesh across GPUs.

**Clusters:** MPI with domain decomposition, plus CUDA-aware MPI. The RTX 5000/6000 Ada cards have no NVLink, so traffic between GPUs goes over PCIe, and between nodes you want InfiniBand. For the occasional very hard run, renting H100s is usually cheaper than building a workstation-card cluster.

**Portability:** kernels written in Kokkos, or through MFEM/PETSc backends, run on the CPU on a Mac and on CUDA on Linux.

## 9. Glossary

| Abbreviation | Meaning |
|---|---|
| **FEM** | Finite Element Method |
| **PDE** | Partial Differential Equation: the math form of physics laws |
| **DOF** | Degree Of Freedom: one unknown in the system |
| **CFD / FVM** | Computational Fluid Dynamics / Finite Volume Method (FEM's cousin, common for fluids) |
| **FP32 / FP64** | 32-bit / 64-bit floating-point numbers (float / double) |
| **FLOP(S)** | Floating-point operation(s) per second. G = 10⁹, T = 10¹² |
| **GB/s** | Memory bandwidth: how fast data moves between GPU memory and cores |
| **HBM** | High Bandwidth Memory, used on data-center GPUs |
| **CSR** | Compressed Sparse Row: the standard sparse matrix format |
| **SpMV** | Sparse Matrix-Vector multiply: the core operation of iterative solvers |
| **LU / Cholesky** | Direct factorizations (Gaussian elimination) |
| **CG / GMRES** | Iterative solvers for symmetric / general matrices |
| **ILU** | Incomplete LU: a cheap approximate factorization used as a preconditioner |
| **AMG** | Algebraic MultiGrid: the best general-purpose preconditioner |
| **LOBPCG / Lanczos** | Eigenvalue solvers |
| **CUDA** | NVIDIA's GPU programming platform (C++ with GPU kernels) |
| **MPI** | Message Passing Interface: communication between processes and nodes |
| **UCX** | Communication library under OpenMPI; enables CUDA-aware MPI |
| **NVLink** | NVIDIA's fast direct GPU-to-GPU interconnect |
| **PCIe** | PCI Express: the standard expansion-card bus |
| **InfiniBand** | Low-latency cluster network |
| **PETSc** | Portable, Extensible Toolkit for Scientific Computation. Solvers + MPI parallelism; a huge standard library |
| **MFEM** | Modular Finite Element Methods library (LLNL). GPU-first, matrix-free |
| **libCEED** | Library for matrix-free high-order element operators |
| **hypre** | LLNL's preconditioner library (its BoomerAMG is the famous AMG) |
| **AmgX** | NVIDIA's GPU AMG library |
| **cuDSS** | NVIDIA's GPU direct sparse solver |
| **METIS / ParMETIS** | Graph and mesh partitioners (serial / MPI-parallel) |
| **Gmsh** | Open-source mesh generator |
| **Kokkos** | C++ library for writing one parallel code that runs on CPU, NVIDIA, or AMD GPUs |
| **LLNL** | Lawrence Livermore National Laboratory (US): author of MFEM and hypre |
| **Ada / Blackwell** | NVIDIA GPU generations (RTX 40 series / RTX 50 series and newer pro cards) |
| **RTX 5000 / 6000 (Ada), RTX PRO 6000 (Blackwell)** | NVIDIA workstation cards: lots of memory, weak FP64 |
| **A100 / H100 / B200** | NVIDIA data-center cards: fast FP64, HBM, NVLink |

## 10. Learning path

1. **Solve the 1D rod in code** (C++ or Python), then 1D heat with 100 elements. Understand assembly and boundary conditions.
2. **2D heat on triangles:** your own mesh reader (from Gmsh), element integrals, CSR, and your own CG solver. This is the step where FEM "clicks".
3. **Port CG + SpMV to CUDA**, then split the mesh across 2 MPI ranks with halo exchange.
4. **Switch to a real library** (MFEM's examples are excellent) for anything serious.

Books:

- **Larson & Bengzon, *The Finite Element Method: Theory, Implementation, and Applications*:** written for implementers, with code.
- **Saad, *Iterative Methods for Sparse Linear Systems*:** the solver bible, free online from the author.
