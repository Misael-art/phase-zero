[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester BeforeAll variables are consumed by nested It scriptblocks.')]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$vendorLibPath = Join-Path $repoRoot 'linux/windows-vm/guest/PZ-Vendor.ps1'
$installerPath = Join-Path $repoRoot 'linux/windows-vm/guest/Install-VirtioFS.ps1'
. $vendorLibPath

# Test-only fixture: a provisioning bundle holding a manifest and one file whose
# bytes the caller chooses. Mirrors the layout the host generates -- manifest and
# MSIs side by side in the bundle root -- minus the network.
function New-VendorBundleFixture {
    param(
        [string]$Root,
        [string]$File = 'sample.msi',
        [string]$Body = 'sample installer bytes',
        [string]$Sha = '',
        [string]$Url = 'https://fixtures.invalid/sample.msi',
        [bool]$IncludeFile = $true
    )
    $null = New-Item -ItemType Directory -Force -Path $Root
    if ($IncludeFile) {
        $payloadPath = Join-Path $Root $File
        Set-Content -LiteralPath $payloadPath -Value $Body -Encoding ASCII -NoNewline
        if (-not $Sha) {
            $Sha = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $entry = @{ file = $File; sha256 = $Sha; url = $Url }
    $manifest = @{ components = @{ sample = $entry } } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath (Join-Path $Root 'vendor.json') -Value $manifest -Encoding ASCII
    return $Root
}

Describe 'Windows VM guest bundle vendor verification' {
    It 'parses the vendor library and the installer without errors' {
        foreach ($path in @($vendorLibPath, $installerPath)) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $path, [ref]$tokens, [ref]$errors)
            if ($errors -and $errors.Count -gt 0) {
                throw (($errors | ForEach-Object Message) -join '; ')
            }
        }
    }

    It 'leaves every download to the verified helper' {
        $source = Get-Content -LiteralPath $installerPath -Raw
        if ($source -match 'Invoke-WebRequest') { throw 'installer downloads without verifying' }
        if ($source -match 'https?://') { throw 'installer carries a URL of its own' }
        (@([regex]::Matches($source, 'Get-PZVerifiedMsi')).Count) | Should Be 3
    }

    Context 'Test-PZVendorHash' {
        BeforeAll {
            $hashRoot = Join-Path $TestDrive 'hashes'
            $null = New-Item -ItemType Directory -Force -Path $hashRoot
            $goodPath = Join-Path $hashRoot 'good.bin'
            Set-Content -LiteralPath $goodPath -Value 'pinned bytes' -Encoding ASCII -NoNewline
            $goodSha = (Get-FileHash -LiteralPath $goodPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        It 'accepts the bytes the manifest describes' {
            Test-PZVendorHash -Path $goodPath -Sha256 $goodSha | Should Be $true
        }

        It 'rejects an uppercase hash the same way it accepts a lowercase one' {
            Test-PZVendorHash -Path $goodPath -Sha256 $goodSha.ToUpperInvariant() | Should Be $true
        }

        It 'rejects different bytes' {
            $otherPath = Join-Path $hashRoot 'other.bin'
            Set-Content -LiteralPath $otherPath -Value 'different bytes' -Encoding ASCII -NoNewline
            Test-PZVendorHash -Path $otherPath -Sha256 $goodSha | Should Be $false
        }

        It 'rejects a hash that is not a SHA-256 instead of trusting the field' {
            Test-PZVendorHash -Path $goodPath -Sha256 'fafd93cb' | Should Be $false
            Test-PZVendorHash -Path $goodPath -Sha256 '' | Should Be $false
        }

        It 'reports no match for a file that is not there' {
            Test-PZVendorHash -Path (Join-Path $hashRoot 'absent.bin') -Sha256 $goodSha | Should Be $false
        }
    }

    Context 'Get-PZVerifiedMsi' {
        It 'hands over the vendored file only while it matches its hash' {
            $root = Join-Path $TestDrive 'ok'
            $vendorDir = New-VendorBundleFixture -Root $root
            $expected = Join-Path $vendorDir 'sample.msi'
            Get-PZVerifiedMsi -BundlePath $root -Entry 'sample' -DownloadDir $root | Should Be $expected
        }

        It 'refuses a vendored file whose bytes are not the pinned ones' {
            $root = Join-Path $TestDrive 'corrupt'
            $vendorDir = New-VendorBundleFixture -Root $root
            Set-Content -LiteralPath (Join-Path $vendorDir 'sample.msi') -Value 'tampered' -Encoding ASCII -NoNewline
            { Get-PZVerifiedMsi -BundlePath $root -Entry 'sample' -DownloadDir $root } | Should Throw 'SHA-256'
        }

        It 'refuses offline with nothing vendored rather than installing nothing' {
            $root = Join-Path $TestDrive 'offline'
            $null = New-VendorBundleFixture -Root $root -IncludeFile $false
            { Get-PZVerifiedMsi -BundlePath $root -Entry 'sample' -DownloadDir $root -Offline } | Should Throw 'not vendored'
        }

        It 'refuses an entry with no URL, which is an unrendered host template' {
            $root = Join-Path $TestDrive 'template'
            $null = New-VendorBundleFixture -Root $root -Url '' -IncludeFile $false
            { Get-PZVerifiedMsi -BundlePath $root -Entry 'sample' -DownloadDir $root } | Should Throw 'no url'
        }

        It 'refuses a component the manifest does not describe' {
            $root = Join-Path $TestDrive 'unknown'
            $null = New-VendorBundleFixture -Root $root
            { Get-PZVerifiedMsi -BundlePath $root -Entry 'other' -DownloadDir $root } | Should Throw 'manifest'
        }

        It 'refuses a bundle with no manifest at all' {
            $root = Join-Path $TestDrive 'bare'
            $null = New-Item -ItemType Directory -Force -Path $root
            { Get-PZVerifiedMsi -BundlePath $root -Entry 'sample' -DownloadDir $root } | Should Throw 'manifest'
        }
    }
}
