#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p results
stamp="$(date +%Y%m%d_%H%M%S)"
out="results/baseline_${stamp}.txt"

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"

{
  echo "## score_all 4096 candidates"
  ./build/benchmark_score_all_baseline --iters 20 --points 1200 --candidates 4096

  echo "## score_all 16384 candidates"
  ./build/benchmark_score_all_baseline --iters 20 --points 1200 --candidates 16384

  echo "## matcher local"
  ./build/benchmark_matcher_baseline \
    --iters 10 \
    --points 1200 \
    --map ../carrographer_task_ros2/carrographer_task_ros2/maps/0501.yaml
} | tee "$out"

echo "Saved results to $out"
