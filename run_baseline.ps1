$ErrorActionPreference = "Stop"

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if ($null -eq $cmake) {
  $cmakePath = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
} else {
  $cmakePath = $cmake.Source
}

if (-not (Test-Path $cmakePath)) {
  throw "CMake was not found. Install CMake or Visual Studio Build Tools."
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$results = Join-Path $root "results"
New-Item -ItemType Directory -Force -Path $results | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$out = Join-Path $results "baseline_$stamp.txt"

Push-Location $root
try {
  & $cmakePath -S . -B build -G "Visual Studio 17 2022" -A x64
  & $cmakePath --build build --config Release --parallel

  "## score_all 4096 candidates" | Tee-Object -FilePath $out
  .\build\Release\benchmark_score_all_baseline.exe --iters 20 --points 1200 --candidates 4096 | Tee-Object -FilePath $out -Append

  "## score_all 16384 candidates" | Tee-Object -FilePath $out -Append
  .\build\Release\benchmark_score_all_baseline.exe --iters 20 --points 1200 --candidates 16384 | Tee-Object -FilePath $out -Append

  "## matcher local" | Tee-Object -FilePath $out -Append
  .\build\Release\benchmark_matcher_baseline.exe --iters 10 --points 1200 --map "..\carrographer_task_ros2\carrographer_task_ros2\maps\0501.yaml" | Tee-Object -FilePath $out -Append

  Write-Host "Saved results to $out"
} finally {
  Pop-Location
}
