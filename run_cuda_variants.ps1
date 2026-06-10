$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root
try {
  . .\setup_cuda_env.ps1
  if ($LASTEXITCODE -ne 0) {
    throw "CUDA Toolkit nvcc is not available."
  }

  $cmake = Get-Command cmake -ErrorAction SilentlyContinue
  if ($null -eq $cmake) {
    $cmakePath = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
  } else {
    $cmakePath = $cmake.Source
  }
  if (-not (Test-Path $cmakePath)) {
    throw "CMake was not found."
  }

  $results = Join-Path $root "results"
  New-Item -ItemType Directory -Force -Path $results | Out-Null
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $out = Join-Path $results "cuda_variants_$stamp.txt"
  $variants = @(
    "gpu_thread",
    "gpu_block",
    "gpu_shared",
    "gpu_reuse_buffer",
    "gpu_reuse_block",
    "gpu_reuse_block_cached_grid"
  )
  $arch = if ($env:CUDA_ARCH) { $env:CUDA_ARCH } else { "75" }
  $buildDir = Join-Path $env:USERPROFILE "slam_opt_cuda_build_nofind"
  $cudaCompiler = $env:CUDACXX -replace "\\", "/"
  $cudaRoot = $env:CUDA_PATH -replace "\\", "/"

  & $cmakePath -S . -B $buildDir -G "Visual Studio 17 2022" -A x64 -DENABLE_CUDA=ON "-DCUDA_ARCHITECTURES=$arch" "-DCMAKE_CUDA_COMPILER=$cudaCompiler" "-DCUDAToolkit_ROOT=$cudaRoot"
  if ($LASTEXITCODE -ne 0) {
    throw "CMake CUDA configure failed."
  }
  & $cmakePath --build $buildDir --config Release --parallel
  if ($LASTEXITCODE -ne 0) {
    throw "CMake CUDA build failed."
  }

  foreach ($variant in $variants) {
    $scoreExe = Join-Path $buildDir "Release\benchmark_score_all_$variant.exe"
    $matcherExe = Join-Path $buildDir "Release\benchmark_matcher_$variant.exe"

    "## score_all $variant 4096 candidates" | Tee-Object -FilePath $out -Append
    & $scoreExe --iters 20 --points 1200 --candidates 4096 | Tee-Object -FilePath $out -Append

    "## score_all $variant 16384 candidates" | Tee-Object -FilePath $out -Append
    & $scoreExe --iters 20 --points 1200 --candidates 16384 | Tee-Object -FilePath $out -Append

    "## matcher $variant" | Tee-Object -FilePath $out -Append
    & $matcherExe --iters 10 --points 1200 --map "..\carrographer_task_ros2\carrographer_task_ros2\maps\0501.yaml" | Tee-Object -FilePath $out -Append
  }

  Write-Host "Saved results to $out"
} finally {
  Pop-Location
}
