param(
  [string]$PackageRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [string]$SharedRoot = (Join-Path $env:LOCALAPPDATA "AudioVideoTool\backend")
)

$ErrorActionPreference = "Stop"

$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
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
Copy-Path "slim.ps1"
Copy-Path "config.example.json" -IfMissing
Copy-Path "runtime\python" -IfMissing
Copy-Path "tools\Real-ESRGAN" -IfMissing
Copy-Path "tools\ffmpeg" -IfMissing

New-Item -ItemType Directory -Force -Path (Join-Path $SharedRoot "config"), (Join-Path $SharedRoot "data"), (Join-Path $SharedRoot "downloads"), (Join-Path $SharedRoot "logs") | Out-Null
Write-Output $SharedRoot
