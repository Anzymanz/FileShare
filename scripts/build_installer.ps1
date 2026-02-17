[CmdletBinding()]
param(
  [string]$AppVersion,
  [string]$Configuration = "release",
  [string]$IsccPath,
  [string]$VCRedistPath,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArgs
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$issPath = Join-Path $repoRoot "installer\FileShare.iss"
$buildDirRelease = Join-Path $repoRoot "build\windows\x64\runner\Release"
$buildDirDebug = Join-Path $repoRoot "build\windows\x64\runner\Debug"
$outputDir = Join-Path $repoRoot "dist\installer"
$vcRedistCachePath = Join-Path $repoRoot "installer\redist\VC_redist.x64.exe"
$vcRedistDownloadUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe"

function Resolve-IsccPath {
  param([string]$ExplicitPath)

  if ($ExplicitPath) {
    if (Test-Path $ExplicitPath) {
      return (Resolve-Path $ExplicitPath).Path
    }
    throw "Provided -IsccPath does not exist: $ExplicitPath"
  }

  $isccCommand = Get-Command "iscc.exe" -ErrorAction SilentlyContinue
  if ($null -ne $isccCommand) {
    return $isccCommand.Source
  }

  $candidatePaths = @()

  if (${env:ProgramFiles(x86)}) {
    $candidatePaths += Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
  }
  if ($env:ProgramFiles) {
    $candidatePaths += Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"
  }
  if ($env:LOCALAPPDATA) {
    $candidatePaths += Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"
  }

  $registryKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1"
  )
  foreach ($key in $registryKeys) {
    if (-not (Test-Path $key)) { continue }
    $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($props -and $props.InstallLocation) {
      $candidatePaths += Join-Path $props.InstallLocation "ISCC.exe"
    }
  }

  $resolvedPath = $candidatePaths |
    Where-Object { $_ -and (Test-Path $_) } |
    Select-Object -First 1

  if ($resolvedPath) {
    return $resolvedPath
  }

  throw @"
ISCC.exe not found.
Install Inno Setup 6, add ISCC.exe to PATH, or pass -IsccPath:

powershell -ExecutionPolicy Bypass -File .\scripts\build_installer.ps1 -IsccPath "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
"@
}

function Show-Usage {
  Write-Host @"
Usage:
  powershell -ExecutionPolicy Bypass -File .\scripts\build_installer.ps1 [options]

Options (PowerShell style):
  -AppVersion <semver>
  -Configuration <release|debug>
  -IsccPath <path-to-ISCC.exe>
  -VCRedistPath <path-to-VC_redist.x64.exe>

Options (GNU style):
  --app-version <semver> | --app-version=<semver>
  --configuration <release|debug> | --configuration=<release|debug>
  --iscc-path <path> | --iscc-path=<path>
  --vc-redist-path <path> | --vc-redist-path=<path>
  --help
"@
}

function Resolve-VCRedistPath {
  param([string]$ExplicitPath)

  if ($ExplicitPath) {
    if (Test-Path $ExplicitPath) {
      return (Resolve-Path $ExplicitPath).Path
    }
    throw "Provided -VCRedistPath does not exist: $ExplicitPath"
  }

  if (Test-Path $vcRedistCachePath) {
    return (Resolve-Path $vcRedistCachePath).Path
  }

  $vcRedistDir = Split-Path -Parent $vcRedistCachePath
  New-Item -ItemType Directory -Force -Path $vcRedistDir | Out-Null

  Write-Host "Downloading Microsoft Visual C++ Redistributable (x64)..."
  Invoke-WebRequest -Uri $vcRedistDownloadUrl -OutFile $vcRedistCachePath

  if (-not (Test-Path $vcRedistCachePath)) {
    throw "Failed to download VC_redist.x64.exe from $vcRedistDownloadUrl"
  }

  return (Resolve-Path $vcRedistCachePath).Path
}

function Apply-GnuStyleArgs {
  param([string[]]$ArgsToParse)

  if (-not $ArgsToParse -or $ArgsToParse.Count -eq 0) {
    return
  }

  $i = 0
  while ($i -lt $ArgsToParse.Count) {
    $token = $ArgsToParse[$i]
    if (-not $token.StartsWith("--")) {
      throw "Unsupported argument '$token'. Use --help to see supported options."
    }

    if ($token -eq "--help") {
      Show-Usage
      exit 0
    }

    $key = $token
    $value = $null
    if ($token.Contains("=")) {
      $parts = $token.Split("=", 2)
      $key = $parts[0]
      $value = $parts[1]
    } else {
      if (($i + 1) -ge $ArgsToParse.Count) {
        throw "Missing value for argument '$token'."
      }
      $value = $ArgsToParse[$i + 1]
      $i += 1
    }

    switch ($key) {
      "--app-version" { $script:AppVersion = $value }
      "--configuration" { $script:Configuration = $value }
      "--iscc-path" { $script:IsccPath = $value }
      "--vc-redist-path" { $script:VCRedistPath = $value }
      default {
        throw "Unsupported argument '$key'. Use --help to see supported options."
      }
    }

    $i += 1
  }
}

Apply-GnuStyleArgs -ArgsToParse $CliArgs

if (-not (Test-Path $issPath)) {
  throw "Installer script not found at $issPath"
}

if (-not $AppVersion) {
  $pubspecPath = Join-Path $repoRoot "pubspec.yaml"
  if (-not (Test-Path $pubspecPath)) {
    throw "pubspec.yaml not found at $pubspecPath"
  }
  $versionLine = Select-String -Path $pubspecPath -Pattern "^\s*version:\s*(.+)\s*$" | Select-Object -First 1
  if (-not $versionLine) {
    throw "Unable to parse app version from pubspec.yaml"
  }
  $rawVersion = $versionLine.Matches[0].Groups[1].Value.Trim()
  $AppVersion = ($rawVersion -split "\+")[0]
}

$flutterArgs = @("build", "windows")
if ($Configuration -eq "release") {
  $flutterArgs += "--release"
} elseif ($Configuration -eq "debug") {
  $flutterArgs += "--debug"
} else {
  throw "Unsupported configuration '$Configuration'. Use 'release' or 'debug'."
}

Write-Host "Building Flutter Windows app ($Configuration)..."
& flutter @flutterArgs
if ($LASTEXITCODE -ne 0) {
  throw "Flutter build failed."
}

if ($Configuration -eq "release") {
  $buildDir = $buildDirRelease
} elseif ($Configuration -eq "debug") {
  $buildDir = $buildDirDebug
} else {
  throw "Unsupported configuration '$Configuration'. Use 'release' or 'debug'."
}

if (-not (Test-Path (Join-Path $buildDir "fileshare.exe"))) {
  throw "Built executable not found in $buildDir (expected fileshare.exe)"
}

$vcRedistResolvedPath = Resolve-VCRedistPath -ExplicitPath $VCRedistPath
$vcRedistStagedPath = Join-Path $buildDir "VC_redist.x64.exe"
Copy-Item -Path $vcRedistResolvedPath -Destination $vcRedistStagedPath -Force
if (-not (Test-Path $vcRedistStagedPath)) {
  throw "Unable to stage VC_redist.x64.exe in build directory."
}
Write-Host "Staged VC++ runtime installer: $vcRedistStagedPath"

$isccExe = Resolve-IsccPath -ExplicitPath $IsccPath
Write-Host "Using ISCC: $isccExe"

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$isccArgs = @(
  "/DAppVersion=$AppVersion",
  "/DBuildDir=$buildDir",
  "/DOutputDir=$outputDir",
  "$issPath"
)

Write-Host "Building installer with Inno Setup..."
& $isccExe @isccArgs
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup compile failed."
}

Write-Host ""
Write-Host "Installer build complete."
Write-Host "Output directory: $outputDir"
