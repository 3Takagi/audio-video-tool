param(
  [string]$PackageRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [string]$SharedRoot = ""
)

$ErrorActionPreference = "Stop"

$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path

function Get-DefaultInstallRoot {
  return (Join-Path $env:LOCALAPPDATA "AudioVideoTool")
}

function Get-SavedBackendRoot {
  $locationFile = Join-Path (Get-DefaultInstallRoot) "install-location.json"
  if (!(Test-Path -LiteralPath $locationFile)) {
    return $null
  }
  try {
    $data = Get-Content -LiteralPath $locationFile -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($data.backendRoot) {
      return [string]$data.backendRoot
    }
    if ($data.installRoot) {
      return (Join-Path ([string]$data.installRoot) "backend")
    }
  } catch {}
  return $null
}

function Save-BackendRoot($BackendRoot) {
  $defaultRoot = Get-DefaultInstallRoot
  $locationFile = Join-Path $defaultRoot "install-location.json"
  New-Item -ItemType Directory -Force -Path $defaultRoot | Out-Null
  $payload = [ordered]@{
    schema = 1
    installRoot = (Split-Path -Parent $BackendRoot)
    backendRoot = $BackendRoot
    updatedAt = (Get-Date).ToUniversalTime().ToString("o")
  }
  $payload | ConvertTo-Json | Set-Content -LiteralPath $locationFile -Encoding UTF8
}

function Resolve-SharedRoot {
  if ($SharedRoot) {
    return $SharedRoot
  }
  if ($env:AV_TOOL_BACKEND) {
    return $env:AV_TOOL_BACKEND
  }
  if ($env:AV_TOOL_INSTALL_ROOT) {
    return (Join-Path $env:AV_TOOL_INSTALL_ROOT "backend")
  }
  $saved = Get-SavedBackendRoot
  if ($saved) {
    return $saved
  }
  return (Join-Path (Get-DefaultInstallRoot) "backend")
}

$SharedRoot = Resolve-SharedRoot
$SharedRoot = [System.IO.Path]::GetFullPath($SharedRoot)
Save-BackendRoot $SharedRoot
New-Item -ItemType Directory -Force -Path $SharedRoot | Out-Null

function Copy-Path($RelativePath, [switch]$IfMissing) {
  $source = Join-Path $PackageRoot $RelativePath
  $dest = Join-Path $SharedRoot $RelativePath
  if (!(Test-Path -LiteralPath $source)) {
    return
  }
  if ($IfMissing -and (Test-Path -LiteralPath $dest)) {
    return
  }
  $parent = Split-Path -Parent $dest
  if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
}

Copy-Path "app"
Copy-Path "requirements.txt"
Copy-Path "install.ps1"
Copy-Path "update.ps1"
Copy-Path "slim.ps1"
Copy-Path "config.example.json" -IfMissing
Copy-Path "runtime\python" -IfMissing
Copy-Path "tools\Real-ESRGAN" -IfMissing
Copy-Path "tools\ffmpeg" -IfMissing

New-Item -ItemType Directory -Force -Path (Join-Path $SharedRoot "config"), (Join-Path $SharedRoot "data"), (Join-Path $SharedRoot "downloads"), (Join-Path $SharedRoot "logs") | Out-Null
Write-Output $SharedRoot
