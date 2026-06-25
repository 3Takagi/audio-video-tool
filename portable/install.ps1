$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Root "logs"
$RuntimeDir = Join-Path $Root "runtime"
$LocalPythonDir = Join-Path $RuntimeDir "python"
$VenvDir = Join-Path $RuntimeDir "venv"
$InstallMarker = Join-Path $RuntimeDir "install.ok"
$ToolsDir = Join-Path $Root "tools"
$RealEsrganDir = Join-Path $ToolsDir "Real-ESRGAN"
$WeightsDir = Join-Path $RealEsrganDir "weights"
$ConfigDir = Join-Path $Root "config"
$ConfigFile = Join-Path $ConfigDir "config.json"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir "install.log") -Append | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Remove-Item -LiteralPath $InstallMarker -Force -ErrorAction SilentlyContinue

function Write-Step($Text) {
  Write-Host ""
  Write-Host "==> $Text" -ForegroundColor Cyan
}

function Test-Python($PythonExe) {
  if (!$PythonExe) {
    return $false
  }
  if (!(Test-Path -LiteralPath $PythonExe)) {
    return $false
  }
  if ($PythonExe -like "*\WindowsApps\python.exe") {
    return $false
  }
  try {
    & $PythonExe -c "import sys; raise SystemExit(0 if sys.version_info[:2] in [(3,10),(3,11)] else 1)" 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Find-AncestorPython {
  $current = (Resolve-Path -LiteralPath $Root).Path
  while ($current) {
    $candidates = @(
      (Join-Path $current "tools\Python310\python.exe"),
      (Join-Path $current "tools\Python311\python.exe"),
      (Join-Path $current "tools\Python312\python.exe")
    )
    foreach ($candidate in $candidates) {
      if (Test-Python $candidate) {
        return $candidate
      }
    }
    $parent = Split-Path -Parent $current
    if (!$parent -or $parent -eq $current) {
      break
    }
    $current = $parent
  }
  return $null
}

function Find-Python {
  $localPython = Join-Path $LocalPythonDir "python.exe"
  if (Test-Python $localPython) {
    return $localPython
  }

  $ancestorPython = Find-AncestorPython
  if ($ancestorPython -ne $null) {
    return $ancestorPython
  }

  $commonPaths = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python310\python.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
    "C:\Program Files\Python310\python.exe",
    "C:\Program Files\Python311\python.exe",
    "C:\Program Files\Python312\python.exe"
  )
  foreach ($candidate in $commonPaths) {
    if (Test-Python $candidate) {
      return $candidate
    }
  }

  $commands = @(
    @{ File = "py"; Args = @("-3.10", "-c", "import sys; print(sys.executable)") },
    @{ File = "py"; Args = @("-3.11", "-c", "import sys; print(sys.executable)") },
    @{ File = "py"; Args = @("-3.12", "-c", "import sys; print(sys.executable)") },
    @{ File = "python"; Args = @("-c", "import sys; print(sys.executable)") }
  )
  foreach ($cmd in $commands) {
    try {
      $result = & $cmd.File @($cmd.Args) 2>$null
      if ($LASTEXITCODE -eq 0 -and $result -and (Test-Python $result.Trim())) {
        return $result.Trim()
      }
    } catch {}
  }
  return $null
}

function Install-LocalPython {
  Write-Step "Download local Python runtime"
  New-Item -ItemType Directory -Force -Path $LocalPythonDir | Out-Null
  $installer = Join-Path $RuntimeDir "python-3.10.11-amd64.exe"
  Download-File "https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe" $installer

  Write-Step "Install local Python runtime"
  $args = @(
    "/quiet",
    "InstallAllUsers=0",
    "PrependPath=0",
    "Include_launcher=0",
    "Include_test=0",
    "Include_pip=1",
    "Include_venv=1",
    "TargetDir=$LocalPythonDir"
  )
  $process = Start-Process -FilePath $installer -ArgumentList $args -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    throw "Python installer failed with exit code $($process.ExitCode)."
  }
  $localPython = Join-Path $LocalPythonDir "python.exe"
  if (!(Test-Path -LiteralPath $localPython)) {
    throw "Local Python install finished but python.exe was not found."
  }
  return $localPython
}

function Download-File($Url, $OutFile) {
  if (Test-Path -LiteralPath $OutFile) {
    return
  }
  $partial = "$OutFile.partial"
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
      Write-Host "Downloading $Url (attempt $attempt/3)"
      Invoke-WebRequest -Uri $Url -OutFile $partial
      Move-Item -LiteralPath $partial -Destination $OutFile -Force
      return
    } catch {
      Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
      if ($attempt -eq 3) {
        throw
      }
      Start-Sleep -Seconds (3 * $attempt)
    }
  }
}

function Run-Native($File, $Arguments) {
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code $LASTEXITCODE`: $File $($Arguments -join ' ')"
  }
}

Write-Step "Prepare config"
if (!(Test-Path -LiteralPath $ConfigFile)) {
  Copy-Item -LiteralPath (Join-Path $Root "config.example.json") -Destination $ConfigFile
}

Write-Step "Create Python virtual environment"
if (!(Test-Path -LiteralPath (Join-Path $VenvDir "Scripts\python.exe"))) {
  $Python = Find-Python
  if ($Python -eq $null) {
    $Python = Install-LocalPython
  }
  Run-Native $Python @("-m", "venv", $VenvDir)
}
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"

Write-Step "Install web and downloader dependencies"
Run-Native $VenvPython @("-m", "pip", "install", "--upgrade", "pip<26", "setuptools<82", "wheel")
Run-Native $VenvPython @("-m", "pip", "install", "-r", (Join-Path $Root "requirements.txt"))

Write-Step "Install PyTorch and Real-ESRGAN dependencies"
Run-Native $VenvPython @("-m", "pip", "install", "torch==2.1.2", "torchvision==0.16.2", "torchaudio==2.1.2", "--index-url", "https://download.pytorch.org/whl/cu121")
Run-Native $VenvPython @("-m", "pip", "install", "numpy==1.26.4", "opencv-python", "pillow", "tqdm", "addict", "future", "lmdb", "pyyaml", "requests", "scipy", "scikit-image", "filterpy", "numba", "yapf")
Run-Native $VenvPython @("-m", "pip", "install", "--no-build-isolation", "--no-deps", "basicsr==1.4.2", "facexlib==0.3.0", "gfpgan==1.3.8")

Write-Step "Download Real-ESRGAN source"
if (!(Test-Path -LiteralPath (Join-Path $RealEsrganDir "inference_realesrgan.py"))) {
  $Zip = Join-Path $ToolsDir "Real-ESRGAN.zip"
  Download-File "https://github.com/xinntao/Real-ESRGAN/archive/refs/heads/master.zip" $Zip
  $Temp = Join-Path $ToolsDir "Real-ESRGAN-src"
  Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive -LiteralPath $Zip -DestinationPath $Temp -Force
  $Extracted = Get-ChildItem -LiteralPath $Temp -Directory | Select-Object -First 1
  if ($Extracted -eq $null) {
    throw "Real-ESRGAN source extraction failed."
  }
  Remove-Item -LiteralPath $RealEsrganDir -Recurse -Force -ErrorAction SilentlyContinue
  Move-Item -LiteralPath $Extracted.FullName -Destination $RealEsrganDir
  Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step "Install Real-ESRGAN package"
Run-Native $VenvPython @("-m", "pip", "install", "--no-build-isolation", "--no-deps", "-e", $RealEsrganDir)

Write-Step "Download Real-ESRGAN model weights"
New-Item -ItemType Directory -Force -Path $WeightsDir | Out-Null
Download-File "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth" (Join-Path $WeightsDir "RealESRGAN_x4plus.pth")
Download-File "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth" (Join-Path $WeightsDir "RealESRGAN_x4plus_anime_6B.pth")
Download-File "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth" (Join-Path $WeightsDir "realesr-animevideov3.pth")

Write-Step "Check FFmpeg"
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ffmpeg -eq $null) {
  Write-Warning "FFmpeg was not found. Video merging may fail. Install FFmpeg and add it to PATH."
  Write-Warning "Recommended command: winget install Gyan.FFmpeg"
} else {
  Write-Host "FFmpeg: $($ffmpeg.Source)"
}

Write-Step "Slim runtime"
$SlimScript = Join-Path $Root "slim.ps1"
if (Test-Path -LiteralPath $SlimScript) {
  Run-Native "powershell" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SlimScript, "-Root", $Root)
}

Write-Step "Install complete"
Write-Host "Run start.bat to open the web UI."
Set-Content -LiteralPath $InstallMarker -Value "ok" -Encoding ASCII
Stop-Transcript | Out-Null
