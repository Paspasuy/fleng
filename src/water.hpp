#pragma once

// Water: runs the Zig simulation (sim/, see docs/water-plan.md) on a background
// thread and hands the newest water surface to the shader as a 3D texture.

#include <SFML/Graphics.hpp>
#include <SFML/OpenGL.hpp>

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../sim/include/fleng_sim.h"
#include "utils/config.hpp"

#ifndef GL_TEXTURE_3D
#define GL_TEXTURE_3D 0x806F
#endif
#ifndef GL_TEXTURE_WRAP_R
#define GL_TEXTURE_WRAP_R 0x8072
#endif
#ifndef GL_CLAMP_TO_EDGE
#define GL_CLAMP_TO_EDGE 0x812F
#endif
#ifndef GL_LUMINANCE16F_ARB
#define GL_LUMINANCE16F_ARB 0x881E
#endif
#ifndef GL_TEXTURE0
#define GL_TEXTURE0 0x84C0
#endif

class Water {
 public:
  // Texture unit the shader samples the surface from. SFML binds its own
  // textures to units 1, 2, ... so this stays out of their way.
  static constexpr unsigned texture_unit = 7;

  ~Water() {
    stop();
  }

  void start() {
    running_ = true;
    thread_ = std::thread([this] { run(); });
  }

  void stop() {
    {
      std::lock_guard lock(mutex_);
      running_ = false;
    }
    wake_.notify_all();
    if (thread_.joinable()) thread_.join();
  }

  // Flags change under the mutex so the simulation thread can't miss a wakeup
  // between checking them and going to sleep.
  void reset() {
    {
      std::lock_guard lock(mutex_);
      reset_requested_ = true;
    }
    wake_.notify_all();
  }

  void togglePause() {
    {
      std::lock_guard lock(mutex_);
      paused_ = !paused_;
    }
    wake_.notify_all();
  }

  // Uploads the newest surface, if any arrived since the last call, into the 3D
  // texture. Call with the GL context that draws the shader active. Returns true
  // when the image changed.
  bool upload() {
    std::lock_guard lock(mutex_);
    if (!fresh_) return false;
    fresh_ = false;
    if (texture_ == 0) glGenTextures(1, &texture_);
    glBindTexture(GL_TEXTURE_3D, texture_);
    const Info& info = snapshot_.info;
    if (uploaded_dims_ != info.dims) {
      glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
      // Half floats are plenty for distances of a few cells and filter everywhere.
      glTexImage3D(GL_TEXTURE_3D, 0, GL_LUMINANCE16F_ARB, info.dims[0], info.dims[1], info.dims[2], 0, GL_LUMINANCE,
                   GL_FLOAT, snapshot_.phi.data());
      uploaded_dims_ = info.dims;
    } else {
      glTexSubImage3D(GL_TEXTURE_3D, 0, 0, 0, 0, info.dims[0], info.dims[1], info.dims[2], GL_LUMINANCE, GL_FLOAT,
                      snapshot_.phi.data());
    }
    glBindTexture(GL_TEXTURE_3D, 0);
    shown_ = info;
    return true;
  }

  // Binds the texture for the next draw. Call with the drawing context active.
  void bind() const {
    glActiveTexture(GL_TEXTURE0 + texture_unit);
    glBindTexture(GL_TEXTURE_3D, texture_);
    glActiveTexture(GL_TEXTURE0);
  }

  bool ready() const {
    return texture_ != 0;
  }

  // Where the grid sits in the world, for the shader.
  void setUniforms(sf::Shader& shader) const {
    const auto& c = config;
    const float s = c.water_scale;
    // The grid includes a one-cell wall layer on every side.
    const sf::Vector3f size(shown_.dims[0] * shown_.dx * s, shown_.dims[1] * shown_.dx * s,
                            shown_.dims[2] * shown_.dx * s);
    const sf::Vector3f min(c.water_position[0] - size.x / 2, c.water_position[1] - shown_.dx * s,
                           c.water_position[2] - size.z / 2);
    shader.setUniform("water_on", 1);
    shader.setUniform("water_min", min);
    shader.setUniform("water_size", size);
    shader.setUniform("water_scale", s);
    shader.setUniform("water_texel", sf::Vector3f(1.f / shown_.dims[0], 1.f / shown_.dims[1], 1.f / shown_.dims[2]));
    // Configured per meter; the shader measures distance in world units.
    shader.setUniform("water_absorb",
                      sf::Vector3f(c.water_absorption[0], c.water_absorption[1], c.water_absorption[2]) / s);
    shader.setUniform("water_ior", c.water_ior);
  }

  std::string status() {
    char buf[160];
    {
      std::lock_guard lock(mutex_);
      if (!error_.empty()) return "water: " + error_;
    }
    if (texture_ == 0) return "water: starting";
    std::snprintf(buf, sizeof buf, "water t=%.2fs, %.0f ms/frame, %u substeps%s%s", shown_.time, shown_.frame_ms,
                  shown_.substeps, paused_ ? " [paused]" : "", shown_.converged ? "" : " [solver not converged]");
    return buf;
  }

 private:
  struct Info {
    std::array<int, 3> dims{0, 0, 0};
    float dx = 0;
    double time = 0;
    double frame_ms = 0;
    unsigned substeps = 0;
    bool converged = true;
  };
  struct Snapshot {
    Info info;
    std::vector<float> phi;
  };

  // Simulation thread: advance one 1/60 s frame at a time and publish the surface.
  void run() {
    using clock = std::chrono::steady_clock;
    const float frame_time = 1.f / 60;
    fs_sim* sim = nullptr;
    Snapshot next;
    auto anchor = clock::now();  // wall time when the simulation was at time 0 (live mode)
    double anchor_sim_time = 0;
    while (true) {
      {
        std::unique_lock lock(mutex_);
        wake_.wait(lock, [&] { return !running_ || reset_requested_ || !paused_ || sim == nullptr; });
        if (!running_) break;
      }
      bool reset;
      {
        std::lock_guard lock(mutex_);
        reset = reset_requested_;
        reset_requested_ = false;
      }
      if (sim == nullptr || reset) {
        fs_destroy(sim);
        sim = fs_create(config.water_scene.c_str(), static_cast<int>(config.water_resolution), 0);
        if (sim == nullptr) {
          std::lock_guard lock(mutex_);
          error_ = "could not create scene '" + config.water_scene + "'";
          running_ = false;
          break;
        }
        next.info = {};
        fs_grid(sim, next.info.dims.data(), &next.info.dx);
        next.phi.resize(static_cast<size_t>(next.info.dims[0]) * next.info.dims[1] * next.info.dims[2]);
        publish(sim, next);
        anchor = clock::now();
        anchor_sim_time = 0;
        continue;
      }
      if (paused_) {
        continue;
      }
      const auto t0 = clock::now();
      fs_frame_stats stats{};
      fs_advance(sim, frame_time, &stats);
      next.info.frame_ms = std::chrono::duration<double, std::milli>(clock::now() - t0).count();
      next.info.substeps = stats.substeps;
      next.info.converged = stats.converged != 0;
      publish(sim, next);

      // Live mode: never run ahead of the wall clock.
      const double sim_time = fs_time(sim) - anchor_sim_time;
      const auto due = anchor + std::chrono::duration_cast<clock::duration>(std::chrono::duration<double>(sim_time));
      if (config.water_realtime && due > clock::now()) {
        std::unique_lock lock(mutex_);
        wake_.wait_until(lock, due, [&] { return !running_ || reset_requested_ || paused_; });
      } else if (!config.water_realtime || due < clock::now()) {
        // Behind (or not pacing): shift the anchor so we don't try to catch up later.
        anchor = clock::now() - std::chrono::duration_cast<clock::duration>(std::chrono::duration<double>(sim_time));
      }
      if (paused_) {
        // Resume from where we are, not from where the wall clock went.
        anchor_sim_time = fs_time(sim);
        anchor = clock::now();
      }
    }
    fs_destroy(sim);
  }

  void publish(fs_sim* sim, Snapshot& next) {
    fs_copy_surface(sim, next.phi.data());
    next.info.time = fs_time(sim);
    std::lock_guard lock(mutex_);
    std::swap(snapshot_, next);
    // `next` now holds the previous buffer; keep it sized for the next copy.
    next.info = snapshot_.info;
    next.phi.resize(snapshot_.phi.size());
    fresh_ = true;
  }

  std::thread thread_;
  std::mutex mutex_;
  std::condition_variable wake_;
  // Guarded by mutex_. paused_ is also read without it by status(), hence atomic.
  bool running_ = false;
  std::atomic<bool> paused_{false};
  bool reset_requested_ = false;
  bool fresh_ = false;
  std::string error_;
  Snapshot snapshot_;  // newest surface from the simulation thread
  Info shown_;         // what's in the texture (render thread only)
  std::array<int, 3> uploaded_dims_{0, 0, 0};
  GLuint texture_ = 0;
};
