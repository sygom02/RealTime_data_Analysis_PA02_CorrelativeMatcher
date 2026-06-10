#ifndef CARTOGRAPHER_PARALLEL_PROFILE_H_
#define CARTOGRAPHER_PARALLEL_PROFILE_H_

#include <cstdint>
#include <chrono>

namespace cartographer_parallel {

using ProfileClock = std::chrono::steady_clock;

inline double ProfileMsSince(const ProfileClock::time_point start) {
  return std::chrono::duration<double, std::milli>(
             ProfileClock::now() - start)
      .count();
}

struct ScoreAllProfile {
  double total_ms = 0.0;
  double device_alloc_ms = 0.0;
  double pinned_alloc_ms = 0.0;
  double h2d_grid_ms = 0.0;
  double h2d_scan_ms = 0.0;
  double h2d_cand_ms = 0.0;
  double h2d_total_ms = 0.0;
  double kernel_ms = 0.0;
  double d2h_score_ms = 0.0;
  double sync_ms = 0.0;
  double cpu_prepost_ms = 0.0;
  std::int64_t call_count = 0;
  std::int64_t grid_cells = 0;
  std::int64_t scan_points = 0;
  std::int64_t candidates = 0;
};

inline ScoreAllProfile& MutableLastScoreAllProfile() {
  static thread_local ScoreAllProfile profile;
  return profile;
}

inline ScoreAllProfile& MutableTotalScoreAllProfile() {
  static thread_local ScoreAllProfile profile;
  return profile;
}

inline void ResetLastScoreAllProfile() {
  MutableLastScoreAllProfile() = ScoreAllProfile();
}

inline void ResetTotalScoreAllProfile() {
  MutableTotalScoreAllProfile() = ScoreAllProfile();
}

inline const ScoreAllProfile& LastScoreAllProfile() {
  return MutableLastScoreAllProfile();
}

inline const ScoreAllProfile& TotalScoreAllProfile() {
  return MutableTotalScoreAllProfile();
}

inline void AddScoreAllProfile(const ScoreAllProfile& sample) {
  ScoreAllProfile& total = MutableTotalScoreAllProfile();
  total.total_ms += sample.total_ms;
  total.device_alloc_ms += sample.device_alloc_ms;
  total.pinned_alloc_ms += sample.pinned_alloc_ms;
  total.h2d_grid_ms += sample.h2d_grid_ms;
  total.h2d_scan_ms += sample.h2d_scan_ms;
  total.h2d_cand_ms += sample.h2d_cand_ms;
  total.h2d_total_ms += sample.h2d_total_ms;
  total.kernel_ms += sample.kernel_ms;
  total.d2h_score_ms += sample.d2h_score_ms;
  total.sync_ms += sample.sync_ms;
  total.cpu_prepost_ms += sample.cpu_prepost_ms;
  total.call_count += sample.call_count;
  total.grid_cells += sample.grid_cells;
  total.scan_points += sample.scan_points;
  total.candidates += sample.candidates;
}

}  // namespace cartographer_parallel

#endif  // CARTOGRAPHER_PARALLEL_PROFILE_H_
