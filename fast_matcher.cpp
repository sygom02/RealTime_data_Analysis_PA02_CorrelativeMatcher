#include "cartographer_parallel/fast_matcher.h"

#include "cartographer_parallel/assignment.h"
#include "cartographer_parallel/nvtx_range.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <limits>
#include <sstream>
#include <stdexcept>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace cartographer_parallel {
namespace {

using Clock = std::chrono::steady_clock;

double MsSince(const Clock::time_point start) {
  return std::chrono::duration<double, std::milli>(Clock::now() - start)
      .count();
}

std::string Trim(const std::string& s) {
  const char* ws = " \t\r\n";
  const std::string::size_type b = s.find_first_not_of(ws);
  if (b == std::string::npos) return "";
  const std::string::size_type e = s.find_last_not_of(ws);
  return s.substr(b, e - b + 1);
}

std::string Unquote(const std::string& s) {
  const std::string v = Trim(s);
  if (v.size() >= 2 &&
      ((v.front() == '"' && v.back() == '"') ||
       (v.front() == '\'' && v.back() == '\''))) {
    return v.substr(1, v.size() - 2);
  }
  return v;
}

std::string Dirname(const std::string& path) {
  const std::string::size_type slash = path.find_last_of("/\\");
  return slash == std::string::npos ? "." : path.substr(0, slash);
}

bool IsAbs(const std::string& path) {
  return !path.empty() &&
         (path[0] == '/' || path[0] == '\\' ||
          (path.size() >= 2 && path[1] == ':'));
}

std::string Join(const std::string& dir, const std::string& file) {
  if (file.empty() || IsAbs(file)) return file;
  return dir == "." ? file : dir + "/" + file;
}

std::vector<double> ParseList(std::string v) {
  for (char& c : v) {
    if (c == '[' || c == ']' || c == ',') c = ' ';
  }
  std::istringstream in(v);
  std::vector<double> out;
  double x = 0.0;
  while (in >> x) out.push_back(x);
  return out;
}

std::string PgmToken(std::istream* in) {
  std::string token;
  char c = 0;
  while (in->get(c)) {
    if (std::isspace(static_cast<unsigned char>(c))) continue;
    if (c == '#') {
      in->ignore(std::numeric_limits<std::streamsize>::max(), '\n');
      continue;
    }
    token.push_back(c);
    break;
  }
  while (in->get(c)) {
    if (std::isspace(static_cast<unsigned char>(c))) break;
    if (c == '#') {
      in->ignore(std::numeric_limits<std::streamsize>::max(), '\n');
      break;
    }
    token.push_back(c);
  }
  return token;
}

int ClampInt(const int x, const int lo, const int hi) {
  return std::max(lo, std::min(hi, x));
}

double NormalizeYaw(double yaw) {
  while (yaw > M_PI) yaw -= 2.0 * M_PI;
  while (yaw < -M_PI) yaw += 2.0 * M_PI;
  return yaw;
}

void AddVectorAlloc(ScoreBreakdown* const score, const int count) {
  if (score == nullptr) return;
  score->score_vector_alloc_count += count;
}

}  // namespace

bool FastMatcher::LoadMap(const std::string& yaml_file) {
  std::ifstream yaml(yaml_file);
  if (!yaml) return false;

  std::string image;
  bool negate = false;
  double occupied_thresh = 0.65;
  double free_thresh = 0.196;
  std::string line;
  while (std::getline(yaml, line)) {
    line = line.substr(0, line.find('#'));
    const std::string::size_type colon = line.find(':');
    if (colon == std::string::npos) continue;
    const std::string key = Trim(line.substr(0, colon));
    const std::string val = Trim(line.substr(colon + 1));
    if (key == "image") {
      image = Join(Dirname(yaml_file), Unquote(val));
    } else if (key == "resolution") {
      res_ = std::stod(val);
    } else if (key == "origin") {
      const std::vector<double> origin = ParseList(val);
      if (origin.size() >= 2) {
        ox_ = origin[0];
        oy_ = origin[1];
      }
    } else if (key == "negate") {
      negate = (val == "1" || val == "true" || val == "True");
    } else if (key == "occupied_thresh") {
      occupied_thresh = std::stod(val);
    } else if (key == "free_thresh") {
      free_thresh = std::stod(val);
    }
  }
  (void)occupied_thresh;
  (void)free_thresh;
  if (image.empty()) return false;

  std::ifstream pgm(image, std::ios::binary);
  if (!pgm) return false;
  const std::string magic = PgmToken(&pgm);
  if (magic != "P5" && magic != "P2") return false;
  w_ = std::stoi(PgmToken(&pgm));
  h_ = std::stoi(PgmToken(&pgm));
  const int max_value = std::stoi(PgmToken(&pgm));
  if (w_ <= 0 || h_ <= 0 || max_value <= 0 || max_value > 255) return false;

  std::vector<unsigned char> pixels(w_ * h_, 0);
  if (magic == "P5") {
    pgm.read(reinterpret_cast<char*>(pixels.data()), pixels.size());
    if (pgm.gcount() != static_cast<std::streamsize>(pixels.size())) {
      return false;
    }
  } else {
    for (unsigned char& pixel : pixels) {
      const std::string token = PgmToken(&pgm);
      if (token.empty()) return false;
      pixel = static_cast<unsigned char>(
          ClampInt(std::stoi(token), 0, max_value));
    }
  }

  map_.assign(w_ * h_, 0);
  for (int i = 0; i < w_ * h_; ++i) {
    const double v = static_cast<double>(pixels[i]) / max_value;
    const double occ = negate ? v : (1.0 - v);
    map_[i] = static_cast<unsigned char>(
        ClampInt(static_cast<int>(std::lround(255.0 * occ)), 0, 255));
  }
  grids_ = MakeGridStack();
  return true;
}

void FastMatcher::SetOptions(const MatchOpt& opt) {
  opt_ = opt;
  if (has_map()) grids_ = MakeGridStack();
}

std::vector<FastMatcher::Scan> FastMatcher::MakeScans(
    const std::vector<float>& xs, const std::vector<float>& ys,
    const Pose2& init, int* const num_ang, double* const step) const {
  double max_range = 3.0 * res_;
  for (size_t i = 0; i < xs.size() && i < ys.size(); ++i) {
    max_range = std::max(max_range,
                         std::hypot(static_cast<double>(xs[i]),
                                    static_cast<double>(ys[i])));
  }

  double angle_step = opt_.angular_step;
  if (angle_step <= 0.0) {
    const double c = 1.0 - (res_ * res_) / (2.0 * max_range * max_range);
    angle_step = 0.999 * std::acos(std::max(-1.0, std::min(1.0, c)));
    if (!std::isfinite(angle_step) || angle_step <= 0.0) angle_step = 0.05;
  }
  const int n_ang = std::max(0, static_cast<int>(
                                   std::ceil(opt_.angular_window / angle_step)));
  const int scan_count = 2 * n_ang + 1;
  if (num_ang) *num_ang = n_ang;
  if (step) *step = angle_step;

  std::vector<Scan> scans(scan_count);
  for (int s = 0; s < scan_count; ++s) {
    const double da = (s - n_ang) * angle_step;
    const double yaw = init.yaw + da;
    const double c = std::cos(yaw);
    const double sn = std::sin(yaw);
    scans[s].x.reserve(xs.size());
    scans[s].y.reserve(xs.size());
    for (size_t i = 0; i < xs.size() && i < ys.size(); ++i) {
      const double wx = init.x + c * xs[i] - sn * ys[i];
      const double wy = init.y + sn * xs[i] + c * ys[i];
      const int mx = static_cast<int>(std::floor((wx - ox_) / res_));
      const int row_bottom = static_cast<int>(std::floor((wy - oy_) / res_));
      const int my = h_ - 1 - row_bottom;
      scans[s].x.push_back(mx);
      scans[s].y.push_back(my);
    }
  }
  return scans;
}

std::vector<FastMatcher::Bounds> FastMatcher::MakeBounds(
    const std::vector<Scan>& scans, const double window,
    const bool full_map) const {
  const int lin = static_cast<int>(std::ceil(window / res_));
  std::vector<Bounds> bounds(scans.size());
  for (size_t s = 0; s < scans.size(); ++s) {
    Bounds b;
    if (full_map) {
      b.min_x = std::numeric_limits<int>::lowest() / 4;
      b.max_x = std::numeric_limits<int>::max() / 4;
      b.min_y = std::numeric_limits<int>::lowest() / 4;
      b.max_y = std::numeric_limits<int>::max() / 4;
    } else {
      b.min_x = -lin;
      b.max_x = lin;
      b.min_y = -lin;
      b.max_y = lin;
      // Local/global-window search should stay centered on the initial pose.
      // Out-of-map scan points are already scored as zero in score_all().
      bounds[s] = b;
      continue;
    }

    for (size_t i = 0; i < scans[s].x.size(); ++i) {
      b.min_x = std::max(b.min_x, -scans[s].x[i]);
      b.max_x = std::min(b.max_x, w_ - 1 - scans[s].x[i]);
      b.min_y = std::max(b.min_y, -scans[s].y[i]);
      b.max_y = std::min(b.max_y, h_ - 1 - scans[s].y[i]);
    }
    bounds[s] = b;
  }
  return bounds;
}

std::vector<FastMatcher::Grid> FastMatcher::MakeGridStack() const {
  const int depth = std::max(1, opt_.branch_depth);
  std::vector<Grid> grids;
  grids.reserve(depth);
  for (int level = 0; level < depth; ++level) {
    const int win = 1 << level;
    Grid g;
    g.w = w_;
    g.h = h_;
    g.win = win;
    g.cell.assign(w_ * h_, 0);
    for (int y = 0; y < h_; ++y) {
      for (int x = 0; x < w_; ++x) {
        unsigned char best = 0;
        for (int dy = 0; dy < win && y + dy < h_; ++dy) {
          for (int dx = 0; dx < win && x + dx < w_; ++dx) {
            best = std::max(best, map_[(y + dy) * w_ + (x + dx)]);
          }
        }
        g.cell[y * w_ + x] = best;
      }
    }
    grids.push_back(g);
  }
  return grids;
}

std::vector<FastMatcher::Cand> FastMatcher::MakeLowCands(
    const std::vector<Bounds>& bounds, const int depth) const {
  const int step = 1 << depth;
  std::vector<Cand> out;
  for (size_t s = 0; s < bounds.size(); ++s) {
    if (bounds[s].min_x > bounds[s].max_x ||
        bounds[s].min_y > bounds[s].max_y) {
      continue;
    }
    std::vector<int> cx;
    std::vector<int> cy;
    make_cand(bounds[s].min_x, bounds[s].max_x, bounds[s].min_y,
              bounds[s].max_y, step, &cx, &cy);
    for (size_t i = 0; i < cx.size(); ++i) {
      Cand c;
      c.scan = static_cast<int>(s);
      c.x = cx[i];
      c.y = cy[i];
      out.push_back(c);
    }
  }
  return out;
}

void FastMatcher::Score(const Grid& grid, const std::vector<Scan>& scans,
                        std::vector<Cand>* const cand,
                        MatchProfile* const profile) const {
  CARTOGRAPHER_PARALLEL_NVTX_RANGE("Score");
  if (cand == nullptr || cand->empty()) return;
  ScoreBreakdown* const score_profile = profile == nullptr ? nullptr
                                                           : &profile->score;
  const auto score_total_start = Clock::now();
  if (score_profile != nullptr) {
    score_profile->score_call_count += 1;
    score_profile->cand_count_total += static_cast<std::int64_t>(cand->size());
    score_profile->max_cand_count = std::max(
        score_profile->max_cand_count,
        static_cast<std::int64_t>(cand->size()));
  }

#if defined(FAST_MATCHER_SCORE_BATCHED_GPU) && FAST_MATCHER_SCORE_BATCHED_GPU
  const auto alloc_start = Clock::now();
  std::vector<int> active_scans;
  std::vector<int> scan_remap(scans.size(), -1);
  std::vector<int> scan_x_flat;
  std::vector<int> scan_y_flat;
  std::vector<int> scan_offsets;
  std::vector<int> scan_sizes;
  std::vector<int> ids;
  std::vector<int> cand_scan;
  std::vector<int> cx;
  std::vector<int> cy;
  std::vector<float> score;
  active_scans.reserve(scans.size());
  scan_offsets.reserve(scans.size());
  scan_sizes.reserve(scans.size());
  ids.reserve(cand->size());
  cand_scan.reserve(cand->size());
  cx.reserve(cand->size());
  cy.reserve(cand->size());
  score.reserve(cand->size());
  if (score_profile != nullptr) {
    score_profile->score_vector_alloc_ms += MsSince(alloc_start);
    AddVectorAlloc(score_profile, 9);
  }

  const auto grouping_start = Clock::now();
  for (size_t i = 0; i < cand->size(); ++i) {
    const int scan = (*cand)[i].scan;
    if (scan < 0 || scan >= static_cast<int>(scans.size())) continue;
    if (scan_remap[scan] < 0) {
      scan_remap[scan] = static_cast<int>(active_scans.size());
      active_scans.push_back(scan);
    }
    ids.push_back(static_cast<int>(i));
    cand_scan.push_back(scan_remap[scan]);
    cx.push_back((*cand)[i].x);
    cy.push_back((*cand)[i].y);
  }

  int total_scan_points = 0;
  for (const int scan : active_scans) {
    const int points = static_cast<int>(
        std::min(scans[scan].x.size(), scans[scan].y.size()));
    scan_offsets.push_back(total_scan_points);
    scan_sizes.push_back(points);
    total_scan_points += points;
  }
  scan_x_flat.reserve(total_scan_points);
  scan_y_flat.reserve(total_scan_points);
  for (const int scan : active_scans) {
    const int points = static_cast<int>(
        std::min(scans[scan].x.size(), scans[scan].y.size()));
    for (int i = 0; i < points; ++i) {
      scan_x_flat.push_back(scans[scan].x[i]);
      scan_y_flat.push_back(scans[scan].y[i]);
    }
  }
  if (score_profile != nullptr) {
    score_profile->score_grouping_ms += MsSince(grouping_start);
  }

  if (!ids.empty()) {
    if (score_profile != nullptr) {
      score_profile->score_nonempty_scan_groups +=
          static_cast<std::int64_t>(active_scans.size());
      score_profile->score_all_call_count += 1;
      score_profile->batched_score_all_call_count += 1;
      score_profile->batch_candidate_count +=
          static_cast<std::int64_t>(ids.size());
      score_profile->batch_scan_count +=
          static_cast<std::int64_t>(active_scans.size());
    }

    const auto score_all_start = Clock::now();
    {
      CARTOGRAPHER_PARALLEL_NVTX_RANGE("score_all_batched");
      score_all_batched(grid.cell, grid.w, grid.h, scan_x_flat, scan_y_flat,
                        scan_offsets, scan_sizes, cand_scan, cx, cy, &score);
    }
    if (score_profile != nullptr) {
      score_profile->score_all_only_ms += MsSince(score_all_start);
    }

    const auto writeback_start = Clock::now();
    for (size_t i = 0; i < ids.size() && i < score.size(); ++i) {
      (*cand)[ids[i]].score = score[i];
    }
    if (score_profile != nullptr) {
      score_profile->score_writeback_ms += MsSince(writeback_start);
    }
  }
#elif defined(FAST_MATCHER_SCORE_BUCKETS) && FAST_MATCHER_SCORE_BUCKETS
  const auto alloc_start = Clock::now();
  std::vector<std::vector<int>> ids_by_scan(scans.size());
  std::vector<int> cx;
  std::vector<int> cy;
  std::vector<float> score;
  cx.reserve(cand->size());
  cy.reserve(cand->size());
  score.reserve(cand->size());
  if (score_profile != nullptr) {
    score_profile->score_vector_alloc_ms += MsSince(alloc_start);
    AddVectorAlloc(score_profile,
                   static_cast<int>(ids_by_scan.size()) + 3);
  }

  const auto grouping_start = Clock::now();
  for (size_t i = 0; i < cand->size(); ++i) {
    const int scan = (*cand)[i].scan;
    if (scan >= 0 && scan < static_cast<int>(ids_by_scan.size())) {
      ids_by_scan[scan].push_back(static_cast<int>(i));
    }
  }
  if (score_profile != nullptr) {
    score_profile->score_grouping_ms += MsSince(grouping_start);
  }

  for (size_t s = 0; s < scans.size(); ++s) {
    const std::vector<int>& ids = ids_by_scan[s];
    if (ids.empty()) continue;
    if (score_profile != nullptr) {
      score_profile->score_nonempty_scan_groups += 1;
      score_profile->score_all_call_count += 1;
    }

    const auto fill_start = Clock::now();
    cx.clear();
    cy.clear();
    for (const int id : ids) {
      cx.push_back((*cand)[id].x);
      cy.push_back((*cand)[id].y);
    }
    if (score_profile != nullptr) {
      score_profile->score_grouping_ms += MsSince(fill_start);
    }

    const auto score_all_start = Clock::now();
    {
      CARTOGRAPHER_PARALLEL_NVTX_RANGE("score_all");
      score_all(grid.cell, grid.w, grid.h, scans[s].x, scans[s].y, cx, cy,
                &score);
    }
    if (score_profile != nullptr) {
      score_profile->score_all_only_ms += MsSince(score_all_start);
    }

    const auto writeback_start = Clock::now();
    for (size_t i = 0; i < ids.size() && i < score.size(); ++i) {
      (*cand)[ids[i]].score = score[i];
    }
    if (score_profile != nullptr) {
      score_profile->score_writeback_ms += MsSince(writeback_start);
    }
  }
#else
#if defined(FAST_MATCHER_SCORE_BUFFER_REUSE) && FAST_MATCHER_SCORE_BUFFER_REUSE
  const auto alloc_start = Clock::now();
  std::vector<int> ids;
  std::vector<int> cx;
  std::vector<int> cy;
  std::vector<float> score;
  ids.reserve(cand->size());
  cx.reserve(cand->size());
  cy.reserve(cand->size());
  score.reserve(cand->size());
  if (score_profile != nullptr) {
    score_profile->score_vector_alloc_ms += MsSince(alloc_start);
    AddVectorAlloc(score_profile, 4);
  }
#endif
  for (size_t s = 0; s < scans.size(); ++s) {
#if !(defined(FAST_MATCHER_SCORE_BUFFER_REUSE) && FAST_MATCHER_SCORE_BUFFER_REUSE)
    const auto alloc_start = Clock::now();
    std::vector<int> ids;
    std::vector<int> cx;
    std::vector<int> cy;
    std::vector<float> score;
    if (score_profile != nullptr) {
      score_profile->score_vector_alloc_ms += MsSince(alloc_start);
      AddVectorAlloc(score_profile, 4);
    }
#else
    ids.clear();
    cx.clear();
    cy.clear();
    score.clear();
#endif

    const auto grouping_start = Clock::now();
    for (size_t i = 0; i < cand->size(); ++i) {
      if ((*cand)[i].scan == static_cast<int>(s)) {
        ids.push_back(i);
        cx.push_back((*cand)[i].x);
        cy.push_back((*cand)[i].y);
      }
    }
    if (score_profile != nullptr) {
      score_profile->score_grouping_ms += MsSince(grouping_start);
    }
    if (ids.empty()) continue;
    if (score_profile != nullptr) {
      score_profile->score_nonempty_scan_groups += 1;
      score_profile->score_all_call_count += 1;
    }
    const auto score_all_start = Clock::now();
    {
      CARTOGRAPHER_PARALLEL_NVTX_RANGE("score_all");
      score_all(grid.cell, grid.w, grid.h, scans[s].x, scans[s].y, cx, cy,
                &score);
    }
    if (score_profile != nullptr) {
      score_profile->score_all_only_ms += MsSince(score_all_start);
    }
    const auto writeback_start = Clock::now();
    for (size_t i = 0; i < ids.size() && i < score.size(); ++i) {
      (*cand)[ids[i]].score = score[i];
    }
    if (score_profile != nullptr) {
      score_profile->score_writeback_ms += MsSince(writeback_start);
    }
  }
#endif
  const auto sort_start = Clock::now();
  std::sort(cand->begin(), cand->end(),
            [](const Cand& a, const Cand& b) { return a.score > b.score; });
  if (score_profile != nullptr) {
    score_profile->score_sort_ms += MsSince(sort_start);
    score_profile->score_total_ms += MsSince(score_total_start);
  }
}

FastMatcher::Cand FastMatcher::Branch(const std::vector<Grid>& grids,
                                      const std::vector<Scan>& scans,
                                      const std::vector<Bounds>& bounds,
                                      const std::vector<Cand>& cand,
                                      const int depth,
                                      const float min_score,
                                      MatchProfile* const profile) const {
  CARTOGRAPHER_PARALLEL_NVTX_RANGE("Branch");
  if (profile != nullptr) profile->branch_call_count += 1;
  if (cand.empty()) {
    Cand empty;
    empty.score = 0.0f;
    return empty;
  }
  if (depth == 0) return cand.front();

  Cand best;
  best.score = min_score;
  const int half = 1 << (depth - 1);
  for (const Cand& c : cand) {
    if (c.score <= best.score) break;
    std::vector<Cand> child;
    for (const int dx : {0, half}) {
      if (c.x + dx > bounds[c.scan].max_x) continue;
      for (const int dy : {0, half}) {
        if (c.y + dy > bounds[c.scan].max_y) continue;
        Cand next;
        next.scan = c.scan;
        next.x = c.x + dx;
        next.y = c.y + dy;
        child.push_back(next);
      }
    }
    if (profile != nullptr) {
      profile->child_cand_count += static_cast<std::int64_t>(child.size());
    }
    Score(grids[depth - 1], scans, &child, profile);
    const Cand refined = Branch(grids, scans, bounds, child, depth - 1,
                                best.score, profile);
    if (refined.score > best.score) best = refined;
  }
  return best;
}

CandOut FastMatcher::ToOut(const Cand& cand, const Pose2& init,
                           const int num_ang, const double step) const {
  CandOut out;
  out.x = init.x + cand.x * res_;
  out.y = init.y - cand.y * res_;
  out.yaw = NormalizeYaw(init.yaw + (cand.scan - num_ang) * step);
  out.score = cand.score;
  return out;
}

bool FastMatcher::Match(const std::vector<float>& xs,
                        const std::vector<float>& ys, const Pose2& init,
                        const bool global, MatchOut* const out) const {
  return MatchWithWindow(xs, ys, init,
                         global ? opt_.global_window : opt_.linear_window,
                         global && opt_.full_map_search, out);
}

bool FastMatcher::MatchWithWindow(const std::vector<float>& xs,
                                  const std::vector<float>& ys,
                                  const Pose2& init,
                                  const double window,
                                  const bool full_map,
                                  MatchOut* const out) const {
  CARTOGRAPHER_PARALLEL_NVTX_RANGE("MatchWithWindow");
  MatchProfile profile;
  profile.scan_points = static_cast<std::int64_t>(
      std::min(xs.size(), ys.size()));
  const auto match_start = Clock::now();
  const auto finish = [this, &profile, match_start]() {
    profile.match_total_ms = MsSince(match_start);
    last_profile_ = profile;
  };

  if (out == nullptr) {
    finish();
    return false;
  }
  *out = MatchOut();
  if (!has_map() || xs.empty() || ys.empty()) {
    finish();
    return false;
  }

  int num_ang = 0;
  double step = 0.0;
  auto stage_start = Clock::now();
  std::vector<Scan> scans;
  {
    CARTOGRAPHER_PARALLEL_NVTX_RANGE("MakeScans");
    scans = MakeScans(xs, ys, init, &num_ang, &step);
    profile.make_scans_ms = MsSince(stage_start);
  }
  profile.scan_count = static_cast<std::int64_t>(scans.size());

  stage_start = Clock::now();
  std::vector<Bounds> bounds;
  {
    CARTOGRAPHER_PARALLEL_NVTX_RANGE("MakeBounds");
    bounds = MakeBounds(scans, window, full_map);
    profile.make_bounds_ms = MsSince(stage_start);
  }

  std::vector<Grid> temp_grids;
  const std::vector<Grid>* grids_ptr = &grids_;
  if (grids_ptr->empty()) {
    stage_start = Clock::now();
    {
      CARTOGRAPHER_PARALLEL_NVTX_RANGE("MakeGridStack");
      temp_grids = MakeGridStack();
      profile.make_grid_stack_ms = MsSince(stage_start);
    }
    grids_ptr = &temp_grids;
  }
  const std::vector<Grid>& grids = *grids_ptr;
  const int max_depth = static_cast<int>(grids.size()) - 1;

  stage_start = Clock::now();
  std::vector<Cand> coarse;
  {
    CARTOGRAPHER_PARALLEL_NVTX_RANGE("MakeLowCands");
    coarse = MakeLowCands(bounds, max_depth);
    profile.make_low_cands_ms = MsSince(stage_start);
  }
  profile.coarse_cand_count = static_cast<std::int64_t>(coarse.size());

  Score(grids[max_depth], scans, &coarse, &profile);
  if (coarse.empty()) {
    finish();
    return false;
  }

  stage_start = Clock::now();
  Cand best;
  {
    CARTOGRAPHER_PARALLEL_NVTX_RANGE("BranchTotal");
    best = Branch(grids, scans, bounds, coarse, max_depth,
                  opt_.min_score, &profile);
    profile.branch_ms = MsSince(stage_start);
  }

  out->ok = best.score > opt_.min_score;
  out->score = best.score;
  out->pose = init;
  if (out->ok) {
    const CandOut best_out = ToOut(best, init, num_ang, step);
    out->pose.x = best_out.x;
    out->pose.y = best_out.y;
    out->pose.yaw = best_out.yaw;
  }

  stage_start = Clock::now();
  CARTOGRAPHER_PARALLEL_NVTX_RANGE("ToOut");
  const int n = std::min(opt_.max_cand, static_cast<int>(coarse.size()));
  out->cand.reserve(n);
  for (int i = 0; i < n; ++i) {
    out->cand.push_back(ToOut(coarse[i], init, num_ang, step));
  }
  profile.to_out_ms = MsSince(stage_start);
  finish();
  return out->ok;
}

}  
