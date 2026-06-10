$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cudaCandidates = @()

$portableCuda = Join-Path $root "tools\cuda-13.1-portable"
if (Test-Path $portableCuda) {
  $cudaCandidates += $portableCuda
}

if ($env:CUDA_PATH) {
  $cudaCandidates += $env:CUDA_PATH
}

Get-ChildItem Env:CUDA_PATH_V* -ErrorAction SilentlyContinue | ForEach-Object {
  $cudaCandidates += $_.Value
}

$toolkitRoot = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA"
if (Test-Path $toolkitRoot) {
  Get-ChildItem $toolkitRoot -Directory | Sort-Object Name -Descending | ForEach-Object {
    $cudaCandidates += $_.FullName
  }
}

$cudaRoot = $null
foreach ($candidate in $cudaCandidates) {
  if (Test-Path (Join-Path $candidate "bin\nvcc.exe")) {
    $cudaRoot = $candidate
    break
  }
}

if ($null -eq $cudaRoot) {
  Write-Host "CUDA Toolkit nvcc was not found on this PC."
  Write-Host "nvidia-smi may show a CUDA driver version, but nvcc requires the CUDA Toolkit."
  Write-Host "Install NVIDIA CUDA Toolkit, then re-run this script."
  exit 1
}

$env:CUDA_PATH = $cudaRoot
$env:CUDA_PATH_V13_1 = $cudaRoot
$env:CUDAToolkit_ROOT = $cudaRoot
$env:CUDACXX = Join-Path $cudaRoot "bin\nvcc.exe"
$env:CMAKE_CUDA_COMPILER = $env:CUDACXX
$env:Path = "$cudaRoot\bin;$cudaRoot\libnvvp;$env:Path"
Write-Host "CUDA_PATH=$env:CUDA_PATH"
nvcc --version
