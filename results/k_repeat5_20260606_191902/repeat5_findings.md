# K Drive Repeat-5 GPU Batching/Grid/Warp Findings

All values are averaged over 5 independent runs. Each run used `--iters 10 --points 1200 --map M:\0501.yaml`.

## Main Matcher Result

| variant | n | match_total_ms mean | stdev | score_all_only_ms | score_all_call_count | batched_call_count | h2d_total_ms | kernel_ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `cpu_boundary_openmp` | 5 | 2.289 | 0.187 | 1.265 | 18.0 | 0.0 | 0.000 | 0.000 |
| `gpu_shared` | 5 | 10.334 | 0.837 | 9.761 | 18.0 | 0.0 | 4.881 | 0.591 |
| `gpu_shared_cached_grid` | 5 | 4.146 | 1.695 | 3.640 | 18.0 | 0.0 | 1.723 | 0.617 |
| `gpu_shared_batched` | 5 | 2.946 | 0.063 | 2.530 | 4.0 | 4.0 | 1.304 | 0.253 |
| `gpu_reuse_buffer` | 5 | 3.829 | 0.592 | 3.330 | 18.0 | 0.0 | 1.749 | 1.038 |
| `gpu_reuse_buffer_cached_grid` | 5 | 3.160 | 0.312 | 2.606 | 18.0 | 0.0 | 1.159 | 0.925 |
| `gpu_reuse_buffer_cached_grid_batched` | 5 | 1.382 | 0.115 | 0.982 | 4.0 | 4.0 | 0.601 | 0.232 |
| `gpu_reuse_warp_cached_grid_batched` | 5 | 1.363 | 0.121 | 0.937 | 4.0 | 4.0 | 0.591 | 0.196 |

## What Actually Decreased

- GPU call count decreased from `18` to `4` when batching is enabled. This is visible in `score_all_call_count`: `gpu_shared=18.0` vs `gpu_shared_batched=4.0`.
- Host-side score vector allocation count decreased from `240` to `36` on batched paths.
- Baseline GPU H2D transfer decreased from `gpu_shared` 4.881 ms to `gpu_shared_batched` 1.304 ms.
- Reuse+cached-grid batching decreased H2D from `gpu_reuse_buffer_cached_grid` 1.159 ms to `gpu_reuse_buffer_cached_grid_batched` 0.601 ms.
- Warp batching did not further reduce call count; it changed per-candidate GPU execution granularity. It reduced kernel time from `gpu_reuse_buffer_cached_grid_batched` 0.232 ms to `gpu_reuse_warp_cached_grid_batched` 0.196 ms.

## Comparison

- Baseline GPU -> batching only: `10.334` ms to `2.946` ms, 71.5% faster.
- Baseline GPU -> cached grid only: `10.334` ms to `4.146` ms, 59.9% faster.
- Reuse buffer -> reuse+cached grid: `3.829` ms to `3.160` ms, 17.5% faster.
- Reuse+cached grid -> reuse+cached grid+batching: `3.160` ms to `1.382` ms, 56.3% faster.
- Reuse+cached grid+batching -> warp version: `1.382` ms to `1.363` ms, 1.4% faster.

## CPU Comparison

- CPU OpenMP reference: `2.289` ms.
- Best GPU variant: `gpu_reuse_warp_cached_grid_batched` at `1.363` ms.
- Best GPU is 1.68x faster than CPU OpenMP, or 40.5% lower match time.

## Interpretation

- The biggest stable gain came from batching, because it reduced repeated small GPU submissions inside `Score()` from 18 to 4 per matcher call.
- Cached grid helps, but by itself it is less decisive than batching because scan/candidate copies and launch overhead still remain.
- Warp strategy is not reducing the number of GPU calls. It improves the kernel side by assigning one candidate to one warp instead of using a whole block per candidate. In this 5-run average it is the fastest GPU path.
- So the correct statement is: batching reduced repeated GPU calls; warp reduced per-candidate kernel work. They solve different parts of the bottleneck.
