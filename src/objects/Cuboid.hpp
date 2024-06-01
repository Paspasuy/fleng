#pragma once

#include "RenderObject.hpp"

class Cuboid : public RenderObject {
  vec3 pos;
  vec4 color;
  vec4 prop;  // (rx, ry, rz, )

 public:
  Cuboid() {
  }

  Cuboid(vec3 pos, vec4 color, float radius)
      : pos(pos),
        color(color),
        prop(radius, radius, radius, 0) {
  }

  Cuboid(vec3 pos, vec4 color, vec3 radii)
      : pos(pos),
        color(color),
        prop(radii.x, radii.y, radii.z, 0) {
  }

  std::array<float, 16> exportData() override {
    return {pos.x,  pos.y,  pos.z,  0, color.x, color.y, color.z, color.w, ObjectType::CUBOID,
            prop.x, prop.y, prop.z, 0, 0,       0,       0};
  }
  ~Cuboid() = default;
};
