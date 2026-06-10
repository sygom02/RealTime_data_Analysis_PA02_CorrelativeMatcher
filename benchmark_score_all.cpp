#include "cartographer_parallel/assignment.h"
#include "cartographer_parallel/profile.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <fstream>
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
  std::string profile_csv;
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
    else if (key == "--profile-csv" && i + 1 < argc) args.profile_csv = argv[++i];
  }
  return args;
}

void WriteCsvHeader(std::ofstream* const csv) {
  if (csv == nullptr || !*csv) return;
  *csv << "iter,total_ms,outer_ms,device_alloc_ms,pinned_alloc_ms,"
       << "h2d_grid_ms,h2d_scan_ms,h2d_cand_ms,h2d_total_ms,kernel_ms,"
       << "d2h_score_ms,sync_ms,cpu_prepost_ms,grid_cells,scan_points,"
       << "candidates,checksum_sample\n";
}

void WriteCsvRow(std::ofstream* const csv, const int iter,
                 const double outer_ms,
                 const cartographer_parallel::ScoreAllProfile& p,
                 const float checksum_sample) {
  if (csv == nullptr || !*csv) return;
  *csv << iter << "," << p.total_ms << "," << outer_ms << ","
       << p.device_alloc_ms << "," << p.pinned_alloc_ms << ","
       << p.h2d_grid_ms << "," << p.h2d_scan_ms << ","
       << p.h2d_cand_ms << "," << p.h2d_total_ms << ","
       << p.kernel_ms << "," << p.d2h_score_ms << ","
       << p.sync_ms << "," << p.cpu_prepost_ms << ","
       << p.grid_cells << "," << p.scan_points << ","
       << p.candidates << "," << checksum_sample << "\n";
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

  std::vector<float> score;
  cartographer_parallel::ResetTotalScoreAllProfile();
  for (int iter = 0; iter < args.warmup; ++iter) {
    cartographer_parallel::score_all(grid, args.width, args.height,
                                     px, py, cx, cy, &score);
  }
  cartographer_parallel::ResetTotalScoreAllProfile();

  double total_ms = 0.0;
  double min_ms = 1e100;
  double max_ms = 0.0;
  float checksum = 0.0f;
  std::ofstream csv;
  if (!args.profile_csv.empty()) {
    csv.open(args.profile_csv);
    WriteCsvHeader(&csv);
  }

  for (int iter = 0; iter < args.iterations; ++iter) {
    cartographer_parallel::ResetLastScoreAllProfile();
    const auto t0 = std::chrono::steady_clock::now();
    cartographer_parallel::score_all(grid, args.width, args.height,
                                     px, py, cx, cy, &score);
    const auto t1 = std::chrono::steady_clock::now();
    const double ms =
        std::chrono::duration<double, std::milli>(t1 - t0).count();
    total_ms += ms;
    min_ms = std::min(min_ms, ms);
    max_ms = std::max(max_ms, ms);
    const float checksum_sample =
        score.empty() ? 0.0f : score[iter % score.size()];
    checksum += checksum_sample;
    WriteCsvRow(&csv, iter, ms, cartographer_parallel::LastScoreAllProfile(),
                checksum_sample);
  }

  const double avg_ms = total_ms / std::max(1, args.iterations);
  const cartographer_parallel::ScoreAllProfile& profile_total =
      cartographer_parallel::TotalScoreAllProfile();
  const double inv_calls =
      1.0 / std::max<std::int64_t>(1, profile_total.call_count);
  const double checks =
      static_cast<double>(args.points) * static_cast<double>(args.candidates);
  const double mchecks_s = checks / (avg_ms * 1000.0);

  std::cout << std::fixed << std::setprecision(3);
  std::cout << "benchmark=score_all"
            << " iterations=" << args.iterations
            << " warmup=" << args.warmup
            << " width=" << args.width
            << " height=" << args.height
            << " points=" << args.points
            << " candidates=" << args.candidates
            << " avg_ms=" << avg_ms
            << " min_ms=" << min_ms
            << " max_ms=" << max_ms
            << " score_all_profile_ms="
            << profile_total.total_ms * inv_calls
            << " device_alloc_ms="
            << profile_total.device_alloc_ms * inv_calls
            << " pinned_alloc_ms="
            << profile_total.pinned_alloc_ms * inv_calls
            << " h2d_grid_ms=" << profile_total.h2d_grid_ms * inv_calls
            << " h2d_scan_ms=" << profile_total.h2d_scan_ms * inv_calls
            << " h2d_cand_ms=" << profile_total.h2d_cand_ms * inv_calls
            << " h2d_total_ms=" << profile_total.h2d_total_ms * inv_calls
            << " kernel_ms=" << profile_total.kernel_ms * inv_calls
            << " d2h_score_ms=" << profile_total.d2h_score_ms * inv_calls
            << " sync_ms=" << profile_total.sync_ms * inv_calls
            << " cpu_prepost_ms="
            << profile_total.cpu_prepost_ms * inv_calls
            << " throughput_mchecks_s=" << mchecks_s
            << " checksum=" << checksum
            << "\n";
  return 0;
}
