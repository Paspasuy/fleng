#pragma once

#include "RenderObject.hpp"

class FractalCube : public RenderObject {
  // Actually this is Mandelbox
  vec3 pos;
  vec4 color;

 public:
  FractalCube() = default;

  FractalCube(vec4 color)
      : color(color) {
  }

  std::array<float, 16> exportData() override {
    return {0, 0, 0, 0, color.x, color.y, color.z, color.w, ObjectType::FRACTAL_CUBE, 2.0, 50, 0.5, 0, 0, 0, 0};
  }
  ~FractalCube() = default;
};
