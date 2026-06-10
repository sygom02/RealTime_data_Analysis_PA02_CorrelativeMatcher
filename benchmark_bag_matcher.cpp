#include "cartographer_parallel/fast_matcher.h"
#include "cartographer_parallel/profile.h"

#include <rosbag/bag.h>
#include <rosbag/view.h>
#include <sensor_msgs/LaserScan.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct Args {
  std::string bag_path;
  std::string map_yaml;
  std::string topic = "/scan";
  std::string summary_json;
  std::string profile_csv;
  int max_scans = 0;
  double start_sec = 0.0;
  double duration_sec = 0.0;
  bool global = false;
  bool global_first = false;
  cartographer_parallel::Pose2 initial_pose{-2.0, 6.82,
                                            -3.0255282583321743};
  cartographer_parallel::MatchOpt options;
};

double ReadDouble(char** argv, int* i, const int argc, const double fallback) {
  if (*i + 1 >= argc) return fallback;
  ++(*i);
  return std::atof(argv[*i]);
}

int ReadInt(char** argv, int* i, const int argc, const int fallback) {
  if (*i + 1 >= argc) return fallback;
  ++(*i);
  return std::atoi(argv[*i]);
}

Args ParseArgs(const int argc, char** argv) {
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
    if (key == "--bag" && i + 1 < argc) args.bag_path = argv[++i];
    else if (key == "--map" && i + 1 < argc) args.map_yaml = argv[++i];
    else if (key == "--topic" && i + 1 < argc) args.topic = argv[++i];
    else if (key == "--summary-json" && i + 1 < argc) args.summary_json = argv[++i];
    else if (key == "--profile-csv" && i + 1 < argc) args.profile_csv = argv[++i];
    else if (key == "--max-scans") args.max_scans = ReadInt(argv, &i, argc, args.max_scans);
    else if (key == "--start-sec") args.start_sec = ReadDouble(argv, &i, argc, args.start_sec);
    else if (key == "--duration-sec") args.duration_sec = ReadDouble(argv, &i, argc, args.duration_sec);
    else if (key == "--global") args.global = true;
    else if (key == "--global-first") args.global_first = true;
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
  return args;
}

bool ScanToPoints(const sensor_msgs::LaserScan& scan,
                  std::vector<float>* const xs,
                  std::vector<float>* const ys) {
  xs->clear();
  ys->clear();
  xs->reserve(scan.ranges.size());
  ys->reserve(scan.ranges.size());
  for (size_t i = 0; i < scan.ranges.size(); ++i) {
    const float r = scan.ranges[i];
    if (!std::isfinite(r) || r <= 0.0f) continue;
    if (scan.range_min > 0.0f && r < scan.range_min) continue;
    if (scan.range_max > 0.0f && std::isfinite(scan.range_max) &&
        r > scan.range_max) {
      continue;
    }
    const float a = scan.angle_min + static_cast<float>(i) * scan.angle_increment;
    xs->push_back(r * std::cos(a));
    ys->push_back(r * std::sin(a));
  }
  return !xs->empty();
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
  *csv << "scan_index,bag_time,valid_points,ok,match_total_ms,make_scans_ms,"
       << "make_bounds_ms,make_grid_stack_ms,make_low_cands_ms,"
       << "coarse_cand_count,score_total_ms,score_call_count,"
       << "score_all_call_count,batched_score_all_call_count,"
       << "batch_candidate_count,batch_scan_count,score_grouping_ms,"
       << "score_vector_alloc_ms,score_vector_alloc_count,"
       << "score_all_only_ms,score_writeback_ms,score_sort_ms,"
       << "cand_count_total,max_cand_count,branch_ms,branch_call_count,"
       << "child_cand_count,to_out_ms,scan_count,scan_points,"
       << "score_all_profile_ms,device_alloc_ms,pinned_alloc_ms,"
       << "h2d_grid_ms,h2d_scan_ms,h2d_cand_ms,h2d_total_ms,kernel_ms,"
       << "d2h_score_ms,sync_ms,cpu_prepost_ms,last_score,last_pose_x,"
       << "last_pose_y,last_pose_yaw,top_candidates\n";
}

void WriteCsvRow(std::ofstream* const csv, const int scan_index,
                 const double bag_time, const int valid_points,
                 const bool ok,
                 const cartographer_parallel::MatchProfile& p,
                 const cartographer_parallel::ScoreAllProfile& score_all_profile,
                 const cartographer_parallel::MatchOut& out) {
  if (csv == nullptr || !*csv) return;
  *csv << scan_index << "," << bag_time << "," << valid_points << ","
       << (ok ? 1 : 0) << "," << p.match_total_ms << ","
       << p.make_scans_ms << "," << p.make_bounds_ms << ","
       << p.make_grid_stack_ms << "," << p.make_low_cands_ms << ","
       << p.coarse_cand_count << "," << p.score.score_total_ms << ","
       << p.score.score_call_count << "," << p.score.score_all_call_count
       << "," << p.score.batched_score_all_call_count << ","
       << p.score.batch_candidate_count << "," << p.score.batch_scan_count
       << "," << p.score.score_grouping_ms << ","
       << p.score.score_vector_alloc_ms << ","
       << p.score.score_vector_alloc_count << ","
       << p.score.score_all_only_ms << "," << p.score.score_writeback_ms
       << "," << p.score.score_sort_ms << "," << p.score.cand_count_total
       << "," << p.score.max_cand_count << "," << p.branch_ms << ","
       << p.branch_call_count << "," << p.child_cand_count << ","
       << p.to_out_ms << "," << p.scan_count << "," << p.scan_points
       << "," << score_all_profile.total_ms << ","
       << score_all_profile.device_alloc_ms << ","
       << score_all_profile.pinned_alloc_ms << ","
       << score_all_profile.h2d_grid_ms << ","
       << score_all_profile.h2d_scan_ms << ","
       << score_all_profile.h2d_cand_ms << ","
       << score_all_profile.h2d_total_ms << ","
       << score_all_profile.kernel_ms << ","
       << score_all_profile.d2h_score_ms << ","
       << score_all_profile.sync_ms << ","
       << score_all_profile.cpu_prepost_ms << "," << out.score << ","
       << out.pose.x << "," << out.pose.y << "," << out.pose.yaw << ","
       << out.cand.size() << "\n";
}

double Div(const double value, const int denom) {
  return denom <= 0 ? 0.0 : value / static_cast<double>(denom);
}

double Div64(const std::int64_t value, const int denom) {
  return denom <= 0 ? 0.0 : static_cast<double>(value) / static_cast<double>(denom);
}

void WriteSummaryJson(const std::string& path, const Args& args,
                      const int processed_scans, const int ok_count,
                      const cartographer_parallel::MatchProfile& profile_total,
                      const cartographer_parallel::ScoreAllProfile& score_all_total,
                      const cartographer_parallel::MatchOut& last_out) {
  if (path.empty()) return;
  std::ofstream json(path);
  if (!json) {
    throw std::runtime_error("failed to open summary json: " + path);
  }
  json << std::fixed << std::setprecision(9);
  json << "{\n";
  json << "  \"bag\": \"" << args.bag_path << "\",\n";
  json << "  \"map\": \"" << args.map_yaml << "\",\n";
  json << "  \"topic\": \"" << args.topic << "\",\n";
  json << "  \"processed_scans\": " << processed_scans << ",\n";
  json << "  \"ok_count\": " << ok_count << ",\n";
  json << "  \"match_ms_avg\": " << Div(profile_total.match_total_ms, processed_scans) << ",\n";
  json << "  \"score_total_ms_avg\": " << Div(profile_total.score.score_total_ms, processed_scans) << ",\n";
  json << "  \"score_all_ms_avg\": " << Div(profile_total.score.score_all_only_ms, processed_scans) << ",\n";
  json << "  \"score_grouping_ms_avg\": " << Div(profile_total.score.score_grouping_ms, processed_scans) << ",\n";
  json << "  \"score_sort_ms_avg\": " << Div(profile_total.score.score_sort_ms, processed_scans) << ",\n";
  json << "  \"score_all_call_count\": " << Div64(profile_total.score.score_all_call_count, processed_scans) << ",\n";
  json << "  \"batched_score_all_call_count\": " << Div64(profile_total.score.batched_score_all_call_count, processed_scans) << ",\n";
  json << "  \"score_vector_alloc_count\": " << Div64(profile_total.score.score_vector_alloc_count, processed_scans) << ",\n";
  json << "  \"h2d_total_ms_avg\": " << Div(score_all_total.h2d_total_ms, processed_scans) << ",\n";
  json << "  \"kernel_ms_avg\": " << Div(score_all_total.kernel_ms, processed_scans) << ",\n";
  json << "  \"d2h_score_ms_avg\": " << Div(score_all_total.d2h_score_ms, processed_scans) << ",\n";
  json << "  \"last_score\": " << last_out.score << ",\n";
  json << "  \"last_pose_x\": " << last_out.pose.x << ",\n";
  json << "  \"last_pose_y\": " << last_out.pose.y << ",\n";
  json << "  \"last_pose_yaw\": " << last_out.pose.yaw << "\n";
  json << "}\n";
}

}  // namespace

int main(int argc, char** argv) {
  const Args args = ParseArgs(argc, argv);
  if (args.bag_path.empty() || args.map_yaml.empty()) {
    std::cerr << "Usage: " << argv[0]
              << " --bag scan.bag --map 0501.yaml --topic /scan "
              << "--summary-json out.json --profile-csv out.csv\n";
    return 2;
  }

  cartographer_parallel::FastMatcher matcher;
  matcher.SetOptions(args.options);
  if (!matcher.LoadMap(args.map_yaml)) {
    std::cerr << "Failed to load map: " << args.map_yaml << "\n";
    return 3;
  }

  std::ofstream csv;
  if (!args.profile_csv.empty()) {
    csv.open(args.profile_csv);
    if (!csv) {
      std::cerr << "Failed to open profile csv: " << args.profile_csv << "\n";
      return 4;
    }
    WriteCsvHeader(&csv);
  }

  rosbag::Bag bag;
  try {
    bag.open(args.bag_path, rosbag::bagmode::Read);
  } catch (const std::exception& e) {
    std::cerr << "Failed to open bag: " << args.bag_path << " error=" << e.what()
              << "\n";
    return 5;
  }

  std::vector<std::string> topics;
  topics.push_back(args.topic);
  rosbag::View view(bag, rosbag::TopicQuery(topics));

  cartographer_parallel::Pose2 pose = args.initial_pose;
  cartographer_parallel::MatchOut last_out;
  cartographer_parallel::MatchProfile profile_total;
  cartographer_parallel::ScoreAllProfile score_all_total;
  std::vector<float> xs;
  std::vector<float> ys;

  int processed_scans = 0;
  int ok_count = 0;
  bool have_first_time = false;
  double first_time = 0.0;

  for (const rosbag::MessageInstance& message : view) {
    const sensor_msgs::LaserScan::ConstPtr scan =
        message.instantiate<sensor_msgs::LaserScan>();
    if (!scan) continue;

    const double bag_time = message.getTime().toSec();
    if (!have_first_time) {
      first_time = bag_time;
      have_first_time = true;
    }
    const double rel_sec = bag_time - first_time;
    if (rel_sec < args.start_sec) continue;
    if (args.duration_sec > 0.0 &&
        rel_sec > args.start_sec + args.duration_sec) {
      break;
    }
    if (!ScanToPoints(*scan, &xs, &ys)) continue;

    cartographer_parallel::ResetTotalScoreAllProfile();
    cartographer_parallel::MatchOut out;
    const bool use_global =
        args.global || (args.global_first && processed_scans == 0);
    const bool ok = matcher.Match(xs, ys, pose, use_global, &out);
    const cartographer_parallel::MatchProfile& profile = matcher.last_profile();
    const cartographer_parallel::ScoreAllProfile& score_all_profile =
        cartographer_parallel::TotalScoreAllProfile();

    ++processed_scans;
    ok_count += ok ? 1 : 0;
    if (ok) pose = out.pose;
    last_out = out;

    AddProfile(&profile_total, profile);
    AddScoreAllProfileTotal(&score_all_total, score_all_profile);
    WriteCsvRow(&csv, processed_scans, bag_time, static_cast<int>(xs.size()),
                ok, profile, score_all_profile, out);

    if (processed_scans % 100 == 0) {
      std::cout << "processed_scans=" << processed_scans
                << " ok_count=" << ok_count
                << " last_match_ms=" << profile.match_total_ms
                << " last_score=" << out.score << std::endl;
    }
    if (args.max_scans > 0 && processed_scans >= args.max_scans) break;
  }

  bag.close();
  WriteSummaryJson(args.summary_json, args, processed_scans, ok_count,
                   profile_total, score_all_total, last_out);

  std::cout << std::fixed << std::setprecision(3);
  std::cout << "benchmark=bag_matcher"
            << " bag=" << args.bag_path
            << " map=" << args.map_yaml
            << " topic=" << args.topic
            << " processed_scans=" << processed_scans
            << " ok_count=" << ok_count
            << " match_ms_avg=" << Div(profile_total.match_total_ms, processed_scans)
            << " score_total_ms_avg="
            << Div(profile_total.score.score_total_ms, processed_scans)
            << " score_all_ms_avg="
            << Div(profile_total.score.score_all_only_ms, processed_scans)
            << " score_grouping_ms_avg="
            << Div(profile_total.score.score_grouping_ms, processed_scans)
            << " score_sort_ms_avg="
            << Div(profile_total.score.score_sort_ms, processed_scans)
            << " score_all_call_count="
            << Div64(profile_total.score.score_all_call_count, processed_scans)
            << " batched_score_all_call_count="
            << Div64(profile_total.score.batched_score_all_call_count,
                     processed_scans)
            << " score_vector_alloc_count="
            << Div64(profile_total.score.score_vector_alloc_count,
                     processed_scans)
            << " h2d_total_ms_avg="
            << Div(score_all_total.h2d_total_ms, processed_scans)
            << " kernel_ms_avg=" << Div(score_all_total.kernel_ms, processed_scans)
            << " d2h_score_ms_avg="
            << Div(score_all_total.d2h_score_ms, processed_scans)
            << " last_score=" << last_out.score
            << " last_pose_x=" << last_out.pose.x
            << " last_pose_y=" << last_out.pose.y
            << " last_pose_yaw=" << last_out.pose.yaw
            << "\n";
  return processed_scans == 0 ? 6 : 0;
}
