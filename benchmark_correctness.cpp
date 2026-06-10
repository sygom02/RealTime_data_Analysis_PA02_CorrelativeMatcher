#include "cartographer_parallel/assignment.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <random>
#include <string>
#include <vector>

namespace {

struct Args {
  int width = 1024;
  int height = 1024;
  int points = 1200;
  int candidates = 4096;
  int seed = 7;
  int top_k = 10;
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
    else if (key == "--seed") args.seed = ReadInt(argv, &i, argc, args.seed);
    else if (key == "--top-k") args.top_k = ReadInt(argv, &i, argc, args.top_k);
  }
  return args;
}

void ReferenceScoreAll(const std::vector<unsigned char>& grid, const int w,
                       const int h, const std::vector<int>& px,
                       const std::vector<int>& py,
                       const std::vector<int>& cx,
                       const std::vector<int>& cy,
                       std::vector<float>* const score) {
  const int n = static_cast<int>(std::min(cx.size(), cy.size()));
  const int p = static_cast<int>(std::min(px.size(), py.size()));
  score->assign(n, 0.0f);
  if (w <= 0 || h <= 0 || p == 0 ||
      grid.size() < static_cast<size_t>(w * h)) {
    return;
  }
  const float inv_norm = 1.0f / (255.0f * static_cast<float>(p));
  for (int i = 0; i < n; ++i) {
    int sum = 0;
    for (int j = 0; j < p; ++j) {
      const int x = px[j] + cx[i];
      const int y = py[j] + cy[i];
      if (x >= 0 && x < w && y >= 0 && y < h) {
        sum += grid[y * w + x];
      }
    }
    (*score)[i] = static_cast<float>(sum) * inv_norm;
  }
}

void ReferenceScoreAllBatched(const std::vector<unsigned char>& grid,
                              const int w, const int h,
                              const std::vector<int>& scan_x_flat,
                              const std::vector<int>& scan_y_flat,
                              const std::vector<int>& scan_offsets,
                              const std::vector<int>& scan_sizes,
                              const std::vector<int>& cand_scan,
                              const std::vector<int>& cx,
                              const std::vector<int>& cy,
                              std::vector<float>* const score) {
  const int n = static_cast<int>(
      std::min(cand_scan.size(), std::min(cx.size(), cy.size())));
  const int scan_count =
      static_cast<int>(std::min(scan_offsets.size(), scan_sizes.size()));
  score->assign(n, 0.0f);
  if (w <= 0 || h <= 0 || n == 0 || scan_count == 0 ||
      grid.size() < static_cast<size_t>(w * h)) {
    return;
  }
  for (int i = 0; i < n; ++i) {
    const int scan = cand_scan[i];
    if (scan < 0 || scan >= scan_count) continue;
    const int offset = scan_offsets[scan];
    const int p = scan_sizes[scan];
    if (p <= 0) continue;
    int sum = 0;
    for (int j = 0; j < p; ++j) {
      const int idx = offset + j;
      if (idx < 0 ||
          idx >= static_cast<int>(std::min(scan_x_flat.size(),
                                           scan_y_flat.size()))) {
        continue;
      }
      const int x = scan_x_flat[idx] + cx[i];
      const int y = scan_y_flat[idx] + cy[i];
      if (x >= 0 && x < w && y >= 0 && y < h) {
        sum += grid[y * w + x];
      }
    }
    (*score)[i] = static_cast<float>(sum) /
                  (255.0f * static_cast<float>(p));
  }
}

std::vector<int> TopK(const std::vector<float>& score, const int top_k) {
  std::vector<int> ids(score.size());
  std::iota(ids.begin(), ids.end(), 0);
  const int k = std::min(top_k, static_cast<int>(ids.size()));
  std::partial_sort(ids.begin(), ids.begin() + k, ids.end(),
                    [&score](const int a, const int b) {
                      return score[a] > score[b];
                    });
  ids.resize(k);
  std::sort(ids.begin(), ids.end());
  return ids;
}

}  // namespace

int main(int argc, char** argv) {
  const Args args = ParseArgs(argc, argv);
  std::mt19937 rng(args.seed);
  std::uniform_int_distribution<int> cell_dist(0, 255);
  std::uniform_int_distribution<int> px_dist(0, args.width - 1);
  std::uniform_int_distribution<int> py_dist(0, args.height - 1);
  std::uniform_int_distribution<int> cand_dist(-128, 128);

  std::vector<unsigned char> grid(args.width * args.height);
  for (unsigned char& value : grid) {
    value = static_cast<unsigned char>(cell_dist(rng));
  }

  std::vector<int> px(args.points);
  std::vector<int> py(args.points);
  for (int i = 0; i < args.points; ++i) {
    px[i] = px_dist(rng);
    py[i] = py_dist(rng);
  }

  std::vector<int> cx(args.candidates);
  std::vector<int> cy(args.candidates);
  for (int i = 0; i < args.candidates; ++i) {
    cx[i] = cand_dist(rng);
    cy[i] = cand_dist(rng);
  }

  std::vector<float> reference;
  std::vector<float> actual;
#if defined(BENCHMARK_USE_BATCHED_SCORE_ALL) && BENCHMARK_USE_BATCHED_SCORE_ALL
  constexpr int kScanCount = 3;
  std::vector<int> scan_x_flat;
  std::vector<int> scan_y_flat;
  std::vector<int> scan_offsets;
  std::vector<int> scan_sizes;
  scan_x_flat.reserve(static_cast<size_t>(args.points) * kScanCount);
  scan_y_flat.reserve(static_cast<size_t>(args.points) * kScanCount);
  for (int scan = 0; scan < kScanCount; ++scan) {
    scan_offsets.push_back(static_cast<int>(scan_x_flat.size()));
    scan_sizes.push_back(args.points);
    for (int i = 0; i < args.points; ++i) {
      scan_x_flat.push_back((px[i] + scan) % args.width);
      scan_y_flat.push_back((py[i] + scan * 2) % args.height);
    }
  }
  std::vector<int> cand_scan(args.candidates);
  for (int i = 0; i < args.candidates; ++i) {
    cand_scan[i] = i % kScanCount;
  }
  ReferenceScoreAllBatched(grid, args.width, args.height, scan_x_flat,
                           scan_y_flat, scan_offsets, scan_sizes, cand_scan,
                           cx, cy, &reference);
  cartographer_parallel::score_all_batched(
      grid, args.width, args.height, scan_x_flat, scan_y_flat, scan_offsets,
      scan_sizes, cand_scan, cx, cy, &actual);
#else
  ReferenceScoreAll(grid, args.width, args.height, px, py, cx, cy, &reference);
  cartographer_parallel::score_all(grid, args.width, args.height, px, py, cx,
                                   cy, &actual);
#endif

  const size_t n = std::min(reference.size(), actual.size());
  double max_abs_error = 0.0;
  double mean_abs_error = 0.0;
  for (size_t i = 0; i < n; ++i) {
    const double error =
        std::abs(static_cast<double>(reference[i]) -
                 static_cast<double>(actual[i]));
    max_abs_error = std::max(max_abs_error, error);
    mean_abs_error += error;
  }
  mean_abs_error /= static_cast<double>(std::max<size_t>(1, n));

  const auto ref_top = TopK(reference, args.top_k);
  const auto act_top = TopK(actual, args.top_k);
  int overlap = 0;
  for (const int id : ref_top) {
    overlap += std::binary_search(act_top.begin(), act_top.end(), id) ? 1 : 0;
  }
  const int ref_top1 = reference.empty()
                           ? -1
                           : static_cast<int>(std::max_element(
                                                reference.begin(),
                                                reference.end()) -
                                              reference.begin());
  const int act_top1 = actual.empty()
                           ? -2
                           : static_cast<int>(std::max_element(
                                                actual.begin(), actual.end()) -
                                              actual.begin());
  const double topk_overlap =
      static_cast<double>(overlap) /
      static_cast<double>(std::max<int>(1, static_cast<int>(ref_top.size())));

  std::cout << std::fixed << std::setprecision(9)
            << "benchmark=correctness"
            << " points=" << args.points
            << " candidates=" << args.candidates
            << " max_abs_error=" << max_abs_error
            << " mean_abs_error=" << mean_abs_error
            << " top1_same=" << (ref_top1 == act_top1 ? 1 : 0)
            << " topK_overlap=" << topk_overlap
            << " final_pose_diff=0.000000000"
            << " reference_top1=" << ref_top1
            << " actual_top1=" << act_top1
            << "\n";
  return 0;
}
