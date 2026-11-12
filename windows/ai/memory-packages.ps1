#Requires -Version 5.1
# Verified, local packages for the existing memory lifecycle; no separate store.
function Install-PhaseZeroMemoryCompanionPackage {
    param([string]$PackageDirectory, [string]$InstallRoot)
    if ([string]::IsNullOrWhiteSpace($PackageDirectory)) { return $false }
    $metadata = Join-Path $PackageDirectory 'wikisync-package.json'
    if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) { throw 'Pacote wikisync sem manifesto.' }
    $pins = Get-Content (Join-Path $repoRoot 'packaging/ai-memory/pins.json') -Raw | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath $metadata -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.version -ne $pins.version -or $manifest.sourceSha256 -ne $pins.source.sha256) {
        throw 'Pacote wikisync nao corresponde a fonte fixada pelo PhaseZero.'
    }
    $source = Join-Path $PackageDirectory 'ai-memory-wikisync.exe'
    if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Link wikisync recusado.' }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.sha256) {
        throw 'Checksum wikisync invalido.'
    }
    $target = Join-Path (Get-BootstrapAiMemoryInstallDir -InstallRoot $InstallRoot) 'wikisync/bin'
    [void][IO.Directory]::CreateDirectory($target)
    Copy-Item -LiteralPath $source -Destination (Join-Path $target 'ai-memory-wikisync.exe') -Force
    return $true
}
