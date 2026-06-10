param(
  [int]$Iters = 10,
  [string]$CMakeExe = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
  [string]$BuildRoot = "C:\Users\seong"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outDir = Join-Path $root "results\analysis_$timestamp"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$map = Join-Path $root "..\carrographer_task_ros2\carrographer_task_ros2\maps\0501.yaml"
$baseBuild = Join-Path $BuildRoot "slam_opt_profile_base"
$reuseBuild = Join-Path $BuildRoot "slam_opt_profile_reuse"
$bucketBuild = Join-Path $BuildRoot "slam_opt_profile_bucket"
$cudaBuild = Join-Path $BuildRoot "slam_opt_profile_cuda"

& $CMakeExe -S $root -B $baseBuild -DENABLE_CUDA=OFF
& $CMakeExe --build $baseBuild --config Release -j 8

& $CMakeExe -S $root -B $reuseBuild -DENABLE_CUDA=OFF -DENABLE_SCORE_BUFFER_REUSE=ON
& $CMakeExe --build $reuseBuild --config Release -j 8

& $CMakeExe -S $root -B $bucketBuild -DENABLE_CUDA=OFF -DENABLE_SCORE_BUCKETING=ON
& $CMakeExe --build $bucketBuild --config Release -j 8

$pipelineSummary = Join-Path $outDir "pipeline_score_summary.txt"
$matcherCases = @(
  @{ Name = "baseline"; Exe = Join-Path $baseBuild "Release\benchmark_matcher_baseline.exe" },
  @{ Name = "cpu_boundary_openmp"; Exe = Join-Path $baseBuild "Release\benchmark_matcher_cpu_boundary_openmp.exe" },
  @{ Name = "score_buffer_reuse"; Exe = Join-Path $reuseBuild "Release\benchmark_matcher_cpu_boundary_openmp.exe" },
  @{ Name = "score_bucket_grouping"; Exe = Join-Path $bucketBuild "Release\benchmark_matcher_cpu_boundary_openmp.exe" }
)
foreach ($case in $matcherCases) {
  $csv = Join-Path $outDir ($case.Name + "_matcher_profile.csv")
  $line = & $case.Exe --iters $Iters --points 1200 --map $map --profile-csv $csv
  "$($case.Name) $line" | Tee-Object -FilePath $pipelineSummary -Append
}

$scoreSummary = Join-Path $outDir "score_scaling_pruning_summary.txt"
$sizes = @(
  @{ P = 256; C = 1000 },
  @{ P = 512; C = 5000 },
  @{ P = 1081; C = 10000 },
  @{ P = 2048; C = 50000 }
)
$gpuBreakdownVariants = @(
  "gpu_thread",
  "gpu_block",
  "gpu_shared",
  "gpu_shared_cached_grid",
  "gpu_reuse_buffer",
  "gpu_reuse_buffer_cached_grid",
  "gpu_reuse_block",
  "gpu_reuse_block_cached_grid"
)
$gpuMatcherVariants = @(
  "gpu_shared",
  "gpu_shared_cached_grid",
  "gpu_shared_batched",
  "gpu_block",
  "gpu_reuse_buffer",
  "gpu_reuse_buffer_cached_grid",
  "gpu_reuse_buffer_cached_grid_batched",
  "gpu_reuse_block",
  "gpu_reuse_block_cached_grid",
  "cpu_boundary_openmp"
)
$gpuScalingVariants = @(
  "gpu_reuse_buffer",
  "gpu_reuse_buffer_cached_grid",
  "gpu_reuse_block",
  "gpu_reuse_block_cached_grid"
)
$gpuCorrectnessVariants = @(
  "gpu_thread",
  "gpu_block",
  "gpu_shared",
  "gpu_shared_cached_grid",
  "gpu_shared_batched",
  "gpu_reuse_buffer",
  "gpu_reuse_buffer_cached_grid",
  "gpu_reuse_buffer_cached_grid_batched",
  "gpu_reuse_block",
  "gpu_reuse_block_cached_grid"
)
foreach ($size in $sizes) {
  foreach ($variant in @("baseline", "cpu_boundary_openmp")) {
    $exe = Join-Path $baseBuild ("Release\benchmark_score_all_$variant.exe")
    $csv = Join-Path $outDir ("score_${variant}_p$($size.P)_c$($size.C).csv")
    $line = & $exe --iters $Iters --warmup 3 --points $size.P --candidates $size.C --profile-csv $csv
    "score_all $variant p=$($size.P) c=$($size.C) $line" |
      Tee-Object -FilePath $scoreSummary -Append
  }
}
foreach ($variant in @("baseline", "cpu_boundary_openmp")) {
  $exe = Join-Path $baseBuild ("Release\benchmark_pruning_$variant.exe")
  $line = & $exe --iters $Iters --warmup 3 --points 1200 --candidates 4096
  "pruning $variant $line" | Tee-Object -FilePath $scoreSummary -Append
}

$correctnessSummary = Join-Path $outDir "correctness_summary.txt"
foreach ($variant in @("baseline", "cpu_boundary_openmp")) {
  $exe = Join-Path $baseBuild ("Release\benchmark_correctness_$variant.exe")
  $line = & $exe --points 1200 --candidates 4096 --top-k 10
  "$variant $line" | Tee-Object -FilePath $correctnessSummary -Append
}

$nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
if (-not $nvcc) {
  $portableCuda = Join-Path $root "tools\cuda-13.1-portable"
  $portableNvcc = Join-Path $portableCuda "bin\nvcc.exe"
  if (Test-Path $portableNvcc) {
    $env:CUDA_PATH = $portableCuda
    $env:CUDAToolkit_ROOT = $portableCuda
    $env:CUDACXX = $portableNvcc
    $env:CMAKE_CUDA_COMPILER = $portableNvcc
    $env:Path = "$portableCuda\bin;$env:Path"
    $nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
  }
}
if (-not $nvcc -and (Test-Path (Join-Path $root "setup_cuda_env.ps1"))) {
  try {
    powershell -ExecutionPolicy Bypass -File (Join-Path $root "setup_cuda_env.ps1")
  } catch {
    Write-Host "CUDA setup script failed; skipping local CUDA analysis."
  }
  $nvcc = Get-Command nvcc -ErrorAction SilentlyContinue
}

if ($nvcc) {
  $nvccPath = $nvcc.Source
  if (-not $nvccPath) {
    $nvccPath = $nvcc.Path
  }
  if (-not $nvccPath) {
    $nvccPath = $nvcc.Definition
  }
  if (-not $env:CUDACXX) {
    $env:CUDACXX = $nvccPath
  }
  if (-not $env:CUDAToolkit_ROOT) {
    $cudaBin = Split-Path -Parent $env:CUDACXX
    $env:CUDAToolkit_ROOT = Split-Path -Parent $cudaBin
  }
  if (-not $env:CUDA_PATH) {
    $env:CUDA_PATH = $env:CUDAToolkit_ROOT
  }
  & $CMakeExe -S $root -B $cudaBuild -DENABLE_CUDA=ON -DCUDA_ARCHITECTURES=75 -DCMAKE_CUDA_COMPILER="$env:CUDACXX" -DCUDAToolkit_ROOT="$env:CUDAToolkit_ROOT"
  & $CMakeExe --build $cudaBuild --config Release -j 8

  $gpuSummary = Join-Path $outDir "gpu_breakdown_scaling_summary.txt"
  foreach ($variant in $gpuBreakdownVariants) {
    $exe = Join-Path $cudaBuild ("Release\benchmark_score_all_$variant.exe")
    $csv = Join-Path $outDir ("score_${variant}_p1200_c4096.csv")
    $line = & $exe --iters $Iters --warmup 3 --points 1200 --candidates 4096 --profile-csv $csv
    "gpu_breakdown $variant $line" | Tee-Object -FilePath $gpuSummary -Append
  }
  foreach ($variant in $gpuMatcherVariants) {
    $exe = Join-Path $cudaBuild ("Release\benchmark_matcher_$variant.exe")
    if (Test-Path $exe) {
      $csv = Join-Path $outDir ("matcher_${variant}_profile.csv")
      $line = & $exe --iters $Iters --points 1200 --map $map --profile-csv $csv
      "matcher_cuda_build $variant $line" | Tee-Object -FilePath $gpuSummary -Append
    }
  }
  foreach ($size in $sizes) {
    foreach ($variant in $gpuScalingVariants) {
      $exe = Join-Path $cudaBuild ("Release\benchmark_score_all_$variant.exe")
      $csv = Join-Path $outDir ("score_${variant}_p$($size.P)_c$($size.C).csv")
      $line = & $exe --iters $Iters --warmup 3 --points $size.P --candidates $size.C --profile-csv $csv
      "gpu_scaling $variant p=$($size.P) c=$($size.C) $line" |
        Tee-Object -FilePath $gpuSummary -Append
    }
  }
  foreach ($variant in $gpuScalingVariants) {
    $exe = Join-Path $cudaBuild ("Release\benchmark_pruning_$variant.exe")
    $line = & $exe --iters $Iters --warmup 3 --points 1200 --candidates 4096
    "pruning $variant $line" | Tee-Object -FilePath $gpuSummary -Append
  }

  foreach ($variant in $gpuCorrectnessVariants) {
    $exe = Join-Path $cudaBuild ("Release\benchmark_correctness_$variant.exe")
    if (Test-Path $exe) {
      $line = & $exe --points 1200 --candidates 4096 --top-k 10
      "$variant $line" | Tee-Object -FilePath $correctnessSummary -Append
    }
  }
}

$strategyScript = Join-Path $root "summarize_best_strategy.py"
$python = Get-Command py -ErrorAction SilentlyContinue
if (-not $python) {
  $python = Get-Command python -ErrorAction SilentlyContinue
  if ($python -and $python.Source -like "*WindowsApps*") {
    $python = $null
  }
}
if ($python -and (Test-Path $strategyScript)) {
  & $python.Source $strategyScript --results-dir $outDir
}

Write-Host "Analysis results written to $outDir"
