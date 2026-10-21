# Disposable Windows end-to-end proof. Installs pinned runtime with a minimal
# PATH, then replaces only the disposable entrypoint with a local HTTP fixture.
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
    throw 'This smoke test requires a disposable Windows x64 runner.'
}

$repo = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $repo 'windows\pz.ps1'
$fixture = Join-Path $PSScriptRoot 'fixtures\deepseek-harness-web-fixture.mjs'
$engine = (Get-Process -Id $PID).Path
$testRoot = Join-Path $env:TEMP ('pz-dsh-clean-' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $env:TEMP ('pz-dsh-workspace-' + [guid]::NewGuid().ToString('N'))
$record = Join-Path $testRoot 'fixture-env.json'
$requestRecord = Join-Path $testRoot 'fixture-requests.txt'
$saved = @{}
$smokeFailure = $null
$cleanupProblems = @()
$testEnvNames = @(
    'PATH','PZ_DSH_ROOT','PZ_DSH_FIXTURE_RECORD','PZ_DSH_FIXTURE_REQUEST_RECORD',
    'PZ_DSH_FIXTURE_CRASH','DEEPSEEK_API_KEY','OPENAI_API_KEY','AWS_SECRET_ACCESS_KEY','NODE_AUTH_TOKEN',
    'NODE_OPTIONS','NODE_PATH','NODE_EXTRA_CA_CERTS','NPM_CONFIG_USERCONFIG'
)
foreach ($name in $testEnvNames) {
    $item = Get-Item -LiteralPath ("Env:" + $name) -ErrorAction SilentlyContinue
    if ($item) { $saved[$name] = $item.Value }
}

function Invoke-Manager {
    param([string]$Name, [string]$Folder = '', [string]$Route = '', [int]$Port = 0, [switch]$DebugManager)
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$cli,'ai','deepseek-harness',$Name)
    if ($Folder) { $arguments += @('--workspace',$Folder) }
    if ($Route) { $arguments += @('--auth-route',$Route) }
    if ($Port) { $arguments += @('--port',[string]$Port) }
    $arguments += '--json'
    $argumentLine = ($arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '
    $hadDebug = Test-Path Env:PZ_DSH_DEBUG
    $oldDebug = $env:PZ_DSH_DEBUG
    $outputRoot = Join-Path $env:TEMP ('pz-dsh-cli-output-' + [guid]::NewGuid().ToString('N'))
    $stdoutPath = Join-Path $outputRoot 'stdout.txt'
    $stderrPath = Join-Path $outputRoot 'stderr.txt'
    $process = $null
    $timeoutSeconds = if ($Name -in @('install','update')) { 1500 } else { 90 }
    try {
        $null = New-Item -ItemType Directory -Path $outputRoot -Force
        if ($DebugManager) { $env:PZ_DSH_DEBUG = '1' }
        $process = Start-Process -FilePath $engine -ArgumentList $argumentLine -WorkingDirectory $repo -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
        if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
            try { $process.Kill() } catch { Write-Verbose 'Could not terminate timed-out smoke manager.' }
            $null = $process.WaitForExit(5000)
            throw "Manager $Name exceeded timeout ($timeoutSeconds seconds)."
        }
        $code = [int]$process.ExitCode
        $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction Stop } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw -ErrorAction Stop } else { '' }
        $lines = @(@($stdout -split '\r?\n') + @($stderr -split '\r?\n'))
        foreach ($line in $lines) {
            $line = [string]$line
            if ($line -match '^PZ_DSH_STAGE=([a-z0-9.-]{1,80})$') {
                Write-SmokeMarker ("manager {0} at {1}" -f $Name,$matches[1])
            }
        }
    } finally {
        if ($process -and -not $process.HasExited) {
            try { $process.Kill() } catch { Write-Verbose 'Could not terminate smoke manager during cleanup.' }
            $null = $process.WaitForExit(5000)
        }
        if ($DebugManager) {
            if ($hadDebug) { $env:PZ_DSH_DEBUG = $oldDebug }
            else { Remove-Item Env:PZ_DSH_DEBUG -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $outputRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $line = @($lines | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if ($line.Count -eq 0) { throw "Manager $Name returned no JSON (exit $code)." }
    try { $payload = $line[0] | ConvertFrom-Json } catch { throw "Manager $Name returned invalid JSON (exit $code)." }
    $diagnostics = @($lines | Where-Object { ([string]$_).Trim() -and ([string]$_ -notmatch '^\s*\{') } | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Code = $code; Payload = $payload; Diagnostics = $diagnostics }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-ExpectedDshHome {
    param([string]$Path, [ValidateSet('account','api')][string]$Route)
    if (-not $Path -or -not [IO.Path]::IsPathRooted($Path)) { return $false }
    # Windows may report the same temporary root through its 8.3 alias or its
    # long name. The unique smoke-root suffix still proves route isolation.
    $expectedSuffix = [IO.Path]::Combine((Split-Path -Leaf $testRoot), 'homes', $Route)
    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    return $normalized.EndsWith($expectedSuffix, [StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Write-SmokeMarker {
    param([string]$Message)
    Write-Information -MessageData ("DeepSeek Harness Windows smoke: " + $Message) -InformationAction Continue
}

function Wait-Stopped {
    param([int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 200
        $status = Invoke-Manager 'status'
        if ($status.Payload.runtimeState -ne 'running' -and $status.Payload.runtimeState -ne 'starting-or-unhealthy') { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Harness fixture did not stop in time.'
}

function Wait-FixtureDescendant {
    param([int]$TimeoutSeconds = 5)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $record) {
            $captured = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
            if ([int]$captured.descendantProcessId -gt 0) { return [int]$captured.descendantProcessId }
            if ($captured.descendantError -match '^[A-Z0-9_-]{1,32}$') { throw "Fixture descendant spawn failed ($($captured.descendantError))." }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Harness fixture descendant did not start.'
}

function Get-RedactedFailureDetail {
    param([string[]]$Diagnostics = @(), [string]$LogPath = '')
    $detail = @($Diagnostics | ForEach-Object {
        $line = [string]$_
        $line = [regex]::Replace($line, '([?&](?:token|launchToken)=)[^&\s"'']+', '$1[redacted]', 'IgnoreCase')
        $line = [regex]::Replace($line, '(?i)((?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|launch[_ -]?token|client[_ -]?secret|secret|password|cookie|authorization|bearer|token)\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|\S+)', '$1[redacted]')
        [regex]::Replace($line, '\bsk-[A-Za-z0-9_-]{8,}', '[redacted-api-key]')
    }) -join ' | '
    if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
        $logDetail = @(Get-Content -LiteralPath $LogPath -Tail 8 | ForEach-Object {
            $line = [regex]::Replace([string]$_, '([?&](?:token|launchToken)=)[^&\s"'']+', '$1[redacted]', 'IgnoreCase')
            $line = [regex]::Replace($line, '(?i)((?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|launch[_ -]?token|client[_ -]?secret|secret|password|cookie|authorization|bearer|token)\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|\S+)', '$1[redacted]')
            [regex]::Replace($line, '\bsk-[A-Za-z0-9_-]{8,}', '[redacted-api-key]')
        }) -join ' | '
        if ($logDetail) { $detail += " Supervisor log: $logDetail" }
    }
    if ($detail.Length -gt 3000) { $detail = $detail.Substring(0,3000) }
    return $detail
}

try {
    $null = New-Item -ItemType Directory -Path $workspace -Force
    Set-Content -LiteralPath (Join-Path $workspace '.env') -Value 'DEEPSEEK_API_KEY=project-dotenv-fixture' -NoNewline
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start(); $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port; $listener.Stop()
    $env:PZ_DSH_ROOT = $testRoot
    $env:PZ_DSH_FIXTURE_RECORD = $record
    $env:PZ_DSH_FIXTURE_REQUEST_RECORD = $requestRecord
    $env:DEEPSEEK_API_KEY = 'ambient-deepseek-fixture'
    $env:OPENAI_API_KEY = 'ambient-openai-fixture'
    $env:AWS_SECRET_ACCESS_KEY = 'ambient-cloud-fixture'
    $env:NODE_AUTH_TOKEN = 'ambient-registry-fixture'
    $env:NODE_OPTIONS = '--require=C:\ambient-hook.js'
    $env:NODE_PATH = 'C:\ambient-modules'
    $env:NODE_EXTRA_CA_CERTS = 'C:\ambient-ca.pem'
    $env:NPM_CONFIG_USERCONFIG = 'C:\ambient.npmrc'

    # Hide runner-provided Node/npm and compiler directories. Manager must use
    # only its fixed Node archive plus Windows system utilities.
    $env:PATH = Join-Path $env:SystemRoot 'System32'
    Assert-True (-not (Get-Command node -ErrorAction SilentlyContinue)) 'Runner Node unexpectedly visible on clean PATH.'
    Assert-True (-not (Get-Command npm -ErrorAction SilentlyContinue)) 'Runner npm unexpectedly visible on clean PATH.'

    Write-SmokeMarker 'read-only diagnostics'
    $plan = Invoke-Manager 'plan'
    Assert-True ($plan.Code -eq 0 -and $plan.Payload.ok -and -not $plan.Payload.mutatesHost) 'Plan must be ready and read-only.'
    $status = Invoke-Manager 'status'
    $doctor = Invoke-Manager 'doctor'
    Assert-True ($status.Code -eq 0 -and $status.Payload.state -eq 'not-installed') 'Absent status must still return a successful report.'
    Assert-True (-not (Test-Path -LiteralPath $testRoot)) 'Read-only diagnostics created managed state.'
    Assert-True ($status.Payload.quota -eq 'unknown' -and $doctor.Payload.sandboxEnforcement -eq 'unknown') 'Diagnostics overclaimed external state.'

    Write-SmokeMarker 'pinned installation started'
    $installed = Invoke-Manager 'install' -DebugManager
    Write-SmokeMarker 'pinned installation returned'
    if ($installed.Code -ne 0 -or -not $installed.Payload.installed) {
        $detail = if ($installed.Diagnostics.Count -gt 0) { "`n" + ($installed.Diagnostics -join "`n") } else { '' }
        throw "Pinned install failed on clean Windows runner ($($installed.Payload.reason)).$detail"
    }
    $active = Get-Content -LiteralPath (Join-Path $testRoot 'active.json') -Raw | ConvertFrom-Json
    $runtime = Join-Path (Join-Path $testRoot 'runtime') ([string]$active.runtimePath)
    $entry = Join-Path $runtime 'app\node_modules\@deepseek-ai\dsh\lib\bin.js'
    $realWorkspace = Join-Path $testRoot 'real-workspace'
    $null = New-Item -ItemType Directory -Path $realWorkspace -Force
    Write-SmokeMarker 'upstream no-credential start started'
    $realStart = Invoke-Manager 'start' $realWorkspace 'account' $port -DebugManager
    Write-SmokeMarker 'upstream no-credential start returned'
    if ($realStart.Code -ne 0 -or $realStart.Payload.state -ne 'running') {
        $detail = Get-RedactedFailureDetail -Diagnostics $realStart.Diagnostics -LogPath (Join-Path $testRoot 'logs\dsh.log')
        throw ("Real upstream Web UI failed no-credential smoke start (exit={0}, state={1}, reason={2}, nextAction={3}, errorType={4}). {5}" -f $realStart.Code,$realStart.Payload.state,$realStart.Payload.reason,$realStart.Payload.nextAction,$realStart.Payload.error.errorType,$detail)
    }
    $realStatus = Invoke-Manager 'status'
    Assert-True ($realStatus.Payload.authRoute -eq 'account' -and $realStatus.Payload.quota -eq 'unknown') 'No-cost smoke claimed account or quota state.'
    Write-SmokeMarker 'upstream no-credential stop started'
    $realStop = Invoke-Manager 'stop'
    Write-SmokeMarker 'upstream no-credential stop returned'
    Assert-True ($realStop.Code -eq 0) 'Real upstream no-credential smoke did not stop cleanly.'
    Assert-True ((Invoke-Manager 'status').Payload.runtimeState -eq 'stopped') 'Real upstream stop left stale supervisor state.'
    $backup = Join-Path $testRoot 'upstream-bin.js'
    Copy-Item -LiteralPath $entry -Destination $backup
    Copy-Item -LiteralPath $fixture -Destination $entry -Force

    $busyListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
    $busyListener.Start()
    Write-SmokeMarker 'occupied port rejection'
    $busy = Invoke-Manager 'start' $workspace 'api' $port
    Assert-True ($busy.Code -ne 0 -and $busy.Payload.reason -eq 'port-occupied') 'Occupied loopback port did not fail closed.'
    Assert-True ($busyListener.LocalEndpoint.Port -eq $port) 'Port conflict handling disturbed unrelated listener.'
    $busyListener.Stop()

    Write-SmokeMarker 'API fixture lifecycle started'
    $api = Invoke-Manager 'start' $workspace 'api' $port -DebugManager
    if ($api.Code -ne 0 -or $api.Payload.state -ne 'running') {
        $detail = Get-RedactedFailureDetail -Diagnostics $api.Diagnostics -LogPath (Join-Path $testRoot 'logs\dsh.log')
        throw ("API route fixture failed health check (exit={0}, state={1}, reason={2}, nextAction={3}, errorType={4}). {5}" -f $api.Code,$api.Payload.state,$api.Payload.reason,$api.Payload.nextAction,$api.Payload.error.errorType,$detail)
    }
    $apiPid = [int]$api.Payload.processId
    $captured = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    $apiChildPid = [int]$captured.processId
    $apiDescendantPid = Wait-FixtureDescendant
    Assert-True (Test-ExpectedDshHome -Path $captured.dshHome -Route 'api') 'API DSH_HOME was not isolated.'
    Assert-True ($captured.permission -eq 'workspace-write' -and $captured.telemetry -eq '1') 'Requested runtime policy was not set.'
    Assert-True ($captured.leakedNames.Count -eq 0) 'Ambient secrets reached the Harness process.'
    Assert-True ($captured.nodeConfigNames.Count -eq 0) 'Ambient Node/npm config reached the Harness process.'
    Assert-True ($captured.nodeOptions -eq '--max-old-space-size=2048') 'Controlled V8 heap limit was not applied.'
    Assert-True ($captured.cwd -eq (Join-Path $testRoot 'homes\api\launch')) 'Harness did not start in its private empty directory.'
    Assert-True ($captured.cwd -ne $workspace) 'Workspace .env could affect Harness startup.'

    $duplicate = Invoke-Manager 'start' $workspace 'api' $port
    Assert-True ($duplicate.Code -eq 0 -and [int]$duplicate.Payload.processId -eq $apiPid) 'Second start created another process.'
    $invalidCredential = Join-Path $testRoot 'homes\api\.credentials.yaml'
    Set-Content -LiteralPath $invalidCredential -Value 'fixture: invalid-credential' -NoNewline
    $unknown = Invoke-Manager 'status'
    Assert-True ($unknown.Payload.apiCredential -eq 'credential file present; validity unknown') 'Credential presence was mistaken for validity.'
    Assert-True ($unknown.Payload.quota -eq 'unknown' -and $unknown.Payload.balance -eq 'unknown') 'Quota/balance were inferred.'
    $doctor = Invoke-Manager 'doctor'
    Assert-True ($doctor.Payload.sandboxEnforcement -eq 'unknown') 'Requested file policy was presented as full sandbox enforcement.'

    Write-SmokeMarker 'authenticated open handoff'
    $opened = Invoke-Manager 'open'
    Assert-True ($opened.Code -eq 0 -and $opened.Payload.opened) 'Authenticated Web UI handoff failed.'
    foreach ($path in @((Join-Path $testRoot 'state.json'),(Join-Path $testRoot 'supervisor.json'),(Join-Path $testRoot 'logs\dsh.log'))) {
        if (Test-Path -LiteralPath $path) {
            Assert-True ((Get-Content -LiteralPath $path -Raw) -notmatch 'fixture-launch-secret') "Launch token persisted in $path"
            Assert-True ((Get-Content -LiteralPath $path -Raw) -notmatch 'fixture-visible-secret') "Credential-like output persisted in $path"
        }
    }
    Assert-True ((Get-Content -LiteralPath (Join-Path $testRoot 'logs\dsh.log') -Raw) -match 'apiKey=\[redacted\]') 'Credential-like Harness output was not redacted.'
    Write-SmokeMarker 'API fixture stop'
    $stopped = Invoke-Manager 'stop'
    Assert-True ($stopped.Code -eq 0) 'Owned runtime stop failed.'
    Wait-Stopped
    Assert-True (-not (Get-Process -Id $apiPid -ErrorAction SilentlyContinue)) 'Supervisor process survived stop.'
    Assert-True (-not (Get-Process -Id $apiChildPid -ErrorAction SilentlyContinue)) 'Harness child process survived stop.'
    Assert-True (-not (Get-Process -Id $apiDescendantPid -ErrorAction SilentlyContinue)) 'Harness descendant survived stop.'
    Assert-True ((Invoke-Manager 'status').Payload.runtimeState -eq 'stopped') 'Fixture stop left stale supervisor state.'

    Write-SmokeMarker 'separate account route lifecycle'
    $account = Invoke-Manager 'start' $workspace 'account' $port
    Assert-True ($account.Code -eq 0 -and $account.Payload.authRoute -eq 'account') 'Account route did not start explicitly.'
    $captured = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    $accountChildPid = [int]$captured.processId
    $accountDescendantPid = Wait-FixtureDescendant
    Assert-True (Test-ExpectedDshHome -Path $captured.dshHome -Route 'account') 'Account route reused API DSH_HOME.'
    Assert-True ($captured.route -eq 'account') 'Account route did not stay explicit.'
    $accountStop = Invoke-Manager 'stop'
    Assert-True ($accountStop.Code -eq 0) 'Account route stop failed.'
    Wait-Stopped
    Assert-True (-not (Get-Process -Id $accountChildPid -ErrorAction SilentlyContinue)) 'Account route child survived stop.'
    Assert-True (-not (Get-Process -Id $accountDescendantPid -ErrorAction SilentlyContinue)) 'Account route descendant survived stop.'

    Write-SmokeMarker 'crash recovery'
    $env:PZ_DSH_FIXTURE_CRASH = '1'
    $crash = Invoke-Manager 'start' $workspace 'api' $port
    Assert-True ($crash.Code -ne 0 -and $crash.Payload.reason -eq 'runtime-crashed') 'Early child crash was not reported.'
    Remove-Item Env:PZ_DSH_FIXTURE_CRASH -ErrorAction SilentlyContinue
    $restarted = Invoke-Manager 'start' $workspace 'api' $port
    Assert-True ($restarted.Code -eq 0 -and $restarted.Payload.state -eq 'running') 'Runtime did not recover after crash.'
    $null = Invoke-Manager 'stop'
    Wait-Stopped

    Copy-Item -LiteralPath $backup -Destination $entry -Force
    Write-SmokeMarker 'safe uninstall'
    $removed = Invoke-Manager 'uninstall'
    Assert-True ($removed.Code -eq 0 -and -not $removed.Payload.installed) 'Uninstall failed.'
    Assert-True (-not (Test-Path -LiteralPath $runtime)) 'Uninstall left pinned runtime files.'
    Assert-True ((Test-Path -LiteralPath (Join-Path $testRoot 'homes\api')) -and (Test-Path -LiteralPath (Join-Path $testRoot 'homes\account'))) 'Uninstall removed route homes.'
    Assert-True ((Test-Path -LiteralPath $workspace) -and (Test-Path -LiteralPath (Join-Path $workspace '.env'))) 'Uninstall removed selected workspace data.'
    Write-Output 'deepseek-harness Windows clean-runtime smoke: passed; no inference sent'
} catch {
    $smokeFailure = $_
    throw
} finally {
    if ($env:PZ_DSH_ROOT -eq $testRoot) {
        try {
            $cleanupStop = Invoke-Manager 'stop'
            if ($cleanupStop.Code -ne 0) { $cleanupProblems += "stop-exit-$($cleanupStop.Code)-$($cleanupStop.Payload.reason)" }
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            do {
                $cleanupStatus = Invoke-Manager 'status'
                if ($cleanupStatus.Payload.runtimeState -notin @('running','starting-or-unhealthy')) { break }
                Start-Sleep -Milliseconds 200
            } while ([DateTime]::UtcNow -lt $deadline)
            if ($cleanupStatus.Payload.runtimeState -in @('running','starting-or-unhealthy')) { $cleanupProblems += 'runtime-remains-running' }
        } catch { $cleanupProblems += 'manager-stop-or-status-failed' }
    }
    foreach ($name in $testEnvNames) {
        if ($saved.ContainsKey($name)) { Set-Item -Path ("Env:" + $name) -Value $saved[$name] }
        else { Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $testRoot) {
        Write-Information -MessageData "Removing test-owned disposable root: $testRoot" -InformationAction Continue
        try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop }
        catch { $cleanupProblems += 'test-root-still-in-use' }
    }
    if (Test-Path -LiteralPath $workspace) {
        Write-Information -MessageData "Removing test-owned workspace: $workspace" -InformationAction Continue
        try { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction Stop }
        catch { $cleanupProblems += 'workspace-cleanup-failed' }
    }
    if ($cleanupProblems.Count -gt 0) {
        $summary = 'Disposable Windows smoke cleanup: ' + ($cleanupProblems -join ', ')
        if ($smokeFailure) { Write-Warning $summary }
        else { throw $summary }
    }
}
