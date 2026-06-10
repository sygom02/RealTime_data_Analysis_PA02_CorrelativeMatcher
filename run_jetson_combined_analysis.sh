#!/usr/bin/env bash
set -euo pipefail

OPT_ROOT="${1:-/data/student_02/Optimization_project}"
ROS_WS="${2:-/data/student_02/cartographer_parallel}"
MAP_PATH="${MAP_PATH:-$ROS_WS/maps/0501.yaml}"

echo "=== Standalone Optimization_project analysis ==="
CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-72}" ITERS="${ITERS:-10}" \
  bash "$OPT_ROOT/run_jetson_full_analysis.sh" "$OPT_ROOT" "$MAP_PATH"

if [[ -n "${BAG_START_SEC:-}" && -n "${BAG_DURATION_SEC:-}" ]]; then
  echo "=== ROS1 BAG segment analysis ==="
  BAG_PATH="${BAG_PATH:-$ROS_WS/bags/scan.bag}" \
  MAP_PATH="$MAP_PATH" \
  BAG_RUNS="${BAG_RUNS:-3}" \
    bash "$OPT_ROOT/run_jetson_bag_segment_analysis.sh" "$OPT_ROOT"
else
  echo "Skipping BAG segment analysis because BAG_START_SEC/BAG_DURATION_SEC were not set."
fi

echo "Combined analysis complete."
