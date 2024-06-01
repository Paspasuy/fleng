#pragma once

#include <array>

enum ObjectType {
  SPHERE = 0,
  PLANE = 1,
  CUBOID = 2,
  SERPINSKY_TETRA = 100,
  MANDELBULB = 101,
  FRACTAL_CUBE = 102,
};

class RenderObject {
 public:
  virtual std::array<float, 16> exportData() = 0;
  virtual ~RenderObject() = default;
};
