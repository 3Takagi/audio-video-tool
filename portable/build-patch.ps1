[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$Project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dist = Join-Path $Project "dist"
$Stage = Join-Path $Dist "AudioVideoTool-Patch"
$Zip = Join-Path $Dist "AudioVideoTool-Patch.zip"
$ManifestPath = Join-Path $Dist "AudioVideoTool-Patch.json"
$VersionPath = Join-Path $Project "app-version.json"

if (!(Test-Path -LiteralPath $VersionPath)) {
  throw "app-version.json was not found."
}

$version = Get-Content -LiteralPath $VersionPath -Encoding UTF8 -Raw | ConvertFrom-Json
if ([int]$version.revision -lt 1) {
  throw "Patch revision must be a positive integer."
}

Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ManifestPath -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "app") | Out-Null

Copy-Item -LiteralPath (Join-Path $Project "app.py") -Destination (Join-Path $Stage "app\app.py")
New-Item -ItemType File -Force -Path (Join-Path $Stage "app\__init__.py") | Out-Null
Copy-Item -LiteralPath (Join-Path $Project "static") -Destination (Join-Path $Stage "app\static") -Recurse
Copy-Item -LiteralPath (Join-Path $Project "templates") -Destination (Join-Path $Stage "app\templates") -Recurse
Copy-Item -LiteralPath (Join-Path $Project "requirements.txt") -Destination (Join-Path $Stage "requirements.txt")
Copy-Item -LiteralPath $VersionPath -Destination (Join-Path $Stage "app-version.json")

foreach ($name in @("install.ps1", "update.ps1", "sync-backend.ps1", "slim.ps1", "patch-update.ps1", "config.example.json")) {
  Copy-Item -LiteralPath (Join-Path $Project "portable\$name") -Destination (Join-Path $Stage $name)
}

Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $Zip -Force
$sha256 = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{
  schema = 1
  revision = [int]$version.revision
  version = [string]$version.version
  minimum_shell_version = [string]$version.minimum_shell_version
  asset = "AudioVideoTool-Patch.zip"
  download_url = "https://github.com/3Takagi/audio-video-tool/releases/latest/download/AudioVideoTool-Patch.zip"
  sha256 = $sha256
  size = (Get-Item -LiteralPath $Zip).Length
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
}
$manifestJson = $manifest | ConvertTo-Json
[System.IO.File]::WriteAllText($ManifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Generated: $Zip"
Write-Host "Generated: $ManifestPath"
