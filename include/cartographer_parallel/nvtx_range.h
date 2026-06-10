#pragma once

#if defined(CARTOGRAPHER_PARALLEL_ENABLE_NVTX)
#if defined(__has_include)
#if __has_include(<nvtx3/nvToolsExt.h>)
#include <nvtx3/nvToolsExt.h>
#define CARTOGRAPHER_PARALLEL_HAVE_NVTX 1
#elif __has_include(<nvToolsExt.h>)
#include <nvToolsExt.h>
#define CARTOGRAPHER_PARALLEL_HAVE_NVTX 1
#endif
#endif
#endif

namespace cartographer_parallel {

class NvtxRange {
 public:
  explicit NvtxRange(const char* const name) {
#if defined(CARTOGRAPHER_PARALLEL_HAVE_NVTX)
    nvtxRangePushA(name);
#else
    (void)name;
#endif
  }

  ~NvtxRange() {
#if defined(CARTOGRAPHER_PARALLEL_HAVE_NVTX)
    nvtxRangePop();
#endif
  }
};

}  // namespace cartographer_parallel

#define CARTOGRAPHER_PARALLEL_CONCAT_IMPL(a, b) a##b
#define CARTOGRAPHER_PARALLEL_CONCAT(a, b) \
  CARTOGRAPHER_PARALLEL_CONCAT_IMPL(a, b)
#define CARTOGRAPHER_PARALLEL_NVTX_RANGE(name)                      \
  ::cartographer_parallel::NvtxRange CARTOGRAPHER_PARALLEL_CONCAT(  \
      cartographer_parallel_nvtx_range_, __LINE__)(name)
