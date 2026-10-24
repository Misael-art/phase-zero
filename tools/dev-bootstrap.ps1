# Contributor tooling only. Product setup remains bootstrap-ui.ps1/bootstrap-tools.ps1.
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Install', 'Doctor', 'PythonPath')][string]$Action = 'Doctor',
    [ValidateSet('Core', 'Ui')][string]$Profile = 'Core',
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dataRoot = if ($env:PZ_DEV_HOME) { $env:PZ_DEV_HOME } else { Join-Path $env:LOCALAPPDATA 'PhaseZero\dev' }
$pointer = Join-Path $dataRoot ('venv-' + $Profile.ToLowerInvariant() + '.txt')
$requirements = Join-Path $root ('requirements\dev-' + $Profile.ToLowerInvariant() + '.txt')

function Get-SelectedVenv {
    if (-not (Test-Path -LiteralPath $pointer -PathType Leaf)) { return $null }
    $selected = (Get-Content -LiteralPath $pointer -Raw).Trim()
    if ($selected -and (Test-Path -LiteralPath (Join-Path $selected 'Scripts\python.exe'))) { return $selected }
    return $null
}
function Get-RealPython {
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        $found = & $launcher.Source -3.13 -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $found -and (Test-Path -LiteralPath $found)) { return $found }
    }
    $candidate = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($candidate -and $candidate.Source -notmatch '\\WindowsApps\\') {
        $found = & $candidate.Source -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $found -and (Test-Path -LiteralPath $found)) { return $found }
    }
    return $null
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User')
}
function Get-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    return $null
}
function Ensure-Winget {
    $winget = Get-Winget
    if ($winget) { return $winget }
    $bundle = Join-Path $dataRoot 'Microsoft.DesktopAppInstaller.msixbundle'
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    Write-Host 'App Installer absent; fetching Microsoft official package.'
    try {
        Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing
        Add-AppxPackage -Path $bundle
    } finally {
        Remove-Item -LiteralPath $bundle -ErrorAction SilentlyContinue
    }
    Refresh-Path
    $winget = Get-Winget
    if (-not $winget) { throw 'App Installer installed, but winget unavailable. Reopen terminal and retry.' }
    return $winget
}
function Install-WingetPackage([string]$winget, [string]$id) {
    & $winget install --exact --id $id --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "winget install failed: $id (exit $LASTEXITCODE)" }
    Refresh-Path
}

if ($Action -ne 'PythonPath') {
    Write-Host "PhaseZero dev: action=$Action profile=$Profile"
    Write-Host 'Packages: Git.Git, Python.Python.3.13 (if missing); Ui adds Pester 3.4.0 and PSScriptAnalyzer 1.25.0.'
    Write-Host "Python requirements: $requirements"
    Write-Host "Environment root: $dataRoot"
    Write-Host 'No PhaseZero service, VM, login, product package or boot mutation.'
}
if ($Action -eq 'Plan') { return }
if ($Action -eq 'PythonPath') {
    $selected = Get-SelectedVenv
    if (-not $selected) { throw 'No selected venv. Run Install first.' }
    Write-Output (Join-Path $selected 'Scripts\python.exe')
    return
}
if ($Action -eq 'Doctor') {
    $selected = Get-SelectedVenv
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    $python = Get-RealPython
    if (-not $git -or -not $python -or -not $selected) { throw 'Missing Git, real Python or dev venv. Run Install -Yes.' }
    $venvPython = Join-Path $selected 'Scripts\python.exe'
    & $venvPython -m pip check
    if ($LASTEXITCODE -ne 0) { throw 'venv dependencies inconsistent.' }
    & $venvPython -c 'import pytest, pytest_timeout, PIL, argon2'
    if ($LASTEXITCODE -ne 0) { throw 'Core Python dependencies missing.' }
    if ($Profile -eq 'Ui') {
        & $venvPython -c 'import importlib.metadata as m; assert m.version("PySide6") == "6.11.1"'
        if ($LASTEXITCODE -ne 0) { throw 'PySide6 missing.' }
        if (-not (Get-Module -ListAvailable -Name Pester) -or -not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
            throw 'Pester or PSScriptAnalyzer missing.'
        }
    }
    Write-Host 'ready: true'
    return
}
if (-not $Yes) { throw 'Install requires -Yes after reviewing Plan.' }
if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA unavailable; cannot isolate dev environment.' }
$os = Get-CimInstance Win32_OperatingSystem
if ([int64]$os.FreePhysicalMemory -lt 786432) {
    throw 'Insufficient available memory (<768 MiB); installation deferred.'
}
$driveRoot = [IO.Path]::GetPathRoot($dataRoot)
$minimumBytes = if ($Profile -eq 'Ui') { 3GB } else { 1GB }
if ([IO.DriveInfo]::new($driveRoot).AvailableFreeSpace -lt $minimumBytes) {
    throw "Insufficient free disk for $Profile profile."
}
$winget = $null
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue) -or -not (Get-RealPython)) {
    $winget = Ensure-Winget
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { Install-WingetPackage $winget 'Git.Git' }
    if (-not (Get-RealPython)) { Install-WingetPackage $winget 'Python.Python.3.13' }
}
$python = Get-RealPython
if (-not $python) { throw 'Real Python not on PATH after installation. Reopen terminal; rerun Install.' }
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'Git not on PATH after installation. Reopen terminal; rerun Install.' }
if ($Profile -eq 'Ui') {
    if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [Version]'3.4.0' })) {
        Install-Module Pester -RequiredVersion 3.4.0 -Force -Scope CurrentUser -SkipPublisherCheck
    }
    if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object { $_.Version -eq [Version]'1.25.0' })) {
        Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force -Scope CurrentUser
    }
}
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
$slotA = Join-Path $dataRoot ('venv-' + $Profile.ToLowerInvariant() + '-a')
$slotB = Join-Path $dataRoot ('venv-' + $Profile.ToLowerInvariant() + '-b')
$selected = Get-SelectedVenv
$stage = if ($selected -eq $slotA) { $slotB } else { $slotA }
if ($stage -eq $selected) { throw 'Refusing to overwrite active venv.' }
# Two fixed slots bound disk usage; only the inactive slot is replaced.
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
try {
    & $python -m venv $stage
    if ($LASTEXITCODE -ne 0) { throw 'venv creation failed.' }
    $venvPython = Join-Path $stage 'Scripts\python.exe'
    & $venvPython -m pip install --disable-pip-version-check -r $requirements
    if ($LASTEXITCODE -ne 0) { throw 'pip install failed.' }
    & $venvPython -m pip check
    if ($LASTEXITCODE -ne 0) { throw 'pip check failed.' }
    & $venvPython -c 'import pytest, pytest_timeout, PIL, argon2'
    if ($LASTEXITCODE -ne 0) { throw 'Core import check failed.' }
    if ($Profile -eq 'Ui') {
        & $venvPython -c 'import importlib.metadata as m; assert m.version("PySide6") == "6.11.1"'
        if ($LASTEXITCODE -ne 0) { throw 'PySide6 import check failed.' }
    }
    $newPointer = "$pointer.new"
    [IO.File]::WriteAllText($newPointer, $stage + [Environment]::NewLine)
    if (Test-Path -LiteralPath $pointer) {
        [IO.File]::Replace($newPointer, $pointer, $null)
    } else {
        Move-Item -LiteralPath $newPointer -Destination $pointer
    }
    Write-Host "ready: true; Python: $venvPython"
} catch {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    throw
}
