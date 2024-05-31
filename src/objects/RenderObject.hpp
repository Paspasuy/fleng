#pragma once

#include <array>

enum ObjectType {
  SPHERE = 0,
  PLANE = 1,
  FRACTAL_CUBE = 102,
};

class RenderObject {
 public:
  virtual std::array<float, 16> exportData() = 0;
  virtual ~RenderObject() = default;
};
