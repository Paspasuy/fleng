#pragma once

#include <cmath>
#include <SFML/Graphics.hpp>

struct vec2 {
  float x, y;
  vec2(float _x, float _y) {
    x = _x;
    y = _y;
  }
  vec2() {
  }
};

struct vec3 {
  float x, y, z;
  vec3(float _x, float _y, float _z) {
    x = _x;
    y = _y;
    z = _z;
  }
  vec3() {
  }
  vec3 operator+(vec3 p) {
    return vec3(x + p.x, y + p.y, z + p.z);
  }
  void operator+=(vec3 p) {
    x += p.x;
    y += p.y;
    z += p.z;
  }
  void operator-=(vec3 p) {
    x -= p.x;
    y -= p.y;
    z -= p.z;
  }
  vec3 operator-(vec3 p) {
    return vec3(x - p.x, y - p.y, z - p.z);
  }
  vec3 operator*(float p) {
    return vec3(x * p, y * p, z * p);
  }
  float dist(vec3 other) {
    return (other - *this).sz();
  }
  float operator*(vec3 p) {
    return x * p.x + y * p.y + z * p.z;
  }
  float sz() {
    return sqrt(x * x + y * y + z * z);
  }
  vec3 norm() {
    float l = sz();
    return vec3(x / l, y / l, z / l);
  };
  void rot_xz(float alpha);
  void rot_yz(float alpha);
  void rot_xy(float alpha);
  sf::Glsl::Vec3 to_glsl() {
    return sf::Glsl::Vec3(x, y, z);
  }
};

struct vec4 {
  float x, y, z, w;
  vec4(float _x, float _y, float _z, float _w) {
    x = _x;
    y = _y;
    z = _z;
    w = _w;
  }
  vec4() {
  }
};

struct M3x3 {
  float a[3][3];
  M3x3() {
    a[0][0] = a[1][1] = a[2][2] = 1;
    a[0][1] = a[1][0] = a[2][0] = a[0][2] = a[1][2] = a[2][1] = 0;
  }
  vec3 get_x() {
    return vec3(a[0][0], a[1][0], a[2][0]);
  }
  vec3 get_y() {
    return vec3(a[0][1], a[1][1], a[2][1]);
  }
  vec3 get_z() {
    return vec3(a[0][2], a[1][2], a[2][2]);
  }
};

M3x3 mul(M3x3 m1, M3x3 m2);
vec3 mul(M3x3& m, vec3& v);
M3x3 get_rot(int a1, int a2, float phi);
