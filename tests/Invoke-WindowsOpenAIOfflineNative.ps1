# Real provisioning only in a disposable hosted Windows reference. No account
# login, private memory, user credentials or physical target is involved.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [Parameter(Mandatory = $true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'Misael-art/phase-zero' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Disposable owner Windows reference required.' }
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Hosted reference administrator required.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
$temporaryRoot = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
if (-not $output.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)) { throw 'Use a fresh owned RUNNER_TEMP directory.' }
$runtime = [IO.Path]::GetFullPath($RuntimeRoot)
if ([IO.Path]::GetPathRoot($runtime) -ine [IO.Path]::GetPathRoot($env:WINDIR) -or -not (Test-Path -LiteralPath (Join-Path $runtime 'runtime-manifest.json'))) { throw 'Use the packaged owner on the current Windows system drive.' }
[void][IO.Directory]::CreateDirectory((Join-Path $output 'packages'))
[void][IO.Directory]::CreateDirectory((Join-Path $output 'receipts'))
$script:ResourceSamples = @()
function Confirm-OpenAIReferenceResource {
    [CmdletBinding()]param()
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $available = [double]$os.FreePhysicalMemory * 1KB; $total = [double]$os.TotalVisibleMemorySize * 1KB
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($runtime))
    $sample = @{ at = [DateTime]::UtcNow.ToString('o'); available = $available; total = $total; freeDisk = $drive.AvailableFreeSpace; estimatedPeak = 1GB; estimatedOutput = 8GB; thermal = 'Hosted VM; physical thermal supervision belongs to provider' }
    $script:ResourceSamples += $sample
    $script:ResourceSamples | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'receipts/resources.json') -Encoding UTF8
    if ($available -lt [Math]::Max(4GB, .25 * $total) + 1GB -or $drive.AvailableFreeSpace -lt 18GB) { throw 'Reference RAM/disk reserve unavailable.' }
}
function Receive-OpenAIReferencePayload {
    [CmdletBinding()]param([Parameter(Mandatory = $true)]$Payload)
    Confirm-OpenAIReferenceResource
    if ($Payload.file -cnotmatch '^packages/[a-f0-9]{64}\.(msix|xml)$' -or $Payload.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Payload.url -cnotmatch '^https://persistent\.oaistatic\.com/codex-app-prod/ChatGPT-(x64\.msix|License\.xml)$') { throw 'Unreviewed reference payload.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Payload.url); $request.Timeout = 180000; $request.ReadWriteTimeout = 30000
    $request.UserAgent = 'PhaseZero-native-reference'
    $response = $request.GetResponse()
    try {
        if ($response.ResponseUri.Scheme -cne 'https' -or ($response.ContentLength -ge 0 -and $response.ContentLength -ne $Payload.size)) { throw 'Reference origin/size changed; review pins.' }
        $path = Join-Path $output $Payload.file
        $sourceStream = $response.GetResponseStream(); $destination = [IO.File]::Open($path, [IO.FileMode]::CreateNew)
        try {
            $buffer = New-Object byte[] (1MB); $written = [long]0; $clock = [Diagnostics.Stopwatch]::StartNew()
            while (($count = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $written += $count; if ($written -gt $Payload.size) { throw 'Excessive reference transfer.' }
                $destination.Write($buffer, 0, $count)
                if ($clock.Elapsed.TotalSeconds -ge 20) { Confirm-OpenAIReferenceResource; $clock.Restart() }
            }
            $destination.Flush($true)
        } finally { $destination.Dispose(); $sourceStream.Dispose() }
    } finally { $response.Dispose() }
    if ((Get-Item -LiteralPath $path).Length -ne $Payload.size -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Payload.sha256) { throw 'Reference payload changed; preserve before review.' }
}
$fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/windows-openai-offline.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$package = $fixture.packages[0]
Receive-OpenAIReferencePayload $package
Receive-OpenAIReferencePayload $package.assets[0]
$fixture | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'packages/packages.lock.json') -Encoding UTF8
$entry = Join-Path $runtime 'windows/ai/prepare-host.ps1'
$exe = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$before = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -Action CachedAppStatus -OfflineCache $output -ApplicationIds 9PLM9XGG6VKS
if ($LASTEXITCODE) { throw 'Owner status failed.' }
$target = ($before | Out-String | ConvertFrom-Json).results[0]
Confirm-OpenAIReferenceResource
$job = Start-Job -ScriptBlock {
    $result = & $using:exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $using:entry -Action InstallCachedApps -OfflineCache $using:output -ApplicationIds 9PLM9XGG6VKS -ExpectedTarget $using:target.windowsId -ExpectedCaller $using:target.caller
    if ($LASTEXITCODE) { throw ('Owner installation failed: ' + ($result | Out-String)) }
    $result
}
$deadline = [Diagnostics.Stopwatch]::StartNew()
try {
    while ($job.State -in @('NotStarted','Running')) {
        Confirm-OpenAIReferenceResource
        if ($deadline.Elapsed.TotalMinutes -ge 8) { throw 'Native provisioning exceeded its bounded reference deadline.' }
        $null = Wait-Job $job -Timeout 20
    }
    $installation = Receive-Job $job -ErrorAction Stop | Out-String | ConvertFrom-Json
    if ($job.State -ne 'Completed' -or $installation.results[0].state -cne 'verified') { throw 'Incomplete owner installation receipt.' }
} finally { if ($job.State -in @('NotStarted','Running')) { Stop-Job $job }; Remove-Job $job -Force }
$after = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -Action CachedAppStatus -OfflineCache $output -ApplicationIds 9PLM9XGG6VKS -ExpectedTarget $target.windowsId -ExpectedCaller $target.caller
if ($LASTEXITCODE) { throw 'Owner verification failed.' }
$status = ($after | Out-String | ConvertFrom-Json).results[0]
if (-not $status.verified) { throw 'Registration was not verified for the bound user.' }
$provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -ceq 'OpenAI.Codex' -and [string]$_.Version -ceq $package.version })
if ($provisioned.Count -ne 1) { throw 'Licensed provisioning is not uniquely confirmed.' }
@{ schemaVersion = 1; sourceCommit = $env:GITHUB_SHA; package = $package.id; version = $package.version; sha256 = $package.sha256; licenseSha256 = $package.assets[0].sha256; provisioning = 'verified-with-vendor-offline-license'; currentUserRegistration = 'verified'; functionTest = 'pending-interactive-user'; authentication = 'pending'; wholeOsOffline = 'pending'; physicalWindows11 = 'pending'; os = (Get-CimInstance Win32_OperatingSystem).Caption } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'receipts/openai-native.json') -Encoding UTF8
Write-Output 'PASS: licensed OpenAI provisioning and bound-user registration verified; login, application use and physical Windows remain pending.'
