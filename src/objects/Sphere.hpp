#pragma once

#include "RenderObject.hpp"

class Sphere : public RenderObject {
  vec4 color;
  vec4 prop;  // (radius, , , )

 public:
  Sphere(vec3 pos, vec4 color, float radius)
      : RenderObject(pos),
        color(color),
        prop(radius, 0, 0, 0) {
  }

  std::array<float, 16> exportData() override {
    return {pos.x, pos.y, pos.z, 0, color.x, color.y, color.z, color.w, ObjectType::SPHERE, prop.x, 0, 0, 0, 0, 0, 0};
  }
  float dist(vec3 point) override {
    return pos.dist(point) - prop.x;
  }
  ~Sphere() = default;
};
