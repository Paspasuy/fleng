#pragma once

#include "math.hpp"
#include "utils/config.hpp"

struct Camera {
  float mt_sz = config.camera_matrix_size;
  float speed = config.camera_speed;
  const float rot_ang = config.camera_rotation_angle;
  vec3 campos;
  M3x3 camor;
  // Camera() {campos = vec3(1.0, 1.0, 0.0); xaxis = vec3(1, 0, 0).norm();
  // camdir = vec3(0, 0, 3).norm();}
  Camera() {
    const auto& p = config.camera_position;
    const auto& t = config.camera_look_at;
    campos = vec3(p[0], p[1], p[2]);
    look_at(vec3(t[0], t[1], t[2]));
  }
  // Points the camera at `target`, keeping the horizon level. The orientation's
  // columns are right (x), up (y) and forward (z).
  void look_at(vec3 target) {
    vec3 f = (target - campos).norm();
    vec3 r = cross(vec3(0, 1, 0), f).norm();
    vec3 u = cross(f, r);
    const vec3 axes[3] = {r, u, f};
    for (int c = 0; c < 3; ++c) {
      camor.a[0][c] = axes[c].x;
      camor.a[1][c] = axes[c].y;
      camor.a[2][c] = axes[c].z;
    }
  }
  static vec3 cross(vec3 a, vec3 b) {
    return vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
  }
  void forward() {
    campos += camor.get_z() * speed;
  }
  void backward() {
    campos -= camor.get_z() * speed;
  }
  void right() {
    campos += camor.get_x() * speed;
  }
  void left() {
    campos -= camor.get_x() * speed;
  }
  void up() {
    campos += camor.get_y() * speed;
  }
  void down() {
    campos -= camor.get_y() * speed;
  }
  // rot_xz/yaw/рысканье
  void rot_xz(bool positive) {
    float phi = (positive ? rot_ang : -rot_ang) * mt_sz / config.camera_matrix_size;
    camor = mul(camor, get_rot(0, 2, phi));
  }
  // rot_yz/pitch/тангаж
  void rot_yz(bool positive) {
    float phi = (positive ? rot_ang : -rot_ang) * mt_sz / config.camera_matrix_size;
    camor = mul(camor, get_rot(1, 2, phi));
  }
  // rot_xy/roll/крен
  void rot_xy(bool positive) {
    float phi = (positive ? rot_ang : -rot_ang) * mt_sz / config.camera_matrix_size;
    camor = mul(camor, get_rot(0, 1, phi));
  }
};
