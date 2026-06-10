#include "cartographer_parallel/assignment.h"
#include "cartographer_parallel/nvtx_range.h"
#include "cartographer_parallel/profile.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>

#include <cuda_runtime.h>

#ifndef SCORE_ALL_CUDA_MODE
#define SCORE_ALL_CUDA_MODE 3
#endif

namespace cartographer_parallel {
namespace {

constexpr int kDefaultThreadsPerBlock = 128;
constexpr int kModeThread = 1;
constexpr int kModeBlockAtomic = 2;
constexpr int kModeShared = 3;
constexpr int kModeReuseShared = 4;
constexpr int kModeReuseBlockAtomic = 5;
constexpr int kModeReuseBlockAtomicCachedGrid = 6;
constexpr int kModeReuseSharedDeviceOnly = 7;
constexpr int kModeReuseSharedDeviceOnlySync = 8;
constexpr int kModeSharedCachedGrid = 9;
constexpr int kModeReuseSharedCachedGrid = 10;
constexpr int kModeSharedBatched = 11;
constexpr int kModeReuseSharedCachedGridBatched = 12;
constexpr int kModeReuseWarpCachedGridBatched = 13;

void CheckCuda(const cudaError_t error, const char* const what) {
  if (error == cudaSuccess) return;
  std::cerr << "CUDA error in " << what << ": "
            << cudaGetErrorString(error) << std::endl;
  throw std::runtime_error(cudaGetErrorString(error));
}

int ThreadsPerBlock() {
  const char* env = std::getenv("SCORE_ALL_CUDA_THREADS");
  if (env == nullptr) return kDefaultThreadsPerBlock;
  const int value = std::atoi(env);
  if (value <= 0) return kDefaultThreadsPerBlock;
  return std::min(1024, value);
}

struct CudaBuffers {
  unsigned char* grid = nullptr;
  int* px = nullptr;
  int* py = nullptr;
  int* cx = nullptr;
  int* cy = nullptr;
  int* cand_scan = nullptr;
  int* scan_offsets = nullptr;
  int* scan_sizes = nullptr;
  int* sums = nullptr;
  float* score = nullptr;
  unsigned char* pinned_grid = nullptr;
  int* pinned_px = nullptr;
  int* pinned_py = nullptr;
  int* pinned_cx = nullptr;
  int* pinned_cy = nullptr;
  size_t grid_cap = 0;
  size_t points_cap = 0;
  size_t candidates_cap = 0;
  size_t cand_scan_cap = 0;
  size_t scans_cap = 0;
  const unsigned char* cached_grid_host = nullptr;
  size_t cached_grid_size = 0;
  cudaEvent_t kernel_start = nullptr;
  cudaEvent_t kernel_stop = nullptr;

  ~CudaBuffers() {
    cudaFree(grid);
    cudaFree(px);
    cudaFree(py);
    cudaFree(cx);
    cudaFree(cy);
    cudaFree(cand_scan);
    cudaFree(scan_offsets);
    cudaFree(scan_sizes);
    cudaFree(sums);
    cudaFree(score);
    cudaFreeHost(pinned_grid);
    cudaFreeHost(pinned_px);
    cudaFreeHost(pinned_py);
    cudaFreeHost(pinned_cx);
    cudaFreeHost(pinned_cy);
    if (kernel_start != nullptr) cudaEventDestroy(kernel_start);
    if (kernel_stop != nullptr) cudaEventDestroy(kernel_stop);
  }

  void EnsureEvents() {
    if (kernel_start == nullptr) {
      CheckCuda(cudaEventCreate(&kernel_start), "cudaEventCreate start");
    }
    if (kernel_stop == nullptr) {
      CheckCuda(cudaEventCreate(&kernel_stop), "cudaEventCreate stop");
    }
  }

  void EnsureGrid(const size_t grid_size, const bool pinned,
                  ScoreAllProfile* const profile) {
    if (grid_size > grid_cap) {
      const auto alloc_start = ProfileClock::now();
      cudaFree(grid);
      grid = nullptr;
      CheckCuda(cudaMalloc(&grid, grid_size * sizeof(unsigned char)),
                "cudaMalloc grid");
      if (profile != nullptr) {
        profile->device_alloc_ms += ProfileMsSince(alloc_start);
      }
      cached_grid_host = nullptr;
      cached_grid_size = 0;
      if (pinned) {
        const auto pinned_start = ProfileClock::now();
        cudaFreeHost(pinned_grid);
        pinned_grid = nullptr;
        CheckCuda(cudaHostAlloc(&pinned_grid, grid_size * sizeof(unsigned char),
                                cudaHostAllocDefault),
                  "cudaHostAlloc pinned_grid");
        if (profile != nullptr) {
          profile->pinned_alloc_ms += ProfileMsSince(pinned_start);
        }
      }
      grid_cap = grid_size;
    }
  }

  void EnsureWork(const size_t points, const size_t candidates,
                  const bool pinned, ScoreAllProfile* const profile) {
    if (points > points_cap) {
      const auto alloc_start = ProfileClock::now();
      cudaFree(px);
      cudaFree(py);
      px = nullptr;
      py = nullptr;
      CheckCuda(cudaMalloc(&px, points * sizeof(int)), "cudaMalloc px");
      CheckCuda(cudaMalloc(&py, points * sizeof(int)), "cudaMalloc py");
      if (profile != nullptr) {
        profile->device_alloc_ms += ProfileMsSince(alloc_start);
      }
      if (pinned) {
        const auto pinned_start = ProfileClock::now();
        cudaFreeHost(pinned_px);
        cudaFreeHost(pinned_py);
        pinned_px = nullptr;
        pinned_py = nullptr;
        CheckCuda(cudaHostAlloc(&pinned_px, points * sizeof(int),
                                cudaHostAllocDefault),
                  "cudaHostAlloc pinned_px");
        CheckCuda(cudaHostAlloc(&pinned_py, points * sizeof(int),
                                cudaHostAllocDefault),
                  "cudaHostAlloc pinned_py");
        if (profile != nullptr) {
          profile->pinned_alloc_ms += ProfileMsSince(pinned_start);
        }
      }
      points_cap = points;
    }
    if (candidates > candidates_cap) {
      const auto alloc_start = ProfileClock::now();
      cudaFree(cx);
      cudaFree(cy);
      cudaFree(sums);
      cudaFree(score);
      cx = nullptr;
      cy = nullptr;
      sums = nullptr;
      score = nullptr;
      CheckCuda(cudaMalloc(&cx, candidates * sizeof(int)), "cudaMalloc cx");
      CheckCuda(cudaMalloc(&cy, candidates * sizeof(int)), "cudaMalloc cy");
      CheckCuda(cudaMalloc(&sums, candidates * sizeof(int)), "cudaMalloc sums");
      CheckCuda(cudaMalloc(&score, candidates * sizeof(float)),
                "cudaMalloc score");
      if (profile != nullptr) {
        profile->device_alloc_ms += ProfileMsSince(alloc_start);
      }
      if (pinned) {
        const auto pinned_start = ProfileClock::now();
        cudaFreeHost(pinned_cx);
        cudaFreeHost(pinned_cy);
        pinned_cx = nullptr;
        pinned_cy = nullptr;
        CheckCuda(cudaHostAlloc(&pinned_cx, candidates * sizeof(int),
                                cudaHostAllocDefault),
                  "cudaHostAlloc pinned_cx");
        CheckCuda(cudaHostAlloc(&pinned_cy, candidates * sizeof(int),
                                cudaHostAllocDefault),
                  "cudaHostAlloc pinned_cy");
        if (profile != nullptr) {
          profile->pinned_alloc_ms += ProfileMsSince(pinned_start);
        }
      }
      candidates_cap = candidates;
    }
    EnsureEvents();
  }

  void EnsureBatchedExtras(const size_t scans, const size_t candidates,
                           ScoreAllProfile* const profile) {
    if (candidates > cand_scan_cap) {
      const auto alloc_start = ProfileClock::now();
      cudaFree(cand_scan);
      cand_scan = nullptr;
      CheckCuda(cudaMalloc(&cand_scan, candidates * sizeof(int)),
                "cudaMalloc cand_scan");
      if (profile != nullptr) {
        profile->device_alloc_ms += ProfileMsSince(alloc_start);
      }
      cand_scan_cap = candidates;
    }
    if (scans > scans_cap) {
      const auto alloc_start = ProfileClock::now();
      cudaFree(scan_offsets);
      cudaFree(scan_sizes);
      scan_offsets = nullptr;
      scan_sizes = nullptr;
      CheckCuda(cudaMalloc(&scan_offsets, scans * sizeof(int)),
                "cudaMalloc scan_offsets");
      CheckCuda(cudaMalloc(&scan_sizes, scans * sizeof(int)),
                "cudaMalloc scan_sizes");
      if (profile != nullptr) {
        profile->device_alloc_ms += ProfileMsSince(alloc_start);
      }
      scans_cap = scans;
    }
  }

  void Ensure(const size_t grid_size, const size_t points,
              const size_t candidates, const bool pinned,
              ScoreAllProfile* const profile) {
    EnsureGrid(grid_size, pinned, profile);
    EnsureWork(points, candidates, pinned, profile);
  }
};

thread_local CudaBuffers g_reuse_buffers;
thread_local CudaBuffers g_grid_cache_buffers;

__global__ void ScoreThreadKernel(const unsigned char* grid, int w, int h,
                                  const int* px, const int* py, int p,
                                  const int* cx, const int* cy, int n,
                                  float inv_norm, float* score) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= n) return;
  int sum = 0;
  const int ox = cx[i];
  const int oy = cy[i];
  for (int j = 0; j < p; ++j) {
    const int x = px[j] + ox;
    const int y = py[j] + oy;
    if (x >= 0 && x < w && y >= 0 && y < h) {
      sum += grid[y * w + x];
    }
  }
  score[i] = static_cast<float>(sum) * inv_norm;
}

__global__ void ClearSumsKernel(int* sums, int n) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) sums[i] = 0;
}

__global__ void NormalizeSumsKernel(const int* sums, int n, float inv_norm,
                                    float* score) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) score[i] = static_cast<float>(sums[i]) * inv_norm;
}

__global__ void ScoreBlockAtomicKernel(const unsigned char* grid, int w, int h,
                                       const int* px, const int* py, int p,
                                       const int* cx, const int* cy, int n,
                                       int* sums) {
  const int i = blockIdx.x;
  if (i >= n) return;
  int local = 0;
  const int ox = cx[i];
  const int oy = cy[i];
  for (int j = threadIdx.x; j < p; j += blockDim.x) {
    const int x = px[j] + ox;
    const int y = py[j] + oy;
    if (x >= 0 && x < w && y >= 0 && y < h) {
      local += grid[y * w + x];
    }
  }
  atomicAdd(&sums[i], local);
}

__global__ void ScoreSharedKernel(const unsigned char* grid, int w, int h,
                                  const int* px, const int* py, int p,
                                  const int* cx, const int* cy, int n,
                                  float inv_norm, float* score) {
  extern __shared__ int shared[];
  const int i = blockIdx.x;
  if (i >= n) return;

  int local = 0;
  const int ox = cx[i];
  const int oy = cy[i];
  for (int j = threadIdx.x; j < p; j += blockDim.x) {
    const int x = px[j] + ox;
    const int y = py[j] + oy;
    if (x >= 0 && x < w && y >= 0 && y < h) {
      local += grid[y * w + x];
    }
  }
  shared[threadIdx.x] = local;
  __syncthreads();

  for (int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
    if (threadIdx.x < stride) {
      shared[threadIdx.x] += shared[threadIdx.x + stride];
    }
    __syncthreads();
  }
  if (threadIdx.x == 0) {
    score[i] = static_cast<float>(shared[0]) * inv_norm;
  }
}

__global__ void ScoreBatchedSharedKernel(
    const unsigned char* grid, int w, int h, const int* scan_x,
    const int* scan_y, const int* scan_offsets, const int* scan_sizes,
    int scan_count, const int* cand_scan, const int* cx, const int* cy, int n,
    float* score) {
  extern __shared__ int shared[];
  const int i = blockIdx.x;
  if (i >= n) return;

  const int scan = cand_scan[i];
  if (scan < 0 || scan >= scan_count) {
    if (threadIdx.x == 0) score[i] = 0.0f;
    return;
  }
  const int offset = scan_offsets[scan];
  const int p = scan_sizes[scan];
  if (p <= 0) {
    if (threadIdx.x == 0) score[i] = 0.0f;
    return;
  }

  int local = 0;
  const int ox = cx[i];
  const int oy = cy[i];
  for (int j = threadIdx.x; j < p; j += blockDim.x) {
    const int x = scan_x[offset + j] + ox;
    const int y = scan_y[offset + j] + oy;
    if (x >= 0 && x < w && y >= 0 && y < h) {
      local += grid[y * w + x];
    }
  }
  shared[threadIdx.x] = local;
  __syncthreads();

  for (int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
    if (threadIdx.x < stride) {
      shared[threadIdx.x] += shared[threadIdx.x + stride];
    }
    __syncthreads();
  }
  if (threadIdx.x == 0) {
    const float inv_norm = 1.0f / (255.0f * static_cast<float>(p));
    score[i] = static_cast<float>(shared[0]) * inv_norm;
  }
}

__global__ void ScoreBatchedWarpKernel(
    const unsigned char* grid, int w, int h, const int* scan_x,
    const int* scan_y, const int* scan_offsets, const int* scan_sizes,
    int scan_count, const int* cand_scan, const int* cx, const int* cy, int n,
    float* score) {
  constexpr int kWarpSize = 32;
  const int lane = threadIdx.x & (kWarpSize - 1);
  const int warp_in_block = threadIdx.x / kWarpSize;
  const int warps_per_block = blockDim.x / kWarpSize;
  const int i = blockIdx.x * warps_per_block + warp_in_block;
  if (i >= n) return;

  const int scan = cand_scan[i];
  if (scan < 0 || scan >= scan_count) {
    if (lane == 0) score[i] = 0.0f;
    return;
  }
  const int offset = scan_offsets[scan];
  const int p = scan_sizes[scan];
  if (p <= 0) {
    if (lane == 0) score[i] = 0.0f;
    return;
  }

  int local = 0;
  const int ox = cx[i];
  const int oy = cy[i];
  for (int j = lane; j < p; j += kWarpSize) {
    const int x = scan_x[offset + j] + ox;
    const int y = scan_y[offset + j] + oy;
    if (x >= 0 && x < w && y >= 0 && y < h) {
      local += grid[y * w + x];
    }
  }

  unsigned mask = 0xffffffffu;
  for (int delta = kWarpSize / 2; delta > 0; delta >>= 1) {
    local += __shfl_down_sync(mask, local, delta);
  }
  if (lane == 0) {
    const float inv_norm = 1.0f / (255.0f * static_cast<float>(p));
    score[i] = static_cast<float>(local) * inv_norm;
  }
}

void CopyInputs(const std::vector<unsigned char>& grid,
                const std::vector<int>& px, const std::vector<int>& py,
                const std::vector<int>& cx, const std::vector<int>& cy,
                CudaBuffers* const grid_buffers,
                CudaBuffers* const work_buffers, const bool pinned,
                const bool cached_grid,
                ScoreAllProfile* const profile) {
  CARTOGRAPHER_PARALLEL_NVTX_RANGE("H2D");
  const size_t grid_bytes = grid.size() * sizeof(unsigned char);
  const size_t points_bytes = px.size() * sizeof(int);
  const size_t candidates_bytes = cx.size() * sizeof(int);
  const bool can_reuse_grid =
      cached_grid && grid_buffers->cached_grid_host == grid.data() &&
      grid_buffers->cached_grid_size == grid.size();

  if (pinned) {
    if (!can_reuse_grid) {
      auto copy_start = ProfileClock::now();
      std::memcpy(grid_buffers->pinned_grid, grid.data(), grid_bytes);
      CheckCuda(cudaMemcpy(grid_buffers->grid, grid_buffers->pinned_grid, grid_bytes,
                           cudaMemcpyHostToDevice),
                "cudaMemcpy grid pinned");
      grid_buffers->cached_grid_host = cached_grid ? grid.data() : nullptr;
      grid_buffers->cached_grid_size = cached_grid ? grid.size() : 0;
      if (profile != nullptr) {
        profile->h2d_grid_ms += ProfileMsSince(copy_start);
      }
    }

    auto copy_start = ProfileClock::now();
    std::memcpy(work_buffers->pinned_px, px.data(), points_bytes);
    std::memcpy(work_buffers->pinned_py, py.data(), points_bytes);
    CheckCuda(cudaMemcpy(work_buffers->px, work_buffers->pinned_px, points_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy px pinned");
    CheckCuda(cudaMemcpy(work_buffers->py, work_buffers->pinned_py, points_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy py pinned");
    if (profile != nullptr) profile->h2d_scan_ms += ProfileMsSince(copy_start);

    copy_start = ProfileClock::now();
    std::memcpy(work_buffers->pinned_cx, cx.data(), candidates_bytes);
    std::memcpy(work_buffers->pinned_cy, cy.data(), candidates_bytes);
    CheckCuda(cudaMemcpy(work_buffers->cx, work_buffers->pinned_cx, candidates_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy cx pinned");
    CheckCuda(cudaMemcpy(work_buffers->cy, work_buffers->pinned_cy, candidates_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy cy pinned");
    if (profile != nullptr) profile->h2d_cand_ms += ProfileMsSince(copy_start);
  } else {
    if (!can_reuse_grid) {
      auto copy_start = ProfileClock::now();
      CheckCuda(cudaMemcpy(grid_buffers->grid, grid.data(), grid_bytes,
                           cudaMemcpyHostToDevice),
                "cudaMemcpy grid");
      grid_buffers->cached_grid_host = cached_grid ? grid.data() : nullptr;
      grid_buffers->cached_grid_size = cached_grid ? grid.size() : 0;
      if (profile != nullptr) {
        profile->h2d_grid_ms += ProfileMsSince(copy_start);
      }
    }

    auto copy_start = ProfileClock::now();
    CheckCuda(cudaMemcpy(work_buffers->px, px.data(), points_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy px");
    CheckCuda(cudaMemcpy(work_buffers->py, py.data(), points_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy py");
    if (profile != nullptr) profile->h2d_scan_ms += ProfileMsSince(copy_start);

    copy_start = ProfileClock::now();
    CheckCuda(cudaMemcpy(work_buffers->cx, cx.data(), candidates_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy cx");
    CheckCuda(cudaMemcpy(work_buffers->cy, cy.data(), candidates_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy cy");
    if (profile != nullptr) profile->h2d_cand_ms += ProfileMsSince(copy_start);
  }
  if (profile != nullptr) {
    profile->h2d_total_ms += profile->h2d_grid_ms + profile->h2d_scan_ms +
                             profile->h2d_cand_ms;
  }
}

void CopyBatchedInputs(const std::vector<unsigned char>& grid,
                       const std::vector<int>& scan_x_flat,
                       const std::vector<int>& scan_y_flat,
                       const std::vector<int>& scan_offsets,
                       const std::vector<int>& scan_sizes,
                       const std::vector<int>& cand_scan,
                       const std::vector<int>& cand_x,
                       const std::vector<int>& cand_y,
                       CudaBuffers* const grid_buffers,
                       CudaBuffers* const work_buffers, const bool pinned,
                       const bool cached_grid,
                       ScoreAllProfile* const profile) {
  CARTOGRAPHER_PARALLEL_NVTX_RANGE("H2D_batched");
  const size_t grid_bytes = grid.size() * sizeof(unsigned char);
  const size_t points_bytes = scan_x_flat.size() * sizeof(int);
  const size_t scans_bytes = scan_offsets.size() * sizeof(int);
  const size_t candidates_bytes = cand_x.size() * sizeof(int);
  const bool can_reuse_grid =
      cached_grid && grid_buffers->cached_grid_host == grid.data() &&
      grid_buffers->cached_grid_size == grid.size();

  if (pinned) {
    if (!can_reuse_grid) {
      auto copy_start = ProfileClock::now();
      std::memcpy(grid_buffers->pinned_grid, grid.data(), grid_bytes);
      CheckCuda(cudaMemcpy(grid_buffers->grid, grid_buffers->pinned_grid,
                           grid_bytes, cudaMemcpyHostToDevice),
                "cudaMemcpy batched grid pinned");
      grid_buffers->cached_grid_host = cached_grid ? grid.data() : nullptr;
      grid_buffers->cached_grid_size = cached_grid ? grid.size() : 0;
      if (profile != nullptr) profile->h2d_grid_ms += ProfileMsSince(copy_start);
    }

    auto copy_start = ProfileClock::now();
    std::memcpy(work_buffers->pinned_px, scan_x_flat.data(), points_bytes);
    std::memcpy(work_buffers->pinned_py, scan_y_flat.data(), points_bytes);
    CheckCuda(cudaMemcpy(work_buffers->px, work_buffers->pinned_px,
                         points_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy batched scan_x pinned");
    CheckCuda(cudaMemcpy(work_buffers->py, work_buffers->pinned_py,
                         points_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy batched scan_y pinned");
    CheckCuda(cudaMemcpy(work_buffers->scan_offsets, scan_offsets.data(),
                         scans_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy scan_offsets");
    CheckCuda(cudaMemcpy(work_buffers->scan_sizes, scan_sizes.data(),
                         scans_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy scan_sizes");
    if (profile != nullptr) profile->h2d_scan_ms += ProfileMsSince(copy_start);

    copy_start = ProfileClock::now();
    std::memcpy(work_buffers->pinned_cx, cand_x.data(), candidates_bytes);
    std::memcpy(work_buffers->pinned_cy, cand_y.data(), candidates_bytes);
    CheckCuda(cudaMemcpy(work_buffers->cx, work_buffers->pinned_cx,
                         candidates_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy batched cand_x pinned");
    CheckCuda(cudaMemcpy(work_buffers->cy, work_buffers->pinned_cy,
                         candidates_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy batched cand_y pinned");
    CheckCuda(cudaMemcpy(work_buffers->cand_scan, cand_scan.data(),
                         candidates_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy cand_scan");
    if (profile != nullptr) profile->h2d_cand_ms += ProfileMsSince(copy_start);
  } else {
    if (!can_reuse_grid) {
      auto copy_start = ProfileClock::now();
      CheckCuda(cudaMemcpy(grid_buffers->grid, grid.data(), grid_bytes,
                           cudaMemcpyHostToDevice),
                "cudaMemcpy batched grid");
      grid_buffers->cached_grid_host = cached_grid ? grid.data() : nullptr;
      grid_buffers->cached_grid_size = cached_grid ? grid.size() : 0;
      if (profile != nullptr) profile->h2d_grid_ms += ProfileMsSince(copy_start);
    }

    auto copy_start = ProfileClock::now();
    CheckCuda(cudaMemcpy(work_buffers->px, scan_x_flat.data(), points_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy batched scan_x");
    CheckCuda(cudaMemcpy(work_buffers->py, scan_y_flat.data(), points_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy batched scan_y");
    CheckCuda(cudaMemcpy(work_buffers->scan_offsets, scan_offsets.data(),
                         scans_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy scan_offsets");
    CheckCuda(cudaMemcpy(work_buffers->scan_sizes, scan_sizes.data(),
                         scans_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy scan_sizes");
    if (profile != nullptr) profile->h2d_scan_ms += ProfileMsSince(copy_start);

    copy_start = ProfileClock::now();
    CheckCuda(cudaMemcpy(work_buffers->cx, cand_x.data(), candidates_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy batched cand_x");
    CheckCuda(cudaMemcpy(work_buffers->cy, cand_y.data(), candidates_bytes,
                         cudaMemcpyHostToDevice),
              "cudaMemcpy batched cand_y");
    CheckCuda(cudaMemcpy(work_buffers->cand_scan, cand_scan.data(),
                         candidates_bytes, cudaMemcpyHostToDevice),
              "cudaMemcpy cand_scan");
    if (profile != nullptr) profile->h2d_cand_ms += ProfileMsSince(copy_start);
  }
  if (profile != nullptr) {
    profile->h2d_total_ms += profile->h2d_grid_ms + profile->h2d_scan_ms +
                             profile->h2d_cand_ms;
  }
}

}  // namespace

void make_cand(const int min_x, const int max_x, const int min_y,
               const int max_y, const int step, std::vector<int>* const cx,
               std::vector<int>* const cy) {
  if (cx == nullptr || cy == nullptr || step <= 0) return;
  const int nx = max_x >= min_x ? (max_x - min_x) / step + 1 : 0;
  const int ny = max_y >= min_y ? (max_y - min_y) / step + 1 : 0;
  cx->reserve(cx->size() + static_cast<size_t>(nx) * ny);
  cy->reserve(cy->size() + static_cast<size_t>(nx) * ny);
  for (int x = min_x; x <= max_x; x += step) {
    for (int y = min_y; y <= max_y; y += step) {
      cx->push_back(x);
      cy->push_back(y);
    }
  }
}

void score_all(const std::vector<unsigned char>& grid, const int w,
               const int h, const std::vector<int>& px,
               const std::vector<int>& py, const std::vector<int>& cx,
               const std::vector<int>& cy, std::vector<float>* const score) {
  CARTOGRAPHER_PARALLEL_NVTX_RANGE("score_all_cuda");
  if (score == nullptr) return;
  ScoreAllProfile profile;
  profile.call_count = 1;
  profile.grid_cells = static_cast<std::int64_t>(grid.size());
  profile.scan_points = static_cast<std::int64_t>(std::min(px.size(), py.size()));
  profile.candidates = static_cast<std::int64_t>(std::min(cx.size(), cy.size()));
  ResetLastScoreAllProfile();
  const auto profile_start = ProfileClock::now();
  const auto finish_profile = [&profile, profile_start]() {
    profile.total_ms = ProfileMsSince(profile_start);
    MutableLastScoreAllProfile() = profile;
    AddScoreAllProfile(profile);
  };

  const int n = static_cast<int>(std::min(cx.size(), cy.size()));
  const int p = static_cast<int>(std::min(px.size(), py.size()));
  const auto setup_start = ProfileClock::now();
  score->assign(n, 0.0f);
  if (w <= 0 || h <= 0 || p == 0 || grid.size() < static_cast<size_t>(w * h)) {
    profile.cpu_prepost_ms += ProfileMsSince(setup_start);
    finish_profile();
    return;
  }
  profile.cpu_prepost_ms += ProfileMsSince(setup_start);

  const bool reuse = SCORE_ALL_CUDA_MODE == kModeReuseShared ||
                     SCORE_ALL_CUDA_MODE == kModeReuseBlockAtomic ||
                     SCORE_ALL_CUDA_MODE == kModeReuseBlockAtomicCachedGrid ||
                     SCORE_ALL_CUDA_MODE == kModeReuseSharedDeviceOnly ||
                     SCORE_ALL_CUDA_MODE == kModeReuseSharedDeviceOnlySync ||
                     SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGrid ||
                     SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGridBatched;
  const bool pinned = SCORE_ALL_CUDA_MODE == kModeReuseShared ||
                      SCORE_ALL_CUDA_MODE == kModeReuseBlockAtomic ||
                      SCORE_ALL_CUDA_MODE == kModeReuseBlockAtomicCachedGrid ||
                      SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGrid ||
                      SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGridBatched;
  const bool block_atomic = SCORE_ALL_CUDA_MODE == kModeBlockAtomic ||
                            SCORE_ALL_CUDA_MODE == kModeReuseBlockAtomic ||
                            SCORE_ALL_CUDA_MODE ==
                                kModeReuseBlockAtomicCachedGrid;
  const bool cached_grid =
      SCORE_ALL_CUDA_MODE == kModeReuseBlockAtomicCachedGrid ||
      SCORE_ALL_CUDA_MODE == kModeSharedCachedGrid ||
      SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGrid ||
      SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGridBatched;
  const bool grid_cache_only =
      cached_grid && !reuse && SCORE_ALL_CUDA_MODE == kModeSharedCachedGrid;
  const bool sync_before_kernel =
      SCORE_ALL_CUDA_MODE == kModeReuseSharedDeviceOnlySync;
  CudaBuffers local_buffers;
  CudaBuffers* const work_buffers = reuse ? &g_reuse_buffers : &local_buffers;
  CudaBuffers* const grid_buffers =
      grid_cache_only ? &g_grid_cache_buffers : work_buffers;
  grid_buffers->EnsureGrid(grid.size(), pinned, &profile);
  work_buffers->EnsureWork(static_cast<size_t>(p), static_cast<size_t>(n),
                           pinned, &profile);
  CopyInputs(grid, px, py, cx, cy, grid_buffers, work_buffers, pinned,
             cached_grid, &profile);

  const int threads = ThreadsPerBlock();
  const int grid_1d = (n + threads - 1) / threads;
  const float inv_norm = 1.0f / (255.0f * static_cast<float>(p));

  if (sync_before_kernel) {
    const auto sync_start = ProfileClock::now();
    CheckCuda(cudaDeviceSynchronize(), "cudaDeviceSynchronize before kernel");
    profile.sync_ms += ProfileMsSince(sync_start);
  }
  {
    CARTOGRAPHER_PARALLEL_NVTX_RANGE("kernel");
    CheckCuda(cudaEventRecord(work_buffers->kernel_start),
              "cudaEventRecord start");
    if (SCORE_ALL_CUDA_MODE == kModeThread) {
      ScoreThreadKernel<<<grid_1d, threads>>>(
          grid_buffers->grid, w, h, work_buffers->px, work_buffers->py, p,
          work_buffers->cx, work_buffers->cy, n, inv_norm,
          work_buffers->score);
    } else if (block_atomic) {
      ClearSumsKernel<<<grid_1d, threads>>>(work_buffers->sums, n);
      ScoreBlockAtomicKernel<<<n, threads>>>(
          grid_buffers->grid, w, h, work_buffers->px, work_buffers->py, p,
          work_buffers->cx, work_buffers->cy, n, work_buffers->sums);
      NormalizeSumsKernel<<<grid_1d, threads>>>(work_buffers->sums, n,
                                                inv_norm,
                                                work_buffers->score);
    } else {
      ScoreSharedKernel<<<n, threads, threads * sizeof(int)>>>(
          grid_buffers->grid, w, h, work_buffers->px, work_buffers->py, p,
          work_buffers->cx, work_buffers->cy, n, inv_norm,
          work_buffers->score);
    }
    CheckCuda(cudaEventRecord(work_buffers->kernel_stop),
              "cudaEventRecord stop");

    CheckCuda(cudaGetLastError(), "score_all kernel launch");
    const auto sync_start = ProfileClock::now();
    CheckCuda(cudaEventSynchronize(work_buffers->kernel_stop),
              "score_all kernel synchronize");
    const double sync_host_ms = ProfileMsSince(sync_start);
    float kernel_ms = 0.0f;
    CheckCuda(cudaEventElapsedTime(&kernel_ms, work_buffers->kernel_start,
                                   work_buffers->kernel_stop),
              "cudaEventElapsedTime");
    profile.kernel_ms += static_cast<double>(kernel_ms);
    profile.sync_ms += std::max(0.0, sync_host_ms - profile.kernel_ms);
  }

  {
    CARTOGRAPHER_PARALLEL_NVTX_RANGE("D2H");
    const auto d2h_start = ProfileClock::now();
    CheckCuda(cudaMemcpy(score->data(), work_buffers->score,
                         n * sizeof(float), cudaMemcpyDeviceToHost),
              "cudaMemcpy score");
    profile.d2h_score_ms += ProfileMsSince(d2h_start);
  }
  finish_profile();
}

void score_all_batched(const std::vector<unsigned char>& grid, const int w,
                       const int h, const std::vector<int>& scan_x_flat,
                       const std::vector<int>& scan_y_flat,
                       const std::vector<int>& scan_offsets,
                       const std::vector<int>& scan_sizes,
                       const std::vector<int>& cand_scan,
                       const std::vector<int>& cand_x,
                       const std::vector<int>& cand_y,
                       std::vector<float>* const score) {
  CARTOGRAPHER_PARALLEL_NVTX_RANGE("score_all_batched_cuda");
  if (score == nullptr) return;
  ScoreAllProfile profile;
  profile.call_count = 1;
  profile.grid_cells = static_cast<std::int64_t>(grid.size());
  profile.scan_points = static_cast<std::int64_t>(
      std::min(scan_x_flat.size(), scan_y_flat.size()));
  profile.candidates = static_cast<std::int64_t>(
      std::min(cand_scan.size(), std::min(cand_x.size(), cand_y.size())));
  ResetLastScoreAllProfile();
  const auto profile_start = ProfileClock::now();
  const auto finish_profile = [&profile, profile_start]() {
    profile.total_ms = ProfileMsSince(profile_start);
    MutableLastScoreAllProfile() = profile;
    AddScoreAllProfile(profile);
  };

  const int n = static_cast<int>(
      std::min(cand_scan.size(), std::min(cand_x.size(), cand_y.size())));
  const int p_total = static_cast<int>(
      std::min(scan_x_flat.size(), scan_y_flat.size()));
  const int scan_count =
      static_cast<int>(std::min(scan_offsets.size(), scan_sizes.size()));
  const auto setup_start = ProfileClock::now();
  score->assign(n, 0.0f);
  if (w <= 0 || h <= 0 || n == 0 || p_total == 0 || scan_count == 0 ||
      grid.size() < static_cast<size_t>(w * h)) {
    profile.cpu_prepost_ms += ProfileMsSince(setup_start);
    finish_profile();
    return;
  }
  profile.cpu_prepost_ms += ProfileMsSince(setup_start);

  const bool reuse =
      SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGridBatched ||
      SCORE_ALL_CUDA_MODE == kModeReuseWarpCachedGridBatched;
  const bool pinned =
      SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGridBatched ||
      SCORE_ALL_CUDA_MODE == kModeReuseWarpCachedGridBatched;
  const bool cached_grid =
      SCORE_ALL_CUDA_MODE == kModeReuseSharedCachedGridBatched ||
      SCORE_ALL_CUDA_MODE == kModeReuseWarpCachedGridBatched;

  CudaBuffers local_buffers;
  CudaBuffers* const work_buffers = reuse ? &g_reuse_buffers : &local_buffers;
  CudaBuffers* const grid_buffers = work_buffers;
  grid_buffers->EnsureGrid(grid.size(), pinned, &profile);
  work_buffers->EnsureWork(static_cast<size_t>(p_total), static_cast<size_t>(n),
                           pinned, &profile);
  work_buffers->EnsureBatchedExtras(static_cast<size_t>(scan_count),
                                    static_cast<size_t>(n), &profile);
  CopyBatchedInputs(grid, scan_x_flat, scan_y_flat, scan_offsets, scan_sizes,
                    cand_scan, cand_x, cand_y, grid_buffers, work_buffers,
                    pinned, cached_grid, &profile);

  int threads = ThreadsPerBlock();
  if (SCORE_ALL_CUDA_MODE == kModeReuseWarpCachedGridBatched) {
    threads = std::max(32, (threads / 32) * 32);
  }
  {
    CARTOGRAPHER_PARALLEL_NVTX_RANGE("kernel_batched");
    CheckCuda(cudaEventRecord(work_buffers->kernel_start),
              "cudaEventRecord batched start");
    if (SCORE_ALL_CUDA_MODE == kModeReuseWarpCachedGridBatched) {
      const int warps_per_block = std::max(1, threads / 32);
      const int blocks = (n + warps_per_block - 1) / warps_per_block;
      ScoreBatchedWarpKernel<<<blocks, threads>>>(
          grid_buffers->grid, w, h, work_buffers->px, work_buffers->py,
          work_buffers->scan_offsets, work_buffers->scan_sizes, scan_count,
          work_buffers->cand_scan, work_buffers->cx, work_buffers->cy, n,
          work_buffers->score);
    } else {
      ScoreBatchedSharedKernel<<<n, threads, threads * sizeof(int)>>>(
          grid_buffers->grid, w, h, work_buffers->px, work_buffers->py,
          work_buffers->scan_offsets, work_buffers->scan_sizes, scan_count,
          work_buffers->cand_scan, work_buffers->cx, work_buffers->cy, n,
          work_buffers->score);
    }
    CheckCuda(cudaEventRecord(work_buffers->kernel_stop),
              "cudaEventRecord batched stop");

    CheckCuda(cudaGetLastError(), "score_all_batched kernel launch");
    const auto sync_start = ProfileClock::now();
    CheckCuda(cudaEventSynchronize(work_buffers->kernel_stop),
              "score_all_batched kernel synchronize");
    const double sync_host_ms = ProfileMsSince(sync_start);
    float kernel_ms = 0.0f;
    CheckCuda(cudaEventElapsedTime(&kernel_ms, work_buffers->kernel_start,
                                   work_buffers->kernel_stop),
              "cudaEventElapsedTime batched");
    profile.kernel_ms += static_cast<double>(kernel_ms);
    profile.sync_ms += std::max(0.0, sync_host_ms - profile.kernel_ms);
  }

  {
    CARTOGRAPHER_PARALLEL_NVTX_RANGE("D2H_batched");
    const auto d2h_start = ProfileClock::now();
    CheckCuda(cudaMemcpy(score->data(), work_buffers->score,
                         n * sizeof(float), cudaMemcpyDeviceToHost),
              "cudaMemcpy batched score");
    profile.d2h_score_ms += ProfileMsSince(d2h_start);
  }
  finish_profile();
}

}  // namespace cartographer_parallel
