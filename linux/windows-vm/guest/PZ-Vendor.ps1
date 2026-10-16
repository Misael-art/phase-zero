# PhaseZero Windows VM - vendored installer verification.
#
# The bundle used to install whatever a download returned, so a mirror serving
# different bytes than the manifest described went straight into msiexec. The
# host verifies before shipping; this is the same contract on the guest side:
# the manifest's SHA-256 decides whether a file is installable, and nothing is
# installed when it does not.
#
# Dot-source this, then call Get-PZVerifiedMsi. It holds no URLs of its own --
# the manifest the host generated is the only source, and a manifest still
# holding an unresolved template is a host bug this layer refuses to guess at.

function Get-PZVendorManifest {
    param(
        [Parameter(Mandatory = $true)][string]$BundlePath
    )
    $path = Join-Path $BundlePath 'vendor.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "No vendor manifest at $path. The bundle must ship the manifest the host resolved."
    }
    $json = Get-Content -LiteralPath $path -Raw
    $parsed = $json | ConvertFrom-Json
    if (-not ($parsed.PSObject.Properties.Name -contains 'components')) {
        throw "Vendor manifest at $path describes no components."
    }
    return $parsed
}

function Test-PZVendorHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        # Not Mandatory: an absent or blank hash is exactly the case this rejects,
        # and the binder would refuse to pass an empty string through otherwise.
        [string]$Sha256
    )
    # A field that is not a SHA-256 cannot vouch for anything; treat it as no
    # match rather than as permission.
    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $computed = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ($computed.ToLowerInvariant() -eq $Sha256.ToLowerInvariant())
}

function Get-PZVerifiedMsi {
    param(
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [Parameter(Mandatory = $true)][string]$Entry,
        [Parameter(Mandatory = $true)][string]$DownloadDir,
        [switch]$Offline
    )
    $manifest = Get-PZVendorManifest -BundlePath $BundlePath
    if (-not ($manifest.components.PSObject.Properties.Name -contains $Entry)) {
        throw "Vendor manifest has no entry for component '$Entry'."
    }
    $component = $manifest.components.$Entry

    $fileName = ''
    if ($component.PSObject.Properties.Name -contains 'file') { $fileName = [string]$component.file }
    if (-not $fileName) { throw "Vendor manifest entry '$Entry' names no file." }

    $sha = ''
    if ($component.PSObject.Properties.Name -contains 'sha256') { $sha = [string]$component.sha256 }

    $vendored = Join-Path $BundlePath $fileName
    if (Test-Path -LiteralPath $vendored) {
        if (Test-PZVendorHash -Path $vendored -Sha256 $sha) { return $vendored }
        throw "Vendored $fileName does not match the SHA-256 the manifest pins. Refusing to install it."
    }
    if ($Offline) {
        throw "$fileName is not vendored in the bundle and -Offline was passed."
    }

    $url = ''
    if ($component.PSObject.Properties.Name -contains 'url') { $url = [string]$component.url }
    if (-not $url) {
        throw "Vendor manifest entry '$Entry' has no url: the host shipped an unresolved template."
    }
    if ($sha -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Vendor manifest entry '$Entry' pins no usable SHA-256, so a download cannot be verified."
    }

    $null = New-Item -ItemType Directory -Force -Path $DownloadDir
    $target = Join-Path $DownloadDir $fileName
    Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
    if (-not (Test-PZVendorHash -Path $target -Sha256 $sha)) {
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        throw "Downloaded $fileName does not match the SHA-256 the manifest pins. It has been deleted."
    }
    return $target
}
