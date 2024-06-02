#pragma once

#include "RenderObject.hpp"

class Plane : public RenderObject {
  vec3 pos;
  vec4 color;
  vec3 norm;

 public:
  Plane() {
  }

  Plane(vec3 pos, vec4 color, vec3 norm)
      : pos(pos),
        color(color),
        norm(norm.norm()) {
  }

  std::array<float, 16> exportData() override {
    return {pos.x,  pos.y,  pos.z,  0, color.x, color.y, color.z, color.w, ObjectType::PLANE,
            norm.x, norm.y, norm.z, 0, 0,       0,       0};
  }
  ~Plane() = default;  // TODO: override?
};
