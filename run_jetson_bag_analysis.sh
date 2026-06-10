#!/usr/bin/env bash
set -euo pipefail

ROS_WS="${1:-/data/student_02/cartographer_parallel}"
OPT_ROOT="${2:-/data/student_02/Optimization_project}"
MAP_PATH="${MAP_PATH:-$ROS_WS/maps/0501.yaml}"
BAG_PATH="${BAG_PATH:-$ROS_WS/bags}"
BAG_RUNS="${BAG_RUNS:-3}"
BAG_TIMEOUT_SEC="${BAG_TIMEOUT_SEC:-90}"
NS_PREFIX="${NS_PREFIX:-bagtest}"

timestamp="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$OPT_ROOT/results/bag_analysis_$timestamp"
mkdir -p "$OUT_DIR/backups"

SCORE_SRC="$ROS_WS/src/score_all.cpp"
CMAKE_SRC="$ROS_WS/CMakeLists.txt"
PKG_NAME="cartographer_parallel"

if [[ ! -f "$SCORE_SRC" ]]; then
  echo "Missing ROS score source: $SCORE_SRC" >&2
  exit 1
fi
if [[ ! -f "$CMAKE_SRC" ]]; then
  echo "Missing ROS CMakeLists: $CMAKE_SRC" >&2
  exit 1
fi
if [[ ! -f "$OPT_ROOT/ros_score_all_cpu_boundary_openmp.cpp" ]]; then
  echo "Missing optimized ROS score source: $OPT_ROOT/ros_score_all_cpu_boundary_openmp.cpp" >&2
  exit 1
fi

cp "$SCORE_SRC" "$OUT_DIR/backups/score_all.cpp"
cp "$CMAKE_SRC" "$OUT_DIR/backups/CMakeLists.txt"

restore_sources() {
  if [[ -f "$OUT_DIR/backups/score_all.cpp" ]]; then
    cp "$OUT_DIR/backups/score_all.cpp" "$SCORE_SRC"
  fi
  if [[ -f "$OUT_DIR/backups/CMakeLists.txt" ]]; then
    cp "$OUT_DIR/backups/CMakeLists.txt" "$CMAKE_SRC"
  fi
}
trap restore_sources EXIT

patch_openmp_cmake() {
  cp "$OUT_DIR/backups/CMakeLists.txt" "$CMAKE_SRC"
  cat >> "$CMAKE_SRC" <<'EOF'

# Optimization_project BAG test patch.
find_package(OpenMP)
if(OpenMP_CXX_FOUND)
  target_link_libraries(assignment_cpu_lib PUBLIC OpenMP::OpenMP_CXX)
  target_link_libraries(fast_matcher_lib PUBLIC OpenMP::OpenMP_CXX)
  target_link_libraries(fast_correlative_node PUBLIC OpenMP::OpenMP_CXX)
endif()
EOF
}

source_ros() {
  set +u
  if [[ -n "${ROS_DISTRO:-}" && -f "/opt/ros/$ROS_DISTRO/setup.bash" ]]; then
    # shellcheck disable=SC1090
    source "/opt/ros/$ROS_DISTRO/setup.bash"
  elif [[ -f /opt/ros/foxy/setup.bash ]]; then
    # shellcheck disable=SC1091
    source /opt/ros/foxy/setup.bash
  elif [[ -f /opt/ros/humble/setup.bash ]]; then
    # shellcheck disable=SC1091
    source /opt/ros/humble/setup.bash
  fi
  set -u
}

build_ros_variant() {
  local variant="$1"
  echo "Building ROS BAG variant: $variant"
  rm -rf "$ROS_WS/build/$PKG_NAME" "$ROS_WS/install/$PKG_NAME" "$ROS_WS/log"
  (
    cd "$ROS_WS"
    source_ros
    colcon build --packages-select "$PKG_NAME" --cmake-clean-cache
  )
}

prepare_variant() {
  local variant="$1"
  case "$variant" in
    ros_baseline)
      cp "$OUT_DIR/backups/score_all.cpp" "$SCORE_SRC"
      cp "$OUT_DIR/backups/CMakeLists.txt" "$CMAKE_SRC"
      ;;
    ros_cpu_boundary_openmp)
      cp "$OPT_ROOT/ros_score_all_cpu_boundary_openmp.cpp" "$SCORE_SRC"
      patch_openmp_cmake
      ;;
    *)
      echo "Unknown BAG variant: $variant" >&2
      exit 1
      ;;
  esac
}

summary_csv="$OUT_DIR/bag_summary.csv"
echo "variant,run,samples,match_ms_avg,score_all_ms_avg,score_all_ratio_pct,score_all_calls_total,score_all_candidates_total,score_all_scan_points_total,score_all_cell_checks_total" > "$summary_csv"

extract_summary() {
  local variant="$1"
  local run_id="$2"
  local log_file="$3"
  local json_file="$OUT_DIR/${variant}_run${run_id}_summary.json"
  local line
  line="$(grep -h 'perf_summary_json=' "$log_file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "$variant,$run_id,,,,,,,," >> "$summary_csv"
    echo "No perf_summary_json found for $variant run $run_id" >&2
    return
  fi
  printf '%s\n' "${line#*perf_summary_json=}" > "$json_file"
  python3 - "$variant" "$run_id" "$json_file" "$summary_csv" <<'PY'
import csv
import json
import sys

variant, run_id, json_file, csv_file = sys.argv[1:5]
with open(json_file, "r") as f:
    data = json.load(f)
row = [
    variant,
    run_id,
    data.get("samples", ""),
    data.get("match_ms_avg", ""),
    data.get("score_all_ms_avg", ""),
    data.get("score_all_ratio_pct", ""),
    data.get("score_all_calls_total", ""),
    data.get("score_all_candidates_total", ""),
    data.get("score_all_scan_points_total", ""),
    data.get("score_all_cell_checks_total", ""),
]
with open(csv_file, "a", newline="") as f:
    csv.writer(f).writerow(row)
PY
}

run_bag_variant() {
  local variant="$1"
  local run_id="$2"
  local ns="${NS_PREFIX}_${variant}_${run_id}"
  local log_file="$OUT_DIR/${variant}_run${run_id}.log"

  echo "Running BAG variant=$variant run=$run_id ns=$ns"
  (
    cd "$ROS_WS"
    source_ros
    # shellcheck disable=SC1091
    set +u
    source "$ROS_WS/install/setup.bash"
    set -u
    timeout "$BAG_TIMEOUT_SEC" ros2 launch "$PKG_NAME" cartographer_parallel_with_bag.launch.py \
      ns:="$ns" \
      bag_file:="$BAG_PATH" \
      map_yaml_file:="$MAP_PATH"
  ) 2>&1 | tee "$log_file" || true

  extract_summary "$variant" "$run_id" "$log_file"
}

variants=(ros_baseline ros_cpu_boundary_openmp)

for variant in "${variants[@]}"; do
  prepare_variant "$variant"
  build_ros_variant "$variant"
  for run_id in $(seq 1 "$BAG_RUNS"); do
    run_bag_variant "$variant" "$run_id"
  done
done

python3 - "$summary_csv" "$OUT_DIR/bag_summary_avg.csv" <<'PY'
import csv
import sys

summary_csv, avg_csv = sys.argv[1:3]
numeric = [
    "samples",
    "match_ms_avg",
    "score_all_ms_avg",
    "score_all_ratio_pct",
    "score_all_calls_total",
    "score_all_candidates_total",
    "score_all_scan_points_total",
    "score_all_cell_checks_total",
]
rows = []
with open(summary_csv, newline="") as f:
    for row in csv.DictReader(f):
        if not row.get("match_ms_avg"):
            continue
        rows.append(row)
groups = {}
for row in rows:
    groups.setdefault(row["variant"], []).append(row)
with open(avg_csv, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["variant", "runs"] + numeric)
    for variant in sorted(groups):
        items = groups[variant]
        out = [variant, len(items)]
        for key in numeric:
            vals = []
            for item in items:
                try:
                    vals.append(float(item[key]))
                except Exception:
                    pass
            out.append(sum(vals) / len(vals) if vals else "")
        writer.writerow(out)
PY

echo "BAG analysis written to $OUT_DIR"
echo "Summary: $summary_csv"
echo "Averages: $OUT_DIR/bag_summary_avg.csv"
