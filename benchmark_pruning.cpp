#include "cartographer_parallel/assignment.h"
#include "cartographer_parallel/profile.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <random>
#include <string>
#include <vector>

namespace {

struct Args {
  int width = 1024;
  int height = 1024;
  int points = 1200;
  int candidates = 4096;
  int iterations = 20;
  int warmup = 3;
  int seed = 7;
};

int ReadInt(char** argv, int* i, int argc, int fallback) {
  if (*i + 1 >= argc) return fallback;
  ++(*i);
  return std::atoi(argv[*i]);
}

Args ParseArgs(int argc, char** argv) {
  Args args;
  for (int i = 1; i < argc; ++i) {
    const std::string key = argv[i];
    if (key == "--w") args.width = ReadInt(argv, &i, argc, args.width);
    else if (key == "--h") args.height = ReadInt(argv, &i, argc, args.height);
    else if (key == "--points") args.points = ReadInt(argv, &i, argc, args.points);
    else if (key == "--candidates") args.candidates = ReadInt(argv, &i, argc, args.candidates);
    else if (key == "--iters") args.iterations = ReadInt(argv, &i, argc, args.iterations);
    else if (key == "--warmup") args.warmup = ReadInt(argv, &i, argc, args.warmup);
    else if (key == "--seed") args.seed = ReadInt(argv, &i, argc, args.seed);
  }
  return args;
}

double MsSince(const std::chrono::steady_clock::time_point start) {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now() - start)
      .count();
}

double RunScore(const std::vector<unsigned char>& grid, const int w,
                const int h, const std::vector<int>& px,
                const std::vector<int>& py, const std::vector<int>& cx,
                const std::vector<int>& cy, std::vector<float>* const score) {
  const auto start = std::chrono::steady_clock::now();
  cartographer_parallel::score_all(grid, w, h, px, py, cx, cy, score);
  return MsSince(start);
}

}  // namespace

int main(int argc, char** argv) {
  const Args args = ParseArgs(argc, argv);
  std::mt19937 rng(args.seed);
  std::uniform_int_distribution<int> cell_dist(0, 255);
  std::uniform_int_distribution<int> px_dist(0, args.width - 1);
  std::uniform_int_distribution<int> py_dist(0, args.height - 1);
  std::uniform_int_distribution<int> cand_dist(-args.width, args.width);

  std::vector<unsigned char> grid(args.width * args.height);
  for (unsigned char& value : grid) {
    value = static_cast<unsigned char>(cell_dist(rng));
  }

  std::vector<int> px(args.points);
  std::vector<int> py(args.points);
  int min_px = args.width;
  int max_px = 0;
  int min_py = args.height;
  int max_py = 0;
  for (int i = 0; i < args.points; ++i) {
    px[i] = px_dist(rng);
    py[i] = py_dist(rng);
    min_px = std::min(min_px, px[i]);
    max_px = std::max(max_px, px[i]);
    min_py = std::min(min_py, py[i]);
    max_py = std::max(max_py, py[i]);
  }

  std::vector<int> cx(args.candidates);
  std::vector<int> cy(args.candidates);
  for (int i = 0; i < args.candidates; ++i) {
    cx[i] = cand_dist(rng);
    cy[i] = cand_dist(rng);
  }

  std::vector<int> pruned_cx;
  std::vector<int> pruned_cy;
  pruned_cx.reserve(cx.size());
  pruned_cy.reserve(cy.size());

  double pruning_ms = 0.0;
  for (int iter = 0; iter < args.iterations; ++iter) {
    pruned_cx.clear();
    pruned_cy.clear();
    const auto prune_start = std::chrono::steady_clock::now();
    for (size_t i = 0; i < cx.size() && i < cy.size(); ++i) {
      const int ox = cx[i];
      const int oy = cy[i];
      const bool all_outside = ox + max_px < 0 || ox + min_px >= args.width ||
                               oy + max_py < 0 || oy + min_py >= args.height;
      if (!all_outside) {
        pruned_cx.push_back(ox);
        pruned_cy.push_back(oy);
      }
    }
    pruning_ms += MsSince(prune_start);
  }
  pruning_ms /= std::max(1, args.iterations);

  std::vector<float> score;
  for (int iter = 0; iter < args.warmup; ++iter) {
    RunScore(grid, args.width, args.height, px, py, cx, cy, &score);
    RunScore(grid, args.width, args.height, px, py, pruned_cx, pruned_cy,
             &score);
  }

  double full_ms = 0.0;
  double pruned_ms = 0.0;
  double full_kernel_ms = 0.0;
  double pruned_kernel_ms = 0.0;
  for (int iter = 0; iter < args.iterations; ++iter) {
    cartographer_parallel::ResetLastScoreAllProfile();
    full_ms += RunScore(grid, args.width, args.height, px, py, cx, cy, &score);
    full_kernel_ms += cartographer_parallel::LastScoreAllProfile().kernel_ms;

    cartographer_parallel::ResetLastScoreAllProfile();
    pruned_ms += RunScore(grid, args.width, args.height, px, py, pruned_cx,
                          pruned_cy, &score);
    pruned_kernel_ms += cartographer_parallel::LastScoreAllProfile().kernel_ms;
  }
  full_ms /= std::max(1, args.iterations);
  pruned_ms /= std::max(1, args.iterations);
  full_kernel_ms /= std::max(1, args.iterations);
  pruned_kernel_ms /= std::max(1, args.iterations);

  const double pruned_ratio =
      1.0 - static_cast<double>(pruned_cx.size()) /
                static_cast<double>(std::max<size_t>(1, cx.size()));
  const double saved_ms = full_ms - pruned_ms;
  const double kernel_saved_ms =
      full_kernel_ms > 0.0 ? full_kernel_ms - pruned_kernel_ms : saved_ms;
  const double net_gain_ms = kernel_saved_ms - pruning_ms;

  std::cout << std::fixed << std::setprecision(3)
            << "benchmark=pruning"
            << " iterations=" << args.iterations
            << " points=" << args.points
            << " candidate_before=" << cx.size()
            << " candidate_after=" << pruned_cx.size()
            << " pruned_ratio=" << pruned_ratio
            << " pruning_ms=" << pruning_ms
            << " full_score_ms=" << full_ms
            << " pruned_score_ms=" << pruned_ms
            << " saved_score_ms=" << saved_ms
            << " kernel_saved_ms=" << kernel_saved_ms
            << " net_gain_ms=" << net_gain_ms
            << "\n";
  return 0;
}
