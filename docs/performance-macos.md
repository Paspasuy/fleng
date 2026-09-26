# Performance on macOS (MacBook Air M4)

Measured 2026-09-24 on a MacBook Air M4 (8-core GPU), release build, default scene, `march_iterations = 200`.

## GPU-bound, not CPU-bound

While running, the GPU sits at 100% utilization and fleng uses about 1.8% CPU.

Uncapped (`framerate_limit = 0`):

| Resolution | fps |
|---|---|
| 300×300 | 147 |
| 500×500 | 66 |
| 800×800 | 32 |
| 1200×1200 | 16 |
| 1800×1800 | 7.5 |

Cost grows almost exactly with pixel count (throughput levels off around 24 megapixels/s), plus about 2 ms of fixed cost per frame. An RTX 4060 Ti running 1800×1800 at 60 fps does at least 194 megapixels/s: more than 8× faster.

## Where the gap comes from

| Factor | How much it matters | Evidence |
|---|---|---|
| **Weaker GPU** | The main cause, about 6× | Roughly 3.5 TFLOPS vs about 22 on the 4060 Ti (spec figures) |
| **Unoptimized shader** | Multiplies everything else | Up to 30 bounces × 200 march steps × 13 objects ≈ 78,000 distance evaluations per pixel. The tight `EPS = 1e-5` makes many rays use all 200 steps (see below) |
| **macOS OpenGL / GLSL** | Small, can't be measured separately | On macOS, OpenGL is a deprecated layer on top of Metal, but the shader goes through the same GPU compiler. At most it explains what's left after the ~6× hardware gap |
| **SFML frame limiter** | About −3 fps, and the instability | With `framerate_limit = 60`, 450×450 gets 57 fps even though 79 is possible uncapped. SFML caps by sleeping, and macOS oversleeps |

Effect of the march step limit at 500×500 (uncapped). Lowering it changes the image unacceptably, so it's not a real fix; it only shows how much time rays spend crawling:

| `march_iterations` | fps |
|---|---|
| 200 | 67 |
| 100 | 92 |
| 60 | 130 |
| 30 | 253 |

## Would Metal help?

Not much by itself. A straight port might gain around 0–20% (an estimate, not measured). What Metal would give:

- Xcode's GPU frame capture and shader profiler, which show the cost of each shader line.
- `half` (16-bit float) math where precision allows.
- Compute shaders and other modern GPU features macOS OpenGL doesn't expose.

## Code changes that keep the image the same

1. **Hit threshold that scales with distance.** A fixed `EPS = 1e-5` is close to float precision at distance 10, so rays crawl toward surfaces. A threshold tied to pixel size (`EPS * t * pixel_angle`) stops rays once they're within a fraction of a pixel: visually identical, far fewer steps. Likely the biggest gain.
2. **Over-relaxed sphere tracing** (Keinert et al., 2014): larger steps with a fallback, typically 20–40% fewer steps.
3. **Compute `warp(ray_pos)` once per march step**, not once per object: up to 13× fewer calls.
4. **Skip distant objects** with a cheap bounding-sphere check before each full distance function. The per-object neighbor lists (`obj_indices`) are already half-built in the shader and commented out.
5. **Only accumulate when the camera is still:** render at lower resolution while moving, full resolution once the image is stale.
