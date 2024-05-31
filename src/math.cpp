#include "math.hpp"

vec2 rot(vec2 v, float alpha) {
  vec2 res;
  res.x = v.x * cos(alpha) - v.y * sin(alpha);
  res.y = v.y * cos(alpha) + v.x * sin(alpha);
  return res;
}

void vec3::rot_xz(float alpha) {
  vec2 susik = rot(vec2(x, z), alpha);
  x = susik.x;
  z = susik.y;
}
void vec3::rot_yz(float alpha) {
  vec2 susik = rot(vec2(y, z), alpha);
  y = susik.x;
  z = susik.y;
}
void vec3::rot_xy(float alpha) {
  vec2 susik = rot(vec2(x, y), alpha);
  x = susik.x;
  y = susik.y;
}

M3x3 mul(M3x3 m1, M3x3 m2) {
  M3x3 ans;
  for (int i = 0; i < 3; ++i) {
    for (int j = 0; j < 3; ++j) {
      ans.a[i][j] = 0;
      for (int k = 0; k < 3; ++k) {
        ans.a[i][j] += m1.a[i][k] * m2.a[k][j];
      }
    }
  }
  return ans;
}

vec3 mul(M3x3& m, vec3& v) {
  vec3 ans;
  ans.x = m.a[0][0] * v.x + m.a[0][1] * v.y + m.a[0][2] * v.z;
  ans.y = m.a[1][0] * v.x + m.a[1][1] * v.y + m.a[1][2] * v.z;
  ans.z = m.a[2][0] * v.x + m.a[2][1] * v.y + m.a[2][2] * v.z;
  return ans;
}

M3x3 get_rot(int a1, int a2, float phi) {
  M3x3 ans;
  ans.a[a1][a1] = cos(phi);
  ans.a[a1][a2] = sin(phi);
  ans.a[a2][a1] = -sin(phi);
  ans.a[a2][a2] = cos(phi);
  return ans;  //.norm();
}
