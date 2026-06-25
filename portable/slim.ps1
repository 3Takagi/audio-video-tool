param(
  [string]$Root = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [switch]$Aggressive
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path -LiteralPath $Root).Path
$Venv = Join-Path $Root "runtime\venv"
$Python = Join-Path $Root "runtime\python"

function Get-TreeSizeMB($Path) {
  if (!(Test-Path -LiteralPath $Path)) {
    return 0
  }
  $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  return [math]::Round(($sum / 1MB), 2)
}

function Remove-IfExists($Path) {
  if (Test-Path -LiteralPath $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "Slim target: $Root"
$Before = Get-TreeSizeMB $Root

$dirs = @()
if (Test-Path -LiteralPath $Venv) {
  $site = Join-Path $Venv "Lib\site-packages"
  $dirs += Get-ChildItem -LiteralPath $Venv -Recurse -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -eq "__pycache__" -or
      $_.FullName -like "*\.pytest_cache*"
    }

  Remove-IfExists (Join-Path $site "torch\include")
  Remove-IfExists (Join-Path $site "torch\share")
  Remove-IfExists (Join-Path $site "torch\test")
  Remove-IfExists (Join-Path $site "torch\bin\nvfuser_tests.exe")
  Remove-IfExists (Join-Path $site "numba\tests")
  Remove-IfExists (Join-Path $site "skimage\data")
  Remove-IfExists (Join-Path $site "matplotlib\mpl-data\sample_data")

  Get-ChildItem -LiteralPath $site -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @(".pyc", ".pyo") } |
    Remove-Item -Force -ErrorAction SilentlyContinue
  if ($Aggressive) {
    Get-ChildItem -LiteralPath (Join-Path $site "torch\lib") -File -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Extension -eq ".lib" } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

foreach ($dir in $dirs) {
  Remove-IfExists $dir.FullName
}

if (Test-Path -LiteralPath $Python) {
  Remove-IfExists (Join-Path $Python "Doc")
  Remove-IfExists (Join-Path $Python "Lib\test")
  Remove-IfExists (Join-Path $Python "Lib\idlelib")
  Remove-IfExists (Join-Path $Python "Lib\tkinter")
  Remove-IfExists (Join-Path $Python "tcl")
  Get-ChildItem -LiteralPath $Python -Recurse -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq "__pycache__" } |
    ForEach-Object { Remove-IfExists $_.FullName }
  Get-ChildItem -LiteralPath $Python -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @(".pyc", ".pyo") } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

$After = Get-TreeSizeMB $Root
$Saved = [math]::Round(($Before - $After), 2)
Write-Host "Before: $Before MB"
Write-Host "After:  $After MB"
Write-Host "Saved:  $Saved MB"
