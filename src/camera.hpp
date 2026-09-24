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
    campos = vec3(1.0, 2.0, -3.0);
    camor = M3x3();
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
