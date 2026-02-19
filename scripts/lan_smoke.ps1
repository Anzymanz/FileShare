param(
  [Parameter(Mandatory = $true)]
  [string]$ExePath,
  [int]$StartupSeconds = 8,
  [int]$RunSeconds = 25,
  [int]$SimLatencyMsA = 0,
  [int]$SimLatencyMsB = 0,
  [int]$SimDropPercentA = 0,
  [int]$SimDropPercentB = 0,
  [switch]$RegressionChecks,
  [switch]$LeaveRunning
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ExePath)) {
  throw "Executable not found: $ExePath"
}

function Start-FileShareInstance {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [int]$LatencyMs,
    [int]$DropPercent
  )

  $latency = [Math]::Max(0, $LatencyMs)
  $drop = [Math]::Max(0, [Math]::Min(95, $DropPercent))
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $Path
  $psi.WorkingDirectory = Split-Path -Parent $Path
  $psi.UseShellExecute = $false
  $psi.EnvironmentVariables["FILESHARE_SIM_LATENCY_MS"] = $latency.ToString()
  $psi.EnvironmentVariables["FILESHARE_SIM_DROP_PERCENT"] = $drop.ToString()
  return [System.Diagnostics.Process]::Start($psi)
}

Write-Host "Starting LAN smoke harness for FileShare..."
Write-Host "Exe: $ExePath"
Write-Host "Instance A sim: latency=${SimLatencyMsA}ms drop=${SimDropPercentA}%"
Write-Host "Instance B sim: latency=${SimLatencyMsB}ms drop=${SimDropPercentB}%"

$proc1 = Start-FileShareInstance -Path $ExePath -LatencyMs $SimLatencyMsA -DropPercent $SimDropPercentA
$proc2 = Start-FileShareInstance -Path $ExePath -LatencyMs $SimLatencyMsB -DropPercent $SimDropPercentB

Write-Host "Started PIDs: $($proc1.Id), $($proc2.Id)"
Write-Host "Waiting $StartupSeconds seconds for startup..."
Start-Sleep -Seconds $StartupSeconds

Write-Host ""
Write-Host "Checking UDP discovery binding (port 40405)..."
Get-NetUDPEndpoint -LocalPort 40405 -ErrorAction SilentlyContinue | Format-Table -AutoSize

Write-Host ""
Write-Host "Checking TCP listener(s) on transfer port 40406..."
Get-NetTCPConnection -LocalPort 40406 -ErrorAction SilentlyContinue | Format-Table -AutoSize

if ($RegressionChecks) {
  $pids = @($proc1.Id, $proc2.Id)
  Write-Host ""
  Write-Host "Regression checks:"
  $udpByPid = Get-NetUDPEndpoint -LocalPort 40405 -ErrorAction SilentlyContinue |
    Where-Object { $pids -contains $_.OwningProcess }
  $tcpByPid = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $pids -contains $_.OwningProcess }
  foreach ($pid in $pids) {
    $udpOk = ($udpByPid | Where-Object { $_.OwningProcess -eq $pid }).Count -gt 0
    $tcpOk = ($tcpByPid | Where-Object { $_.OwningProcess -eq $pid }).Count -gt 0
    if ($udpOk -and $tcpOk) {
      Write-Host " - PID ${pid}: PASS (UDP+TCP listeners present)"
    } else {
      Write-Warning " - PID ${pid}: FAIL (UDP=$udpOk TCP=$tcpOk)"
    }
  }
}

Write-Host ""
Write-Host "Harness running for $RunSeconds seconds."
Write-Host "During this window:"
Write-Host " - Drop files into either window."
Write-Host " - Verify peer visibility in settings."
Write-Host " - Verify transfer panel updates."
Write-Host " - Verify nudge both directions."
Start-Sleep -Seconds $RunSeconds

if ($LeaveRunning) {
  Write-Host "Leaving FileShare processes running."
  exit 0
}

Write-Host ""
Write-Host "Stopping harness processes..."
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

Write-Host "LAN smoke harness complete."
