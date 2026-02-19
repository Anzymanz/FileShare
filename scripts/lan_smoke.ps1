param(
  [Parameter(Mandatory = $true)]
  [string]$ExePath,
  [int]$StartupSeconds = 8,
  [int]$RunSeconds = 25,
  [switch]$LeaveRunning
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $ExePath)) {
  throw "Executable not found: $ExePath"
}

Write-Host "Starting LAN smoke harness for FileShare..."
Write-Host "Exe: $ExePath"

$proc1 = Start-Process -FilePath $ExePath -PassThru
$proc2 = Start-Process -FilePath $ExePath -PassThru

Write-Host "Started PIDs: $($proc1.Id), $($proc2.Id)"
Write-Host "Waiting $StartupSeconds seconds for startup..."
Start-Sleep -Seconds $StartupSeconds

Write-Host ""
Write-Host "Checking UDP discovery binding (port 40405)..."
Get-NetUDPEndpoint -LocalPort 40405 -ErrorAction SilentlyContinue | Format-Table -AutoSize

Write-Host ""
Write-Host "Checking TCP listener(s) on transfer port 40406..."
Get-NetTCPConnection -LocalPort 40406 -ErrorAction SilentlyContinue | Format-Table -AutoSize

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
