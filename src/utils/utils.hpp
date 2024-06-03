#pragma once
#include "../math.hpp"
#include "../objects/objects.hpp"
#include <vector>
#include <algorithm>
#include <array>

std::array<float, 16> get_nearest(const std::vector<RenderObject*>& obj, int idx) {
  std::array<float, 16> result = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
  std::vector<int> indices(obj.size());
  std::iota(indices.begin(), indices.end(), 0);
  std::sort(indices.begin(), indices.end(), [&](int i, int j) {
    return obj[i]->dist(obj[idx]->pos) < obj[j]->dist(obj[idx]->pos);
  });
  for (size_t i = 1; i < std::min((size_t)17, obj.size()); ++i) {
    result[i] = indices[i];
  }
  return result;
}
