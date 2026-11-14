param([string]$RuntimeRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RuntimeRoot 'bootstrap-tools.ps1') -BootstrapUiLibraryMode -RotateSecretsSchedule none
. (Join-Path $RuntimeRoot 'windows/ai/windows-dependencies.ps1')

function Assert-Equal($Actual, $Expected, [string]$Case) {
    if ($Actual -ne $Expected) { throw "$Case expected [$Expected], got [$Actual]" }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('phasezero-dependencies-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$oldWindows = $env:WINDIR
$env:WINDIR = $fixture
$script:repoRoot = $RuntimeRoot
$script:fixtureState = @{
    Registry = @{}; Files = @{}; RegistryFailure = $false; Queries = @(); Exit = 0; Runs = @()
    After = $null; Admin = $true; Reboot = @(); Idle = $true; Winget = 'fixture-winget'
}

function Get-BootstrapWindowsArchitecture { 'x64' }
function Get-BootstrapDependencySystemDirectory($Architecture, $WindowsArchitecture) { Join-Path $fixture $Architecture }
function Read-BootstrapDependencyRegistry($Key, $View, $Hive, $Names) {
    if ($script:fixtureState.RegistryFailure) { throw 'fixture registry access denied' }
    return $script:fixtureState.Registry[$Key]
}
function Get-BootstrapDependencyFile($Path) {
    $script:fixtureState.Queries += $Path
    return $script:fixtureState.Files[$Path]
}
function Test-IsAdmin { $script:fixtureState.Admin }
Set-Item Function:Get-BootstrapPendingRebootReasons -Value { $script:fixtureState.Reboot }
function Wait-BootstrapWingetMsiIdle($TimeoutSeconds, $HeartbeatSeconds) { $script:fixtureState.Idle }
function Resolve-CommandPath($Name) { if ($Name -eq 'winget') { $script:fixtureState.Winget } }
function Assert-BootstrapDiskSpace($RequiredGB) {}
Set-Item Function:Refresh-SessionPath -Value {}
Set-Item Function:Write-Log -Value { param($Message, $Level); $script:fixtureState['LastLog'] = @{ message = $Message; level = $Level } }
function Invoke-NativeWithLog {
    param($Exe, [Alias('Args')]$Arguments)
    if ($Exe -cne $script:fixtureState.Winget) { throw 'Unexpected native executable outside the fixture' }
    $script:fixtureState.Runs += ,$Arguments
    if ($script:fixtureState.After) { & $script:fixtureState.After }
    return $script:fixtureState.Exit
}
function Add-FixtureFile($Cpu, $FileName, $Version = '14.50.35710.0') {
    $script:fixtureState.Files[(Join-Path (Join-Path $fixture $Cpu) $FileName)] = @{ VersionInfo = @{ FileVersionRaw = $Version } }
}
function Add-FixtureVCRuntime($Cpu, $Version) {
    $script:fixtureState.Registry["SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$Cpu"] = @{ Installed = 1; Version = $Version }
    foreach ($file in 'vcruntime140.dll', 'msvcp140.dll') { Add-FixtureFile $Cpu $file $Version }
    if ($Cpu -eq 'x64') { Add-FixtureFile $Cpu 'vcruntime140_1.dll' $Version }
}
function Assert-InstallBlock($Definition, $Reason, $Code = $null) {
    $failure = $null
    try { $null = Install-BootstrapWindowsDependency -Definition $Definition } catch { $failure = $_ }
    Assert-Equal (Get-BootstrapBlockedErrorInfo $failure).Kind $Reason 'installer blocker'
    if ($null -ne $Code) { Assert-Equal $failure.Exception.Data['DependencyExitCode'] $Code 'installer code' }
}

try {
    $catalog = Get-PhaseZeroDependencyDefinition
    $dx = $catalog['directx-runtime']; $vc64 = $catalog['vcpp-redist']; $vc86 = $catalog['vcpp-redist-x86']
    $paths = @($vc64.ProbePaths)
    Assert-Equal (@($paths | Where-Object { $_ -match 'System32' }).Count) 3 'VC diagnostic paths remain public'
    Assert-Equal (@($paths | Where-Object { $_ -match 'Program Files' }).Count) 0 'VC diagnostic paths never use a phantom program directory'
    foreach ($dll in 'vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll') { Assert-Equal (@($paths | Where-Object { $_.EndsWith($dll) }).Count) 1 'VC diagnostic DLL coverage' }

    $legacy = @('d3dx9_43.dll','d3dx10_43.dll','d3dx11_43.dll','xinput1_3.dll','xaudio2_7.dll','xactengine3_7.dll')
    Add-FixtureFile x64 'd3d12.dll'
    Add-FixtureFile x86 'd3d11.dll'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $dx).status 'missing' 'OS DirectX alone'
    Assert-Equal (Get-BootstrapItemStatus -Kind app -Id directx-runtime -ProbePaths @('d3d12.dll') -Cache @{}) 'not-installed' 'generic DirectX status'
    Add-FixtureFile x64 $legacy[0]
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $dx).status 'partial' 'DirectX partial'
    $script:fixtureState.After = { foreach ($cpu in 'x64','x86') { foreach ($dll in $legacy) { Add-FixtureFile $cpu $dll } } }
    Assert-Equal (Install-BootstrapWindowsDependency $dx).status 'satisfied' 'DirectX rechecked after install'
    Assert-Equal (($script:fixtureState.Runs[0] -join ' ') -match '--installer-type exe') $true 'Win32 DirectX installer'
    $script:fixtureState.After = $null

    Add-FixtureVCRuntime x86 '14.10.0.0'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $vc86).status 'satisfied' 'VC x86'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $vc64).status 'missing' 'VC x64 independent'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $vc86 -MinimumVersion '14.44.0').status 'insufficient' 'VC minimum'
    Add-FixtureVCRuntime x64 '14.50.35710.0'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $vc64).status 'satisfied' 'VC x64'
    $script:fixtureState.Files.Remove((Join-Path (Join-Path $fixture x64) 'vcruntime140_1.dll'))
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $vc64).status 'partial' 'VC registered but DLL missing'
    $script:fixtureState.RegistryFailure = $true
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $vc64).status 'unknown' 'registry failure'
    Assert-InstallBlock $vc64 'dependency-unknown'
    $script:fixtureState.RegistryFailure = $false
    $script:fixtureState.Admin = $false
    Assert-InstallBlock $vc64 'elevation-required'
    $script:fixtureState.Admin = $true
    $script:fixtureState.Winget = ''
    Assert-InstallBlock $vc64 'winget-missing'
    $script:fixtureState.Winget = 'fixture-winget'
    $script:fixtureState.Reboot = @('fixture reboot')
    Assert-InstallBlock $vc64 'pending-reboot-msi'
    $script:fixtureState.Reboot = @()
    $script:fixtureState.Idle = $false
    Assert-InstallBlock $vc64 'winget-msi-busy'
    $script:fixtureState.Idle = $true
    foreach ($case in @(@(3010, 'pending-reboot-msi'), @(1618, 'winget-msi-busy'), @(-1978334969, 'download-unavailable'), @(1602, 'cancelled'), @(124, 'installer-timeout'), @(0, 'post-install-unverified'))) {
        $script:fixtureState.Exit = $case[0]
        Assert-InstallBlock $vc64 $case[1] $case[0]
    }
    $script:fixtureState.Exit = 0

    function Get-BootstrapDotNetDependencyEvidence($Definition, $WindowsArchitecture) {
        if ($Definition.DependencyArchitecture -eq 'x64' -and $Definition.DependencyMajor -eq 10) {
            return [pscustomobject]@{ version = [version]'10.0.4.0'; complete = ($Definition.DependencyProbe -ne 'sdk'); missing = @(); path = 'fixture' }
        }
    }
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $catalog['dotnet-runtime-10-x64'] -MinimumVersion '10.0.5').status 'insufficient' '.NET minimum'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $catalog['dotnet-runtime-11-x64']).status 'missing' '.NET major isolation'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $catalog['dotnet-runtime-10-x86']).status 'missing' '.NET architecture isolation'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $catalog['dotnet-desktop-10-x64']).status 'satisfied' '.NET desktop and matching core'
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $catalog['dotnet-sdk-10-x64']).status 'partial' '.NET SDK incomplete'
    $frameworkKey = 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    $script:fixtureState.Registry[$frameworkKey] = @{ Release = 533509 }
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $catalog['dotnet-framework']).version '4.8.1.0' '.NET Framework release'
    $webKey = 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    $script:fixtureState.Registry[$webKey] = @{ pv = '152.0.4191.66' }
    Assert-Equal (Get-BootstrapWindowsDependencyStatus $catalog['webview2-runtime']).version '152.0.4191.66' 'WebView2 version'

    $project = Join-Path $fixture 'global.json'
    Set-Content -LiteralPath $project -Value '{"sdk":{"version":"10.0.400","rollForward":"latestPatch"}}'
    $requirements = Resolve-PhaseZeroDependencyRequirement -RequirementFile $project -Definitions $catalog
    Assert-Equal $requirements['dotnet-sdk-10-x64'].policy 'sdk-band' 'global.json policy'
    Set-Content -LiteralPath $project -Value '{"sdk":{"version":"10.0.100","rollForward":"latestFeature"}}'
    $requirements = Resolve-PhaseZeroDependencyRequirement -RequirementFile $project -Definitions $catalog
    Assert-Equal $requirements['dotnet-sdk-10-x64'].policy 'minimum' 'global.json feature roll-forward'
    $app = Join-Path $fixture 'app.runtimeconfig.json'
    Set-Content -LiteralPath $app -Value '{"runtimeOptions":{"framework":{"name":"Microsoft.WindowsDesktop.App","version":"10.0.4"}}}'
    $requirements = Resolve-PhaseZeroDependencyRequirement -RequirementFile $app -Definitions $catalog -ApplicationArchitecture x86
    Assert-Equal $requirements['dotnet-desktop-10-x86'].version '10.0.4' '32-bit app requirements'

    function Get-PhaseZeroDependencyTarget {
        [pscustomobject]@{ windowsId = 'fixture-windows'; hostId = 'fixture-host'; boot = $script:fixtureBoot
            caller = 'fixture-user'; systemDrive = [IO.Path]::GetPathRoot($RuntimeRoot) }
    }
    function Get-PhaseZeroStoreDependency { [pscustomobject]@{ status = 'unknown'; packages = @() } }
    function Get-BootstrapVsWherePath { '' }
    function Get-PhaseZeroDependencyReceiptPath { Join-Path $fixture 'receipt.json' }
    $script:fixtureBoot = 'boot-1'
    $script:fixtureState.Exit = 3010
    $receipt = Invoke-PhaseZeroDependencySelection -Selected @('vcpp-redist','directx-runtime')
    Assert-Equal $receipt.state 'restart-required' 'restart retained'
    Assert-Equal $receipt.results['directx-runtime'].status 'queued' 'queue paused'
    $blocked = $false
    try { $null = Invoke-PhaseZeroDependencySelection -Selected @('vcpp-redist') } catch { $blocked = $_.Exception.Message -match 'reinicio' }
    Assert-Equal $blocked $true 'same boot resume blocked'
    $script:fixtureBoot = 'boot-2'
    $script:fixtureState.Exit = 0
    $script:fixtureState.After = { Add-FixtureVCRuntime x64 '14.50.35710.0' }
    $receipt = Invoke-PhaseZeroDependencySelection -Selected @('vcpp-redist','directx-runtime')
    Assert-Equal $receipt.state 'verified' 'resume verifies all'
    Assert-Equal (Get-PhaseZeroDependencyReport).previousRun['state'] 'verified' 'reopened receipt'
    $runs = $script:fixtureState.Runs.Count
    $null = Invoke-PhaseZeroDependencySelection -Selected @('vcpp-redist','directx-runtime')
    Assert-Equal $script:fixtureState.Runs.Count $runs 'rerun does not install again'
    Assert-Equal $script:fixtureState.Runs[-1][2] $vc64.Id 'x64 installer only'

    # The simplified preparation calls the same desktop entry without relying on the full bootstrap plan.
    $script:fixtureState.Files.Remove((Join-Path (Join-Path $fixture x64) 'vcruntime140_1.dll'))
    function Get-BootstrapCodexDesktopPackageInfo {
        if ((Get-BootstrapWindowsDependencyStatus $vc64).status -ne 'satisfied') { throw 'Codex checked before its redistributable' }
        return @{ installed = $true }
    }
    Install-PhaseZeroHostCodexRuntime
    Ensure-CodexInstaller -WingetPath 'fixture-winget'
    Assert-Equal $script:fixtureState.Runs.Count ($runs + 1) 'simplified Codex installs its dependency exactly once'
    $script:fixtureState.Files.Remove((Join-Path (Join-Path $fixture x64) 'vcruntime140_1.dll'))
    Ensure-CodexInstaller -WingetPath 'fixture-winget'
    Assert-Equal $script:fixtureState.Runs.Count ($runs + 2) 'direct Codex entry also repairs its dependency'
    Write-Output "PASS: Windows dependency probes, requirements, installers and recovery (PowerShell $($PSVersionTable.PSVersion))."
} finally {
    $env:WINDIR = $oldWindows
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
