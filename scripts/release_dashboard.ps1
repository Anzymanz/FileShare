[CmdletBinding()]
param(
  [switch]$SkipAnalyze,
  [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
  param(
    [string]$Check,
    [string]$Status,
    [string]$Details
  )
  $results.Add([pscustomobject]@{
    Check = $Check
    Status = $Status
    Details = $Details
  }) | Out-Null
}

function Invoke-Check {
  param(
    [string]$Name,
    [scriptblock]$Action
  )
  try {
    & $Action
  } catch {
    Add-Result -Check $Name -Status "FAIL" -Details $_.Exception.Message
  }
}

Invoke-Check -Name "Git working tree" -Action {
  $dirty = git status --porcelain
  if ([string]::IsNullOrWhiteSpace($dirty)) {
    Add-Result -Check "Git working tree" -Status "PASS" -Details "Clean"
  } else {
    Add-Result -Check "Git working tree" -Status "WARN" -Details "Uncommitted changes present"
  }
}

Invoke-Check -Name "Latest release tag" -Action {
  $latestTag = git describe --tags --abbrev=0 2>$null
  if ([string]::IsNullOrWhiteSpace($latestTag)) {
    Add-Result -Check "Latest release tag" -Status "WARN" -Details "No tags found"
  } else {
    Add-Result -Check "Latest release tag" -Status "PASS" -Details $latestTag.Trim()
  }
}

Invoke-Check -Name "Installer artifact" -Action {
  $installerDir = Join-Path $repoRoot "dist\installer"
  $latestInstaller = Get-ChildItem -Path $installerDir -Filter "FileShare-Setup-*.exe" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -eq $latestInstaller) {
    Add-Result -Check "Installer artifact" -Status "WARN" -Details "No installer found in dist/installer"
  } else {
    Add-Result -Check "Installer artifact" -Status "PASS" -Details "$($latestInstaller.Name) ($([math]::Round($latestInstaller.Length / 1MB, 1)) MB)"
  }
}

if (-not $SkipAnalyze) {
  Invoke-Check -Name "flutter analyze" -Action {
    & flutter analyze | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "flutter analyze failed"
    }
    Add-Result -Check "flutter analyze" -Status "PASS" -Details "No issues"
  }
} else {
  Add-Result -Check "flutter analyze" -Status "SKIP" -Details "Skipped by flag"
}

if (-not $SkipTests) {
  Invoke-Check -Name "flutter test" -Action {
    & flutter test | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "flutter test failed"
    }
    Add-Result -Check "flutter test" -Status "PASS" -Details "All tests passed"
  }
} else {
  Add-Result -Check "flutter test" -Status "SKIP" -Details "Skipped by flag"
}

Write-Host ""
Write-Host "FileShare Release Readiness"
$results | Format-Table -AutoSize

$failed = @($results | Where-Object { $_.Status -eq "FAIL" }).Count
if ($failed -gt 0) {
  Write-Host ""
  Write-Host "Overall: NOT READY ($failed failing check(s))"
  exit 1
}

$warn = @($results | Where-Object { $_.Status -eq "WARN" }).Count
Write-Host ""
if ($warn -gt 0) {
  Write-Host "Overall: READY WITH WARNINGS ($warn warning(s))"
} else {
  Write-Host "Overall: READY"
}
