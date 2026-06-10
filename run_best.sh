#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p results
stamp="$(date +%Y%m%d_%H%M%S)"
out="results/best_cpu_boundary_openmp_${stamp}.txt"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}"

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"

{
  echo "## best cpu_boundary_openmp OMP_NUM_THREADS=${OMP_NUM_THREADS}"

  echo "## best score_all 4096 candidates"
  ./build/benchmark_score_all --iters 30 --points 1200 --candidates 4096

  echo "## best score_all 16384 candidates"
  ./build/benchmark_score_all --iters 30 --points 1200 --candidates 16384

  echo "## best matcher local"
  ./build/benchmark_matcher \
    --iters 20 \
    --points 1200 \
    --map ../carrographer_task_ros2/carrographer_task_ros2/maps/0501.yaml
} | tee "$out"

echo "Saved results to $out"
