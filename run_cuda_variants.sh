#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v nvcc >/dev/null 2>&1; then
  echo "nvcc was not found. Install CUDA Toolkit or source the Jetson CUDA environment." >&2
  echo "Jetson usually has nvcc at /usr/local/cuda/bin/nvcc." >&2
  exit 1
fi

mkdir -p results
stamp="$(date +%Y%m%d_%H%M%S)"
out="results/cuda_variants_${stamp}.txt"
variants=(
  gpu_thread
  gpu_block
  gpu_shared
  gpu_reuse_buffer
  gpu_reuse_block
  gpu_reuse_block_cached_grid
)

arch="${CUDA_ARCH:-}"
if [[ -z "$arch" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    arch="75"
  else
    arch="87"
  fi
fi

cmake_args=(-S . -B build_cuda -DCMAKE_BUILD_TYPE=Release -DENABLE_CUDA=ON)
if [[ -n "$arch" ]]; then
  cmake_args+=(-DCUDA_ARCHITECTURES="$arch")
fi

cmake "${cmake_args[@]}"
cmake --build build_cuda -j"$(nproc)"

for variant in "${variants[@]}"; do
  {
    echo "## score_all ${variant} 4096 candidates"
    "./build_cuda/benchmark_score_all_${variant}" --iters 20 --points 1200 --candidates 4096

    echo "## score_all ${variant} 16384 candidates"
    "./build_cuda/benchmark_score_all_${variant}" --iters 20 --points 1200 --candidates 16384

    echo "## matcher ${variant}"
    "./build_cuda/benchmark_matcher_${variant}" \
      --iters 10 \
      --points 1200 \
      --map ../carrographer_task_ros2/carrographer_task_ros2/maps/0501.yaml
  } | tee -a "$out"
done

echo "Saved results to $out"
