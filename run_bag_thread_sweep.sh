#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  bash run_bag_thread_sweep.sh <variant>
  bash run_bag_thread_sweep.sh all

Recommended variants:
  gpu_reuse_buffer
  gpu_reuse_buffer_cached_grid_batched
  gpu_reuse_warp_cached_grid_batched

Default thread values:
  64 128 256 512

Optional environment variables:
  THREAD_VALUES="64 128 256 512"
  OUT_ROOT=results/bag_full_thread_sweep_<timestamp>
  BAG_PATH=/data/student_02/cartographer_parallel/bags/scan.bag
  MAP_PATH=/data/student_02/cartographer_parallel/maps/0501.yaml
  SCAN_TOPIC=/scan
  BUILD_DIR=build_jetson_bag_offline
USAGE
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

if [[ ! -f run_bag_full_variant.sh ]]; then
  echo "run_bag_full_variant.sh is required in the current directory." >&2
  exit 3
fi

if [[ "$1" == "all" ]]; then
  variants=(
    gpu_reuse_buffer
    gpu_reuse_buffer_cached_grid_batched
    gpu_reuse_warp_cached_grid_batched
  )
else
  variants=("$@")
fi

THREAD_VALUES="${THREAD_VALUES:-64 128 256 512}"
OUT_ROOT="${OUT_ROOT:-results/bag_full_thread_sweep_$(date +%Y%m%d_%H%M%S)}"
summary_csv="${OUT_ROOT}/thread_sweep_summary.csv"

mkdir -p "${OUT_ROOT}"

extract_json_number() {
  local key="$1"
  local file="$2"
  local value
  value="$(grep -m1 "\"${key}\"" "${file}" | sed -E 's/.*: ([0-9.+-eE]+).*/\1/' || true)"
  if [[ -z "${value}" ]]; then
    value="0"
  fi
  echo "${value}"
}

echo "variant,threads,processed_scans,ok_count,match_ms_avg,score_all_ms_avg,score_all_call_count,batched_score_all_call_count,h2d_total_ms_avg,kernel_ms_avg,d2h_score_ms_avg,summary_json,profile_csv" \
  > "${summary_csv}"

for variant in "${variants[@]}"; do
  case "${variant}" in
    gpu_reuse_buffer|gpu_reuse_buffer_cached_grid_batched|gpu_reuse_warp_cached_grid_batched)
      ;;
    *)
      echo "Unsupported sweep variant: ${variant}" >&2
      echo "Use one of the recommended variants or update this script deliberately." >&2
      exit 4
      ;;
  esac

  for threads in ${THREAD_VALUES}; do
    out_dir="${OUT_ROOT}/${variant}/threads_${threads}"
    echo "============================================================"
    echo "Running BAG thread sweep"
    echo "  variant=${variant}"
    echo "  SCORE_ALL_CUDA_THREADS=${threads}"
    echo "  out_dir=${out_dir}"
    echo "============================================================"

    SCORE_ALL_CUDA_THREADS="${threads}" OUT_DIR="${out_dir}" \
      bash run_bag_full_variant.sh "${variant}"

    json="${out_dir}/${variant}.json"
    csv="${out_dir}/${variant}.csv"
    if [[ ! -f "${json}" ]]; then
      echo "Missing summary json: ${json}" >&2
      exit 5
    fi

    processed_scans="$(extract_json_number processed_scans "${json}")"
    ok_count="$(extract_json_number ok_count "${json}")"
    match_ms_avg="$(extract_json_number match_ms_avg "${json}")"
    score_all_ms_avg="$(extract_json_number score_all_ms_avg "${json}")"
    score_all_call_count="$(extract_json_number score_all_call_count "${json}")"
    batched_score_all_call_count="$(extract_json_number batched_score_all_call_count "${json}")"
    h2d_total_ms_avg="$(extract_json_number h2d_total_ms_avg "${json}")"
    kernel_ms_avg="$(extract_json_number kernel_ms_avg "${json}")"
    d2h_score_ms_avg="$(extract_json_number d2h_score_ms_avg "${json}")"

    echo "${variant},${threads},${processed_scans},${ok_count},${match_ms_avg},${score_all_ms_avg},${score_all_call_count},${batched_score_all_call_count},${h2d_total_ms_avg},${kernel_ms_avg},${d2h_score_ms_avg},${json},${csv}" \
      >> "${summary_csv}"
  done
done

echo "Thread sweep finished."
echo "Summary: ${summary_csv}"
