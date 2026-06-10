#include "cartographer_parallel/fast_matcher.h"
#include "cartographer_parallel/profile.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace {

struct Args {
  std::string map_yaml;
  int iterations = 20;
  int points = 1200;
  bool global = false;
  std::string profile_csv;
  cartographer_parallel::Pose2 initial_pose{-2.0, 6.82,
                                            -3.0255282583321743};
  cartographer_parallel::MatchOpt options;
};

bool Exists(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  return static_cast<bool>(in);
}

std::string DefaultMapPath() {
  const std::vector<std::string> candidates = {
      "maps/0501.yaml",
      "../maps/0501.yaml",
      "../carrographer_task_ros2/carrographer_task_ros2/maps/0501.yaml",
      "../../carrographer_task_ros2/carrographer_task_ros2/maps/0501.yaml",
  };
  for (const std::string& path : candidates) {
    if (Exists(path)) return path;
  }
  return "";
}

double ReadDouble(char** argv, int* i, int argc, double fallback) {
  if (*i + 1 >= argc) return fallback;
  ++(*i);
  return std::atof(argv[*i]);
}

int ReadInt(char** argv, int* i, int argc, int fallback) {
  if (*i + 1 >= argc) return fallback;
  ++(*i);
  return std::atoi(argv[*i]);
}

Args ParseArgs(int argc, char** argv) {
  Args args;
  args.options.linear_window = 3.0;
  args.options.global_window = 20.0;
  args.options.full_map_search = false;
  args.options.angular_window = 0.35;
  args.options.angular_step = 0.05;
  args.options.branch_depth = 4;
  args.options.min_score = 0.05f;
  args.options.max_cand = 150;

  for (int i = 1; i < argc; ++i) {
    const std::string key = argv[i];
    if (key == "--map" && i + 1 < argc) args.map_yaml = argv[++i];
    else if (key == "--profile-csv" && i + 1 < argc) args.profile_csv = argv[++i];
    else if (key == "--iters") args.iterations = ReadInt(argv, &i, argc, args.iterations);
    else if (key == "--points") args.points = ReadInt(argv, &i, argc, args.points);
    else if (key == "--global") args.global = true;
    else if (key == "--initial-x") args.initial_pose.x = ReadDouble(argv, &i, argc, args.initial_pose.x);
    else if (key == "--initial-y") args.initial_pose.y = ReadDouble(argv, &i, argc, args.initial_pose.y);
    else if (key == "--initial-yaw") args.initial_pose.yaw = ReadDouble(argv, &i, argc, args.initial_pose.yaw);
    else if (key == "--linear-window") args.options.linear_window = ReadDouble(argv, &i, argc, args.options.linear_window);
    else if (key == "--global-window") args.options.global_window = ReadDouble(argv, &i, argc, args.options.global_window);
    else if (key == "--full-map-search") args.options.full_map_search = true;
    else if (key == "--angular-window") args.options.angular_window = ReadDouble(argv, &i, argc, args.options.angular_window);
    else if (key == "--angular-step") args.options.angular_step = ReadDouble(argv, &i, argc, args.options.angular_step);
    else if (key == "--branch-depth") args.options.branch_depth = ReadInt(argv, &i, argc, args.options.branch_depth);
    else if (key == "--min-score") args.options.min_score = static_cast<float>(ReadDouble(argv, &i, argc, args.options.min_score));
    else if (key == "--max-candidates") args.options.max_cand = ReadInt(argv, &i, argc, args.options.max_cand);
  }

  if (args.map_yaml.empty()) args.map_yaml = DefaultMapPath();
  return args;
}

void AddProfile(cartographer_parallel::MatchProfile* const total,
                const cartographer_parallel::MatchProfile& sample) {
  total->match_total_ms += sample.match_total_ms;
  total->make_scans_ms += sample.make_scans_ms;
  total->make_bounds_ms += sample.make_bounds_ms;
  total->make_grid_stack_ms += sample.make_grid_stack_ms;
  total->make_low_cands_ms += sample.make_low_cands_ms;
  total->branch_ms += sample.branch_ms;
  total->to_out_ms += sample.to_out_ms;
  total->coarse_cand_count += sample.coarse_cand_count;
  total->branch_call_count += sample.branch_call_count;
  total->child_cand_count += sample.child_cand_count;
  total->scan_count += sample.scan_count;
  total->scan_points += sample.scan_points;
  total->score.score_total_ms += sample.score.score_total_ms;
  total->score.score_grouping_ms += sample.score.score_grouping_ms;
  total->score.score_vector_alloc_ms += sample.score.score_vector_alloc_ms;
  total->score.score_all_only_ms += sample.score.score_all_only_ms;
  total->score.score_writeback_ms += sample.score.score_writeback_ms;
  total->score.score_sort_ms += sample.score.score_sort_ms;
  total->score.score_call_count += sample.score.score_call_count;
  total->score.score_all_call_count += sample.score.score_all_call_count;
  total->score.score_nonempty_scan_groups +=
      sample.score.score_nonempty_scan_groups;
  total->score.batched_score_all_call_count +=
      sample.score.batched_score_all_call_count;
  total->score.batch_candidate_count += sample.score.batch_candidate_count;
  total->score.batch_scan_count += sample.score.batch_scan_count;
  total->score.score_vector_alloc_count +=
      sample.score.score_vector_alloc_count;
  total->score.cand_count_total += sample.score.cand_count_total;
  total->score.max_cand_count =
      std::max(total->score.max_cand_count, sample.score.max_cand_count);
}

void AddScoreAllProfileTotal(cartographer_parallel::ScoreAllProfile* const total,
                             const cartographer_parallel::ScoreAllProfile& sample) {
  total->total_ms += sample.total_ms;
  total->device_alloc_ms += sample.device_alloc_ms;
  total->pinned_alloc_ms += sample.pinned_alloc_ms;
  total->h2d_grid_ms += sample.h2d_grid_ms;
  total->h2d_scan_ms += sample.h2d_scan_ms;
  total->h2d_cand_ms += sample.h2d_cand_ms;
  total->h2d_total_ms += sample.h2d_total_ms;
  total->kernel_ms += sample.kernel_ms;
  total->d2h_score_ms += sample.d2h_score_ms;
  total->sync_ms += sample.sync_ms;
  total->cpu_prepost_ms += sample.cpu_prepost_ms;
  total->call_count += sample.call_count;
  total->grid_cells += sample.grid_cells;
  total->scan_points += sample.scan_points;
  total->candidates += sample.candidates;
}

void WriteCsvHeader(std::ofstream* const csv) {
  if (csv == nullptr || !*csv) return;
  *csv << "iter,ok,match_total_ms,make_scans_ms,make_bounds_ms,"
       << "make_grid_stack_ms,make_low_cands_ms,coarse_cand_count,"
       << "score_total_ms,score_call_count,score_all_call_count,"
       << "batched_score_all_call_count,batch_candidate_count,"
       << "batch_scan_count,"
       << "score_grouping_ms,score_vector_alloc_ms,"
       << "score_vector_alloc_count,score_all_only_ms,"
       << "score_writeback_ms,score_sort_ms,cand_count_total,"
       << "max_cand_count,branch_ms,branch_call_count,child_cand_count,"
       << "to_out_ms,scan_count,scan_points,score_all_profile_ms,"
       << "device_alloc_ms,pinned_alloc_ms,h2d_grid_ms,h2d_scan_ms,"
       << "h2d_cand_ms,h2d_total_ms,kernel_ms,d2h_score_ms,sync_ms,"
       << "cpu_prepost_ms,last_score,last_pose_x,last_pose_y,last_pose_yaw\n";
}

void WriteCsvRow(std::ofstream* const csv, const int iter, const bool ok,
                 const cartographer_parallel::MatchProfile& p,
                 const cartographer_parallel::ScoreAllProfile& score_all_profile,
                 const cartographer_parallel::MatchOut& out) {
  if (csv == nullptr || !*csv) return;
  *csv << iter << "," << (ok ? 1 : 0) << ","
       << p.match_total_ms << "," << p.make_scans_ms << ","
       << p.make_bounds_ms << "," << p.make_grid_stack_ms << ","
       << p.make_low_cands_ms << "," << p.coarse_cand_count << ","
       << p.score.score_total_ms << "," << p.score.score_call_count << ","
       << p.score.score_all_call_count << ","
       << p.score.batched_score_all_call_count << ","
       << p.score.batch_candidate_count << "," << p.score.batch_scan_count << ","
       << p.score.score_grouping_ms << ","
       << p.score.score_vector_alloc_ms << ","
       << p.score.score_vector_alloc_count << ","
       << p.score.score_all_only_ms << ","
       << p.score.score_writeback_ms << ","
       << p.score.score_sort_ms << ","
       << p.score.cand_count_total << "," << p.score.max_cand_count << ","
       << p.branch_ms << "," << p.branch_call_count << ","
       << p.child_cand_count << "," << p.to_out_ms << ","
       << p.scan_count << "," << p.scan_points << ","
       << score_all_profile.total_ms << "," << score_all_profile.device_alloc_ms
       << "," << score_all_profile.pinned_alloc_ms << ","
       << score_all_profile.h2d_grid_ms << ","
       << score_all_profile.h2d_scan_ms << ","
       << score_all_profile.h2d_cand_ms << ","
       << score_all_profile.h2d_total_ms << ","
       << score_all_profile.kernel_ms << ","
       << score_all_profile.d2h_score_ms << ","
       << score_all_profile.sync_ms << ","
       << score_all_profile.cpu_prepost_ms << ","
       << out.score << "," << out.pose.x << "," << out.pose.y << ","
       << out.pose.yaw << "\n";
}

void GenerateScanFromMap(const cartographer_parallel::FastMatcher& matcher,
                         const cartographer_parallel::Pose2& pose,
                         const int target_points,
                         std::vector<float>* xs,
                         std::vector<float>* ys) {
  xs->clear();
  ys->clear();
  xs->reserve(target_points);
  ys->reserve(target_points);

  struct Point {
    int x;
    int y;
  };
  std::vector<Point> occupied;
  const std::vector<unsigned char>& map = matcher.map();
  const int w = matcher.width();
  const int h = matcher.height();
  const double res = matcher.resolution();
  const double c = std::cos(pose.yaw);
  const double s = std::sin(pose.yaw);
  const double max_range = 12.0;

  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      if (map[y * w + x] < 200) continue;
      const int row_bottom = h - 1 - y;
      const double wx = matcher.origin_x() + (x + 0.5) * res;
      const double wy = matcher.origin_y() + (row_bottom + 0.5) * res;
      const double dx = wx - pose.x;
      const double dy = wy - pose.y;
      if (std::hypot(dx, dy) <= max_range) occupied.push_back({x, y});
    }
  }

  if (!occupied.empty()) {
    const int stride =
        std::max(1, static_cast<int>(occupied.size()) / target_points);
    for (size_t k = 0; k < occupied.size() &&
                       static_cast<int>(xs->size()) < target_points;
         k += stride) {
      const Point p = occupied[k];
      const int row_bottom = h - 1 - p.y;
      const double wx = matcher.origin_x() + (p.x + 0.5) * res;
      const double wy = matcher.origin_y() + (row_bottom + 0.5) * res;
      const double dx = wx - pose.x;
      const double dy = wy - pose.y;
      xs->push_back(static_cast<float>(c * dx + s * dy));
      ys->push_back(static_cast<float>(-s * dx + c * dy));
    }
  }

  if (xs->empty()) {
    for (int i = 0; i < target_points; ++i) {
      const double a = 2.0 * M_PI * i / std::max(1, target_points);
      const double r = 2.0 + 0.01 * (i % 300);
      xs->push_back(static_cast<float>(r * std::cos(a)));
      ys->push_back(static_cast<float>(r * std::sin(a)));
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  const Args args = ParseArgs(argc, argv);
  if (args.map_yaml.empty()) {
    std::cerr << "Map YAML not found. Pass --map path/to/0501.yaml\n";
    return 2;
  }

  cartographer_parallel::FastMatcher matcher;
  matcher.SetOptions(args.options);
  if (!matcher.LoadMap(args.map_yaml)) {
    std::cerr << "Failed to load map: " << args.map_yaml << "\n";
    return 3;
  }

  std::vector<float> xs;
  std::vector<float> ys;
  GenerateScanFromMap(matcher, args.initial_pose, args.points, &xs, &ys);

  cartographer_parallel::MatchOut out;
  for (int i = 0; i < 3; ++i) {
    matcher.Match(xs, ys, args.initial_pose, args.global, &out);
  }

  double total_ms = 0.0;
  double min_ms = 1e100;
  double max_ms = 0.0;
  int ok_count = 0;
  cartographer_parallel::MatchProfile profile_total;
  cartographer_parallel::ScoreAllProfile score_all_profile_total;
  std::ofstream csv;
  if (!args.profile_csv.empty()) {
    csv.open(args.profile_csv);
    WriteCsvHeader(&csv);
  }
  for (int iter = 0; iter < args.iterations; ++iter) {
    cartographer_parallel::ResetTotalScoreAllProfile();
    const auto t0 = std::chrono::steady_clock::now();
    const bool ok = matcher.Match(xs, ys, args.initial_pose, args.global, &out);
    const auto t1 = std::chrono::steady_clock::now();
    const double ms =
        std::chrono::duration<double, std::milli>(t1 - t0).count();
    total_ms += ms;
    min_ms = std::min(min_ms, ms);
    max_ms = std::max(max_ms, ms);
    ok_count += ok ? 1 : 0;
    const cartographer_parallel::MatchProfile& profile =
        matcher.last_profile();
    const cartographer_parallel::ScoreAllProfile& score_all_profile =
        cartographer_parallel::TotalScoreAllProfile();
    AddProfile(&profile_total, profile);
    AddScoreAllProfileTotal(&score_all_profile_total, score_all_profile);
    WriteCsvRow(&csv, iter, ok, profile, score_all_profile, out);
  }

  const double avg_ms = total_ms / std::max(1, args.iterations);
  const double inv_iters = 1.0 / std::max(1, args.iterations);
  const double avg_score_call_count =
      profile_total.score.score_call_count * inv_iters;
  const double avg_score_cands =
      profile_total.score.score_call_count == 0
          ? 0.0
          : static_cast<double>(profile_total.score.cand_count_total) /
                static_cast<double>(profile_total.score.score_call_count);
  std::cout << std::fixed << std::setprecision(3);
  std::cout << "benchmark=matcher"
            << " map=" << args.map_yaml
            << " iterations=" << args.iterations
            << " scan_points=" << xs.size()
            << " global=" << (args.global ? 1 : 0)
            << " avg_ms=" << avg_ms
            << " min_ms=" << min_ms
            << " max_ms=" << max_ms
            << " match_total_ms=" << profile_total.match_total_ms * inv_iters
            << " make_scans_ms=" << profile_total.make_scans_ms * inv_iters
            << " make_bounds_ms=" << profile_total.make_bounds_ms * inv_iters
            << " make_grid_stack_ms="
            << profile_total.make_grid_stack_ms * inv_iters
            << " make_low_cands_ms="
            << profile_total.make_low_cands_ms * inv_iters
            << " coarse_cand_count="
            << profile_total.coarse_cand_count * inv_iters
            << " score_total_ms="
            << profile_total.score.score_total_ms * inv_iters
            << " score_call_count=" << avg_score_call_count
            << " score_all_call_count="
            << profile_total.score.score_all_call_count * inv_iters
            << " batched_score_all_call_count="
            << profile_total.score.batched_score_all_call_count * inv_iters
            << " batch_candidate_count="
            << profile_total.score.batch_candidate_count * inv_iters
            << " batch_scan_count="
            << profile_total.score.batch_scan_count * inv_iters
            << " score_grouping_ms="
            << profile_total.score.score_grouping_ms * inv_iters
            << " score_vector_alloc_ms="
            << profile_total.score.score_vector_alloc_ms * inv_iters
            << " score_vector_alloc_count="
            << profile_total.score.score_vector_alloc_count * inv_iters
            << " score_all_only_ms="
            << profile_total.score.score_all_only_ms * inv_iters
            << " score_writeback_ms="
            << profile_total.score.score_writeback_ms * inv_iters
            << " score_sort_ms="
            << profile_total.score.score_sort_ms * inv_iters
            << " cand_count_per_score_call=" << avg_score_cands
            << " score_all_profile_ms="
            << score_all_profile_total.total_ms * inv_iters
            << " device_alloc_ms="
            << score_all_profile_total.device_alloc_ms * inv_iters
            << " pinned_alloc_ms="
            << score_all_profile_total.pinned_alloc_ms * inv_iters
            << " h2d_grid_ms="
            << score_all_profile_total.h2d_grid_ms * inv_iters
            << " h2d_scan_ms="
            << score_all_profile_total.h2d_scan_ms * inv_iters
            << " h2d_cand_ms="
            << score_all_profile_total.h2d_cand_ms * inv_iters
            << " h2d_total_ms="
            << score_all_profile_total.h2d_total_ms * inv_iters
            << " kernel_ms="
            << score_all_profile_total.kernel_ms * inv_iters
            << " d2h_score_ms="
            << score_all_profile_total.d2h_score_ms * inv_iters
            << " sync_ms=" << score_all_profile_total.sync_ms * inv_iters
            << " cpu_prepost_ms="
            << score_all_profile_total.cpu_prepost_ms * inv_iters
            << " branch_ms=" << profile_total.branch_ms * inv_iters
            << " branch_call_count="
            << profile_total.branch_call_count * inv_iters
            << " child_cand_count=" << profile_total.child_cand_count * inv_iters
            << " to_out_ms=" << profile_total.to_out_ms * inv_iters
            << " ok_count=" << ok_count
            << " last_score=" << out.score
            << " last_pose_x=" << out.pose.x
            << " last_pose_y=" << out.pose.y
            << " last_pose_yaw=" << out.pose.yaw
            << " top_candidates=" << out.cand.size()
            << "\n";
  return 0;
}
