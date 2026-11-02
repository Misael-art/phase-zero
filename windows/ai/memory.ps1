#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('install','repair','install-sync')][string]$Action = 'repair', [string]$InstallRoot = '')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'bootstrap-tools.ps1')

if ($Action -eq 'install-sync') {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) { throw 'Rust toolchain required for the official ai-memory-wikisync companion.' }
    $pins = Get-Content (Join-Path $repoRoot 'packaging/ai-memory/pins.json') -Raw | ConvertFrom-Json
    $work = Join-Path ([IO.Path]::GetTempPath()) ('phasezero-memory-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $archive = Join-Path $work 'source.tar.gz'
        Invoke-WebRequest -Uri $pins.source.url -OutFile $archive -UseBasicParsing
        if ((Get-Item $archive).Length -gt 70000000) { throw 'Download exceeds manual-download budget.' }
        if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pins.source.sha256) { throw 'Companion source checksum mismatch.' }
        & tar.exe -xzf $archive -C $work ('ai-memory-' + $pins.version + '/companions/ai-memory-wikisync')
        if ($LASTEXITCODE -ne 0) { throw 'Companion extraction failed.' }
        $previousJobs = $env:CARGO_BUILD_JOBS
        try {
            $env:CARGO_BUILD_JOBS = '1'
            $companionRoot = Join-Path (Get-BootstrapAiMemoryInstallDir -InstallRoot (Get-BootstrapAiInstallRoot -InstallRoot $InstallRoot)) 'wikisync'
            & $cargo.Source install --locked --path (Join-Path $work ('ai-memory-' + $pins.version + '/companions/ai-memory-wikisync')) --root $companionRoot --force
            if ($LASTEXITCODE -ne 0) { throw 'Companion build failed.' }
        } finally { $env:CARGO_BUILD_JOBS = $previousJobs }
    } finally { Remove-Item -LiteralPath $work -Recurse -Force }
    exit 0
}

$catalog = Get-BootstrapAiToolCatalog
$installRoot = Get-BootstrapAiInstallRoot -InstallRoot $InstallRoot
$existing = Get-BootstrapAiMemoryExePath -InstallRoot $installRoot
$dataDir = Get-BootstrapAiMemoryDataDir
$backup = ''
$pins = Get-Content (Join-Path $repoRoot 'packaging/ai-memory/pins.json') -Raw | ConvertFrom-Json
$needsInstall = $Action -eq 'install' -or -not $existing
if ($existing) {
    $versionText = & $existing --version
    if ($versionText -match '(\d+\.\d+\.\d+)') {
        if ([version]$matches[1] -gt [version]$pins.version) { throw 'Newer memory installation preserved; downgrade requires migration review.' }
        $needsInstall = [version]$matches[1] -lt [version]$pins.version
    }
    $backupRoot = Join-Path $env:LOCALAPPDATA ('PhaseZero/ai-portability/upgrade-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backup = Join-Path $backupRoot 'before.tar.gz'
    & $existing --data-dir $dataDir backup --to $backup
    if ($LASTEXITCODE -ne 0) { throw 'Pre-upgrade snapshot failed; memory remains unchanged.' }
    Copy-Item -LiteralPath $existing -Destination (Join-Path $backupRoot 'ai-memory-before.exe')
    # Stop only processes of this exact managed executable; never all ai-memory processes.
    $managedDir = [IO.Path]::GetFullPath((Get-BootstrapAiMemoryInstallDir -InstallRoot $installRoot))
    if (-not [IO.Path]::GetFullPath($existing).StartsWith($managedDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'External ai-memory installation preserved; migrate through its package manager.'
    }
    Get-CimInstance Win32_Process -Filter "Name='ai-memory.exe'" | Where-Object { $_.ExecutablePath -eq $existing } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -ErrorAction Stop
    }
}
try {
    if ($needsInstall) {
        $installed = Install-BootstrapAiMemoryViaRelease -CatalogEntry $catalog['ai-memory'] -InstallRoot $installRoot
        if ($installed.status -notin @('installed','present')) { throw 'Native memory installation did not complete.' }
    }
    $binary = Get-BootstrapAiMemoryExePath -InstallRoot $installRoot
    & $binary --data-dir $dataDir init
    if ($LASTEXITCODE -ne 0) { throw 'Memory migration failed.' }
    $configured = Set-BootstrapAiMemoryConfig -InstallRoot $installRoot -ManagedLifecycle
    if ($configured.serverTask.status -notin @('registered','created','configured')) { throw 'Memory server startup task failed.' }
    Start-ScheduledTask -TaskName 'BootstrapTools-AiMemoryServer' -ErrorAction Stop
    if (-not (Test-Path (Join-Path (Get-BootstrapAiMemoryInstallDir -InstallRoot $installRoot) 'wikisync/bin/ai-memory-wikisync.exe'))) {
        & (Join-Path $PSScriptRoot 'memory.ps1') -Action install-sync -InstallRoot $installRoot
        if ($LASTEXITCODE -ne 0) { throw 'Memory sync companion unavailable.' }
    }
} catch {
    if ($backup) {
        $binary = Get-BootstrapAiMemoryExePath -InstallRoot $installRoot
        & $binary --data-dir $dataDir restore --from $backup --force
        if ($LASTEXITCODE -ne 0) { throw "Rollback needs operator recovery from $backup" }
        Copy-Item -LiteralPath (Join-Path (Split-Path $backup) 'ai-memory-before.exe') -Destination $existing -Force
        Start-ScheduledTask -TaskName 'BootstrapTools-AiMemoryServer' -ErrorAction SilentlyContinue
    }
    throw
}
