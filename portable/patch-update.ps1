[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Root,
  [string]$ManifestUrl = "https://github.com/3Takagi/audio-video-tool/releases/latest/download/AudioVideoTool-Patch.json"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = [System.IO.Path]::GetFullPath($Root)
$UpdateDir = Join-Path $Root "data\patch-update"
$LogDir = Join-Path $Root "logs"
$LogFile = Join-Path $LogDir "update.log"
New-Item -ItemType Directory -Force -Path $UpdateDir, $LogDir | Out-Null

function Write-UpdateLog($Message) {
  $line = "{0} {1}" -f (Get-Date).ToString("s"), $Message
  Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value $line
  Write-Host $Message
}

function Get-Revision($VersionFile) {
  if (!(Test-Path -LiteralPath $VersionFile)) {
    return 0
  }
  try {
    $data = Get-Content -LiteralPath $VersionFile -Encoding UTF8 -Raw | ConvertFrom-Json
    return [int]$data.revision
  } catch {
    return 0
  }
}

$LocalVersionFile = Join-Path $Root "app-version.json"
$localRevision = Get-Revision $LocalVersionFile
$RemoteManifestPath = Join-Path $UpdateDir "remote-manifest.json"

try {
  Remove-Item -LiteralPath $RemoteManifestPath -Force -ErrorAction SilentlyContinue
  Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -TimeoutSec 8 -Headers @{ "User-Agent" = "AudioVideoTool-Updater" } -OutFile $RemoteManifestPath
  $remote = Get-Content -LiteralPath $RemoteManifestPath -Encoding UTF8 -Raw | ConvertFrom-Json
} catch {
  Write-UpdateLog "Patch check skipped: $($_.Exception.Message)"
  exit 0
}

$remoteRevision = [int]$remote.revision
$minimumShell = [string]$remote.minimum_shell_version
if ($env:AV_TOOL_SHELL_VERSION -and $minimumShell) {
  try {
    if ([version]$env:AV_TOOL_SHELL_VERSION -lt [version]$minimumShell) {
      Write-UpdateLog "Patch requires desktop shell $minimumShell or newer."
      exit 0
    }
  } catch {
    Write-UpdateLog "Patch shell compatibility could not be evaluated."
    exit 0
  }
}
if ($remoteRevision -le $localRevision) {
  Write-UpdateLog "Content is current (revision $localRevision)."
  exit 0
}

$ZipPath = Join-Path $UpdateDir "patch.zip"
$ExtractRoot = Join-Path $UpdateDir "next"
$NextApp = Join-Path $Root "app.patch-next"
$BackupApp = Join-Path $UpdateDir "app-backup"
$BackupRequirements = Join-Path $UpdateDir "requirements.txt.backup"
$AppBackupCreated = $false
$AppInstalled = $false
Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue

try {
  Write-UpdateLog "Downloading content patch revision $remoteRevision..."
  Invoke-WebRequest -Uri ([string]$remote.download_url) -UseBasicParsing -TimeoutSec 120 -Headers @{ "User-Agent" = "AudioVideoTool-Updater" } -OutFile $ZipPath
  $actualHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $expectedHash = ([string]$remote.sha256).ToLowerInvariant()
  if ($actualHash -ne $expectedHash) {
    throw "Patch SHA-256 verification failed."
  }

  Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractRoot -Force
  $patchRevision = Get-Revision (Join-Path $ExtractRoot "app-version.json")
  if ($patchRevision -ne $remoteRevision) {
    throw "Patch version does not match its manifest."
  }
  if (!(Test-Path -LiteralPath (Join-Path $ExtractRoot "app\app.py"))) {
    throw "Patch payload is incomplete."
  }

  Remove-Item -LiteralPath $NextApp, $BackupApp -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $BackupRequirements -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath (Join-Path $ExtractRoot "app") -Destination $NextApp -Recurse

  $oldRequirementsHash = ""
  $requirementsPath = Join-Path $Root "requirements.txt"
  if (Test-Path -LiteralPath $requirementsPath) {
    $oldRequirementsHash = (Get-FileHash -LiteralPath $requirementsPath -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $requirementsPath -Destination $BackupRequirements
  }

  if (Test-Path -LiteralPath (Join-Path $Root "app")) {
    Move-Item -LiteralPath (Join-Path $Root "app") -Destination $BackupApp
    $AppBackupCreated = $true
  }
  Move-Item -LiteralPath $NextApp -Destination (Join-Path $Root "app")
  $AppInstalled = $true

  foreach ($name in @("requirements.txt", "install.ps1", "update.ps1", "sync-backend.ps1", "slim.ps1", "patch-update.ps1", "config.example.json")) {
    $source = Join-Path $ExtractRoot $name
    if (Test-Path -LiteralPath $source) {
      Copy-Item -LiteralPath $source -Destination (Join-Path $Root $name) -Force
    }
  }

  $newRequirementsHash = (Get-FileHash -LiteralPath $requirementsPath -Algorithm SHA256).Hash
  $venvPython = Join-Path $Root "runtime\venv\Scripts\python.exe"
  if ($oldRequirementsHash -and $newRequirementsHash -ne $oldRequirementsHash -and (Test-Path -LiteralPath $venvPython)) {
    Write-UpdateLog "Updating Python dependencies..."
    & $venvPython -m pip install -r $requirementsPath
    if ($LASTEXITCODE -ne 0) {
      throw "Python dependency update failed."
    }
  }

  Copy-Item -LiteralPath (Join-Path $ExtractRoot "app-version.json") -Destination $LocalVersionFile -Force
  Remove-Item -LiteralPath $BackupApp -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $BackupRequirements -Force -ErrorAction SilentlyContinue
  Write-UpdateLog "Applied content patch $($remote.version) (revision $remoteRevision)."
} catch {
  if ($AppBackupCreated -and (Test-Path -LiteralPath $BackupApp)) {
    Remove-Item -LiteralPath (Join-Path $Root "app") -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $BackupApp -Destination (Join-Path $Root "app")
  } elseif ($AppInstalled) {
    Remove-Item -LiteralPath (Join-Path $Root "app") -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $BackupRequirements) {
    Copy-Item -LiteralPath $BackupRequirements -Destination (Join-Path $Root "requirements.txt") -Force
  }
  Write-UpdateLog "Patch update failed; existing version was kept: $($_.Exception.Message)"
  exit 0
} finally {
  Remove-Item -LiteralPath $RemoteManifestPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $Root "app.patch-next") -Recurse -Force -ErrorAction SilentlyContinue
}
