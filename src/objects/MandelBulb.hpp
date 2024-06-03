#pragma once

#include "RenderObject.hpp"

class MandelBulb : public RenderObject {
  vec4 color;

 public:
  MandelBulb(vec3 pos, vec4 color)
      : RenderObject(pos),
        color(color) {
  }

  std::array<float, 16> exportData() override {
    return {pos.x, pos.y, pos.z, 0, color.x, color.y, color.z, color.w, ObjectType::MANDELBULB,
            2.0,   50,    0.5,   0, 0,       0,       0};
  }
  ~MandelBulb() = default;
};
