[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ExePath,
  [string]$DatasetDir = "",
  [int[]]$FileSizesMb = @(10, 50, 200, 512),
  [int]$FilesPerSize = 2,
  [int]$StartupSeconds = 8,
  [int]$RunSeconds = 45,
  [switch]$SkipDataset,
  [switch]$LeaveRunning
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ExePath)) {
  throw "Executable not found: $ExePath"
}

if ([string]::IsNullOrWhiteSpace($DatasetDir)) {
  $DatasetDir = Join-Path (Split-Path -Parent $PSScriptRoot) "dist\benchmark_data"
}

function New-BenchmarkDataset {
  param(
    [string]$Root,
    [int[]]$SizesMb,
    [int]$PerSize
  )

  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  foreach ($sizeMb in $SizesMb) {
    if ($sizeMb -le 0) { continue }
    $bucket = Join-Path $Root "${sizeMb}MB"
    New-Item -ItemType Directory -Path $bucket -Force | Out-Null
    for ($i = 1; $i -le [Math]::Max(1, $PerSize); $i++) {
      $filePath = Join-Path $bucket ("sample_{0}_{1}MB.bin" -f $i, $sizeMb)
      if (Test-Path $filePath) { continue }
      $bytes = [int64]$sizeMb * 1MB
      Write-Host "Creating $filePath ($sizeMb MB)"
      fsutil file createnew $filePath $bytes | Out-Null
    }
  }
}

if (-not $SkipDataset) {
  Write-Host "Preparing benchmark dataset in $DatasetDir"
  New-BenchmarkDataset -Root $DatasetDir -SizesMb $FileSizesMb -PerSize $FilesPerSize
} else {
  Write-Host "Dataset generation skipped."
}

$totalFiles = @(Get-ChildItem -Path $DatasetDir -Recurse -File -ErrorAction SilentlyContinue).Count
$totalBytes = @(Get-ChildItem -Path $DatasetDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
if ($null -eq $totalBytes) { $totalBytes = 0 }
$totalGb = [math]::Round(($totalBytes / 1GB), 2)

Write-Host ""
Write-Host "Starting benchmark harness..."
Write-Host "Exe: $ExePath"
Write-Host "Dataset: $DatasetDir"
Write-Host "Dataset files: $totalFiles"
Write-Host "Dataset size: $totalGb GB"

$proc1 = Start-Process -FilePath $ExePath -PassThru
$proc2 = Start-Process -FilePath $ExePath -PassThru

Write-Host "Started PIDs: $($proc1.Id), $($proc2.Id)"
Write-Host "Waiting $StartupSeconds seconds for startup..."
Start-Sleep -Seconds $StartupSeconds

Write-Host ""
Write-Host "Listener sanity checks:"
Get-NetUDPEndpoint -LocalPort 40405 -ErrorAction SilentlyContinue | Format-Table -AutoSize
Get-NetTCPConnection -State Listen -LocalPort 40406 -ErrorAction SilentlyContinue | Format-Table -AutoSize

Write-Host ""
Write-Host "Benchmark run window: $RunSeconds seconds"
Write-Host "Suggested workload:"
Write-Host "  1) Drag folders/files from '$DatasetDir' into instance A."
Write-Host "  2) Verify appearance latency in instance B."
Write-Host "  3) Drag large remote files out from instance B."
Write-Host "  4) Capture logs (%APPDATA%\\FileShare\\fileshare.log) after run."
Start-Sleep -Seconds $RunSeconds

if ($LeaveRunning) {
  Write-Host "Leaving FileShare instances running."
  exit 0
}

Write-Host ""
Write-Host "Stopping benchmark harness processes..."
foreach ($p in @($proc1, $proc2)) {
  try {
    if ($null -ne $p -and !$p.HasExited) {
      Stop-Process -Id $p.Id -Force
      Write-Host "Stopped PID $($p.Id)"
    }
  } catch {
    Write-Warning "Failed to stop PID $($p.Id): $($_.Exception.Message)"
  }
}

Write-Host "Benchmark harness complete."
