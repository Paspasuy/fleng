/* C interface to the fleng water simulation (sim/src/capi.zig).
 * Build: cd sim && zig build -Doptimize=ReleaseFast → zig-out/lib/libfleng_sim.a
 * A handle may be used from one thread at a time. */
#ifndef FLENG_SIM_H
#define FLENG_SIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fs_sim fs_sim;

typedef struct {
  uint32_t substeps;
  uint32_t iterations; /* pressure-solver iterations, summed over substeps */
  uint32_t converged;  /* 1 if every pressure solve converged */
} fs_frame_stats;

/* scene: "still_tank", "dam_break" or "drop". resolution: cells across the
 * scene's x axis. threads: 0 = every core. Returns NULL on failure. */
fs_sim* fs_create(const char* scene, int resolution, int threads);
void fs_destroy(fs_sim* sim);

/* Advances by frame_time seconds of simulated time. Returns 0 on success. */
int fs_advance(fs_sim* sim, float frame_time, fs_frame_stats* stats);
double fs_time(const fs_sim* sim);

/* Grid cells per axis (including a one-cell wall layer) and cell size in meters. */
void fs_grid(const fs_sim* sim, int dims[3], float* dx);
/* Inside of the tank in meters. */
void fs_interior(const fs_sim* sim, float size[3]);

/* Water surface as a signed distance in meters, negative inside, at every
 * cell center, x varying fastest: dims[0]*dims[1]*dims[2] floats. */
void fs_copy_surface(const fs_sim* sim, float* out);

#ifdef __cplusplus
}
#endif

#endif
