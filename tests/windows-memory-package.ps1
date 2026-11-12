#Requires -Version 5.1
param([Parameter(Mandatory = $true)][string]$PackageDirectory, [string]$RuntimeRoot = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
if ($RuntimeRoot) { $repoRoot = $RuntimeRoot }
. (Join-Path $repoRoot 'bootstrap-tools.ps1') -BootstrapUiLibraryMode
. (Join-Path $repoRoot 'windows/ai/memory-packages.ps1')
. (Join-Path $repoRoot 'windows/ai/host-instructions.ps1')
$sandbox = Join-Path $env:TEMP ('phasezero-memory-test-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
$env:USERPROFILE = Join-Path $sandbox 'user'
$env:HOME = $env:USERPROFILE
$env:LOCALAPPDATA = Join-Path $sandbox 'local'
$env:APPDATA = Join-Path $sandbox 'roaming'
$env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex'
$env:CLAUDE_CONFIG_DIR = Join-Path $env:USERPROFILE '.claude'
$env:AI_MEMORY_DATA_DIR = Join-Path $sandbox 'data'
[void][IO.Directory]::CreateDirectory($env:USERPROFILE)
$ruleFiles = @(Set-PhaseZeroHostInstructions)
if ($ruleFiles.Count -ne 2) { throw 'Global instructions missing' }
foreach ($file in $ruleFiles) {
    if (-not ([IO.File]::ReadAllText($file) -match '4 GiB')) { throw 'Host memory reserve missing' }
}
$installRoot = Get-BootstrapAiInstallRoot -InstallRoot ''
if (-not (Install-PhaseZeroMemoryCompanionPackage -PackageDirectory $PackageDirectory -InstallRoot $installRoot)) { throw 'Missing package' }
$metadata = Join-Path $PackageDirectory 'wikisync-package.json'
$original = [IO.File]::ReadAllBytes($metadata)
try {
    $bad = Get-Content $metadata -Raw | ConvertFrom-Json
    $bad.sha256 = '0' * 64
    $bad | ConvertTo-Json | Set-Content $metadata -Encoding UTF8
    $rejected = $false
    try { Install-PhaseZeroMemoryCompanionPackage -PackageDirectory $PackageDirectory -InstallRoot $installRoot | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Corrupted companion was accepted' }
} finally { [IO.File]::WriteAllBytes($metadata, $original) }
$catalog = Get-BootstrapAiToolCatalog
$result = Install-BootstrapAiMemoryViaRelease -CatalogEntry $catalog['ai-memory'] -InstallRoot $installRoot
if ($result.status -ne 'installed') { throw 'Native package not installed' }
$binary = Get-BootstrapAiMemoryExePath -InstallRoot $installRoot
& $binary --data-dir $env:AI_MEMORY_DATA_DIR init
if ($LASTEXITCODE) { throw 'Native init failed' }
$wiring = @(Invoke-BootstrapAiMemoryWiring -ExePath $binary -Agents @('codex','claude-code'))
if (@($wiring | Where-Object { $_.status -eq 'failed' }).Count) {
    $wiring | ConvertTo-Json -Depth 4 | Write-Output
    foreach ($failed in @($wiring | Where-Object { $_.status -eq 'failed' })) {
        $arguments = @($failed.command.Split(' ')) + @('--apply','--server-url','http://127.0.0.1:49374')
        $probe = Invoke-BootstrapAiNativeCommand -Exe $binary -Args $arguments
        # Disposable fixture only; never dump rendered config or bearer values.
        ($probe.stderr -split "`n" | Where-Object { $_ -match 'error:|Error:|unexpected|required|invalid' -and $_ -notmatch 'Bearer|token' }) | Write-Output
    }
    throw 'Native MCP/hook wiring failed'
}
& $binary --data-dir $env:AI_MEMORY_DATA_DIR backup --to (Join-Path $sandbox 'consistent.tar.gz')
if ($LASTEXITCODE) { throw 'Native backup failed' }
if (-not (Test-Path (Join-Path $env:CODEX_HOME 'config.toml'))) { throw 'Codex config missing' }
Write-Output 'PASS: native Windows 5.1 init, MCP/hooks for both clients, backup and rejected corrupt companion.'
$ui = Start-Process powershell.exe -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $repoRoot 'windows/ai/prepare-host.ps1') + '"') -PassThru
try {
    Start-Sleep -Seconds 8
    $ui.Refresh()
    if ($ui.HasExited -or $ui.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Native preparation window did not open' }
    Write-Output 'PASS: native WPF preparation window opened.'
    $null = $ui.CloseMainWindow()
    $null = $ui.WaitForExit(5000)
} finally { if (-not $ui.HasExited) { Stop-Process -Id $ui.Id -Force } }
