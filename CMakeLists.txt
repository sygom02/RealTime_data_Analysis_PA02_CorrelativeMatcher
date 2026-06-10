cmake_minimum_required(VERSION 3.16)
project(optimization_project LANGUAGES CXX)

option(ENABLE_OPENMP "Enable OpenMP for future CPU variants" ON)
option(ENABLE_CUDA "Build CUDA score_all variants" OFF)
option(ENABLE_ROS1_BAG_NODE "Build ROS1 fast_correlative_node variants for bag segment tests" OFF)
option(ENABLE_ROS1_BAG "Build ROS1 rosbag matcher benchmarks" OFF)
option(ENABLE_SCORE_BUFFER_REUSE "Reuse Score() temporary vectors across scan groups" OFF)
option(ENABLE_SCORE_BUCKETING "Group Score() candidates by scan in one pass" OFF)
set(CUDA_ARCHITECTURES "" CACHE STRING
    "CUDA architectures, e.g. 75 for RTX 2070, 87 for Jetson Orin, 72 for Xavier, 53 for Nano")
set(NSIGHT_SYSTEMS_NVTX_INCLUDE_DIR "" CACHE PATH
    "Optional Nsight Systems NVTX include directory for Windows profiling")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CUDA_STANDARD 14)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_EXTENSIONS OFF)

if(ENABLE_SCORE_BUFFER_REUSE)
  add_compile_definitions(FAST_MATCHER_SCORE_BUFFER_REUSE=1)
endif()
if(ENABLE_SCORE_BUCKETING)
  add_compile_definitions(FAST_MATCHER_SCORE_BUCKETS=1)
endif()

function(add_assignment_variant variant source)
  add_library(assignment_${variant}
    ${source}
  )
  target_include_directories(assignment_${variant} PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  )
  target_compile_definitions(assignment_${variant} PRIVATE _USE_MATH_DEFINES NOMINMAX)

  add_library(fast_matcher_${variant}
    fast_matcher.cpp
  )
  target_include_directories(fast_matcher_${variant} PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  )
  target_compile_definitions(fast_matcher_${variant} PRIVATE _USE_MATH_DEFINES NOMINMAX)
  target_link_libraries(fast_matcher_${variant} PUBLIC assignment_${variant})

  add_executable(benchmark_score_all_${variant}
    benchmark_score_all.cpp
  )
  target_link_libraries(benchmark_score_all_${variant} PRIVATE assignment_${variant})

  add_executable(benchmark_pruning_${variant}
    benchmark_pruning.cpp
  )
  target_link_libraries(benchmark_pruning_${variant} PRIVATE assignment_${variant})

  add_executable(benchmark_correctness_${variant}
    benchmark_correctness.cpp
  )
  target_link_libraries(benchmark_correctness_${variant} PRIVATE assignment_${variant})

  add_executable(benchmark_matcher_${variant}
    benchmark_matcher.cpp
  )
  target_link_libraries(benchmark_matcher_${variant} PRIVATE fast_matcher_${variant})

  if(ENABLE_OPENMP AND OpenMP_CXX_FOUND)
    target_link_libraries(assignment_${variant} PUBLIC OpenMP::OpenMP_CXX)
    target_link_libraries(benchmark_score_all_${variant} PRIVATE OpenMP::OpenMP_CXX)
    target_link_libraries(benchmark_pruning_${variant} PRIVATE OpenMP::OpenMP_CXX)
    target_link_libraries(benchmark_correctness_${variant} PRIVATE OpenMP::OpenMP_CXX)
    target_link_libraries(benchmark_matcher_${variant} PRIVATE OpenMP::OpenMP_CXX)
  endif()
endfunction()

if(ENABLE_OPENMP)
  find_package(OpenMP)
endif()

add_assignment_variant(baseline score_all_baseline.cpp)
add_assignment_variant(cpu_boundary score_all_cpu_boundary.cpp)
add_assignment_variant(cpu_openmp score_all_cpu_openmp.cpp)
add_assignment_variant(cpu_boundary_openmp score_all_cpu_boundary_openmp.cpp)

if(ENABLE_CUDA)
  if(CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES ${CUDA_ARCHITECTURES})
  endif()
  enable_language(CUDA)
  set(CARTOGRAPHER_PARALLEL_NVTX_TARGET "")
  if(WIN32)
    set(LOCAL_CUDA_ROOT "${CUDAToolkit_ROOT}")
    if(NOT LOCAL_CUDA_ROOT)
      get_filename_component(LOCAL_CUDA_BIN_DIR "${CMAKE_CUDA_COMPILER}" DIRECTORY)
      get_filename_component(LOCAL_CUDA_ROOT "${LOCAL_CUDA_BIN_DIR}" DIRECTORY)
    endif()
    set(LOCAL_CUDA_INCLUDE_DIR "${LOCAL_CUDA_ROOT}/include")
    set(LOCAL_CUDA_RUNTIME_LIB "${LOCAL_CUDA_ROOT}/lib/x64/cudart.lib")
    if(NOT EXISTS "${LOCAL_CUDA_RUNTIME_LIB}")
      message(FATAL_ERROR "cudart.lib was not found at ${LOCAL_CUDA_RUNTIME_LIB}")
    endif()
    if(NOT NSIGHT_SYSTEMS_NVTX_INCLUDE_DIR)
      foreach(candidate
          "C:/Program Files/NVIDIA Corporation/Nsight Systems 2025.5.2/target-windows-x64/nvtx/include"
          "C:/Program Files/NVIDIA Corporation/Nsight Compute 2025.4.1/host/target-windows-x64/nvtx/include")
        if(EXISTS "${candidate}/nvtx3/nvToolsExt.h")
          set(NSIGHT_SYSTEMS_NVTX_INCLUDE_DIR "${candidate}")
          break()
        endif()
      endforeach()
    endif()
    if(NSIGHT_SYSTEMS_NVTX_INCLUDE_DIR
        AND EXISTS "${NSIGHT_SYSTEMS_NVTX_INCLUDE_DIR}/nvtx3/nvToolsExt.h")
      add_library(cartographer_parallel_nvtx INTERFACE)
      target_include_directories(cartographer_parallel_nvtx INTERFACE
        "${NSIGHT_SYSTEMS_NVTX_INCLUDE_DIR}"
      )
      set(CARTOGRAPHER_PARALLEL_NVTX_TARGET cartographer_parallel_nvtx)
    endif()
  else()
    find_package(CUDAToolkit REQUIRED)
    set(LOCAL_CUDA_INCLUDE_DIR "")
    set(LOCAL_CUDA_RUNTIME_LIB CUDA::cudart)
    if(TARGET CUDA::nvToolsExt)
      set(CARTOGRAPHER_PARALLEL_NVTX_TARGET CUDA::nvToolsExt)
    elseif(TARGET CUDA::nvtx3)
      set(CARTOGRAPHER_PARALLEL_NVTX_TARGET CUDA::nvtx3)
    endif()
  endif()

  function(enable_nvtx_if_available target)
    if(CARTOGRAPHER_PARALLEL_NVTX_TARGET)
      target_compile_definitions(${target} PRIVATE
        CARTOGRAPHER_PARALLEL_ENABLE_NVTX=1
      )
      target_link_libraries(${target} PUBLIC
        ${CARTOGRAPHER_PARALLEL_NVTX_TARGET}
      )
    endif()
  endfunction()

  function(add_cuda_assignment_variant variant mode)
    set(extra_variant_defs ${ARGN})
    add_library(assignment_${variant}
      score_all_cuda.cu
    )
    target_include_directories(assignment_${variant} PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/include
      ${LOCAL_CUDA_INCLUDE_DIR}
    )
    target_compile_definitions(assignment_${variant} PRIVATE
      _USE_MATH_DEFINES NOMINMAX SCORE_ALL_CUDA_MODE=${mode}
    )
    target_link_libraries(assignment_${variant} PUBLIC ${LOCAL_CUDA_RUNTIME_LIB})
    enable_nvtx_if_available(assignment_${variant})
    set_target_properties(assignment_${variant} PROPERTIES
      CUDA_SEPARABLE_COMPILATION OFF
      POSITION_INDEPENDENT_CODE ON
    )
    if(CUDA_ARCHITECTURES)
      set_target_properties(assignment_${variant} PROPERTIES
        CUDA_ARCHITECTURES "${CUDA_ARCHITECTURES}"
      )
    endif()

    add_library(fast_matcher_${variant}
      fast_matcher.cpp
    )
    target_include_directories(fast_matcher_${variant} PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/include
    )
    target_compile_definitions(fast_matcher_${variant} PRIVATE
      _USE_MATH_DEFINES NOMINMAX
      ${extra_variant_defs}
    )
    target_link_libraries(fast_matcher_${variant} PUBLIC assignment_${variant})
    enable_nvtx_if_available(fast_matcher_${variant})

    add_executable(benchmark_score_all_${variant}
      benchmark_score_all.cpp
    )
    target_link_libraries(benchmark_score_all_${variant} PRIVATE
      assignment_${variant}
    )

    add_executable(benchmark_pruning_${variant}
      benchmark_pruning.cpp
    )
    target_link_libraries(benchmark_pruning_${variant} PRIVATE
      assignment_${variant}
    )

    add_executable(benchmark_correctness_${variant}
      benchmark_correctness.cpp
    )
    target_compile_definitions(benchmark_correctness_${variant} PRIVATE
      ${extra_variant_defs}
    )
    target_link_libraries(benchmark_correctness_${variant} PRIVATE
      assignment_${variant}
    )

    add_executable(benchmark_matcher_${variant}
      benchmark_matcher.cpp
    )
    target_link_libraries(benchmark_matcher_${variant} PRIVATE
      fast_matcher_${variant}
    )
  endfunction()

  add_cuda_assignment_variant(gpu_thread 1)
  add_cuda_assignment_variant(gpu_block 2)
  add_cuda_assignment_variant(gpu_shared 3)
  add_cuda_assignment_variant(gpu_reuse_buffer 4)
  add_cuda_assignment_variant(gpu_reuse_block 5)
  add_cuda_assignment_variant(gpu_reuse_block_cached_grid 6)
  add_cuda_assignment_variant(gpu_reuse_shared_device 7)
  add_cuda_assignment_variant(gpu_reuse_shared_device_sync 8)
  add_cuda_assignment_variant(gpu_shared_cached_grid 9)
  add_cuda_assignment_variant(gpu_reuse_buffer_cached_grid 10)
  add_cuda_assignment_variant(gpu_shared_batched 11
    FAST_MATCHER_SCORE_BATCHED_GPU=1
    BENCHMARK_USE_BATCHED_SCORE_ALL=1
  )
  add_cuda_assignment_variant(gpu_reuse_buffer_cached_grid_batched 12
    FAST_MATCHER_SCORE_BATCHED_GPU=1
    BENCHMARK_USE_BATCHED_SCORE_ALL=1
  )
  add_cuda_assignment_variant(gpu_reuse_warp_cached_grid_batched 13
    FAST_MATCHER_SCORE_BATCHED_GPU=1
    BENCHMARK_USE_BATCHED_SCORE_ALL=1
  )
endif()

add_library(assignment_cpu
  score_all.cpp
)
target_include_directories(assignment_cpu PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_compile_definitions(assignment_cpu PRIVATE _USE_MATH_DEFINES NOMINMAX)

add_library(fast_matcher
  fast_matcher.cpp
)
target_include_directories(fast_matcher PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_compile_definitions(fast_matcher PRIVATE _USE_MATH_DEFINES NOMINMAX)
target_link_libraries(fast_matcher PUBLIC assignment_cpu)

add_executable(benchmark_matcher
  benchmark_matcher.cpp
)
target_link_libraries(benchmark_matcher PRIVATE fast_matcher)

add_executable(benchmark_score_all
  benchmark_score_all.cpp
)
target_link_libraries(benchmark_score_all PRIVATE assignment_cpu)

add_executable(benchmark_pruning
  benchmark_pruning.cpp
)
target_link_libraries(benchmark_pruning PRIVATE assignment_cpu)

add_executable(benchmark_correctness
  benchmark_correctness.cpp
)
target_link_libraries(benchmark_correctness PRIVATE assignment_cpu)

if(ENABLE_OPENMP AND OpenMP_CXX_FOUND)
  target_link_libraries(assignment_cpu PUBLIC OpenMP::OpenMP_CXX)
  target_link_libraries(benchmark_matcher PRIVATE OpenMP::OpenMP_CXX)
  target_link_libraries(benchmark_score_all PRIVATE OpenMP::OpenMP_CXX)
  target_link_libraries(benchmark_pruning PRIVATE OpenMP::OpenMP_CXX)
  target_link_libraries(benchmark_correctness PRIVATE OpenMP::OpenMP_CXX)
endif()

if(ENABLE_ROS1_BAG_NODE)
  find_package(catkin REQUIRED COMPONENTS
    geometry_msgs
    nav_msgs
    roscpp
    sensor_msgs
    std_msgs
    visualization_msgs
  )

  function(add_ros1_fast_correlative_node target matcher_target)
    add_executable(${target}
      fast_correlative_node.cpp
    )
    target_include_directories(${target} PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/include
      ${catkin_INCLUDE_DIRS}
    )
    target_compile_definitions(${target} PRIVATE _USE_MATH_DEFINES NOMINMAX)
    target_link_libraries(${target} PRIVATE
      ${matcher_target}
      ${catkin_LIBRARIES}
    )
  endfunction()

  add_library(fast_matcher_score_buffer_reuse_ros
    fast_matcher.cpp
  )
  target_include_directories(fast_matcher_score_buffer_reuse_ros PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  )
  target_compile_definitions(fast_matcher_score_buffer_reuse_ros PRIVATE
    _USE_MATH_DEFINES NOMINMAX FAST_MATCHER_SCORE_BUFFER_REUSE=1
  )
  target_link_libraries(fast_matcher_score_buffer_reuse_ros PUBLIC
    assignment_cpu_boundary_openmp
  )

  add_ros1_fast_correlative_node(
    fast_correlative_node_baseline fast_matcher_baseline)
  add_ros1_fast_correlative_node(
    fast_correlative_node_cpu_boundary_openmp
    fast_matcher_cpu_boundary_openmp)
  add_ros1_fast_correlative_node(
    fast_correlative_node_score_buffer_reuse
    fast_matcher_score_buffer_reuse_ros)

  if(ENABLE_CUDA)
    add_ros1_fast_correlative_node(
      fast_correlative_node_gpu_shared fast_matcher_gpu_shared)
    add_ros1_fast_correlative_node(
      fast_correlative_node_gpu_shared_cached_grid
      fast_matcher_gpu_shared_cached_grid)
    add_ros1_fast_correlative_node(
      fast_correlative_node_gpu_shared_batched
      fast_matcher_gpu_shared_batched)
    add_ros1_fast_correlative_node(
      fast_correlative_node_gpu_reuse_buffer
      fast_matcher_gpu_reuse_buffer)
    add_ros1_fast_correlative_node(
      fast_correlative_node_gpu_reuse_buffer_cached_grid
      fast_matcher_gpu_reuse_buffer_cached_grid)
    add_ros1_fast_correlative_node(
      fast_correlative_node_gpu_reuse_buffer_cached_grid_batched
      fast_matcher_gpu_reuse_buffer_cached_grid_batched)
    add_ros1_fast_correlative_node(
      fast_correlative_node_gpu_reuse_warp_cached_grid_batched
      fast_matcher_gpu_reuse_warp_cached_grid_batched)
  endif()
endif()

if(ENABLE_ROS1_BAG)
  find_package(catkin REQUIRED COMPONENTS
    rosbag
    roscpp
    sensor_msgs
  )

  function(add_ros1_bag_matcher_benchmark variant matcher_target)
    add_executable(benchmark_bag_matcher_${variant}
      benchmark_bag_matcher.cpp
    )
    target_include_directories(benchmark_bag_matcher_${variant} PRIVATE
      ${CMAKE_CURRENT_SOURCE_DIR}/include
      ${catkin_INCLUDE_DIRS}
    )
    target_compile_definitions(benchmark_bag_matcher_${variant} PRIVATE
      _USE_MATH_DEFINES NOMINMAX
    )
    target_link_libraries(benchmark_bag_matcher_${variant} PRIVATE
      ${matcher_target}
      ${catkin_LIBRARIES}
    )
    if(catkin_EXPORTED_TARGETS)
      add_dependencies(benchmark_bag_matcher_${variant}
        ${catkin_EXPORTED_TARGETS}
      )
    endif()
  endfunction()

  add_library(fast_matcher_score_buffer_reuse_bag
    fast_matcher.cpp
  )
  target_include_directories(fast_matcher_score_buffer_reuse_bag PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
  )
  target_compile_definitions(fast_matcher_score_buffer_reuse_bag PRIVATE
    _USE_MATH_DEFINES NOMINMAX FAST_MATCHER_SCORE_BUFFER_REUSE=1
  )
  target_link_libraries(fast_matcher_score_buffer_reuse_bag PUBLIC
    assignment_cpu_boundary_openmp
  )

  add_ros1_bag_matcher_benchmark(
    baseline fast_matcher_baseline)
  add_ros1_bag_matcher_benchmark(
    cpu_boundary_openmp fast_matcher_cpu_boundary_openmp)
  add_ros1_bag_matcher_benchmark(
    score_buffer_reuse fast_matcher_score_buffer_reuse_bag)

  if(TARGET fast_matcher_gpu_shared)
    add_ros1_bag_matcher_benchmark(
      gpu_shared
      fast_matcher_gpu_shared)
  endif()
  if(TARGET fast_matcher_gpu_shared_cached_grid)
    add_ros1_bag_matcher_benchmark(
      gpu_shared_cached_grid
      fast_matcher_gpu_shared_cached_grid)
  endif()
  if(TARGET fast_matcher_gpu_shared_batched)
    add_ros1_bag_matcher_benchmark(
      gpu_shared_batched
      fast_matcher_gpu_shared_batched)
  endif()
  if(TARGET fast_matcher_gpu_reuse_buffer)
    add_ros1_bag_matcher_benchmark(
      gpu_reuse_buffer
      fast_matcher_gpu_reuse_buffer)
  endif()
  if(TARGET fast_matcher_gpu_reuse_buffer_cached_grid)
    add_ros1_bag_matcher_benchmark(
      gpu_reuse_buffer_cached_grid
      fast_matcher_gpu_reuse_buffer_cached_grid)
  endif()
  if(TARGET fast_matcher_gpu_reuse_buffer_cached_grid_batched)
    add_ros1_bag_matcher_benchmark(
      gpu_reuse_buffer_cached_grid_batched
      fast_matcher_gpu_reuse_buffer_cached_grid_batched)
  endif()
  if(TARGET fast_matcher_gpu_reuse_warp_cached_grid_batched)
    add_ros1_bag_matcher_benchmark(
      gpu_reuse_warp_cached_grid_batched
      fast_matcher_gpu_reuse_warp_cached_grid_batched)
  endif()
  if(TARGET fast_matcher_gpu_reuse_block_cached_grid)
    add_ros1_bag_matcher_benchmark(
      gpu_reuse_block_cached_grid
      fast_matcher_gpu_reuse_block_cached_grid)
  endif()
endif()
