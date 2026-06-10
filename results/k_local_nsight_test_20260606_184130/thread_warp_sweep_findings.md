# Thread/Warp Sweep Findings

| variant | threads | match_total_ms | vs CPU | h2d_total_ms | kernel_ms | score_all_calls |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| gpu_reuse_buffer | 64 | 3.384 | 1.40x CPU | 1.615 | 0.827 | 18 |
| gpu_reuse_buffer | 128 | 3.237 | 1.34x CPU | 1.553 | 0.768 | 18 |
| gpu_reuse_buffer | 256 | 3.339 | 1.38x CPU | 1.555 | 0.814 | 18 |
| gpu_reuse_buffer | 512 | 3.384 | 1.40x CPU | 1.558 | 0.904 | 18 |
| gpu_reuse_buffer_cached_grid_batched | 64 | 1.321 | 0.55x CPU | 0.558 | 0.220 | 4 |
| gpu_reuse_buffer_cached_grid_batched | 128 | 1.220 | 0.51x CPU | 0.489 | 0.228 | 4 |
| gpu_reuse_buffer_cached_grid_batched | 256 | 1.238 | 0.51x CPU | 0.482 | 0.265 | 4 |
| gpu_reuse_buffer_cached_grid_batched | 512 | 1.433 | 0.59x CPU | 0.532 | 0.383 | 4 |
| cpu_boundary_openmp | - | 2.412 | baseline | 0.000 | 0.000 | 18 |
| gpu_reuse_warp_cached_grid_batched | 64 | 1.339 | 0.56x CPU | 0.559 | 0.196 | 4 |
| gpu_reuse_warp_cached_grid_batched | 128 | 1.470 | 0.61x CPU | 0.750 | 0.189 | 4 |
| gpu_reuse_warp_cached_grid_batched | 256 | 1.265 | 0.52x CPU | 0.534 | 0.199 | 4 |
| gpu_reuse_warp_cached_grid_batched | 512 | 1.289 | 0.53x CPU | 0.538 | 0.198 | 4 |

## Interpretation

- `gpu_reuse_buffer` best match time: threads=128, match_total_ms=3.237, kernel_ms=0.768.
- `gpu_reuse_buffer` best kernel time: threads=128, kernel_ms=0.768, match_total_ms=3.237.
- `gpu_reuse_buffer_cached_grid_batched` best match time: threads=128, match_total_ms=1.220, kernel_ms=0.228.
- `gpu_reuse_buffer_cached_grid_batched` best kernel time: threads=64, kernel_ms=0.220, match_total_ms=1.321.
- `gpu_reuse_warp_cached_grid_batched` best match time: threads=256, match_total_ms=1.265, kernel_ms=0.199.
- `gpu_reuse_warp_cached_grid_batched` best kernel time: threads=128, kernel_ms=0.189, match_total_ms=1.470.
- For this K local sweep, block-style batched shared kernel is best at 128 threads, while warp batched is most competitive at 256/512 threads.
- Warp lowers kernel_ms slightly versus block-style batched, but its total match time is not always lower because H2D and CPU-side branch/writeback remain part of the total path.
- Nsight Compute kernel counters were not collected on this Windows machine, so occupancy/warp stall diagnosis remains a Jetson task.
