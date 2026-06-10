#include "cartographer_parallel/assignment.h"
#include "cartographer_parallel/profile.h"

#include <algorithm>

namespace cartographer_parallel {

void make_cand(const int min_x, const int max_x, const int min_y,
               const int max_y, const int step, std::vector<int>* const cx,
               std::vector<int>* const cy) {
  if (cx == nullptr || cy == nullptr || step <= 0) return;
  const int nx = max_x >= min_x ? (max_x - min_x) / step + 1 : 0;
  const int ny = max_y >= min_y ? (max_y - min_y) / step + 1 : 0;
  cx->reserve(cx->size() + static_cast<size_t>(nx) * ny);
  cy->reserve(cy->size() + static_cast<size_t>(nx) * ny);
  for (int x = min_x; x <= max_x; x += step) {
    for (int y = min_y; y <= max_y; y += step) {
      cx->push_back(x);
      cy->push_back(y);
    }
  }
}

void score_all(const std::vector<unsigned char>& grid, const int w,
               const int h, const std::vector<int>& px,
               const std::vector<int>& py, const std::vector<int>& cx,
               const std::vector<int>& cy, std::vector<float>* const score) {
  if (score == nullptr) return;
  ScoreAllProfile profile;
  profile.call_count = 1;
  profile.grid_cells = static_cast<std::int64_t>(grid.size());
  profile.scan_points = static_cast<std::int64_t>(std::min(px.size(), py.size()));
  profile.candidates = static_cast<std::int64_t>(std::min(cx.size(), cy.size()));
  ResetLastScoreAllProfile();
  const auto profile_start = ProfileClock::now();
  const auto finish_profile = [&profile, profile_start]() {
    profile.total_ms = ProfileMsSince(profile_start);
    MutableLastScoreAllProfile() = profile;
    AddScoreAllProfile(profile);
  };
  const int n = static_cast<int>(std::min(cx.size(), cy.size()));
  const int p = static_cast<int>(std::min(px.size(), py.size()));
  score->assign(n, 0.0f);
  if (w <= 0 || h <= 0 || p == 0 || grid.size() < static_cast<size_t>(w * h)) {
    finish_profile();
    return;
  }

  int min_px = px[0];
  int max_px = px[0];
  int min_py = py[0];
  int max_py = py[0];
  std::vector<int> scan_offsets(p);
  for (int j = 0; j < p; ++j) {
    min_px = std::min(min_px, px[j]);
    max_px = std::max(max_px, px[j]);
    min_py = std::min(min_py, py[j]);
    max_py = std::max(max_py, py[j]);
    scan_offsets[j] = py[j] * w + px[j];
  }

  const float inv_norm = 1.0f / (255.0f * static_cast<float>(p));
  const unsigned char* const grid_data = grid.data();
  float* const score_data = score->data();

  for (int i = 0; i < n; ++i) {
    const int ox = cx[i];
    const int oy = cy[i];
    const bool all_inside = ox + min_px >= 0 && ox + max_px < w &&
                            oy + min_py >= 0 && oy + max_py < h;
    int sum = 0;
    if (all_inside) {
      const int base = oy * w + ox;
      for (int j = 0; j < p; ++j) {
        sum += grid_data[base + scan_offsets[j]];
      }
    } else {
      if (ox + max_px < 0 || ox + min_px >= w ||
          oy + max_py < 0 || oy + min_py >= h) {
        continue;
      }
      for (int j = 0; j < p; ++j) {
        const int x = px[j] + ox;
        const int y = py[j] + oy;
        if (x >= 0 && x < w && y >= 0 && y < h) {
          sum += grid_data[y * w + x];
        }
      }
    }
    score_data[i] = static_cast<float>(sum) * inv_norm;
  }
  finish_profile();
}

}  // namespace cartographer_parallel
