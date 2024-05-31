#pragma once

#include <array>

class RenderObject {
 public:
  virtual std::array<float, 16> exportData() = 0;
  virtual ~RenderObject() = default;
};
