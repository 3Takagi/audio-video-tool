param(
  [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"

$PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SyncScript = Join-Path $PackageRoot "sync-backend.ps1"
if (!(Test-Path -LiteralPath $SyncScript)) {
  throw "sync-backend.ps1 was not found."
}

$syncArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SyncScript, "-PackageRoot", $PackageRoot)
if ($InstallRoot) {
  $syncArgs += @("-SharedRoot", (Join-Path $InstallRoot "backend"))
}

$syncOutput = powershell @syncArgs
if ($LASTEXITCODE -ne 0) {
  throw "Backend update failed."
}

$root = [string]($syncOutput | Select-Object -Last 1)
Write-Host "Updated backend files:" -ForegroundColor Cyan
Write-Host $root
Write-Host ""
Write-Host "Runtime, config, cookies, downloads, and logs were preserved."
