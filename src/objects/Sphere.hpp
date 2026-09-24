#pragma once

#include "RenderObject.hpp"

class Sphere : public RenderObject {
  public:
  vec4 color;
  vec4 prop;  // (radius, , , )
  bool refracting;

 public:
  Sphere(vec3 pos, vec4 color, float radius, bool refracting = false)
      : RenderObject(pos),
        color(color),
        prop(radius, 0, 0, 0),
        refracting(refracting) {
  }

  std::array<float, 16> exportData() override {
    return {pos.x, pos.y, pos.z, 0, color.x, color.y, color.z, color.w, static_cast<float>(refracting ? ObjectType::REFRACTING_SPHERE : ObjectType::SPHERE), prop.x, 0, 0, 0, 0, 0, 0};
  }
  float dist(vec3 point) override {
    return pos.dist(point) - prop.x;
  }
  ~Sphere() = default;
};
