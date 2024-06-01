#pragma once

#include "RenderObject.hpp"

class SerpinskyTetrahedron : public RenderObject {
  vec3 pos;
  vec4 color;

 public:
  SerpinskyTetrahedron() = default;

  SerpinskyTetrahedron(vec4 color)
      : color(color) {
  }

  std::array<float, 16> exportData() override {
    return {0, 0, 0, 0, color.x, color.y, color.z, color.w, ObjectType::SERPINSKY_TETRA, 2.0, 50, 0.5, 0, 0, 0, 0};
  }
  ~SerpinskyTetrahedron() = default;
};
