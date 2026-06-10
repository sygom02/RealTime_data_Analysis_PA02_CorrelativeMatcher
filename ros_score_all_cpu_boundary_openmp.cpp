#include "cartographer_parallel/assignment.h"

#include <algorithm>
#include <vector>

namespace cartographer_parallel {

Candidate make_cand(int idx, int x, int y, int stride, int nx) {
  Candidate c;
  c.x = (idx % nx) * stride + x;
  c.y = (idx / nx) * stride + y;
  c.score = 0.0f;
  return c;
}

std::vector<Candidate> make_low_res_cands(int nx, int ny, int stride) {
  std::vector<Candidate> candidates;
  candidates.reserve(static_cast<size_t>(nx) * static_cast<size_t>(ny));
  for (int iy = 0; iy < ny; ++iy) {
    for (int ix = 0; ix < nx; ++ix) {
      candidates.push_back(make_cand(iy * nx + ix, 0, 0, stride, nx));
    }
  }
  return candidates;
}

void score_all(const Grid& grid, const std::vector<Point>& scan,
               const std::vector<int>& xs, const std::vector<int>& ys,
               std::vector<float>* scores) {
  const size_t n = xs.size();
  scores->assign(n, 0.0f);
  if (ys.size() != n || scan.empty() || n == 0 || grid.data.empty() ||
      grid.width <= 0 || grid.height <= 0) {
    return;
  }

  const int width = grid.width;
  const int height = grid.height;
  const float* data = grid.data.data();
  float* out = scores->data();

#pragma omp parallel for schedule(static)
  for (int i = 0; i < static_cast<int>(n); ++i) {
    const int base_x = xs[static_cast<size_t>(i)];
    const int base_y = ys[static_cast<size_t>(i)];
    float sum = 0.0f;
    int cnt = 0;
    for (const auto& p : scan) {
      const int x = base_x + static_cast<int>(p.x);
      const int y = base_y + static_cast<int>(p.y);
      if (static_cast<unsigned>(x) < static_cast<unsigned>(width) &&
          static_cast<unsigned>(y) < static_cast<unsigned>(height)) {
        sum += data[static_cast<size_t>(y) * static_cast<size_t>(width) +
                    static_cast<size_t>(x)];
        ++cnt;
      }
    }
    out[static_cast<size_t>(i)] = cnt > 0 ? sum / static_cast<float>(cnt) : 0.0f;
  }
}

std::vector<Candidate> branch_and_bound(const Grid& grid,
                                        const std::vector<Point>& scan,
                                        const std::vector<Candidate>& low,
                                        int levels, int top_k) {
  std::vector<Candidate> current = low;
  for (int l = 0; l < levels; ++l) {
    std::vector<Candidate> next;
    next.reserve(current.size() * 4);
    for (const auto& c : current) {
      for (int dy = 0; dy < 2; ++dy) {
        for (int dx = 0; dx < 2; ++dx) {
          Candidate child = c;
          child.x = c.x * 2 + dx;
          child.y = c.y * 2 + dy;
          next.push_back(child);
        }
      }
    }

    std::vector<int> xs(next.size());
    std::vector<int> ys(next.size());
    for (size_t i = 0; i < next.size(); ++i) {
      xs[i] = next[i].x;
      ys[i] = next[i].y;
    }

    std::vector<float> scores;
    score_all(grid, scan, xs, ys, &scores);
    for (size_t i = 0; i < next.size(); ++i) {
      next[i].score = scores[i];
    }

    std::sort(next.begin(), next.end(),
              [](const Candidate& a, const Candidate& b) {
                return a.score > b.score;
              });
    if (static_cast<int>(next.size()) > top_k) {
      next.resize(static_cast<size_t>(top_k));
    }
    current.swap(next);
  }
  return current;
}

}  // namespace cartographer_parallel
