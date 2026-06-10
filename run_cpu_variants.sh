#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p results
stamp="$(date +%Y%m%d_%H%M%S)"
out="results/cpu_variants_${stamp}.txt"
variants=(baseline cpu_boundary cpu_openmp cpu_boundary_openmp)

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"

for variant in "${variants[@]}"; do
  {
    echo "## score_all ${variant} 4096 candidates"
    "./build/benchmark_score_all_${variant}" --iters 30 --points 1200 --candidates 4096

    echo "## score_all ${variant} 16384 candidates"
    "./build/benchmark_score_all_${variant}" --iters 30 --points 1200 --candidates 16384

    echo "## matcher ${variant}"
    "./build/benchmark_matcher_${variant}" \
      --iters 20 \
      --points 1200 \
      --map ../carrographer_task_ros2/carrographer_task_ros2/maps/0501.yaml
  } | tee -a "$out"
done

echo "Saved results to $out"
