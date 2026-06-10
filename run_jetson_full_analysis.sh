#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-/data/student_02/Optimization_project}"
MAP="${2:-/data/student_02/cartographer_parallel/maps/0501.yaml}"
ITERS="${ITERS:-10}"
JOBS="${JOBS:-$(nproc)}"
CUDA_ARCH="${CUDA_ARCHITECTURES:-72}"
CUDA_ARCH_FALLBACKS="${CUDA_ARCH_FALLBACKS:-$CUDA_ARCH 62 53}"
RUN_NSIGHT="${RUN_NSIGHT:-0}"
RUN_NCU="${RUN_NCU:-0}"
RUN_THREAD_SWEEP="${RUN_THREAD_SWEEP:-1}"
NSIGHT_ITERS="${NSIGHT_ITERS:-5}"
NCU_LAUNCH_COUNT="${NCU_LAUNCH_COUNT:-8}"
THREAD_SWEEP_ITERS="${THREAD_SWEEP_ITERS:-$NSIGHT_ITERS}"

cd "$ROOT"
timestamp="$(date +%Y%m%d_%H%M%S)"
out_dir="$ROOT/results/jetson_analysis_$timestamp"
mkdir -p "$out_dir"

run_and_log() {
  local summary="$1"
  shift
  echo "$*" | tee -a "$summary"
  "$@" | tee -a "$summary"
}

bin_path() {
  local build="$1"
  local target="$2"
  if [[ -x "$build/$target" ]]; then
    printf '%s/%s\n' "$build" "$target"
  elif [[ -x "$build/Release/$target" ]]; then
    printf '%s/Release/%s\n' "$build" "$target"
  else
    printf '%s/%s\n' "$build" "$target"
  fi
}

configure_cuda_build() {
  local arch
  local log="$out_dir/cuda_configure_build.log"
  local smoke_log
  local smoke_exe
  for arch in $CUDA_ARCH_FALLBACKS; do
    echo "Trying CUDA_ARCHITECTURES=$arch" | tee -a "$log"
    rm -rf "$cuda_build"
    if cmake -S "$ROOT" -B "$cuda_build" -DCMAKE_BUILD_TYPE=Release \
      -DENABLE_CUDA=ON -DCUDA_ARCHITECTURES="$arch" 2>&1 | tee -a "$log" &&
      cmake --build "$cuda_build" -j "$JOBS" 2>&1 | tee -a "$log"; then
      smoke_exe="$(bin_path "$cuda_build" benchmark_score_all_gpu_thread)"
      smoke_log="$out_dir/cuda_smoke_arch_${arch}.log"
      echo "Running CUDA runtime smoke test for arch $arch" | tee -a "$log"
      if [[ -x "$smoke_exe" ]] &&
        "$smoke_exe" --iters 1 --warmup 0 --points 16 --candidates 16 \
          > "$smoke_log" 2>&1; then
        echo "$arch" > "$out_dir/cuda_arch_used.txt"
        echo "CUDA arch $arch passed runtime smoke test." | tee -a "$log"
        return 0
      fi
      echo "CUDA arch $arch built but failed runtime smoke test; trying next fallback." |
        tee -a "$log"
      if [[ -f "$smoke_log" ]]; then
        cat "$smoke_log" | tee -a "$log"
      fi
    fi
    echo "CUDA arch $arch failed; trying next fallback." | tee -a "$log"
  done
  return 1
}

write_best_strategy_summary() {
  if [[ -f "$ROOT/summarize_best_strategy.py" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 "$ROOT/summarize_best_strategy.py" --results-dir "$out_dir" || true
    elif command -v python >/dev/null 2>&1; then
      python "$ROOT/summarize_best_strategy.py" --results-dir "$out_dir" || true
    else
      echo "python was not found; best strategy summary skipped." |
        tee -a "$out_dir/best_strategy_summary.log"
    fi
  fi
}

run_thread_block_sweep() {
  local summary="$out_dir/thread_block_sweep_summary.txt"
  local threads
  local variant
  local exe
  local csv
  local variants=(
    gpu_reuse_buffer
    gpu_reuse_buffer_cached_grid_batched
    gpu_reuse_warp_cached_grid_batched
  )

  echo "Thread block size sweep" | tee -a "$summary"
  for threads in 64 128 256 512; do
    for variant in "${variants[@]}"; do
      exe="$(bin_path "$cuda_build" "benchmark_matcher_${variant}")"
      if [[ ! -x "$exe" ]]; then
        echo "skip $variant threads=$threads missing executable $exe" |
          tee -a "$summary"
        continue
      fi
      csv="$out_dir/matcher_${variant}_threads${threads}_profile.csv"
      echo -n "thread_sweep $variant threads=$threads " | tee -a "$summary"
      SCORE_ALL_CUDA_THREADS="$threads" \
        "$exe" --iters "$THREAD_SWEEP_ITERS" --points 1200 --map "$MAP" \
        --profile-csv "$csv" | tee -a "$summary"
    done
  done
}

run_nsight_systems() {
  local nsight_dir="$out_dir/nsight_systems"
  local summary="$out_dir/nsight_systems_summary.txt"
  local variant
  local exe
  local report_base
  local stats_file
  local variants=(
    gpu_shared
    gpu_shared_cached_grid
    gpu_shared_batched
    gpu_reuse_buffer
    gpu_reuse_buffer_cached_grid
    gpu_reuse_buffer_cached_grid_batched
    gpu_reuse_warp_cached_grid_batched
    score_buffer_reuse
  )

  mkdir -p "$nsight_dir"
  if ! command -v nsys >/dev/null 2>&1; then
    echo "nsys not found; Nsight Systems analysis skipped." |
      tee -a "$summary"
    return 0
  fi

  for variant in "${variants[@]}"; do
    if [[ "$variant" == "score_buffer_reuse" ]]; then
      exe="$(bin_path "$reuse_build" benchmark_matcher_cpu_boundary_openmp)"
    else
      exe="$(bin_path "$cuda_build" "benchmark_matcher_${variant}")"
    fi
    if [[ ! -x "$exe" ]]; then
      echo "skip $variant missing executable $exe" | tee -a "$summary"
      continue
    fi

    report_base="$nsight_dir/${variant}"
    stats_file="$nsight_dir/${variant}_stats.txt"
    echo "nsys profile $variant" | tee -a "$summary"
    if nsys profile --trace=cuda,nvtx,osrt --stats=true \
      --force-overwrite=true -o "$report_base" \
      "$exe" --iters "$NSIGHT_ITERS" --points 1200 --map "$MAP" \
      --profile-csv "$out_dir/nsight_${variant}_matcher_profile.csv" \
      2>&1 | tee -a "$summary"; then
      if [[ -f "${report_base}.nsys-rep" ]]; then
        nsys stats \
          --report cuda_api_sum,cuda_gpu_kern_sum,cuda_gpu_mem_time_sum,osrt_sum,nvtx_sum \
          "${report_base}.nsys-rep" > "$stats_file" 2>&1 || true
      fi
    else
      echo "nsys profile failed for $variant; continuing." | tee -a "$summary"
    fi
  done
}

run_nsight_compute() {
  local ncu_dir="$out_dir/nsight_compute"
  local summary="$out_dir/nsight_compute_summary.txt"
  local variant
  local exe
  local variants=(
    gpu_shared
    gpu_shared_batched
    gpu_reuse_buffer
    gpu_reuse_buffer_cached_grid_batched
    gpu_reuse_warp_cached_grid_batched
    gpu_reuse_block_cached_grid
  )

  mkdir -p "$ncu_dir"
  if ! command -v ncu >/dev/null 2>&1; then
    echo "ncu not found; Nsight Compute analysis skipped." |
      tee -a "$summary"
    return 0
  fi

  for variant in "${variants[@]}"; do
    exe="$(bin_path "$cuda_build" "benchmark_matcher_${variant}")"
    if [[ ! -x "$exe" ]]; then
      echo "skip $variant missing executable $exe" | tee -a "$summary"
      continue
    fi

    echo "ncu profile $variant" | tee -a "$summary"
    if ! ncu --set full --target-processes all \
      --kernel-name regex:Score.*Kernel \
      --launch-count "$NCU_LAUNCH_COUNT" \
      --force-overwrite -o "$ncu_dir/${variant}" \
      "$exe" --iters "$NSIGHT_ITERS" --points 1200 --map "$MAP" \
      2>&1 | tee -a "$summary"; then
      echo "ncu profile failed for $variant; continuing." | tee -a "$summary"
    fi
  done
}

cpu_build="$ROOT/build_jetson_profile_cpu"
reuse_build="$ROOT/build_jetson_profile_reuse"
bucket_build="$ROOT/build_jetson_profile_bucket"
cuda_build="$ROOT/build_jetson_profile_cuda"

cmake -S "$ROOT" -B "$cpu_build" -DCMAKE_BUILD_TYPE=Release -DENABLE_CUDA=OFF
cmake --build "$cpu_build" -j "$JOBS"

cmake -S "$ROOT" -B "$reuse_build" -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_CUDA=OFF -DENABLE_SCORE_BUFFER_REUSE=ON
cmake --build "$reuse_build" -j "$JOBS"

cmake -S "$ROOT" -B "$bucket_build" -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_CUDA=OFF -DENABLE_SCORE_BUCKETING=ON
cmake --build "$bucket_build" -j "$JOBS"

pipeline_summary="$out_dir/pipeline_score_summary.txt"
declare -A matcher_cases=(
  [baseline]="$(bin_path "$cpu_build" benchmark_matcher_baseline)"
  [cpu_boundary_openmp]="$(bin_path "$cpu_build" benchmark_matcher_cpu_boundary_openmp)"
  [score_buffer_reuse]="$(bin_path "$reuse_build" benchmark_matcher_cpu_boundary_openmp)"
  [score_bucket_grouping]="$(bin_path "$bucket_build" benchmark_matcher_cpu_boundary_openmp)"
)
for name in baseline cpu_boundary_openmp score_buffer_reuse score_bucket_grouping; do
  csv="$out_dir/${name}_matcher_profile.csv"
  echo -n "$name " | tee -a "$pipeline_summary"
  "${matcher_cases[$name]}" --iters "$ITERS" --points 1200 --map "$MAP" \
    --profile-csv "$csv" | tee -a "$pipeline_summary"
done

score_summary="$out_dir/score_scaling_pruning_summary.txt"
sizes=("256 1000" "512 5000" "1081 10000" "2048 50000")
gpu_breakdown_variants=(
  gpu_thread
  gpu_block
  gpu_shared
  gpu_shared_cached_grid
  gpu_reuse_buffer
  gpu_reuse_buffer_cached_grid
  gpu_reuse_block
  gpu_reuse_block_cached_grid
)
gpu_matcher_variants=(
  gpu_shared
  gpu_shared_cached_grid
  gpu_shared_batched
  gpu_block
  gpu_reuse_buffer
  gpu_reuse_buffer_cached_grid
  gpu_reuse_buffer_cached_grid_batched
  gpu_reuse_warp_cached_grid_batched
  gpu_reuse_block
  gpu_reuse_block_cached_grid
  cpu_boundary_openmp
)
gpu_scaling_variants=(
  gpu_reuse_buffer
  gpu_reuse_buffer_cached_grid
  gpu_reuse_block
  gpu_reuse_block_cached_grid
)
gpu_correctness_variants=(
  gpu_thread
  gpu_block
  gpu_shared
  gpu_shared_cached_grid
  gpu_shared_batched
  gpu_reuse_buffer
  gpu_reuse_buffer_cached_grid
  gpu_reuse_buffer_cached_grid_batched
  gpu_reuse_warp_cached_grid_batched
  gpu_reuse_block
  gpu_reuse_block_cached_grid
)
for item in "${sizes[@]}"; do
  read -r points candidates <<< "$item"
  for variant in baseline cpu_boundary_openmp; do
    exe="$(bin_path "$cpu_build" "benchmark_score_all_${variant}")"
    csv="$out_dir/score_${variant}_p${points}_c${candidates}.csv"
    echo -n "score_all $variant p=$points c=$candidates " |
      tee -a "$score_summary"
    "$exe" --iters "$ITERS" --warmup 3 --points "$points" \
      --candidates "$candidates" --profile-csv "$csv" |
      tee -a "$score_summary"
  done
done
for variant in baseline cpu_boundary_openmp; do
  exe="$(bin_path "$cpu_build" "benchmark_pruning_${variant}")"
  echo -n "pruning $variant " | tee -a "$score_summary"
  "$exe" --iters "$ITERS" --warmup 3 --points 1200 --candidates 4096 |
    tee -a "$score_summary"
done

correctness_summary="$out_dir/correctness_summary.txt"
for variant in baseline cpu_boundary_openmp; do
  exe="$(bin_path "$cpu_build" "benchmark_correctness_${variant}")"
  echo -n "$variant " | tee -a "$correctness_summary"
  "$exe" --points 1200 --candidates 4096 --top-k 10 |
    tee -a "$correctness_summary"
done

if command -v nvcc >/dev/null 2>&1; then
  gpu_summary="$out_dir/gpu_breakdown_scaling_summary.txt"
  if ! configure_cuda_build; then
    echo "CUDA build failed for all arch candidates: $CUDA_ARCH_FALLBACKS" |
      tee -a "$gpu_summary"
    echo "CPU analysis results are still available in $out_dir" |
      tee -a "$gpu_summary"
    write_best_strategy_summary
    echo "Jetson analysis results written to $out_dir"
    exit 0
  fi

  for variant in "${gpu_breakdown_variants[@]}"; do
    exe="$(bin_path "$cuda_build" "benchmark_score_all_${variant}")"
    csv="$out_dir/score_${variant}_p1200_c4096.csv"
    echo -n "gpu_breakdown $variant " | tee -a "$gpu_summary"
    "$exe" --iters "$ITERS" --warmup 3 --points 1200 --candidates 4096 \
      --profile-csv "$csv" | tee -a "$gpu_summary"
  done

  for variant in "${gpu_matcher_variants[@]}"; do
    exe="$(bin_path "$cuda_build" "benchmark_matcher_${variant}")"
    if [[ -x "$exe" ]]; then
      csv="$out_dir/matcher_${variant}_profile.csv"
      echo -n "matcher_cuda_build $variant " | tee -a "$gpu_summary"
      "$exe" --iters "$ITERS" --points 1200 --map "$MAP" --profile-csv "$csv" |
        tee -a "$gpu_summary"
    fi
  done

  for item in "${sizes[@]}"; do
    read -r points candidates <<< "$item"
    for variant in "${gpu_scaling_variants[@]}"; do
      exe="$(bin_path "$cuda_build" "benchmark_score_all_${variant}")"
      csv="$out_dir/score_${variant}_p${points}_c${candidates}.csv"
      echo -n "gpu_scaling $variant p=$points c=$candidates " |
        tee -a "$gpu_summary"
      "$exe" --iters "$ITERS" --warmup 3 --points "$points" \
        --candidates "$candidates" --profile-csv "$csv" |
        tee -a "$gpu_summary"
    done
  done

  for variant in "${gpu_scaling_variants[@]}"; do
    exe="$(bin_path "$cuda_build" "benchmark_pruning_${variant}")"
    echo -n "pruning $variant " | tee -a "$gpu_summary"
    "$exe" --iters "$ITERS" --warmup 3 --points 1200 --candidates 4096 |
      tee -a "$gpu_summary"
  done

  for variant in "${gpu_correctness_variants[@]}"; do
    exe="$(bin_path "$cuda_build" "benchmark_correctness_${variant}")"
    if [[ -x "$exe" ]]; then
      echo -n "$variant " | tee -a "$correctness_summary"
      "$exe" --points 1200 --candidates 4096 --top-k 10 |
        tee -a "$correctness_summary"
    fi
  done

  run_thread_block_sweep

  if [[ "$RUN_NSIGHT" == "1" ]]; then
    run_nsight_systems
  fi

  if [[ "$RUN_NCU" == "1" ]]; then
    run_nsight_compute
  fi
else
  echo "nvcc not found; CUDA analysis skipped." | tee -a "$out_dir/gpu_breakdown_scaling_summary.txt"
fi

write_best_strategy_summary
echo "Jetson analysis results written to $out_dir"
