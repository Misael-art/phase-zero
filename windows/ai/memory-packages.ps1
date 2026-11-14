#Requires -Version 5.1
# Verified, local packages for the existing memory lifecycle; no separate store.
function Install-PhaseZeroMemoryModelCache {
    param([string]$PackageDirectory, [string]$DataDirectory)
    if (-not $PackageDirectory) { return }
    $pins = Get-Content (Join-Path $repoRoot 'packaging/ai-memory/pins.json') -Raw | ConvertFrom-Json
    $relative = 'models/' + $pins.localModel.directory
    $sourceRoot = Join-Path $PackageDirectory $relative
    # The native default fetches ~87 MiB. Prepared hosts must reuse the verified cache.
    foreach ($item in $pins.localModel.files.PSObject.Properties) {
        $source = Join-Path $sourceRoot $item.Name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Modelo local ausente no pacote; prepare o cache verificado antes de iniciar o servidor.' }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.Value) { throw 'Checksum do modelo local invalido.' }
    }
    $destination = Join-Path $DataDirectory $relative
    [void][IO.Directory]::CreateDirectory($destination)
    foreach ($item in $pins.localModel.files.PSObject.Properties) {
        $target = Join-Path $destination $item.Name
        if (Test-Path -LiteralPath $target) {
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $item.Value) { throw 'Cache existente divergente preservado; revise a instalacao.' }
        } else { Copy-Item -LiteralPath (Join-Path $sourceRoot $item.Name) -Destination $target }
    }
}

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
