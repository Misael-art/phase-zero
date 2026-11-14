# Pure filesystem/adapter fixtures. No real installer, client, network or service.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'bootstrap-tools.ps1') -BootstrapUiLibraryMode -RotateSecretsSchedule none
. (Join-Path $repoRoot 'windows/ai/cached-apps.ps1')
Set-StrictMode -Version 2
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('phasezero-cached-apps-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'cache/packages'))
$env:USERPROFILE = Join-Path $fixture 'user'
$env:HOME = $env:USERPROFILE
$env:LOCALAPPDATA = Join-Path $fixture 'local'
$env:APPDATA = Join-Path $fixture 'roaming'
$env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex'
$env:CLAUDE_CONFIG_DIR = Join-Path $env:USERPROFILE '.claude'
$script:Checks = 0; $script:NativeCalls = 0; $script:AppxCalls = 0; $script:RuntimeState = 'satisfied'
function Confirm-Fixture([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('FAIL: ' + $Message) }; $script:Checks++ }
function Invoke-RejectedFixture([scriptblock]$Action, [string]$Message) { $rejected = $false; try { & $Action | Out-Null } catch { $rejected = $true }; Confirm-Fixture $rejected $Message }
function Get-PhaseZeroDependencyTarget { [CmdletBinding()]param(); return @{ windowsId = 'fixture-windows'; caller = 'fixture-user'; boot = 'fixture-boot'; elevated = $true; systemDrive = [IO.Path]::GetPathRoot($repoRoot) } }
Set-Item Function:Get-PhaseZeroDependencyDefinition -Value { [CmdletBinding()]param(); return @{ 'vcpp-redist' = @{ Name = 'vcpp-redist' } } }
function Get-PhaseZeroDependencyStatus { [CmdletBinding()]param($Definition, $Requirements); Confirm-Fixture ($Definition.Name -eq 'vcpp-redist' -and $Requirements.Count -eq 0) 'Only declared runtime prerequisite queried'; return @{ status = $script:RuntimeState } }
$nativeBudget = ${function:Invoke-PhaseZeroCachedBudget}
function Invoke-PhaseZeroCachedBudget { [CmdletBinding()]param([string]$InstallRoot, [long]$OutputBytes); Confirm-Fixture ($InstallRoot.StartsWith($fixture) -and $OutputBytes -ge 0 -and $OutputBytes -le 2GB) 'Fixture budget never targets real app data' }
Set-Item Function:Ensure-PathUserContainsFirst -Value { [CmdletBinding()]param([string]$Dir); $script:FixturePath = $Dir }
Set-Item Function:Invoke-BootstrapAiNativeCommand -Value {
    [CmdletBinding()]param([string]$Exe, [Alias('Args')][string[]]$ArgumentList, [int]$TimeoutMs)
    $script:NativeCalls++
    throw ('Fixture blocked client execution: ' + $Exe + ' ' + ($ArgumentList -join ' ') + ' timeout=' + $TimeoutMs)
}

Set-Item Function:Get-AuthenticodeSignature -Value {
    [CmdletBinding()]param([string]$LiteralPath)
    $certificate = [pscustomobject]@{ Subject = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' }
    $certificate | Add-Member ScriptMethod GetNameInfo { param($NameType, $ForIssuer); if ([string]$NameType -eq 'SimpleName' -and -not $ForIssuer) { return 'Anthropic, PBC' }; return '' }
    return @{ Status = $(if ($LiteralPath.EndsWith('.msix')) { 'Valid' } else { 'NotSigned' }); SignerCertificate = $certificate }
}
function Add-AppxPackage {
    [CmdletBinding(SupportsShouldProcess = $true)]param([string]$Path, [switch]$RegisterByFamilyName, [string]$MainPackage)
    if ($PSCmdlet.ShouldProcess($Path, 'Fixture registration only')) {
        $script:AppxCalls++
        if ($RegisterByFamilyName) {
            Confirm-Fixture ($MainPackage -ceq 'OpenAI.Codex_2p2nqsd0c76g0' -and $script:ProvisionCalls -eq 1) 'OpenAI registration follows licensed provisioning'
            $script:FixtureAppx = @{ Name = 'OpenAI.Codex'; Version = '26.1111.2228.0'; Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'; Status = 'Ok' }
        } else { $script:FixtureAppx = @{ Name = 'Claude'; Version = '3.6556.2.0'; Publisher = 'CN=Anthropic Fixture'; Status = 'Ok' } }
    }
}
function Add-AppxProvisionedPackage {
    [CmdletBinding(SupportsShouldProcess = $true)]param([switch]$Online, [string]$PackagePath, [string]$LicensePath, [string]$Regions)
    if ($PSCmdlet.ShouldProcess($PackagePath, 'Fixture licensing only')) {
        Confirm-Fixture ($Online -and $Regions -eq 'all' -and [IO.File]::Exists($LicensePath)) 'Public offline license reaches provisioning without SkipLicense'
        $script:ProvisionCalls++
    }
}
function Get-AppxPackage { [CmdletBinding()]param([string]$Name); if ($script:FixtureAppx -and $Name -ceq $script:FixtureAppx.Name) { return $script:FixtureAppx } }
$script:ProvisionCalls = 0
$script:FixtureAppx = $null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$cache = Join-Path $fixture 'cache'
function New-FixtureArchive {
    [CmdletBinding(SupportsShouldProcess = $true)]param([hashtable]$Contents, [string]$Name)
    $path = Join-Path $fixture $Name
    if (-not $PSCmdlet.ShouldProcess($path, 'Create private archive fixture')) { return }
    $archive = [IO.Compression.ZipFile]::Open($path, [IO.Compression.ZipArchiveMode]::Create)
    try { foreach ($key in $Contents.Keys) { $entry = $archive.CreateEntry($key); $stream = $entry.Open(); try { $bytes = [Text.Encoding]::UTF8.GetBytes($Contents[$key]); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() } } } finally { $archive.Dispose() }
    return $path
}
function New-FixtureRecord {
    [CmdletBinding(SupportsShouldProcess = $true)]param([string]$Id, [string]$Version, [string]$Kind, [string]$Url, [string]$Source)
    $hash = Get-BootstrapFileSha256 $Source; $extension = if ($Kind -eq 'portable') { 'exe' } else { $Kind }
    $name = 'packages/' + $hash + '.' + $extension
    if (-not $PSCmdlet.ShouldProcess((Join-Path $cache $name), 'Copy private fixture payload')) { return }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $cache $name)
    return @{ id = $Id; name = $Id; version = $Version; installerType = $Kind; url = $Url; sha256 = $hash; size = (Get-Item -LiteralPath $Source).Length; file = $name }
}
try {
    # Exercise the real arithmetic with synthetic 16/32 GiB readings. The
    # native PowerShell 5.1 overload must not narrow a byte count to Int32.
    $script:BudgetTotal = 16GB; $script:BudgetAvailable = 12GB
    Set-Item Function:Get-CimInstance -Value { [CmdletBinding()]param([string]$ClassName, [int]$OperationTimeoutSec); if ($ClassName -cne 'Win32_OperatingSystem' -or $OperationTimeoutSec -ne 5) { throw 'Unexpected budget query' }; return @{ FreePhysicalMemory = $script:BudgetAvailable / 1KB; TotalVisibleMemorySize = $script:BudgetTotal / 1KB } }
    & $nativeBudget $fixture 0
    Confirm-Fixture $true '16 GiB native budget arithmetic accepts sufficient physical reserve'
    $script:BudgetTotal = 32GB; $script:BudgetAvailable = 7GB
    Invoke-RejectedFixture { & $nativeBudget $fixture 0 } '32 GiB reference keeps its proportional reserve instead of accepting a low-memory sample'
    $portable = Join-Path $fixture 'portable-fixture.exe'; [IO.File]::WriteAllText($portable, 'not executable; native boundary mocked')
    $claude = New-FixtureRecord 'Anthropic.ClaudeCode' '2.1.318' 'portable' 'https://downloads.claude.ai/claude-code-releases/2.1.318/win32-x64/claude.exe' $portable
    $layout = @{ layoutVersion = 1; version = '0.168.0'; target = 'x86_64-pc-windows-msvc'; entrypoint = 'codex-x86_64-pc-windows-msvc.exe' } | ConvertTo-Json
    $archive = New-FixtureArchive @{ 'codex-package.json' = $layout; 'codex-x86_64-pc-windows-msvc.exe' = 'fake main'; 'bin/codex-exec-server.exe' = 'fake helper'; 'codex-path/rg.exe' = 'fake search' } 'codex-fixture.zip'
    $codex = New-FixtureRecord 'OpenAI.Codex' '0.168.0' 'zip' 'https://github.com/openai/codex/releases/download/rust-v0.168.0/codex-x86_64-pc-windows-msvc.exe.zip' $archive
    $msix = New-FixtureArchive @{ 'AppxManifest.xml' = '<Package><Identity Name="Claude" ProcessorArchitecture="x64" Version="3.6556.2.0" Publisher="CN=Anthropic Fixture" /></Package>' } 'desktop-fixture.msix'
    $desktop = New-FixtureRecord 'Anthropic.Claude' '3.6556.2' 'msix' ('https://downloads.claude.ai/releases/win32/x64/3.6556.2/Claude-' + ('a' * 40) + '.msix') $msix
    $openaiMsix = New-FixtureArchive @{ 'AppxManifest.xml' = '<Package><Identity Name="OpenAI.Codex" ProcessorArchitecture="x64" Version="26.1111.2228.0" Publisher="CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B" /></Package>' } 'openai-fixture.msix'
    $openai = New-FixtureRecord '9PLM9XGG6VKS' '26.1111.2228.0' 'msix' 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix' $openaiMsix
    $licenseBytes = [Text.Encoding]::UTF8.GetBytes('<License>public fixture</License>')
    $licenseSource = Join-Path $fixture 'license.xml'; [IO.File]::WriteAllBytes($licenseSource, $licenseBytes)
    $licenseHash = Get-BootstrapFileSha256 $licenseSource; $licenseFile = 'packages/' + $licenseHash + '.xml'
    Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $cache $licenseFile)
    $openai.assets = @(@{ id = 'OpenAI.Desktop.OfflineLicense'; purpose = 'vendor-offline-license'; url = 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml'; sha256 = $licenseHash; size = $licenseBytes.Length; file = $licenseFile })
    $lock = @{ schemaVersion = 1; wingetCommit = ('1' * 40); packages = @($claude, $codex, $desktop, $openai) }
    $lockPath = Join-Path $cache 'packages/packages.lock.json'
    $null = Write-BootstrapJsonFile -Path $lockPath -Value $lock
    Invoke-RejectedFixture { Get-PhaseZeroCachedApplication $cache 'Unknown.App' } 'Unapproved app refused'
    $claudePath = Join-Path $cache $claude.file; $original = [IO.File]::ReadAllBytes($claudePath)
    [IO.File]::WriteAllText($claudePath, 'corrupt')
    Invoke-RejectedFixture { Get-PhaseZeroCachedApplication $cache $claude.id } 'Corrupt payload refused and preserved'
    Confirm-Fixture ([IO.File]::ReadAllText($claudePath) -eq 'corrupt') 'No overwrite while rejecting corruption'
    [IO.File]::WriteAllBytes($claudePath, $original)
    $lock.packages += $claude; $null = Write-BootstrapJsonFile -Path $lockPath -Value $lock
    Invoke-RejectedFixture { Get-PhaseZeroCachedApplication $cache $claude.id } 'Duplicate identity refused'
    $lock.packages = @($claude, $codex, $desktop, $openai); $null = Write-BootstrapJsonFile -Path $lockPath -Value $lock
    $script:RuntimeState = 'missing'
    Invoke-RejectedFixture { Invoke-PhaseZeroCachedApplication $cache $claude.id } 'Missing runtime never triggers an online installer'
    $script:RuntimeState = 'satisfied'
    $installRoot = Get-BootstrapAiInstallRoot -InstallRoot ''
    $inventory = New-BootstrapAiToolManifest; $inventory['keep'] = 'existing-state'; $inventory['tools']['unrelated'] = @{ state = 'preserve' }
    $null = Write-BootstrapAiToolManifest -InstallRoot $installRoot -Manifest $inventory
    $installed = Invoke-PhaseZeroCachedApplication $cache $claude.id
    Confirm-Fixture ($installed.state -eq 'verified' -and $installed.authentication -eq 'pending') 'Portable installed without inventing authentication'
    $before = $script:NativeCalls; $reused = Invoke-PhaseZeroCachedApplication $cache $claude.id
    Confirm-Fixture ($reused.reused -and $script:NativeCalls -eq $before) 'Resume verifies payload bytes without executing a user client'
    $installed = Invoke-PhaseZeroCachedApplication $cache $codex.id
    Confirm-Fixture ($installed.state -eq 'verified') 'Complete Codex layout installed'
    $inventory = Get-PhaseZeroCachedManifest $installRoot
    Confirm-Fixture ($inventory['keep'] -eq 'existing-state' -and $inventory['tools']['unrelated']['state'] -eq 'preserve') 'Existing inventory preserved'
    $entry = $inventory['tools']['codex-cli']
    Confirm-Fixture ([IO.File]::Exists((Join-Path $entry['directory'] 'bin/codex-exec-server.exe')) -and [IO.File]::Exists((Join-Path $entry['directory'] 'codex-path/rg.exe'))) 'Codex helper and bundled search are retained'
    $extra = Join-Path $entry['directory'] 'unexpected.dll'; [IO.File]::WriteAllText($extra, 'untrusted extra')
    Confirm-Fixture (-not (Get-PhaseZeroCachedApplicationStatus $cache $codex.id).verified) 'Unexpected installed DLL cannot participate in a verified bundle'
    Remove-Item -LiteralPath $extra
    $installed = Invoke-PhaseZeroCachedApplication $cache $desktop.id
    Confirm-Fixture ($installed.state -eq 'verified' -and $script:AppxCalls -eq 1) 'Signed MSIX uses only current-user registration boundary'
    $licensePath = Join-Path $cache $licenseFile
    [IO.File]::WriteAllText($licensePath, '<License>damaged</License>')
    Invoke-RejectedFixture { Invoke-PhaseZeroCachedApplication $cache $openai.id } 'Corrupt offline license blocks provisioning'
    Confirm-Fixture ($script:ProvisionCalls -eq 0) 'No provisioning occurs before license verification'
    [IO.File]::WriteAllBytes($licensePath, $licenseBytes)
    $installed = Invoke-PhaseZeroCachedApplication $cache $openai.id
    Confirm-Fixture ($installed.state -eq 'verified' -and $script:ProvisionCalls -eq 1 -and $script:AppxCalls -eq 2) 'OpenAI offline package is provisioned with its public license and registered for the bound user'
    $null = Invoke-PhaseZeroCachedApplication $cache $openai.id
    Confirm-Fixture ($script:ProvisionCalls -eq 1) 'Verified OpenAI registration is reused without repeated provisioning'
    $target = Get-PhaseZeroDependencyTarget; $target.caller = 'other-user'
    Confirm-Fixture (-not (Test-PhaseZeroCachedApplication (Get-PhaseZeroCachedApplication $cache $codex.id) $target $entry)) 'Other account cannot reuse a prepared receipt'
    $binary = Join-Path $entry['directory'] 'codex.exe'; [IO.File]::WriteAllText($binary, 'corrupt installed binary')
    foreach ($name in @('codex.exe','codex-x86_64-pc-windows-msvc.exe')) { $entry['files'][$name] = Get-BootstrapFileSha256 (Join-Path $entry['directory'] $name) }
    $inventory['tools']['codex-cli'] = $entry
    $null = Write-BootstrapAiToolManifest -InstallRoot $installRoot -Manifest $inventory
    Confirm-Fixture (-not (Get-PhaseZeroCachedApplicationStatus $cache $codex.id).verified) 'Installed corruption never reports verified'
    Confirm-Fixture ($script:NativeCalls -eq 0) 'Writable receipts never authorize executing an installed client'
    Invoke-RejectedFixture { Invoke-PhaseZeroCachedApplication $cache $codex.id } 'Corrupt owned tree requires review instead of blind replacement'
    foreach ($badName in @('../outside.txt', '.. /outside.txt', 'CON.txt')) {
        $badArchive = New-FixtureArchive @{ 'codex-package.json' = $layout; 'codex-x86_64-pc-windows-msvc.exe' = 'fake main'; $badName = 'must not escape' } ('bad-' + [Guid]::NewGuid().ToString('N') + '.zip')
        $badRecord = New-FixtureRecord 'OpenAI.Codex' '0.168.0' 'zip' $codex.url $badArchive
        $lock.packages = @($claude, $badRecord, $desktop); $null = Write-BootstrapJsonFile -Path $lockPath -Value $lock
        # Only the fixture's damaged registration is removed to exercise a fresh
        # target. Its owned file data remains preserved until fixture teardown.
        $inventory = Get-PhaseZeroCachedManifest $installRoot; $inventory['tools'].Remove('codex-cli')
        $null = Write-BootstrapAiToolManifest -InstallRoot $installRoot -Manifest $inventory
        Invoke-RejectedFixture { Invoke-PhaseZeroCachedApplication $cache $codex.id } 'Archive traversal or Windows device/normalization path refused'
        Confirm-Fixture (-not [IO.File]::Exists((Join-Path $fixture 'outside.txt')) -and -not [IO.File]::Exists((Join-Path $installRoot 'apps/codex-cli/outside.txt'))) 'No archive write escaped staging'
    }
    Write-Output ('PASS: ' + $script:Checks + ' cached application checks; native installers, clients, registry and network mocked.')
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
