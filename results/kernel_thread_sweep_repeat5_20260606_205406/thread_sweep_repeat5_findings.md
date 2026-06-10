# Kernel Thread/Warp Sweep Repeat-5 Findings

All values are averaged over 5 independent runs per configuration. Each run used `--iters 10 --points 1200 --map M:\0501.yaml`.

## Nsight Compute Status

- Local `ncu` was executed against the latest K-drive build, but it failed to create a profiling session: `Failed to get connected session` / `Failed to create profiling session`.
- Therefore this local machine could not provide hardware counters such as occupancy, warp stall, cache hit, or memory throughput.
- To still test the kernel-side hypothesis, `SCORE_ALL_CUDA_THREADS=64/128/256/512` was swept with 5-run averages.

## Sweep Summary

| variant | threads | n | match_total_ms | stdev | score_all_only_ms | h2d_total_ms | kernel_ms | kernel stdev | calls |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `gpu_reuse_buffer` | 64 | 5 | 3.515 | 0.212 | 3.004 | 1.628 | 0.898 | 0.096 | 18.0 |
| `gpu_reuse_buffer` | 128 | 5 | 3.324 | 0.205 | 2.817 | 1.579 | 0.753 | 0.017 | 18.0 |
| `gpu_reuse_buffer` | 256 | 5 | 3.638 | 0.282 | 3.061 | 1.757 | 0.768 | 0.037 | 18.0 |
| `gpu_reuse_buffer` | 512 | 5 | 4.042 | 0.901 | 3.517 | 1.888 | 0.987 | 0.109 | 18.0 |
| `gpu_reuse_buffer_cached_grid_batched` | 64 | 5 | 1.354 | 0.118 | 0.912 | 0.554 | 0.230 | 0.007 | 4.0 |
| `gpu_reuse_buffer_cached_grid_batched` | 128 | 5 | 1.305 | 0.046 | 0.897 | 0.531 | 0.227 | 0.004 | 4.0 |
| `gpu_reuse_buffer_cached_grid_batched` | 256 | 5 | 1.365 | 0.087 | 0.945 | 0.542 | 0.269 | 0.007 | 4.0 |
| `gpu_reuse_buffer_cached_grid_batched` | 512 | 5 | 1.559 | 0.112 | 1.112 | 0.576 | 0.378 | 0.006 | 4.0 |
| `gpu_reuse_warp_cached_grid_batched` | 64 | 5 | 1.266 | 0.039 | 0.851 | 0.522 | 0.194 | 0.004 | 4.0 |
| `gpu_reuse_warp_cached_grid_batched` | 128 | 5 | 1.334 | 0.119 | 0.898 | 0.557 | 0.195 | 0.007 | 4.0 |
| `gpu_reuse_warp_cached_grid_batched` | 256 | 5 | 1.281 | 0.046 | 0.869 | 0.544 | 0.189 | 0.002 | 4.0 |
| `gpu_reuse_warp_cached_grid_batched` | 512 | 5 | 1.391 | 0.178 | 0.940 | 0.567 | 0.202 | 0.012 | 4.0 |

## Best Configurations
- `gpu_reuse_buffer` best match: threads=128, match_total_ms=3.324, kernel_ms=0.753.
- `gpu_reuse_buffer` best kernel: threads=128, kernel_ms=0.753, match_total_ms=3.324.
- `gpu_reuse_buffer_cached_grid_batched` best match: threads=128, match_total_ms=1.305, kernel_ms=0.227.
- `gpu_reuse_buffer_cached_grid_batched` best kernel: threads=128, kernel_ms=0.227, match_total_ms=1.305.
- `gpu_reuse_warp_cached_grid_batched` best match: threads=64, match_total_ms=1.266, kernel_ms=0.194.
- `gpu_reuse_warp_cached_grid_batched` best kernel: threads=256, kernel_ms=0.189, match_total_ms=1.281.

## Kernel-Side Interpretation

- Non-batched shared reuse (`gpu_reuse_buffer`) still calls `score_all` 18 times. Its kernel varied with block size: best threads=128 at 0.753 ms; worst threads=512 at 0.987 ms.
- Batched shared and batched warp both call `score_all` 4 times, so their difference is kernel organization rather than call count.
- threads=64: shared-batched kernel 0.230 ms vs warp-batched 0.194 ms; warp is lower by 0.036 ms (15.6%).
- threads=128: shared-batched kernel 0.227 ms vs warp-batched 0.195 ms; warp is lower by 0.032 ms (14.2%).
- threads=256: shared-batched kernel 0.269 ms vs warp-batched 0.189 ms; warp is lower by 0.080 ms (29.9%).
- threads=512: shared-batched kernel 0.378 ms vs warp-batched 0.202 ms; warp is lower by 0.176 ms (46.5%).
- This supports the hypothesis that warp-per-candidate reduces block-level reduction/synchronization overhead. However, exact stall attribution still requires Nsight Compute counters on Jetson or a profiling-enabled machine.
