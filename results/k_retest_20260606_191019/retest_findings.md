# K Retest GPU/Nsight Findings

- Result directory: `O:\results\k_retest_20260606_191019`
- Correctness: PASS (`top1_same=1`, `topK_overlap=1.0` for all tested GPU variants).
- Nsight Systems was run with `--trace=cuda,nvtx` because Windows local Nsight does not support Linux `osrt` trace.
- Nsight Compute was not rerun here because local Windows previously failed to create a profiling session; occupancy/warp-stall counters remain a Jetson/NCU task.

## Matcher Benchmark

| variant | match_total_ms | vs CPU | score_all_calls | batched_calls | h2d_total_ms | kernel_ms | score_all_only_ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cpu_boundary_openmp | 2.415 | baseline | 18 | 0 | 0.000 | 0.000 | 1.479 |
| gpu_shared | 8.720 | 3.61x CPU | 18 | 0 | 4.066 | 0.464 | 8.216 |
| gpu_shared_cached_grid | 2.797 | 1.16x CPU | 18 | 0 | 1.008 | 0.447 | 2.315 |
| gpu_shared_batched | 2.593 | 1.07x CPU | 4 | 4 | 1.025 | 0.240 | 2.192 |
| gpu_reuse_buffer | 3.451 | 1.43x CPU | 18 | 0 | 1.664 | 0.816 | 2.960 |
| gpu_reuse_buffer_cached_grid | 2.723 | 1.13x CPU | 18 | 0 | 1.016 | 0.776 | 2.238 |
| gpu_reuse_buffer_cached_grid_batched | 1.292 | 0.53x CPU | 4 | 4 | 0.503 | 0.227 | 0.886 |
| gpu_reuse_warp_cached_grid_batched | 1.206 | 0.50x CPU | 4 | 4 | 0.494 | 0.189 | 0.804 |
| gpu_reuse_block_cached_grid | 2.982 | 1.23x CPU | 18 | 0 | 1.008 | 0.895 | 2.507 |

## Nsight Systems Timeline Summary

| variant | NVTX score_all ranges | CUDA memcpy calls | CUDA launch calls | event sync calls | GPU H2D copies | GPU kernel launches | GPU kernel ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cpu_boundary_openmp | 0 | 0 | 0 | 0 | 0 | 0 | 0.000 |
| gpu_shared | 90 | 540 | 90 | 90 | 450 | 90 | 1.234 |
| gpu_shared_cached_grid | 90 | 470 | 90 | 90 | 380 | 90 | 1.186 |
| gpu_shared_batched | 20 | 180 | 20 | 20 | 160 | 20 | 0.968 |
| gpu_reuse_buffer | 90 | 540 | 90 | 90 | 450 | 90 | 1.192 |
| gpu_reuse_buffer_cached_grid | 90 | 470 | 90 | 90 | 380 | 90 | 1.198 |
| gpu_reuse_buffer_cached_grid_batched | 20 | 180 | 20 | 20 | 160 | 20 | 0.966 |
| gpu_reuse_warp_cached_grid_batched | 20 | 180 | 20 | 20 | 160 | 20 | 0.789 |
| gpu_reuse_block_cached_grid | 90 | 470 | 270 | 90 | 380 | 270 | 1.437 |

## Thread/Warp Sweep

| variant | threads | match_total_ms | h2d_total_ms | kernel_ms | score_all_calls |
| --- | ---: | ---: | ---: | ---: | ---: |
| gpu_reuse_buffer | 64 | 3.697 | 1.692 | 1.000 | 18 |
| gpu_reuse_buffer | 128 | 4.960 | 2.510 | 0.860 | 18 |
| gpu_reuse_buffer | 256 | 3.228 | 1.504 | 0.804 | 18 |
| gpu_reuse_buffer | 512 | 3.298 | 1.487 | 0.905 | 18 |
| gpu_reuse_buffer_cached_grid_batched | 64 | 1.320 | 0.552 | 0.224 | 4 |
| gpu_reuse_buffer_cached_grid_batched | 128 | 1.271 | 0.501 | 0.226 | 4 |
| gpu_reuse_buffer_cached_grid_batched | 256 | 1.345 | 0.542 | 0.269 | 4 |
| gpu_reuse_buffer_cached_grid_batched | 512 | 1.400 | 0.504 | 0.371 | 4 |
| gpu_reuse_warp_cached_grid_batched | 64 | 1.236 | 0.514 | 0.189 | 4 |
| gpu_reuse_warp_cached_grid_batched | 128 | 1.190 | 0.493 | 0.193 | 4 |
| gpu_reuse_warp_cached_grid_batched | 256 | 1.167 | 0.475 | 0.183 | 4 |
| gpu_reuse_warp_cached_grid_batched | 512 | 1.256 | 0.514 | 0.191 | 4 |

## Interpretation

- CPU OpenMP reference: `2.415 ms`.
- Best matcher variant in the main retest: `gpu_reuse_warp_cached_grid_batched` at `1.206 ms`, 50.1% faster than CPU.
- Best thread-sweep configuration: `gpu_reuse_warp_cached_grid_batched` with `SCORE_ALL_CUDA_THREADS=256` at `1.167 ms`.
- Batching is still the structural fix: non-batched GPU variants issue 18 score calls per matcher; batched/warp-batched variants issue 4.
- Nsight Systems confirms that reduction in the timeline: non-batched variants show 90 score_all NVTX ranges over the profiled run, while batched variants show 20. This matches 18 -> 4 per matcher window.
- Grid cache helps mainly by reducing H2D traffic. It is useful, but the biggest jump comes when grid cache is combined with batching.
- Warp-per-candidate is now the best local strategy in this retest: it lowers kernel time while keeping H2D comparable to the shared batched path.
- Block/atomic cached-grid is not a good final candidate here: it keeps 18 score calls and launches more kernels than the shared/warp batched path.
