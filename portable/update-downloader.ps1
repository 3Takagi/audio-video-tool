param(
  [string]$BackendRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [switch]$Automatic
)

$ErrorActionPreference = "Stop"
$python = Join-Path $BackendRoot "runtime\venv\Scripts\python.exe"
if (!(Test-Path -LiteralPath $python)) { throw "Backend Python was not found: $python" }
$runtime = [System.IO.Path]::GetFullPath((Join-Path $BackendRoot "runtime"))
$statePath = Join-Path $runtime "downloader-update.json"
$current = Join-Path $runtime "downloader"
$stagePackages = Join-Path $runtime "downloader-next"
$previous = Join-Path $runtime "downloader-previous"
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
function Remove-DownloaderDirectory($Path) {
  $resolved = [System.IO.Path]::GetFullPath($Path)
  if ($resolved -notin @($stagePackages, $previous)) { throw "Unexpected downloader cleanup path." }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
$mutexHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($runtime))).Replace("-", "")
$mutex = New-Object System.Threading.Mutex($false, ("Local\AudioVideoToolDownloader-" + $mutexHash))
if (!$mutex.WaitOne(0)) { $mutex.Dispose(); return }
try {
  $state = @{}
  if (Test-Path -LiteralPath $statePath) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  if ($Automatic -and $state.last_attempt) {
    $interval = if ($state.success) { 24 } else { 6 }
    if ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($state.last_attempt) -lt [TimeSpan]::FromHours($interval)) { return }
  }
  $attempt = [DateTimeOffset]::UtcNow.ToString("o")
  @{ last_attempt = $attempt; success = $false } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
  try {
    Remove-DownloaderDirectory $stagePackages
    & $python -m pip install --upgrade --target $stagePackages --timeout 10 --retries 1 "yt-dlp[default]"
    if ($LASTEXITCODE -ne 0) { throw "Downloader dependency update failed." }
    & $python -c "import sys; sys.path.insert(0, sys.argv[1]); import yt_dlp, yt_dlp_ejs; from yt_dlp.version import __version__; print(__version__)" $stagePackages
    if ($LASTEXITCODE -ne 0) { throw "Downloader import validation failed." }
    Remove-DownloaderDirectory $previous
    if (Test-Path -LiteralPath $current) { Move-Item -LiteralPath $current -Destination $previous }
    try { Move-Item -LiteralPath $stagePackages -Destination $current } catch {
      if (Test-Path -LiteralPath $previous) { Move-Item -LiteralPath $previous -Destination $current }
      throw
    }
    Remove-DownloaderDirectory $previous
    @{ last_attempt = $attempt; success = $true } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
  } catch {
    @{ last_attempt = $attempt; success = $false; error = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    throw
  }

$nodeDir = Join-Path $BackendRoot "tools\node"
$nodeExe = Join-Path $nodeDir "node.exe"
if (Test-Path -LiteralPath $nodeExe) {
  $version = & $nodeExe --version
  if ($LASTEXITCODE -eq 0 -and $version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 22) { return }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = "https://nodejs.org/dist/latest-v24.x/"
$checksums = (Invoke-WebRequest -Uri ($base + "SHASUMS256.txt") -UseBasicParsing -TimeoutSec 60).Content
$line = ($checksums -split "`n" | Where-Object { $_ -match 'node-v[\d.]+-win-x64.zip$' } | Select-Object -First 1).Trim()
if (!$line) { throw "Node download checksum was not found." }
$parts = $line -split '\s+'
$archive = Join-Path $BackendRoot "runtime\node-download.zip"
$stage = Join-Path $BackendRoot "runtime\node-extract"
Invoke-WebRequest -Uri ($base + $parts[1]) -UseBasicParsing -TimeoutSec 180 -OutFile $archive
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $parts[0]) {
  throw "Node download checksum verification failed."
}
Expand-Archive -LiteralPath $archive -DestinationPath $stage -Force
$extracted = Get-ChildItem -LiteralPath $stage -Filter node.exe -Recurse -File | Select-Object -First 1
if (!$extracted) { throw "Node executable was not found in archive." }
New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null
Copy-Item -LiteralPath $extracted.FullName -Destination $nodeExe -Force
$license = Join-Path $extracted.DirectoryName "LICENSE"
if (Test-Path -LiteralPath $license) { Copy-Item -LiteralPath $license -Destination $nodeDir -Force }
Remove-Item -LiteralPath $archive -Force
$resolvedStage = [System.IO.Path]::GetFullPath($stage)
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $BackendRoot "runtime")) + [System.IO.Path]::DirectorySeparatorChar
if (!$resolvedStage.StartsWith($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Node extraction directory is outside the backend runtime."
}
Remove-Item -LiteralPath $resolvedStage -Recurse -Force
Write-Host "Downloader and JavaScript runtime are ready."
} catch {
  if ($attempt) {
    @{ last_attempt = $attempt; success = $false; error = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
  }
  if ($Automatic) { Write-Warning "Downloader check failed; keeping installed components: $($_.Exception.Message)" } else { throw }
} finally {
  $mutex.ReleaseMutex()
  $mutex.Dispose()
}
