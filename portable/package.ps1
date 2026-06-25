[CmdletBinding()]
param(
  [switch]$IncludePython,
  [switch]$Full,
  [switch]$IncludeFfmpeg,
  [switch]$MakeExe,
  [switch]$Slim
)

$ErrorActionPreference = "Stop"

$Project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dist = Join-Path $Project "dist"
if ($Full) {
  $IncludePython = $true
  $IncludeFfmpeg = $true
  $Slim = $true
}
$PackageName = if ($Full) { "AudioVideoTool-Full" } elseif ($IncludePython) { "AudioVideoTool-Portable-Python" } else { "AudioVideoTool-Portable" }
$Stage = Join-Path $Dist $PackageName
$Zip = Join-Path $Dist "$PackageName.zip"
$Exe = Join-Path $Dist "$PackageName.exe"

Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Exe -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Stage "app") | Out-Null

Copy-Item -LiteralPath (Join-Path $Project "app.py") -Destination (Join-Path $Stage "app\app.py")
New-Item -ItemType File -Force -Path (Join-Path $Stage "app\__init__.py") | Out-Null
Copy-Item -LiteralPath (Join-Path $Project "static") -Destination (Join-Path $Stage "app\static") -Recurse
Copy-Item -LiteralPath (Join-Path $Project "templates") -Destination (Join-Path $Stage "app\templates") -Recurse
Copy-Item -LiteralPath (Join-Path $Project "requirements.txt") -Destination (Join-Path $Stage "requirements.txt")

Copy-Item -LiteralPath (Join-Path $Project "portable\start.bat") -Destination (Join-Path $Stage "start.bat")
Copy-Item -LiteralPath (Join-Path $Project "portable\start.ps1") -Destination (Join-Path $Stage "start.ps1")
Copy-Item -LiteralPath (Join-Path $Project "portable\install.ps1") -Destination (Join-Path $Stage "install.ps1")
Copy-Item -LiteralPath (Join-Path $Project "portable\slim.ps1") -Destination (Join-Path $Stage "slim.ps1")
Copy-Item -LiteralPath (Join-Path $Project "portable\config.example.json") -Destination (Join-Path $Stage "config.example.json")
Copy-Item -LiteralPath (Join-Path $Project "portable\README-PORTABLE.md") -Destination (Join-Path $Stage "README.md")

New-Item -ItemType Directory -Force -Path (Join-Path $Stage "config"), (Join-Path $Stage "downloads"), (Join-Path $Stage "data"), (Join-Path $Stage "logs"), (Join-Path $Stage "tools"), (Join-Path $Stage "runtime") | Out-Null

if ($IncludePython) {
  $BundledPython = Join-Path $Project "..\tools\Python310"
  $BundledPython = (Resolve-Path -LiteralPath $BundledPython -ErrorAction SilentlyContinue)
  if ($BundledPython -eq $null) {
    throw "Bundled Python was not found. Expected ..\tools\Python310"
  }
  Copy-Item -LiteralPath $BundledPython.Path -Destination (Join-Path $Stage "runtime\python") -Recurse

  $BundledRealEsrgan = Join-Path $Project "..\tools\Real-ESRGAN"
  $BundledRealEsrgan = (Resolve-Path -LiteralPath $BundledRealEsrgan -ErrorAction SilentlyContinue)
  if ($BundledRealEsrgan -ne $null) {
    Copy-Item -LiteralPath $BundledRealEsrgan.Path -Destination (Join-Path $Stage "tools\Real-ESRGAN") -Recurse
  }
}

if ($Full) {
  $InstalledPortable = Join-Path $Dist "AudioVideoTool-Portable-Python"
  $InstalledVenv = Join-Path $InstalledPortable "runtime\venv"
  $InstalledMarker = Join-Path $InstalledPortable "runtime\install.ok"
  $InstalledRealEsrgan = Join-Path $InstalledPortable "tools\Real-ESRGAN"

  if (!(Test-Path -LiteralPath (Join-Path $InstalledVenv "Scripts\python.exe"))) {
    throw "Installed venv was not found. Run install.ps1 once in dist\AudioVideoTool-Portable-Python first."
  }
  if (!(Test-Path -LiteralPath $InstalledMarker)) {
    throw "Installed marker was not found. Run install.ps1 successfully before building Full."
  }
  if (Test-Path -LiteralPath (Join-Path $Stage "runtime\venv")) {
    Remove-Item -LiteralPath (Join-Path $Stage "runtime\venv") -Recurse -Force
  }
  Copy-Item -LiteralPath $InstalledVenv -Destination (Join-Path $Stage "runtime\venv") -Recurse
  Copy-Item -LiteralPath $InstalledMarker -Destination (Join-Path $Stage "runtime\install.ok")

  if (Test-Path -LiteralPath $InstalledRealEsrgan) {
    Remove-Item -LiteralPath (Join-Path $Stage "tools\Real-ESRGAN") -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $InstalledRealEsrgan -Destination (Join-Path $Stage "tools\Real-ESRGAN") -Recurse
  }
}

if ($IncludeFfmpeg) {
  $FfmpegBin = Resolve-Path -LiteralPath "D:\ffmpeg\bin" -ErrorAction SilentlyContinue
  if ($FfmpegBin -eq $null) {
    Write-Warning "FFmpeg bin was not found at D:\ffmpeg\bin. The package will rely on system FFmpeg."
  } else {
    $StageFfmpegBin = Join-Path $Stage "tools\ffmpeg\bin"
    New-Item -ItemType Directory -Force -Path $StageFfmpegBin | Out-Null
    foreach ($name in @("ffmpeg.exe", "ffprobe.exe")) {
      $source = Join-Path $FfmpegBin.Path $name
      if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $StageFfmpegBin $name) -Force
      }
    }
  }
}

if ($Slim) {
  powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Stage "slim.ps1") -Root $Stage
  if ($LASTEXITCODE -ne 0) {
    throw "Slim step failed."
  }
}

Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $Zip -Force
Write-Host "Generated: $Zip"

if ($MakeExe) {
  $SevenZip = "C:\Program Files\7-Zip\7z.exe"
  $SfxModule = "C:\Program Files\7-Zip\7z.sfx"
  if (!(Test-Path -LiteralPath $SevenZip) -or !(Test-Path -LiteralPath $SfxModule)) {
    throw "7-Zip was not found. Install 7-Zip, then rerun with -MakeExe."
  }
  $Archive7z = Join-Path $Dist "$PackageName.7z"
  $SfxConfig = Join-Path $Dist "$PackageName.sfx.txt"
  Remove-Item -LiteralPath $Archive7z -Force -ErrorAction SilentlyContinue
  Set-Content -LiteralPath $SfxConfig -Encoding UTF8 -Value @(
    ';!@Install@!UTF-8!',
    'Title="Audio Video Tool"',
    'InstallPath="%LocalAppData%\\AudioVideoTool-Full"',
    'RunProgram="start.bat"',
    'GUIMode="2"',
    ';!@InstallEnd@!'
  )
  Push-Location $Stage
  try {
    & $SevenZip a -t7z -mx=5 -mmt=on $Archive7z ".\*"
    if ($LASTEXITCODE -ne 0) {
      throw "7-Zip archive creation failed with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }
  $out = [System.IO.File]::Create($Exe)
  try {
    foreach ($part in @($SfxModule, $SfxConfig, $Archive7z)) {
      $bytes = [System.IO.File]::ReadAllBytes($part)
      $out.Write($bytes, 0, $bytes.Length)
    }
  } finally {
    $out.Close()
  }
  if (!(Test-Path -LiteralPath $Exe)) {
    throw "SFX EXE was not created."
  }
  Write-Host "Generated: $Exe"
}
