param(
  [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"

$PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SyncScript = Join-Path $PackageRoot "sync-backend.ps1"
if (Test-Path -LiteralPath $SyncScript) {
  $syncArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SyncScript, "-PackageRoot", $PackageRoot)
  if ($InstallRoot) {
    $syncArgs += @("-SharedRoot", (Join-Path $InstallRoot "backend"))
  }
  $syncOutput = powershell @syncArgs
  if ($LASTEXITCODE -eq 0 -and $syncOutput) {
    $Root = [string]($syncOutput | Select-Object -Last 1)
  } else {
    $Root = $PackageRoot
  }
} else {
  $Root = $PackageRoot
}
$ConfigDir = Join-Path $Root "config"
$ConfigFile = Join-Path $ConfigDir "config.json"
$ExampleConfig = Join-Path $Root "config.example.json"
$LogDir = Join-Path $Root "logs"
$Python = Join-Path $Root "runtime\venv\Scripts\python.exe"
$InstallMarker = Join-Path $Root "runtime\install.ok"
$BundledFfmpegBin = Join-Path $Root "tools\ffmpeg\bin"
$BundledPython = Join-Path $Root "runtime\python"
$VenvConfig = Join-Path $Root "runtime\venv\pyvenv.cfg"

Set-Location $Root
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

if (!(Test-Path -LiteralPath $ConfigFile)) {
  Copy-Item -LiteralPath $ExampleConfig -Destination $ConfigFile -Force
}

$configText = Get-Content -LiteralPath $ConfigFile -Encoding UTF8 -Raw
$config = ConvertFrom-Json $configText
$port = 7860
$hostName = "127.0.0.1"
if ($config.port) {
  $port = [int]$config.port
}
if ($config.host) {
  $hostName = [string]$config.host
}

if ((Test-Path -LiteralPath $Python) -and (Test-Path -LiteralPath $InstallMarker)) {
  Write-Host ""
  Write-Host "==> Existing runtime found, skipping dependency install" -ForegroundColor Cyan
} else {
  Write-Host ""
  Write-Host "==> First run: installing dependencies" -ForegroundColor Cyan
  powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "install.ps1")
  if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $InstallMarker)) {
    Write-Host "Install failed. See logs\install.log" -ForegroundColor Red
    exit 1
  }
}

if (Test-Path -LiteralPath $VenvConfig) {
  $venvConfigText = Get-Content -LiteralPath $VenvConfig -Raw -Encoding UTF8
  $expectedHome = "home = $BundledPython"
  if ($venvConfigText -notmatch [regex]::Escape($expectedHome)) {
    $venvConfigText = $venvConfigText -replace "(?m)^home = .*$", $expectedHome
    Set-Content -LiteralPath $VenvConfig -Value $venvConfigText -Encoding UTF8
  }
}

$env:AV_TOOL_ROOT = $Root
$env:AV_TOOL_CONFIG = $ConfigFile
if (Test-Path -LiteralPath (Join-Path $BundledFfmpegBin "ffmpeg.exe")) {
  $env:PATH = $BundledFfmpegBin + ";" + $env:PATH
}

while ($true) {
  $busy = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($busy -eq $null) {
    break
  }
  Write-Host "Port $port is busy. Trying $($port + 1)..." -ForegroundColor Yellow
  $port = $port + 1
}

$url = "http://" + $hostName + ":" + $port + "/"
Write-Host ""
Write-Host "==> Starting web server" -ForegroundColor Cyan
Write-Host "URL: $url" -ForegroundColor Green
Start-Process $url

$serverOut = Join-Path $LogDir "server.log"
$serverErr = Join-Path $LogDir "server.err.log"
$arguments = @("-m", "uvicorn", "app.app:app", "--host", $hostName, "--port", "$port")
$process = Start-Process -FilePath $Python -ArgumentList $arguments -WorkingDirectory $Root -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -PassThru -Wait
if ($process.ExitCode -eq -1073741510) {
  Write-Host "Server stopped." -ForegroundColor Yellow
  exit 0
}
if ($process.ExitCode -ne 0) {
  Write-Host "Server exited with code $($process.ExitCode). See logs\server.err.log" -ForegroundColor Red
  exit $process.ExitCode
}
