#!/usr/bin/env bash
set -euo pipefail

variants=(
  gpu_shared
  gpu_shared_cached_grid
  gpu_shared_batched
  gpu_reuse_buffer
  gpu_reuse_buffer_cached_grid
  gpu_reuse_buffer_cached_grid_batched
  gpu_reuse_block_cached_grid
)

for variant in "${variants[@]}"; do
  echo "============================================================"
  echo "Running remaining BAG GPU variant: ${variant}"
  echo "============================================================"
  bash run_bag_full_variant.sh "${variant}"
done

echo "Remaining BAG GPU variants finished."
