#!/usr/bin/env bash
set -euo pipefail

OPT_ROOT="${1:-/data/student_02/Optimization_project}"
BAG_PATH="${BAG_PATH:-/data/student_02/cartographer_parallel/bags/scan.bag}"
MAP_PATH="${MAP_PATH:-/data/student_02/cartographer_parallel/maps/0501.yaml}"
SCAN_TOPIC="${SCAN_TOPIC:-/scan}"
BAG_RUNS="${BAG_RUNS:-3}"
BAG_START_SEC="${BAG_START_SEC:-}"
BAG_DURATION_SEC="${BAG_DURATION_SEC:-}"
CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-53}"
CUDA_ARCH_FALLBACKS="${CUDA_ARCH_FALLBACKS:-53}"
ENABLE_CUDA="${ENABLE_CUDA:-ON}"
INITIAL_X="${INITIAL_X:--2.0}"
INITIAL_Y="${INITIAL_Y:-6.82}"
INITIAL_YAW="${INITIAL_YAW:--3.0255282583321743}"
NODE_IDLE_SEC="${NODE_IDLE_SEC:-1.5}"
NODE_WAIT_SEC="${NODE_WAIT_SEC:-180}"
MAX_SCANS="${MAX_SCANS:-3}"
BAG_RATE="${BAG_RATE:-1.0}"

if [[ -z "$BAG_START_SEC" || -z "$BAG_DURATION_SEC" ]]; then
  echo "BAG_START_SEC and BAG_DURATION_SEC are required." >&2
  echo "Example:" >&2
  echo "  BAG_START_SEC=40 BAG_DURATION_SEC=20 bash $0 $OPT_ROOT" >&2
  exit 1
fi

if [[ ! -f "$BAG_PATH" ]]; then
  echo "Missing BAG_PATH: $BAG_PATH" >&2
  exit 1
fi
if [[ ! -f "$MAP_PATH" ]]; then
  echo "Missing MAP_PATH: $MAP_PATH" >&2
  exit 1
fi

source_ros1() {
  set +u
  if [[ -n "${ROS_DISTRO:-}" && -f "/opt/ros/$ROS_DISTRO/setup.bash" ]]; then
    # shellcheck disable=SC1090
    source "/opt/ros/$ROS_DISTRO/setup.bash"
  elif [[ -f /opt/ros/melodic/setup.bash ]]; then
    # shellcheck disable=SC1091
    source /opt/ros/melodic/setup.bash
  else
    echo "ROS1 setup.bash was not found under /opt/ros." >&2
    exit 1
  fi
  export CMAKE_PREFIX_PATH="/opt/ros/melodic:${CMAKE_PREFIX_PATH:-}"
  export ROS_PACKAGE_PATH="/opt/ros/melodic/share:${ROS_PACKAGE_PATH:-}"
  set -u
}

timestamp="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="$OPT_ROOT/results/bag_segment_analysis_$timestamp"
BUILD_DIR="$OPT_ROOT/build_jetson_bag_segment"
mkdir -p "$OUT_DIR"

source_ros1

echo "BAG info:" | tee "$OUT_DIR/bag_info.txt"
rosbag info "$BAG_PATH" | tee -a "$OUT_DIR/bag_info.txt"

echo "Configuring ROS1 BAG segment build..."
rm -rf "$BUILD_DIR"
cmake_ros_args=(
  -DCMAKE_PREFIX_PATH=/opt/ros/melodic
  -Dcatkin_DIR=/opt/ros/melodic/share/catkin/cmake
)
for ros_pkg in roscpp geometry_msgs nav_msgs sensor_msgs std_msgs visualization_msgs; do
  if [[ -d "/opt/ros/melodic/share/${ros_pkg}/cmake" ]]; then
    cmake_ros_args+=("-D${ros_pkg}_DIR=/opt/ros/melodic/share/${ros_pkg}/cmake")
  fi
done
cmake -S "$OPT_ROOT" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_ROS1_BAG_NODE=ON \
  -DENABLE_CUDA="$ENABLE_CUDA" \
  -DENABLE_OPENMP=ON \
  -DCUDA_ARCHITECTURES="$CUDA_ARCHITECTURES" \
  "${cmake_ros_args[@]}"

targets=(
  fast_correlative_node_baseline
  fast_correlative_node_cpu_boundary_openmp
  fast_correlative_node_score_buffer_reuse
)

if [[ "$ENABLE_CUDA" == "ON" ]]; then
  targets+=(
    fast_correlative_node_gpu_shared
    fast_correlative_node_gpu_shared_cached_grid
    fast_correlative_node_gpu_shared_batched
    fast_correlative_node_gpu_reuse_buffer
    fast_correlative_node_gpu_reuse_buffer_cached_grid
    fast_correlative_node_gpu_reuse_buffer_cached_grid_batched
    fast_correlative_node_gpu_reuse_warp_cached_grid_batched
  )
fi

echo "Building ROS1 BAG segment node targets..."
cmake --build "$BUILD_DIR" -j"$(nproc)" --target "${targets[@]}"

ROSCORE_PID=""
cleanup() {
  if [[ -n "${NODE_PID:-}" ]] && kill -0 "$NODE_PID" >/dev/null 2>&1; then
    kill "$NODE_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ROSCORE_PID" ]] && kill -0 "$ROSCORE_PID" >/dev/null 2>&1; then
    kill "$ROSCORE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! rostopic list >/dev/null 2>&1; then
  echo "Starting roscore..."
  roscore > "$OUT_DIR/roscore.log" 2>&1 &
  ROSCORE_PID="$!"
  sleep 3
fi

summary_csv="$OUT_DIR/bag_segment_summary.csv"
cat > "$summary_csv" <<'EOF'
variant,run,samples,ok_count,match_ms_avg,score_total_ms_avg,score_all_ms_avg,score_grouping_ms_avg,score_sort_ms_avg,score_vector_alloc_count,score_all_call_count,batched_score_all_call_count,candidate_before,candidate_after,pruned_ratio,device_alloc_ms_avg,h2d_grid_ms_avg,h2d_scan_ms_avg,h2d_cand_ms_avg,h2d_total_ms_avg,kernel_ms_avg,d2h_score_ms_avg,last_score,top_candidates
EOF

extract_summary() {
  local variant="$1"
  local run_id="$2"
  local node_log="$3"
  local json_file="$OUT_DIR/${variant}_run${run_id}_summary.json"
  local line
  if [[ -s "$json_file" ]]; then
    python3 - "$variant" "$run_id" "$json_file" "$summary_csv" <<'PY'
import csv
import json
import sys

variant, run_id, json_file, csv_file = sys.argv[1:5]
with open(json_file, "r") as f:
    data = json.load(f)
keys = [
    "samples",
    "ok_count",
    "match_ms_avg",
    "score_total_ms_avg",
    "score_all_ms_avg",
    "score_grouping_ms_avg",
    "score_sort_ms_avg",
    "score_vector_alloc_count",
    "score_all_call_count",
    "batched_score_all_call_count",
    "candidate_before",
    "candidate_after",
    "pruned_ratio",
    "device_alloc_ms_avg",
    "h2d_grid_ms_avg",
    "h2d_scan_ms_avg",
    "h2d_cand_ms_avg",
    "h2d_total_ms_avg",
    "kernel_ms_avg",
    "d2h_score_ms_avg",
    "last_score",
    "top_candidates",
]
row = [variant, run_id] + [data.get(k, "") for k in keys]
with open(csv_file, "a", newline="") as f:
    csv.writer(f).writerow(row)
PY
    return
  fi
  line="$(grep -h 'perf_summary_json=' "$node_log" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "$variant,$run_id,,,,,,,,,,,,,,,,,,,,,," >> "$summary_csv"
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
keys = [
    "samples",
    "ok_count",
    "match_ms_avg",
    "score_total_ms_avg",
    "score_all_ms_avg",
    "score_grouping_ms_avg",
    "score_sort_ms_avg",
    "score_vector_alloc_count",
    "score_all_call_count",
    "batched_score_all_call_count",
    "candidate_before",
    "candidate_after",
    "pruned_ratio",
    "device_alloc_ms_avg",
    "h2d_grid_ms_avg",
    "h2d_scan_ms_avg",
    "h2d_cand_ms_avg",
    "h2d_total_ms_avg",
    "kernel_ms_avg",
    "d2h_score_ms_avg",
    "last_score",
    "top_candidates",
]
row = [variant, run_id] + [data.get(k, "") for k in keys]
with open(csv_file, "a", newline="") as f:
    csv.writer(f).writerow(row)
PY
}

run_variant_once() {
  local variant="$1"
  local run_id="$2"
  local exe="$BUILD_DIR/fast_correlative_node_$variant"
  local node_log="$OUT_DIR/${variant}_run${run_id}_node.log"
  local bag_log="$OUT_DIR/${variant}_run${run_id}_bag.log"
  local summary_file="$OUT_DIR/${variant}_run${run_id}_summary.json"
  local node_name="bagseg_${variant}_${run_id}"

  if [[ ! -x "$exe" ]]; then
    echo "Missing executable: $exe" >&2
    return
  fi

  echo "Running variant=$variant run=$run_id"
  echo "  MAX_SCANS=$MAX_SCANS NODE_WAIT_SEC=$NODE_WAIT_SEC BAG_RATE=$BAG_RATE"
  "$exe" \
    __name:="$node_name" \
    _map_yaml_file:="$MAP_PATH" \
    _scan_topic:="$SCAN_TOPIC" \
    _initial_x:="$INITIAL_X" \
    _initial_y:="$INITIAL_Y" \
    _initial_yaw:="$INITIAL_YAW" \
    _global_first_match:=false \
    _global_every_n:=0 \
    _linear_search_window:=3.0 \
    _global_search_window:=20.0 \
    _angular_search_window:=0.35 \
    _angular_step:=0.05 \
    _branch_and_bound_depth:=4 \
    _min_score:=0.05 \
    _publish_top_candidates:=150 \
    _max_candidates:=150 \
    _perf_summary_idle_seconds:="$NODE_IDLE_SEC" \
    _perf_shutdown_on_idle:=true \
    _max_perf_samples:="$MAX_SCANS" \
    _perf_summary_file:="$summary_file" \
    > "$node_log" 2>&1 &
  NODE_PID="$!"

  sleep 1
  rosbag play "$BAG_PATH" \
    --start "$BAG_START_SEC" \
    --duration "$BAG_DURATION_SEC" \
    --rate "$BAG_RATE" \
    --topics "$SCAN_TOPIC" \
    > "$bag_log" 2>&1 || true

  for _ in $(seq 1 "$NODE_WAIT_SEC"); do
    if ! kill -0 "$NODE_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if kill -0 "$NODE_PID" >/dev/null 2>&1; then
    echo "Node did not exit after idle timeout; killing $NODE_PID" >&2
    kill "$NODE_PID" >/dev/null 2>&1 || true
  fi
  wait "$NODE_PID" >/dev/null 2>&1 || true
  NODE_PID=""

  extract_summary "$variant" "$run_id" "$node_log"
}

variants=(
  baseline
  cpu_boundary_openmp
  score_buffer_reuse
)
if [[ "$ENABLE_CUDA" == "ON" ]]; then
  variants+=(
    gpu_shared
    gpu_shared_cached_grid
    gpu_shared_batched
    gpu_reuse_buffer
    gpu_reuse_buffer_cached_grid
    gpu_reuse_buffer_cached_grid_batched
    gpu_reuse_warp_cached_grid_batched
  )
fi

for variant in "${variants[@]}"; do
  for run_id in $(seq 1 "$BAG_RUNS"); do
    run_variant_once "$variant" "$run_id"
  done
done

python3 - "$summary_csv" "$OUT_DIR/bag_segment_summary_avg.csv" "$OUT_DIR/bag_segment_findings.md" <<'PY'
import csv
import sys

summary_csv, avg_csv, md_file = sys.argv[1:4]
metrics = [
    "samples",
    "ok_count",
    "match_ms_avg",
    "score_total_ms_avg",
    "score_all_ms_avg",
    "score_grouping_ms_avg",
    "score_sort_ms_avg",
    "score_vector_alloc_count",
    "score_all_call_count",
    "batched_score_all_call_count",
    "candidate_before",
    "candidate_after",
    "pruned_ratio",
    "device_alloc_ms_avg",
    "h2d_total_ms_avg",
    "kernel_ms_avg",
    "d2h_score_ms_avg",
]
rows = []
with open(summary_csv, newline="") as f:
    for row in csv.DictReader(f):
        if row.get("match_ms_avg"):
            rows.append(row)
groups = {}
for row in rows:
    groups.setdefault(row["variant"], []).append(row)
avg_rows = []
for variant in sorted(groups):
    items = groups[variant]
    avg = {"variant": variant, "runs": len(items)}
    for key in metrics:
        vals = []
        for item in items:
            try:
                vals.append(float(item.get(key, "")))
            except Exception:
                pass
        avg[key] = sum(vals) / len(vals) if vals else ""
    avg_rows.append(avg)
with open(avg_csv, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["variant", "runs"] + metrics)
    writer.writeheader()
    for row in avg_rows:
        writer.writerow(row)
best = None
for row in avg_rows:
    val = row.get("match_ms_avg")
    if val == "":
        continue
    if best is None or val < best.get("match_ms_avg", 1e100):
        best = row
with open(md_file, "w") as f:
    f.write("# BAG Segment Findings\n\n")
    if best:
        f.write("Best variant by match_ms_avg: `{}` ({:.6f} ms).\n\n".format(
            best["variant"], best["match_ms_avg"]))
    f.write("| variant | runs | match_ms_avg | score_all_ms_avg | score_all_call_count | h2d_total_ms_avg | kernel_ms_avg |\n")
    f.write("| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n")
    for row in avg_rows:
        f.write("| {} | {} | {:.6f} | {:.6f} | {:.3f} | {:.6f} | {:.6f} |\n".format(
            row["variant"], row["runs"],
            float(row["match_ms_avg"] or 0.0),
            float(row["score_all_ms_avg"] or 0.0),
            float(row["score_all_call_count"] or 0.0),
            float(row["h2d_total_ms_avg"] or 0.0),
            float(row["kernel_ms_avg"] or 0.0)))
    f.write("\nNote: `pruned_ratio` is a candidate reduction proxy from scored candidates to published top candidates in the ROS1 node, not a dedicated pruning-before/after hook.\n")
PY

echo "BAG segment analysis written to $OUT_DIR"
echo "Summary: $summary_csv"
echo "Averages: $OUT_DIR/bag_segment_summary_avg.csv"
echo "Findings: $OUT_DIR/bag_segment_findings.md"
