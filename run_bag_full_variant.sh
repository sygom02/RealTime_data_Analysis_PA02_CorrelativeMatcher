#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  cat >&2 <<'USAGE'
Usage:
  bash run_bag_full_variant.sh <variant>

Variants:
  baseline
  cpu_boundary_openmp
  score_buffer_reuse
  gpu_shared
  gpu_shared_cached_grid
  gpu_shared_batched
  gpu_reuse_buffer
  gpu_reuse_buffer_cached_grid
  gpu_reuse_buffer_cached_grid_batched
  gpu_reuse_warp_cached_grid_batched
  gpu_reuse_block_cached_grid

Optional environment variables:
  BAG_PATH=/data/student_02/cartographer_parallel/bags/scan.bag
  MAP_PATH=/data/student_02/cartographer_parallel/maps/0501.yaml
  SCAN_TOPIC=/scan
  BUILD_DIR=build_jetson_bag
  OUT_DIR=results/bag_full
USAGE
  exit 2
fi

variant="$1"

BAG_PATH="${BAG_PATH:-/data/student_02/cartographer_parallel/bags/scan.bag}"
MAP_PATH="${MAP_PATH:-/data/student_02/cartographer_parallel/maps/0501.yaml}"
SCAN_TOPIC="${SCAN_TOPIC:-/scan}"
BUILD_DIR="${BUILD_DIR:-build_jetson_bag}"
OUT_DIR="${OUT_DIR:-results/bag_full}"

case "${variant}" in
  baseline|cpu_boundary_openmp|score_buffer_reuse|\
  gpu_shared|gpu_shared_cached_grid|gpu_shared_batched|\
  gpu_reuse_buffer|gpu_reuse_buffer_cached_grid|\
  gpu_reuse_buffer_cached_grid_batched|\
  gpu_reuse_warp_cached_grid_batched|\
  gpu_reuse_block_cached_grid)
    ;;
  *)
    echo "Unknown variant: ${variant}" >&2
    exit 2
    ;;
esac

exe="${BUILD_DIR}/benchmark_bag_matcher_${variant}"
if [[ ! -x "${exe}" ]]; then
  echo "Executable not found or not executable: ${exe}" >&2
  echo "Build it first with the README.md build command." >&2
  exit 3
fi

mkdir -p "${OUT_DIR}"

summary="${OUT_DIR}/${variant}.json"
csv="${OUT_DIR}/${variant}.csv"

echo "Running BAG full benchmark"
echo "  variant=${variant}"
echo "  exe=${exe}"
echo "  bag=${BAG_PATH}"
echo "  map=${MAP_PATH}"
echo "  topic=${SCAN_TOPIC}"
echo "  summary=${summary}"
echo "  csv=${csv}"

"${exe}" \
  --bag "${BAG_PATH}" \
  --map "${MAP_PATH}" \
  --topic "${SCAN_TOPIC}" \
  --summary-json "${summary}" \
  --profile-csv "${csv}"

echo "Done: ${summary}"
