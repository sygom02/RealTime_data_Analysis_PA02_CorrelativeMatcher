# K Local Nsight Systems Findings

## Matcher Benchmark

| variant | match_total_ms | vs CPU | score_all_calls | batched_calls | vector_alloc_count | h2d_total_ms | kernel_ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cpu_boundary_openmp | 3.131 | baseline | 18 | 0 | 240 | 0.000 | 0.000 |
| gpu_shared | 20.142 | 6.43x CPU time | 18 | 0 | 240 | 10.551 | 0.667 |
| gpu_shared_cached_grid | 11.768 | 3.76x CPU time | 18 | 0 | 240 | 6.517 | 1.056 |
| gpu_shared_batched | 6.362 | 2.03x CPU time | 4 | 4 | 36 | 2.941 | 0.334 |
| gpu_reuse_buffer | 6.268 | 2.00x CPU time | 18 | 0 | 240 | 2.425 | 2.105 |
| gpu_reuse_buffer_cached_grid | 5.761 | 1.84x CPU time | 18 | 0 | 240 | 1.649 | 2.343 |
| gpu_reuse_buffer_cached_grid_batched | 2.653 | 0.85x CPU time | 4 | 4 | 36 | 1.362 | 0.267 |
| gpu_reuse_warp_cached_grid_batched | 2.762 | 0.88x CPU time | 4 | 4 | 36 | 1.562 | 0.224 |
| gpu_reuse_block_cached_grid | 5.838 | 1.86x CPU time | 18 | 0 | 240 | 1.676 | 2.250 |

## Nsight Systems CUDA Summary

| variant | NVTX score_all ranges | CUDA memcpy calls | CUDA kernel launches | GPU H2D copies | GPU H2D ms | GPU kernel launches | GPU kernel ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cpu_boundary_openmp | 0 | 0 | 0 | 0 | 0.000 | 0 | 0.000 |
| gpu_shared | 90 | 540 | 90 | 450 | 3.454 | 90 | 1.278 |
| gpu_shared_cached_grid | 90 | 470 | 90 | 380 | 1.111 | 90 | 1.259 |
| gpu_shared_batched | 20 | 180 | 20 | 160 | 1.027 | 20 | 0.984 |
| gpu_reuse_buffer | 90 | 540 | 90 | 450 | 3.077 | 90 | 1.203 |
| gpu_reuse_buffer_cached_grid | 90 | 470 | 90 | 380 | 1.779 | 90 | 1.314 |
| gpu_reuse_buffer_cached_grid_batched | 20 | 180 | 20 | 160 | 1.156 | 20 | 0.986 |
| gpu_reuse_warp_cached_grid_batched | 20 | 180 | 20 | 160 | 1.045 | 20 | 0.810 |
| gpu_reuse_block_cached_grid | 90 | 470 | 270 | 380 | 1.476 | 270 | 1.459 |

## Key Interpretation

- CPU reference is `cpu_boundary_openmp` at 3.131 ms.
- Best local GPU variant is `gpu_reuse_buffer_cached_grid_batched` at 2.653 ms, 15.3% faster than CPU OpenMP in this K local run.
- Batching changes the matcher structure: non-batched GPU variants call `score_all` 18 times per matcher, while batched variants call it 4 times.
- Nsight Systems confirms the same reduction: non-batched reports show 90 `score_all` NVTX ranges over the profiled run, while batched reports show 20 `score_all_batched` ranges. This is the same 18 -> 4 reduction per matcher.
- Grid cache reduces H2D pressure, but by itself is weaker than batching. The best result comes from combining reuse buffer + cached grid + batching.
- Local Nsight Compute did not complete: it failed to create a profiling session, so kernel counter analysis should be run on Jetson or a machine where NCU profiling permissions are available.
