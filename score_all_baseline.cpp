#include "cartographer_parallel/assignment.h"
#include "cartographer_parallel/profile.h"

#include <algorithm>

namespace cartographer_parallel {

void make_cand(const int min_x, const int max_x, const int min_y,
               const int max_y, const int step, std::vector<int>* const cx,
               std::vector<int>* const cy) {
  if (cx == nullptr || cy == nullptr || step <= 0) return;
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
  const int n = std::min(cx.size(), cy.size());
  const int p = std::min(px.size(), py.size());
  score->assign(n, 0.0f);
  if (w <= 0 || h <= 0 || p == 0 || grid.size() < static_cast<size_t>(w * h)) {
    finish_profile();
    return;
  }

  for (int i = 0; i < n; ++i) {
    int sum = 0;
    for (int j = 0; j < p; ++j) {
      const int x = px[j] + cx[i];
      const int y = py[j] + cy[i];
      if (x >= 0 && x < w && y >= 0 && y < h) {
        sum += grid[y * w + x];
      }
    }
    (*score)[i] = static_cast<float>(sum) / (255.0f * static_cast<float>(p));
  }
  finish_profile();
}

}  // namespace cartographer_parallel
