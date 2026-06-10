#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-/data/student_02/Optimization_project}"
MAP_PATH="${MAP_PATH:-/data/student_02/cartographer_parallel/maps/0501.yaml}"
BUILD_DIR="${BUILD_DIR:-build_jetson_reuse_state_probe}"
OUT_ROOT="${OUT_ROOT:-results/reuse_state_probe_$(date +%Y%m%d_%H%M%S)}"
CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-53}"
JOBS="${JOBS:-$(nproc)}"
RUNS="${RUNS:-5}"
ITERS="${ITERS:-10}"
WARMUP="${WARMUP:-3}"
POINTS="${POINTS:-1200}"
CANDIDATES="${CANDIDATES:-4096}"

variants=(
  gpu_shared
  gpu_reuse_shared_device
  gpu_reuse_shared_device_sync
  gpu_reuse_buffer
)

cd "${ROOT}"
mkdir -p "${OUT_ROOT}"

build_log="${OUT_ROOT}/build.log"
summary_csv="${OUT_ROOT}/reuse_state_probe_summary.csv"
avg_csv="${OUT_ROOT}/reuse_state_probe_summary_avg.csv"
findings_md="${OUT_ROOT}/reuse_state_probe_findings.md"

echo "Reuse state probe"
echo "  root=${ROOT}"
echo "  map=${MAP_PATH}"
echo "  build_dir=${BUILD_DIR}"
echo "  out=${OUT_ROOT}"
echo "  cuda_arch=${CUDA_ARCHITECTURES}"
echo "  runs=${RUNS}"
echo "  iters=${ITERS}"
echo "  warmup=${WARMUP}"
echo "  points=${POINTS}"
echo "  candidates=${CANDIDATES}"

target_args=()
for variant in "${variants[@]}"; do
  target_args+=(
    "benchmark_score_all_${variant}"
    "benchmark_matcher_${variant}"
    "benchmark_correctness_${variant}"
  )
done

echo "Configuring CUDA build..." | tee "${build_log}"
cmake -S "${ROOT}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_CUDA=ON \
  -DENABLE_OPENMP=ON \
  -DCUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
  2>&1 | tee -a "${build_log}"

echo "Building reuse-state probe targets..." | tee -a "${build_log}"
cmake --build "${BUILD_DIR}" -j "${JOBS}" --target "${target_args[@]}" \
  2>&1 | tee -a "${build_log}"

bin_path() {
  local target="$1"
  if [[ -x "${BUILD_DIR}/${target}" ]]; then
    printf '%s/%s\n' "${BUILD_DIR}" "${target}"
  elif [[ -x "${BUILD_DIR}/Release/${target}" ]]; then
    printf '%s/Release/%s\n' "${BUILD_DIR}" "${target}"
  else
    printf '%s/%s\n' "${BUILD_DIR}" "${target}"
  fi
}

kv() {
  local key="$1"
  local line="$2"
  printf '%s\n' "${line}" | tr ' ' '\n' | awk -F= -v key="${key}" '$1 == key { print $2; found=1 } END { if (!found) print "" }'
}

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "${value}"
}

echo "benchmark,variant,run,avg_ms,match_total_ms,score_total_ms,score_all_only_ms,score_all_call_count,batched_score_all_call_count,score_vector_alloc_count,device_alloc_ms,pinned_alloc_ms,h2d_grid_ms,h2d_scan_ms,h2d_cand_ms,h2d_total_ms,kernel_ms,d2h_score_ms,sync_ms,cpu_prepost_ms,throughput_mchecks_s,top1_same,topK_overlap,max_abs_error,log_path,csv_path" \
  > "${summary_csv}"

append_row() {
  local benchmark="$1"
  local variant="$2"
  local run="$3"
  local line="$4"
  local log_path="$5"
  local csv_path="$6"
  local avg_ms match_total_ms score_total_ms score_all_only_ms
  local score_all_call_count batched_score_all_call_count score_vector_alloc_count
  local device_alloc_ms pinned_alloc_ms h2d_grid_ms h2d_scan_ms h2d_cand_ms
  local h2d_total_ms kernel_ms d2h_score_ms sync_ms cpu_prepost_ms throughput
  local top1_same topk_overlap max_abs_error

  avg_ms="$(kv avg_ms "${line}")"
  match_total_ms="$(kv match_total_ms "${line}")"
  score_total_ms="$(kv score_total_ms "${line}")"
  score_all_only_ms="$(kv score_all_only_ms "${line}")"
  score_all_call_count="$(kv score_all_call_count "${line}")"
  batched_score_all_call_count="$(kv batched_score_all_call_count "${line}")"
  score_vector_alloc_count="$(kv score_vector_alloc_count "${line}")"
  device_alloc_ms="$(kv device_alloc_ms "${line}")"
  pinned_alloc_ms="$(kv pinned_alloc_ms "${line}")"
  h2d_grid_ms="$(kv h2d_grid_ms "${line}")"
  h2d_scan_ms="$(kv h2d_scan_ms "${line}")"
  h2d_cand_ms="$(kv h2d_cand_ms "${line}")"
  h2d_total_ms="$(kv h2d_total_ms "${line}")"
  kernel_ms="$(kv kernel_ms "${line}")"
  d2h_score_ms="$(kv d2h_score_ms "${line}")"
  sync_ms="$(kv sync_ms "${line}")"
  cpu_prepost_ms="$(kv cpu_prepost_ms "${line}")"
  throughput="$(kv throughput_mchecks_s "${line}")"
  top1_same="$(kv top1_same "${line}")"
  topk_overlap="$(kv topK_overlap "${line}")"
  max_abs_error="$(kv max_abs_error "${line}")"

  {
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,' \
      "${benchmark}" "${variant}" "${run}" "${avg_ms}" "${match_total_ms}" \
      "${score_total_ms}" "${score_all_only_ms}" "${score_all_call_count}" \
      "${batched_score_all_call_count}" "${score_vector_alloc_count}" \
      "${device_alloc_ms}" "${pinned_alloc_ms}" "${h2d_grid_ms}" \
      "${h2d_scan_ms}" "${h2d_cand_ms}" "${h2d_total_ms}" "${kernel_ms}" \
      "${d2h_score_ms}" "${sync_ms}" "${cpu_prepost_ms}" "${throughput}" \
      "${top1_same}" "${topk_overlap}" "${max_abs_error}"
    csv_escape "${log_path}"
    printf ','
    csv_escape "${csv_path}"
    printf '\n'
  } >> "${summary_csv}"
}

run_one() {
  local benchmark="$1"
  local variant="$2"
  local run="$3"
  local exe="$4"
  local out_dir="${OUT_ROOT}/${benchmark}/${variant}"
  local log_path="${out_dir}/run_${run}.log"
  local csv_path="${out_dir}/run_${run}.csv"
  local final_line

  mkdir -p "${out_dir}"
  echo "Running benchmark=${benchmark} variant=${variant} run=${run}"

  if [[ "${benchmark}" == "score_all" ]]; then
    "${exe}" \
      --iters "${ITERS}" \
      --warmup "${WARMUP}" \
      --points "${POINTS}" \
      --candidates "${CANDIDATES}" \
      --profile-csv "${csv_path}" \
      2>&1 | tee "${log_path}"
  elif [[ "${benchmark}" == "matcher" ]]; then
    "${exe}" \
      --iters "${ITERS}" \
      --points "${POINTS}" \
      --map "${MAP_PATH}" \
      --profile-csv "${csv_path}" \
      2>&1 | tee "${log_path}"
  elif [[ "${benchmark}" == "correctness" ]]; then
    "${exe}" \
      --points "${POINTS}" \
      --candidates "${CANDIDATES}" \
      2>&1 | tee "${log_path}"
    csv_path=""
  else
    echo "Unknown benchmark: ${benchmark}" >&2
    exit 9
  fi

  final_line="$(grep -E "benchmark=${benchmark}" "${log_path}" | tail -n 1 || true)"
  if [[ -z "${final_line}" ]]; then
    echo "No final benchmark line found in ${log_path}" >&2
    exit 10
  fi
  append_row "${benchmark}" "${variant}" "${run}" "${final_line}" "${log_path}" "${csv_path}"
}

for variant in "${variants[@]}"; do
  score_exe="$(bin_path "benchmark_score_all_${variant}")"
  matcher_exe="$(bin_path "benchmark_matcher_${variant}")"
  correctness_exe="$(bin_path "benchmark_correctness_${variant}")"

  for exe in "${score_exe}" "${matcher_exe}" "${correctness_exe}"; do
    if [[ ! -x "${exe}" ]]; then
      echo "Executable not found: ${exe}" >&2
      exit 8
    fi
  done

  for run in $(seq 1 "${RUNS}"); do
    run_one score_all "${variant}" "${run}" "${score_exe}"
    run_one matcher "${variant}" "${run}" "${matcher_exe}"
  done
  run_one correctness "${variant}" 1 "${correctness_exe}"
done

if command -v python3 >/dev/null 2>&1; then
  python3 - "${summary_csv}" "${avg_csv}" "${findings_md}" <<'PY'
import csv
import math
import sys
from collections import defaultdict

summary_csv, avg_csv, findings_md = sys.argv[1:4]
numeric_fields = [
    "avg_ms",
    "match_total_ms",
    "score_total_ms",
    "score_all_only_ms",
    "score_all_call_count",
    "batched_score_all_call_count",
    "score_vector_alloc_count",
    "device_alloc_ms",
    "pinned_alloc_ms",
    "h2d_grid_ms",
    "h2d_scan_ms",
    "h2d_cand_ms",
    "h2d_total_ms",
    "kernel_ms",
    "d2h_score_ms",
    "sync_ms",
    "cpu_prepost_ms",
    "throughput_mchecks_s",
    "top1_same",
    "topK_overlap",
    "max_abs_error",
]

def to_float(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None

rows = []
with open(summary_csv, newline="") as f:
    rows = list(csv.DictReader(f))

groups = defaultdict(list)
for row in rows:
    groups[(row["benchmark"], row["variant"])].append(row)

avg_rows = []
for (benchmark, variant), group_rows in sorted(groups.items()):
    out = {
        "benchmark": benchmark,
        "variant": variant,
        "runs": str(len(group_rows)),
    }
    for field in numeric_fields:
        values = [to_float(row.get(field)) for row in group_rows]
        values = [v for v in values if v is not None and not math.isnan(v)]
        if values:
            out[field] = "{:.6f}".format(sum(values) / len(values))
        else:
            out[field] = ""
    avg_rows.append(out)

avg_header = ["benchmark", "variant", "runs"] + numeric_fields
with open(avg_csv, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=avg_header)
    writer.writeheader()
    writer.writerows(avg_rows)

def find_avg(benchmark, variant, field):
    for row in avg_rows:
        if row["benchmark"] == benchmark and row["variant"] == variant:
            value = row.get(field, "")
            return float(value) if value else None
    return None

def fmt(value):
    if value is None:
        return ""
    return "{:.3f}".format(value)

def pct(after, before):
    if after is None or before in (None, 0):
        return ""
    return "{:+.1f}%".format((after - before) / before * 100.0)

variants = [
    "gpu_shared",
    "gpu_reuse_shared_device",
    "gpu_reuse_shared_device_sync",
    "gpu_reuse_buffer",
]

with open(findings_md, "w", encoding="utf-8") as f:
    f.write("# Reuse State Probe Findings\n\n")
    f.write("## Score_all Standalone Average\n\n")
    f.write("| variant | avg_ms | device_alloc_ms | pinned_alloc_ms | h2d_total_ms | kernel_ms | d2h_score_ms |\n")
    f.write("| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n")
    for variant in variants:
        f.write("| `{}` | {} | {} | {} | {} | {} | {} |\n".format(
            variant,
            fmt(find_avg("score_all", variant, "avg_ms")),
            fmt(find_avg("score_all", variant, "device_alloc_ms")),
            fmt(find_avg("score_all", variant, "pinned_alloc_ms")),
            fmt(find_avg("score_all", variant, "h2d_total_ms")),
            fmt(find_avg("score_all", variant, "kernel_ms")),
            fmt(find_avg("score_all", variant, "d2h_score_ms")),
        ))

    f.write("\n## Matcher Average\n\n")
    f.write("| variant | match_total_ms | score_all_only_ms | score_all_call_count | device_alloc_ms | pinned_alloc_ms | h2d_total_ms | kernel_ms | d2h_score_ms |\n")
    f.write("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n")
    for variant in variants:
        f.write("| `{}` | {} | {} | {} | {} | {} | {} | {} | {} |\n".format(
            variant,
            fmt(find_avg("matcher", variant, "match_total_ms")),
            fmt(find_avg("matcher", variant, "score_all_only_ms")),
            fmt(find_avg("matcher", variant, "score_all_call_count")),
            fmt(find_avg("matcher", variant, "device_alloc_ms")),
            fmt(find_avg("matcher", variant, "pinned_alloc_ms")),
            fmt(find_avg("matcher", variant, "h2d_total_ms")),
            fmt(find_avg("matcher", variant, "kernel_ms")),
            fmt(find_avg("matcher", variant, "d2h_score_ms")),
        ))

    shared_kernel = find_avg("matcher", "gpu_shared", "kernel_ms")
    shared_h2d = find_avg("matcher", "gpu_shared", "h2d_total_ms")
    f.write("\n## Kernel Increase Check vs `gpu_shared`\n\n")
    f.write("| variant | kernel_ms | kernel change | h2d_total_ms | h2d change | interpretation |\n")
    f.write("| --- | ---: | ---: | ---: | ---: | --- |\n")
    for variant in variants:
        kernel = find_avg("matcher", variant, "kernel_ms")
        h2d = find_avg("matcher", variant, "h2d_total_ms")
        if variant == "gpu_shared":
            interp = "baseline"
        elif variant == "gpu_reuse_shared_device":
            interp = "device buffer reuse only"
        elif variant == "gpu_reuse_shared_device_sync":
            interp = "device reuse plus explicit sync"
        else:
            interp = "full reuse path"
        f.write("| `{}` | {} | {} | {} | {} | {} |\n".format(
            variant,
            fmt(kernel),
            pct(kernel, shared_kernel),
            fmt(h2d),
            pct(h2d, shared_h2d),
            interp,
        ))

    f.write("\n## Correctness\n\n")
    f.write("| variant | top1_same | topK_overlap | max_abs_error |\n")
    f.write("| --- | ---: | ---: | ---: |\n")
    for variant in variants:
        f.write("| `{}` | {} | {} | {} |\n".format(
            variant,
            fmt(find_avg("correctness", variant, "top1_same")),
            fmt(find_avg("correctness", variant, "topK_overlap")),
            fmt(find_avg("correctness", variant, "max_abs_error")),
        ))

    f.write("\n## How To Read This Probe\n\n")
    f.write("- If `gpu_reuse_shared_device` and `gpu_reuse_shared_device_sync` do not show a large kernel increase while `gpu_reuse_buffer` does, stale device data is unlikely to be the direct cause.\n")
    f.write("- If all reuse variants show a similar kernel increase, buffer reuse or CUDA execution-state changes are stronger suspects.\n")
    f.write("- If `gpu_reuse_buffer` reduces H2D/alloc time but increases kernel time, report both facts separately: allocation reuse helped transfer/preparation overhead, but did not solve shared-kernel execution cost.\n")

print("Wrote {}".format(avg_csv))
print("Wrote {}".format(findings_md))
PY
else
  echo "python3 not found; average CSV and findings markdown were skipped."
fi

echo "Reuse state probe finished."
echo "Raw summary: ${summary_csv}"
echo "Average summary: ${avg_csv}"
echo "Findings: ${findings_md}"
