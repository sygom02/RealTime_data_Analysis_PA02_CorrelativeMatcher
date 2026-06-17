# PA_02 Fast Correlative Scan Matcher



## 1. 준비

Jetson 안에서 프로젝트와 BAG/map 파일 

```bash
/data/student_02/Optimization_project
/data/student_02/cartographer_parallel/bags/scan.bag
/data/student_02/cartographer_parallel/maps/0501.yaml
```

ROS1 Melodic 환경을 먼저 불러온다.

```bash
cd /data/student_02/Optimization_project
source /opt/ros/melodic/setup.bash
```

## 2. 빌드 

```bash
cd /data/student_02/Optimization_project
source /opt/ros/melodic/setup.bash

rm -rf build_jetson_bag

cmake -S . -B build_jetson_bag \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_ROS1_BAG=ON \
  -DENABLE_CUDA=ON \
  -DENABLE_OPENMP=ON \
  -DCUDA_ARCHITECTURES=53 \
  -DCMAKE_PREFIX_PATH=/opt/ros/melodic \
  -Dcatkin_DIR=/opt/ros/melodic/share/catkin/cmake

cmake --build build_jetson_bag -j$(nproc) \
  --target benchmark_bag_matcher_baseline \
           benchmark_bag_matcher_cpu_boundary_openmp \
           benchmark_bag_matcher_score_buffer_reuse \
           benchmark_bag_matcher_gpu_shared \
           benchmark_bag_matcher_gpu_shared_cached_grid \
           benchmark_bag_matcher_gpu_shared_batched \
           benchmark_bag_matcher_gpu_reuse_buffer \
           benchmark_bag_matcher_gpu_reuse_buffer_cached_grid \
           benchmark_bag_matcher_gpu_reuse_buffer_cached_grid_batched \
           benchmark_bag_matcher_gpu_reuse_warp_cached_grid_batched \
           benchmark_bag_matcher_gpu_reuse_block_cached_grid
```

빌드가 끝나면 실행 파일이 생성되었는지 확인한다.

```bash
ls -lh build_jetson_bag/benchmark_bag_matcher_*
```

## 3. 실행 방법

bag 파일을 하나씩 실행한다

```bash
chmod +x run_bag_full_variant.sh

bash run_bag_full_variant.sh baseline
bash run_bag_full_variant.sh cpu_boundary_openmp
bash run_bag_full_variant.sh score_buffer_reuse
bash run_bag_full_variant.sh gpu_shared
bash run_bag_full_variant.sh gpu_shared_cached_grid
bash run_bag_full_variant.sh gpu_shared_batched
bash run_bag_full_variant.sh gpu_reuse_buffer
bash run_bag_full_variant.sh gpu_reuse_buffer_cached_grid
bash run_bag_full_variant.sh gpu_reuse_buffer_cached_grid_batched
bash run_bag_full_variant.sh gpu_reuse_warp_cached_grid_batched
bash run_bag_full_variant.sh gpu_reuse_block_cached_grid
bash run_bag_thread_sweep.sh gpu_reuse_buffer_cached_grid_batched
bash run_bag_thread_sweep.sh gpu_reuse_warp_cached_grid_batched
```

기본 입력 경로는 스크립트 안에서 아래 값으로 설정되어 있다.

```bash
BAG_PATH=/data/student_02/cartographer_parallel/bags/scan.bag
MAP_PATH=/data/student_02/cartographer_parallel/maps/0501.yaml
SCAN_TOPIC=/scan
BUILD_DIR=build_jetson_bag
OUT_DIR=results/bag_full
```

다른 BAG이나 map을 쓰고 싶으면 환경변수로 바꿔서 실행한다.

```bash
BAG_PATH=/path/to/scan.bag \
MAP_PATH=/path/to/map.yaml \
SCAN_TOPIC=/scan \
bash run_bag_full_variant.sh score_buffer_reuse
```

## 4. 결과 위치

실행 결과는 variant별로 아래에 저장된다.

```bash
results/bag_full/<variant>.json
results/bag_full/<variant>.csv
```

예시:

```bash
cat results/bag_full/baseline.json
cat results/bag_full/score_buffer_reuse.json
cat results/bag_full/gpu_reuse_warp_cached_grid_batched.json
```

