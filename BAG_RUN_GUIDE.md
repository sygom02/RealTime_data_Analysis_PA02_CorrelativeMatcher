# Jetson ROS1 BAG Segment Test Guide

This guide targets Jetson Nano with ROS1 Melodic and a ROS1 bag at:

```bash
/data/student_02/cartographer_parallel/bags/scan.bag
```

The BAG segment test requires the user to provide `BAG_START_SEC` and
`BAG_DURATION_SEC`. Full BAG testing is intentionally not run here.

## Segment BAG Only

```bash
cd /data/student_02/Optimization_project
chmod +x run_jetson_bag_segment_analysis.sh

CUDA_ARCHITECTURES=53 CUDA_ARCH_FALLBACKS=53 \
BAG_PATH=/data/student_02/cartographer_parallel/bags/scan.bag \
MAP_PATH=/data/student_02/cartographer_parallel/maps/0501.yaml \
SCAN_TOPIC=/scan \
BAG_START_SEC=<start_seconds> \
BAG_DURATION_SEC=<duration_seconds> \
BAG_RUNS=3 \
MAX_SCANS=3 \
NODE_WAIT_SEC=180 \
BAG_RATE=1.0 \
bash run_jetson_bag_segment_analysis.sh \
  /data/student_02/Optimization_project
```

## Standalone + Segment BAG

```bash
cd /data/student_02/Optimization_project
chmod +x run_jetson_full_analysis.sh run_jetson_bag_segment_analysis.sh run_jetson_combined_analysis.sh

CUDA_ARCHITECTURES=53 CUDA_ARCH_FALLBACKS=53 \
ITERS=10 \
BAG_PATH=/data/student_02/cartographer_parallel/bags/scan.bag \
BAG_START_SEC=<start_seconds> \
BAG_DURATION_SEC=<duration_seconds> \
BAG_RUNS=3 \
MAX_SCANS=3 \
NODE_WAIT_SEC=180 \
BAG_RATE=1.0 \
bash run_jetson_combined_analysis.sh \
  /data/student_02/Optimization_project \
  /data/student_02/cartographer_parallel
```

If `BAG_START_SEC` and `BAG_DURATION_SEC` are not set, the combined script
runs standalone only and skips BAG.

## Variants

The segment test builds and runs:

- `baseline`
- `cpu_boundary_openmp`
- `score_buffer_reuse`
- `gpu_shared`
- `gpu_shared_cached_grid`
- `gpu_shared_batched`
- `gpu_reuse_buffer`
- `gpu_reuse_buffer_cached_grid`
- `gpu_reuse_buffer_cached_grid_batched`
- `gpu_reuse_warp_cached_grid_batched`

## Results

Standalone results:

```bash
ls -la /data/student_02/Optimization_project/results/jetson_analysis_*
```

BAG results:

```bash
ls -la /data/student_02/Optimization_project/results/bag_segment_analysis_*
cat /data/student_02/Optimization_project/results/bag_segment_analysis_*/bag_segment_summary_avg.csv
cat /data/student_02/Optimization_project/results/bag_segment_analysis_*/bag_segment_findings.md
```

Important BAG metrics:

- `match_ms_avg`
- `score_all_ms_avg`
- `score_all_call_count`
- `score_vector_alloc_count`
- `candidate_before`
- `candidate_after`
- `pruned_ratio`
- `h2d_total_ms_avg`
- `kernel_ms_avg`

`MAX_SCANS` limits how many LaserScan callbacks each variant processes before
writing a summary. Use `MAX_SCANS=1` for a smoke test and `MAX_SCANS=3` or `5`
for a short segment comparison on Jetson Nano.

`pruned_ratio` is a candidate reduction proxy in the ROS1 node. Treat it as
supporting evidence, not as a dedicated pruning-before/after hook.
