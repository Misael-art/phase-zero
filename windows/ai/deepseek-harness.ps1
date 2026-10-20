#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Action = 'status',
    [string]$Workspace = '',
    [ValidateSet('', 'account', 'api')][string]$AuthRoute = '',
    [int]$Port = 3080,
    [string]$Runtime = '',
    [string]$RequestedWorkspace = '',
    [switch]$InternalSupervisor,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:PinsPath = Join-Path $script:RepoRoot 'packaging\deepseek-harness\pins.json'
$script:PackagePath = Join-Path $script:RepoRoot 'packaging\deepseek-harness'
$localAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }
$script:AppRoot = if ($env:PZ_DSH_ROOT) { [IO.Path]::GetFullPath($env:PZ_DSH_ROOT) } else { Join-Path $localAppData 'PhaseZero\DeepSeekHarness' }
$script:RuntimeRoot = Join-Path $script:AppRoot 'runtime'
$script:HomesRoot = Join-Path $script:AppRoot 'homes'
$script:StatePath = Join-Path $script:AppRoot 'state.json'
$script:ActivePath = Join-Path $script:AppRoot 'active.json'
$script:SupervisorPath = Join-Path $script:AppRoot 'supervisor.json'
$script:LogPath = Join-Path $script:AppRoot 'logs\dsh.log'
$script:DefaultPort = if ($env:PZ_DSH_PORT) { [int]$env:PZ_DSH_PORT } else { 3080 }
$script:ExplicitPort = $PSBoundParameters.ContainsKey('Port')
if ($script:ExplicitPort) { $script:DefaultPort = $Port }
$script:ReadyTimeoutSeconds = 35
$script:MinAvailableMemoryBytes = 2147483648L
$script:LaunchUrl = ''
$script:SupervisorReady = $false

function Test-SensitiveEnvironmentName {
    param([string]$Name)
    if ($Name -match '^(?i)DEEPSEEK_') { return $true }
    if ($Name -match '^(?i)NPM_CONFIG_' -or $Name -match '^(?i)(NODE_OPTIONS|NODE_PATH|NODE_EXTRA_CA_CERTS)$') { return $true }
    $sensitiveWords = @('API','AUTH','ACCESS','REFRESH','BEARER','KEY','TOKEN','SECRET','PASSWORD','COOKIE','CREDENTIAL','CREDENTIALS')
    $words = [regex]::Split($Name, '[^A-Za-z0-9]+')
    foreach ($word in $words) { if ($sensitiveWords -contains $word) { return $true } }
    return $false
}

if ($InternalSupervisor) {
    Get-ChildItem Env: | Where-Object { Test-SensitiveEnvironmentName -Name $_.Name } |
        ForEach-Object { Remove-Item -LiteralPath ("Env:" + $_.Name) -ErrorAction SilentlyContinue }
}

function Get-Pins {
    if (-not (Test-Path -LiteralPath $script:PinsPath -PathType Leaf)) { throw 'pin-data-invalid' }
    $pins = Get-Content -LiteralPath $script:PinsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$pins.schemaVersion -ne 1 -or -not $pins.harness.version -or -not $pins.node.version) { throw 'pin-data-invalid' }
    return $pins
}

function Get-AvailableMemoryBytes {
    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return ([long]$operatingSystem.FreePhysicalMemory) * 1024L
    } catch { return $null }
}

function Get-PortValue {
    $portValue = $script:DefaultPort
    if (-not $script:ExplicitPort -and -not $env:PZ_DSH_PORT) {
        $savedState = Read-JsonFile -Path $script:StatePath
        if ($savedState -and $savedState.port) { $portValue = [int]$savedState.port }
    }
    if ($portValue -lt 1024 -or $portValue -gt 65535) { throw 'invalid-port' }
    return $portValue
}

function New-Result {
    param([string]$Command, [bool]$Ok, [string]$State, [string]$Reason = '', [string]$NextAction = '', [hashtable]$Extra = @{})
    $pins = Get-Pins
    $portValue = Get-PortValue
    $value = [ordered]@{
        schemaVersion = 1; appId = 'app.deepseek-harness'; command = $Command
        ok = $Ok; state = $State; reason = $Reason; nextAction = $NextAction
        version = [string]$pins.harness.version; profile = 'web'; port = $portValue
        authRoute = 'unknown'; accountAuth = 'unknown'; apiCredential = 'unknown'
        quota = 'unknown'; balance = 'unknown'; sandboxPolicy = 'workspace-write + ask (requested)'
        sandboxEnforcement = 'unknown'; workspaceSelection = 'confirm in Harness Web UI'
        plugins = 'opt-in; none enabled by PhaseZero'; telemetry = 'disabled by DSH_TELEMETRY_DISABLED=1'
    }
    foreach ($key in $Extra.Keys) { $value[$key] = $Extra[$key] }
    return $value
}

function Write-JsonResult {
    param([System.Collections.IDictionary]$Value, [int]$Code = 0)
    [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 10 -Compress))
    return $Code
}

function Set-PrivateAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($env:OS -ne 'Windows_NT') { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'unsafe-reparse-point' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($item.PSIsContainer) {
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } else {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
}

function New-PrivateDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-SafeManagedRoot)) { throw 'unsafe-managed-root' }
    $root = [IO.Path]::GetFullPath($script:AppRoot).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals($fullPath.TrimEnd('\'), $root, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith(($root + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe-managed-path' }
    if (Test-Path -LiteralPath $root) {
        if (-not (Get-Item -LiteralPath $root -Force).PSIsContainer) { throw 'unsafe-managed-root' }
    } else { $null = New-Item -ItemType Directory -Path $root -Force }
    Set-PrivateAcl -Path $root
    $relative = $fullPath.Substring([Math]::Min($fullPath.Length, $root.Length)).TrimStart('\')
    $current = $root
    foreach ($part in @($relative -split '[\\/]+' | Where-Object { $_ })) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            if (-not (Get-Item -LiteralPath $current -Force).PSIsContainer) { throw 'unsafe-managed-path' }
        } else { $null = New-Item -ItemType Directory -Path $current -Force }
        Set-PrivateAcl -Path $current
    }
}

function Test-SafeManagedRoot {
    $root = [IO.Path]::GetFullPath($script:AppRoot)
    $volume = [IO.Path]::GetPathRoot($root)
    if ([string]::Equals($root.TrimEnd('\'), $volume.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (Test-Path -LiteralPath $root) {
        $item = Get-Item -LiteralPath $root -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    return $true
}

function Write-PrivateJson {
    param([string]$Path, [object]$Value)
    New-PrivateDirectory -Path (Split-Path -Parent $Path)
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Item -LiteralPath $Path -Force
        if ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'unsafe-managed-path' }
    }
    $temp = Join-Path (Split-Path -Parent $Path) ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 10 -Compress), (New-Object Text.UTF8Encoding($false)))
    Set-PrivateAcl -Path $temp
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, $null) } else { [IO.File]::Move($temp, $Path) }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-Root {
    New-PrivateDirectory -Path $script:AppRoot
    return $script:AppRoot
}

function Get-ActiveRuntime {
    $active = Read-JsonFile -Path $script:ActivePath
    if ($null -eq $active -or [int]$active.schemaVersion -ne 1 -or -not $active.runtimePath) { return $null }
    $candidate = Join-Path $script:RuntimeRoot ([string]$active.runtimePath)
    $base = [IO.Path]::GetFullPath($script:RuntimeRoot).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $null }
    if ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
    return [pscustomobject]@{ Path = $full; Metadata = $active }
}

function Test-PidAlive {
    param([object]$Id)
    if ($null -eq $Id -or [int]$Id -le 0) { return $false }
    try { $null = Get-Process -Id ([int]$Id) -ErrorAction Stop; return $true } catch { return $false }
}

function Test-LoopbackHttp {
    param([int]$PortNumber)
    try {
        $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$PortNumber/")
        $request.Proxy = $null; $request.Timeout = 700; $request.AllowAutoRedirect = $false
        $request.Host = "127.0.0.1:$PortNumber"
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode; $response.Close()
        return [pscustomobject]@{ Healthy = ($code -in @(200,301,302,303,307,308,401)); Status = $code }
    } catch [Net.WebException] {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode; $_.Exception.Response.Close()
            return [pscustomobject]@{ Healthy = ($code -in @(301,302,303,307,308,401)); Status = $code }
        }
        return [pscustomobject]@{ Healthy = $false; Status = $null }
    } catch { return [pscustomobject]@{ Healthy = $false; Status = $null } }
}

function Invoke-Control {
    param([string]$ControlAction, [int]$TimeoutMs = 1500)
    $info = Read-JsonFile -Path $script:SupervisorPath
    if ($null -eq $info -or -not $info.controlPort -or -not $info.controlNonce) { throw 'supervisor-unavailable' }
    $client = New-Object Net.Sockets.TcpClient
    $client.ReceiveTimeout = $TimeoutMs; $client.SendTimeout = $TimeoutMs
    try {
        $client.Connect('127.0.0.1', [int]$info.controlPort)
        $stream = $client.GetStream()
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)), 1024, $true)
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)), $false, 1024, $true)
        $writer.WriteLine((@{ action = $ControlAction; nonce = [string]$info.controlNonce } | ConvertTo-Json -Compress))
        $writer.Flush()
        $line = $reader.ReadLine()
        if (-not $line) { throw 'supervisor-unavailable' }
        $result = $line | ConvertFrom-Json
        if (-not $result.ok) { throw ([string]$result.code) }
        return $result
    } finally { $client.Dispose() }
}

function Get-Status {
    $pins = Get-Pins
    $active = Get-ActiveRuntime
    $state = Read-JsonFile -Path $script:StatePath
    $sup = Read-JsonFile -Path $script:SupervisorPath
    $runtimeState = 'stopped'; $healthy = $false; $httpCode = $null
    $supervisorId = if ($sup -and $sup.pid) { [int]$sup.pid } elseif ($state -and $state.supervisorPid) { [int]$state.supervisorPid } else { 0 }
    if (Test-PidAlive $supervisorId) {
        try {
            $control = Invoke-Control -ControlAction 'status' -TimeoutMs 700
            $probe = Test-LoopbackHttp -PortNumber (Get-PortValue)
            $healthy = [bool]$probe.Healthy; $httpCode = $probe.Status
            if ($healthy -and $control.running) { $runtimeState = 'running' } else { $runtimeState = 'starting-or-unhealthy' }
        } catch { $runtimeState = 'crashed-or-stale' }
    } elseif ($sup) { $runtimeState = 'crashed-or-stale' }
    $installed = ($null -ne $active -and [string]$active.Metadata.version -eq [string]$pins.harness.version)
    $overall = if (-not $installed) { 'not-installed' } elseif ($runtimeState -eq 'running') { 'running' } elseif ($runtimeState -eq 'crashed-or-stale') { 'degraded' } else { 'installed' }
    $route = if ($state -and $state.authRoute) { [string]$state.authRoute } else { 'unknown' }
    $dshHomePath = if ($route -in @('account','api')) { Join-Path $script:HomesRoot $route } else { '' }
    $credentialFile = if ($dshHomePath) { Test-Path -LiteralPath (Join-Path $dshHomePath '.credentials.yaml') -PathType Leaf } else { $false }
    $accountAuth = if ($route -eq 'account' -and $credentialFile) { 'credential file present; session unknown' } else { 'unknown' }
    $apiCredential = if ($route -eq 'api' -and $credentialFile) { 'credential file present; validity unknown' } elseif ($route -eq 'api') { 'not observed' } else { 'not-selected' }
    $memory = Get-AvailableMemoryBytes
    $memoryBudget = if ($null -eq $memory) { 'unknown' } elseif ($memory -ge $script:MinAvailableMemoryBytes) { 'sufficient' } else { 'insufficient' }
    $next = switch ($overall) { 'not-installed' { 'install' } 'degraded' { 'doctor' } 'running' { 'open' } default { 'choose workspace and auth route, then start' } }
    $result = New-Result -Command 'status' -Ok ($installed -and $runtimeState -ne 'crashed-or-stale') -State $overall -Reason $(if ($installed) { '' } else { 'runtime-not-installed' }) -NextAction $next -Extra @{
        installed = $installed; installedVersion = if ($active) { [string]$active.Metadata.version } else { '' }
        runtimeState = $runtimeState; workspace = if ($state) { [string]$state.requestedWorkspace } else { '' }
        workspaceSelection = if ($state -and $state.workspaceSelection) { [string]$state.workspaceSelection } else { 'not-selected' }
        authRoute = $route; accountAuth = $accountAuth; apiCredential = $apiCredential
        processId = if ($runtimeState -eq 'running') { $supervisorId } else { $null }
        availableMemoryBytes = $memory; requiredMemoryBytes = $script:MinAvailableMemoryBytes; memoryBudget = $memoryBudget
        healthCheck = @{ loopbackHttp = $httpCode; healthy = $healthy }
        dshHome = $dshHomePath; proxyRoute = 'blocked until request-bound grants are available'
    }
    return $result
}

function Get-Plan {
    $pins = Get-Pins
    $platformId = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $resource = $pins.node.platforms.'win32-x64'
    $free = 0L
    try { $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($script:AppRoot)); $free = [long]$drive.AvailableFreeSpace } catch { }
    $memory = Get-AvailableMemoryBytes
    $rootSafe = Test-SafeManagedRoot
    $supported = ($env:OS -eq 'Windows_NT' -and $platformId -eq 'X64' -and $null -ne $resource -and $rootSafe)
    $enoughDisk = $free -ge 536870912L
    $memoryBudget = if ($null -eq $memory) { 'unknown' } elseif ($memory -ge $script:MinAvailableMemoryBytes) { 'sufficient' } else { 'insufficient' }
    $ready = $supported -and $enoughDisk -and $memoryBudget -eq 'sufficient'
    $reason = if (-not $rootSafe) { 'unsafe-managed-root' } elseif (-not $supported) { 'unsupported-platform-or-architecture' } elseif (-not $enoughDisk) { 'insufficient-disk-space' } elseif ($null -eq $memory) { 'memory-status-unavailable' } elseif (-not $ready) { 'insufficient-memory' } else { '' }
    $next = if (-not $rootSafe) { 'choose a dedicated non-reparse PZ_DSH_ROOT' } elseif ($ready) { 'install' } elseif ($null -eq $memory -or $memory -lt $script:MinAvailableMemoryBytes) { 'use Windows x64 with at least 512 MiB free and 2 GiB available memory' } else { 'use Windows x64 with at least 512 MiB free' }
    return (New-Result -Command 'plan' -Ok $ready -State $(if ($ready) { 'ready' } else { 'blocked' }) -Reason $reason -NextAction $next -Extra @{
        platform = 'windows'; architecture = $platformId; nodeVersion = [string]$pins.node.version
        nodeArchive = [string]$resource.url; nodeSha256 = [string]$resource.sha256
        packageIntegrity = [string]$pins.harness.integrity; registry = [string]$pins.harness.registry
        freeBytes = $free; requiredFreeBytes = 536870912L; availableMemoryBytes = $memory
        requiredMemoryBytes = $script:MinAvailableMemoryBytes; memoryBudget = $memoryBudget
        mutatesHost = $false; startsRuntime = $false
    })
}

function Get-Mutex {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $digest = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($script:AppRoot))).Replace('-', '').Substring(0,16)
    return New-Object Threading.Mutex($false, "Local\PhaseZeroDSH-$identity-$digest")
}

function Test-ZipSafe {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace('\','/')
            $parts = $name.Split('/')
            if ([IO.Path]::IsPathRooted($name) -or $name -match '^[A-Za-z]:' -or $parts -contains '..' -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'archive-path-unsafe' }
        }
    } finally { $zip.Dispose() }
}

function Quote-ProcessArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Install-Runtime {
    param([bool]$Update = $false)
    $pins = Get-Pins
    $plan = Get-Plan
    if (-not $plan.ok) { throw ([string]$plan.reason) }
    $mutex = Get-Mutex
    if (-not $mutex.WaitOne(0)) { throw 'operation-busy' }
    try {
        $state = Read-JsonFile -Path $script:StatePath
        if ($state -and (Test-PidAlive $state.supervisorPid)) { throw 'runtime-running' }
        $current = Get-ActiveRuntime
        if ($current -and -not $Update) { return (Get-Status) }
        New-PrivateDirectory -Path $script:RuntimeRoot
        $stage = Join-Path $script:RuntimeRoot ('.stage-' + [guid]::NewGuid().ToString('N'))
        New-PrivateDirectory -Path $stage
        try {
            $resource = $pins.node.platforms.'win32-x64'
            $archive = Join-Path $stage 'node.zip'
            try { Invoke-WebRequest -Uri ([string]$resource.url) -OutFile $archive -UseBasicParsing -TimeoutSec 90 }
            catch { Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue; throw 'download-failed' }
            $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -ne ([string]$resource.sha256).ToLowerInvariant()) { throw 'integrity-mismatch' }
            Test-ZipSafe -Path $archive
            $extract = Join-Path $stage 'extract'; New-PrivateDirectory -Path $extract
            Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
            $nodeSource = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
            if (-not $nodeSource -or -not (Test-Path -LiteralPath (Join-Path $nodeSource.FullName 'node.exe'))) { throw 'node-archive-invalid' }
            $nodeRoot = Join-Path $stage 'node'; Move-Item -LiteralPath $nodeSource.FullName -Destination $nodeRoot
            Remove-Item -LiteralPath $archive,$extract -Recurse -Force
            $app = Join-Path $stage 'app'; New-PrivateDirectory -Path $app
            Copy-Item -LiteralPath (Join-Path $script:PackagePath 'package.json') -Destination $app
            Copy-Item -LiteralPath (Join-Path $script:PackagePath 'package-lock.json') -Destination $app
            $npmUserConfig = Join-Path $stage 'npm-userconfig'
            $npmGlobalConfig = Join-Path $stage 'npm-globalconfig'
            [IO.File]::WriteAllText($npmUserConfig, '', (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText($npmGlobalConfig, '', (New-Object Text.UTF8Encoding($false)))
            $node = Join-Path $nodeRoot 'node.exe'; $npm = Join-Path $nodeRoot 'npm.cmd'
            $envBefore = @{}; Get-ChildItem Env: | ForEach-Object { $envBefore[$_.Name] = $_.Value }
            try {
                Get-ChildItem Env: | Where-Object { Test-SensitiveEnvironmentName -Name $_.Name } | ForEach-Object { Remove-Item -LiteralPath ("Env:" + $_.Name) -ErrorAction SilentlyContinue }
                $env:npm_config_cache = Join-Path $stage 'npm-cache'
                $env:npm_config_update_notifier = 'false'; $env:npm_config_audit = 'false'; $env:npm_config_fund = 'false'; $env:CI = '1'
                $env:PATH = $nodeRoot + ';' + $env:PATH
                $version = (& $node --version 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0 -or $version -ne ('v' + [string]$pins.node.version)) { throw 'node-version-mismatch' }
                Push-Location $app
                try {
                    $null = @(& $npm ci --ignore-scripts --no-audit --no-fund --userconfig $npmUserConfig --globalconfig $npmGlobalConfig --registry ([string]$pins.harness.registry) 2>&1)
                    if ($LASTEXITCODE -ne 0) { throw 'registry-or-dependency-failed' }
                    $null = @(& $npm rebuild --foreground-scripts --no-audit --no-fund --userconfig $npmUserConfig --globalconfig $npmGlobalConfig --registry ([string]$pins.harness.registry) node-pty koffi '@deepseek-ai/dsh-subprocess-local' 2>&1)
                    if ($LASTEXITCODE -ne 0) { throw 'allowed-build-hook-failed' }
                } finally { Pop-Location }
            } finally {
                foreach ($name in @((Get-ChildItem Env: | Select-Object -ExpandProperty Name))) { Remove-Item -LiteralPath ("Env:" + $name) -ErrorAction SilentlyContinue }
                foreach ($name in $envBefore.Keys) { Set-Item -Path ("Env:" + $name) -Value $envBefore[$name] }
            }
            $lock = Get-Content -LiteralPath (Join-Path $app 'package-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $entry = $lock.packages.'node_modules/@deepseek-ai/dsh'
            if ($entry.version -ne $pins.harness.version -or $entry.integrity -ne $pins.harness.integrity) { throw 'package-integrity-mismatch' }
            $pkg = Get-Content -LiteralPath (Join-Path $app 'node_modules\@deepseek-ai\dsh\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pkg.version -ne $pins.harness.version -or $pkg.license -ne 'MIT') { throw 'package-metadata-mismatch' }
            $finalName = 'dsh-' + [string]$pins.harness.version + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
            $final = Join-Path $script:RuntimeRoot $finalName
            Move-Item -LiteralPath $stage -Destination $final
            $active = @{ schemaVersion = 1; version = [string]$pins.harness.version; nodeVersion = [string]$pins.node.version; runtimePath = $finalName; installedAt = [DateTime]::UtcNow.ToString('o'); sourceCommit = [string]$pins.harness.commit }
            try { Write-PrivateJson -Path $script:ActivePath -Value $active }
            catch {
                $selected = Get-ActiveRuntime
                if (-not $selected -or $selected.Path -ne [IO.Path]::GetFullPath($final)) {
                    Remove-Item -LiteralPath $final -Recurse -Force -ErrorAction SilentlyContinue
                }
                throw
            }
            return (Get-Status)
        } catch {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
            throw
        }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Test-PortOccupied {
    param([int]$PortNumber)
    $client = New-Object Net.Sockets.TcpClient
    try { $task = $client.ConnectAsync('127.0.0.1', $PortNumber); return $task.Wait(200) -and $client.Connected } catch { return $false } finally { $client.Dispose() }
}

function Get-LaunchEnvironment {
    param([string]$DshHome)
    $envMap = @{}
    Get-ChildItem Env: | ForEach-Object {
        if (-not (Test-SensitiveEnvironmentName -Name $_.Name)) { $envMap[$_.Name] = $_.Value }
    }
    $envMap['DSH_HOME'] = $DshHome; $envMap['DSH_TELEMETRY_DISABLED'] = '1'
    $envMap['DSH_PERMISSION_MODE'] = 'workspace-write'
    $envMap['NODE_OPTIONS'] = '--max-old-space-size=2048'
    return $envMap
}

function Start-Runtime {
    if ($AuthRoute -notin @('account','api')) { throw 'auth-route-required' }
    if (-not $Workspace -or -not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw 'workspace-unavailable' }
    $workspaceFull = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Workspace).Path)
    $active = Get-ActiveRuntime
    if (-not $active -or $active.Metadata.version -ne (Get-Pins).harness.version) { throw 'runtime-not-installed' }
    $mutex = Get-Mutex
    if (-not $mutex.WaitOne(0)) { throw 'operation-busy' }
    try {
        $state = Read-JsonFile -Path $script:StatePath
        if ($state -and (Test-PidAlive $state.supervisorPid)) {
            try { $null = Invoke-Control -ControlAction 'status' -TimeoutMs 700 }
            catch { throw 'supervisor-unhealthy' }
            if ($state.authRoute -ne $AuthRoute -or $state.requestedWorkspace -ne $workspaceFull) { throw 'different-route-running-stop-first' }
            return (Get-Status)
        }
        $memory = Get-AvailableMemoryBytes
        if ($null -eq $memory) { throw 'memory-status-unavailable' }
        if ($memory -lt $script:MinAvailableMemoryBytes) { throw 'insufficient-memory' }
        $portValue = Get-PortValue
        if (Test-PortOccupied -PortNumber $portValue) { throw 'port-occupied' }
        $launchDir = Join-Path (Join-Path $script:HomesRoot $AuthRoute) 'launch'
        New-PrivateDirectory -Path $launchDir
        $state = @{ schemaVersion = 1; requestedWorkspace = $workspaceFull; workspace = ''; workspaceSelection = 'confirm in Harness Web UI'; authRoute = $AuthRoute; state = 'starting'; port = $portValue; profile = 'web'; supervisorPid = $null; sandboxPolicy = 'workspace-write + ask (requested)'; sandboxEnforcement = 'unknown'; plugins = @(); updatedAt = [DateTime]::UtcNow.ToString('o') }
        Write-PrivateJson -Path $script:StatePath -Value $state
        $engine = (Get-Process -Id $PID).Path
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Action','supervise','-InternalSupervisor','-Workspace',$launchDir,'-RequestedWorkspace',$workspaceFull,'-AuthRoute',$AuthRoute,'-Port',[string]$portValue,'-Runtime',$active.Path)
        $argumentLine = ($arguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' '
        $process = Start-Process -FilePath $engine -ArgumentList $argumentLine -WorkingDirectory $launchDir -WindowStyle Hidden -PassThru
        $state.supervisorPid = [int]$process.Id; Write-PrivateJson -Path $script:StatePath -Value $state
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    $deadline = [DateTime]::UtcNow.AddSeconds($script:ReadyTimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        if (-not (Test-PidAlive $process.Id)) { throw 'runtime-crashed' }
        $status = Get-Status
        if ($status.state -eq 'running') { return $status }
    } while ([DateTime]::UtcNow -lt $deadline)
    try { $null = Invoke-Control -ControlAction 'stop' } catch { }
    throw 'health-timeout'
}

function Redact-Line {
    param([string]$Line)
    $line = [regex]::Replace($Line, '([?&](?:token|launchToken)=)[^&\s"'']+', '$1[redacted]', 'IgnoreCase')
    $line = [regex]::Replace($line, '(?i)(["'']?\b(?:deepseek[\s_-]+)?(?:api[\s_-]*key|access[\s_-]*token|refresh[\s_-]*token|launch[\s_-]*token|client[\s_-]*secret|secret|password|cookie|authorization|bearer|token)\b["'']?\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;}]+)', '$1[redacted]')
    $line = [regex]::Replace($line, '(?i)\bBearer\s+\S+', 'Bearer [redacted]')
    $line = [regex]::Replace($line, '\bsk-[A-Za-z0-9_-]{8,}', '[redacted-api-key]')
    return $line
}

function Start-Supervisor {
    param([string]$LaunchDirectory, [string]$WorkspaceForUi, [string]$Route, [int]$PortNumber, [string]$RuntimeDirectory)
    New-PrivateDirectory -Path $LaunchDirectory
    New-PrivateDirectory -Path (Split-Path -Parent $script:LogPath)
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $controlPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $nonceBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($nonceBytes); $rng.Dispose()
    $nonce = [BitConverter]::ToString($nonceBytes).Replace('-', '').ToLowerInvariant()
    Write-PrivateJson -Path $script:SupervisorPath -Value @{ schemaVersion = 1; pid = $PID; port = $PortNumber; controlPort = $controlPort; controlNonce = $nonce; startedAt = [DateTime]::UtcNow.ToString('o'); ready = $false }
    $node = Join-Path $RuntimeDirectory 'node\node.exe'
    $dsh = Join-Path $RuntimeDirectory 'app\node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (-not (Test-Path -LiteralPath $node -PathType Leaf) -or -not (Test-Path -LiteralPath $dsh -PathType Leaf)) { throw 'runtime-incomplete' }
    $routeHome = Join-Path $script:HomesRoot $Route
    New-PrivateDirectory -Path $routeHome
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = ((@($dsh,'--profile','web','--host','127.0.0.1','--port',[string]$PortNumber,'--no-open') | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
    $psi.WorkingDirectory = $LaunchDirectory; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    foreach ($key in @($psi.EnvironmentVariables.Keys)) {
        if (Test-SensitiveEnvironmentName -Name ([string]$key)) { $psi.EnvironmentVariables.Remove([string]$key) }
    }
    $launchEnvironment = Get-LaunchEnvironment -DshHome $routeHome
    foreach ($key in $launchEnvironment.Keys) { $psi.EnvironmentVariables[[string]$key] = $launchEnvironment[$key] }
    $script:Port = $PortNumber; $script:LaunchUrl = ''; $script:SupervisorReady = $false
    $child = New-Object Diagnostics.Process; $child.StartInfo = $psi
    $handler = [Diagnostics.DataReceivedEventHandler]{
        param($sender, $eventArgs)
        if ($null -eq $eventArgs.Data) { return }
        $line = [string]$eventArgs.Data
        if ($line -match '(?i)dsh web:' -and $line -match 'https?://[^\s"'']+') {
            $candidate = $matches[0].TrimEnd('.,;)')
            try {
                $uri = [Uri]$candidate
                if ($uri.Host -in @('127.0.0.1','localhost') -and $uri.Port -eq $script:Port -and $uri.Query -match '(?i)(token|launchToken)=') {
                    $script:LaunchUrl = $candidate; $script:SupervisorReady = $true
                    $info = Read-JsonFile -Path $script:SupervisorPath
                    if ($info) { $info.ready = $true; Write-PrivateJson -Path $script:SupervisorPath -Value $info }
                    $state = Read-JsonFile -Path $script:StatePath
                    if ($state) { $state.state = 'running'; $state.updatedAt = [DateTime]::UtcNow.ToString('o'); Write-PrivateJson -Path $script:StatePath -Value $state }
                }
            } catch { }
        }
        [IO.File]::AppendAllText($script:LogPath, (Redact-Line $line) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    }
    $child.add_OutputDataReceived($handler); $child.add_ErrorDataReceived($handler)
    if (-not $child.Start()) { throw 'runtime-start-failed' }
    $child.BeginOutputReadLine(); $child.BeginErrorReadLine()
    $stopRequested = $false
    try {
        while (-not $child.HasExited -and -not $stopRequested) {
            if ($listener.Pending()) {
                $client = $listener.AcceptTcpClient()
                try {
                    $reader = New-Object IO.StreamReader($client.GetStream())
                    $writer = New-Object IO.StreamWriter($client.GetStream()); $writer.AutoFlush = $true
                    $line = $reader.ReadLine(); $request = $line | ConvertFrom-Json
                    if (-not [string]::Equals([string]$request.nonce, $nonce, [StringComparison]::Ordinal)) { $reply = @{ ok = $false; code = 'unauthorized' } }
                    elseif ($request.action -eq 'status') { $reply = @{ ok = $true; ready = $script:SupervisorReady; running = -not $child.HasExited } }
                    elseif ($request.action -eq 'open') {
                        $url = if ($script:LaunchUrl) { $script:LaunchUrl } else { "http://127.0.0.1:$PortNumber/" }
                        try {
                            Start-Process -FilePath $url | Out-Null
                            $script:LaunchUrl = ''; $reply = @{ ok = $true; opened = $true }
                        } catch { $reply = @{ ok = $false; code = 'browser-unavailable' } }
                    }
                    elseif ($request.action -eq 'stop') {
                        try { & taskkill.exe /PID $child.Id /T /F | Out-Null } catch { }
                        $stopRequested = $true; $reply = @{ ok = $true; stopping = $true }
                    } else { $reply = @{ ok = $false; code = 'unknown-action' } }
                    $writer.WriteLine(($reply | ConvertTo-Json -Compress))
                } catch { }
                finally { if ($client) { $client.Dispose() } }
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not $child.HasExited) { try { & taskkill.exe /PID $child.Id /T /F | Out-Null } catch { } }
        $state = Read-JsonFile -Path $script:StatePath
        if ($state) { $state.state = if ($stopRequested) { 'stopped' } else { 'crashed' }; $state.updatedAt = [DateTime]::UtcNow.ToString('o'); Write-PrivateJson -Path $script:StatePath -Value $state }
    } finally { $listener.Stop(); $child.Dispose() }
}

function Stop-Runtime {
    $mutex = Get-Mutex
    if (-not $mutex.WaitOne(0)) { throw 'operation-busy' }
    try {
        try { return (Invoke-Control -ControlAction 'stop') }
        catch {
            $state = Read-JsonFile -Path $script:StatePath
            if ($state -and (Test-PidAlive $state.supervisorPid)) { throw 'supervisor-unreachable-runtime-preserved' }
            return @{ ok = $true; state = 'stopped'; reason = 'stale supervisor record; no process was killed' }
        }
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

function Get-Doctor {
    $status = Get-Status
    $checks = @(
        @{ id = 'pinned-lock'; state = if (Test-Path (Join-Path $script:PackagePath 'package-lock.json')) { 'ok' } else { 'missing' } },
        @{ id = 'runtime'; state = if ($status.installed) { 'ok' } else { 'missing' } },
        @{ id = 'loopback'; state = $status.runtimeState; httpStatus = $status.healthCheck.loopbackHttp },
        @{ id = 'workspace'; state = if ($status.workspace) { 'requested; confirm in Harness Web UI' } else { 'not-selected' } },
        @{ id = 'sandbox-enforcement'; state = 'unknown'; reason = 'no live sandbox probe; file policy does not restrict network or processes' },
        @{ id = 'account-session'; state = 'unknown' }, @{ id = 'api-validity-and-quota'; state = 'unknown' },
        @{ id = 'proxy-and-9router'; state = 'blocked; request-bound grants unavailable' }, @{ id = 'autostart'; state = 'disabled' }
        @{ id = 'memory-budget'; state = $status.memoryBudget; availableBytes = $status.availableMemoryBytes; requiredBytes = $status.requiredMemoryBytes }
    )
    $status.command = 'doctor'; $status.checks = $checks; $status.logPath = $script:LogPath
    if ($status.memoryBudget -eq 'insufficient') { $status.ok = $false; $status.state = 'degraded'; $status.reason = 'insufficient-memory' }
    $status.nextAction = 'review unknown account and sandbox gates before using tools'
    return $status
}

function Assert-NoReparseTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = Get-Item -LiteralPath $Path -Force
    if (($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'unsafe-managed-path' }
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'unsafe-managed-path' }
    }
}

function Uninstall-Runtime {
    if (-not (Test-SafeManagedRoot)) { throw 'unsafe-managed-root' }
    $null = Stop-Runtime
    if (Test-Path -LiteralPath $script:RuntimeRoot) {
        Assert-NoReparseTree -Path $script:RuntimeRoot
        Remove-Item -LiteralPath $script:RuntimeRoot -Recurse -Force
    }
    foreach ($path in @($script:ActivePath,$script:StatePath,$script:SupervisorPath,$script:LogPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'unsafe-managed-path' }
            Remove-Item -LiteralPath $path -Force
        }
    }
    return (New-Result -Command 'uninstall' -Ok $true -State 'removed' -Reason 'runtime removed; DSH_HOME and workspace data preserved' -NextAction 'install when needed' -Extra @{ installed = $false; preservedData = @((Join-Path $script:HomesRoot 'account'),(Join-Path $script:HomesRoot 'api')) })
}

function Invoke-Action {
    switch ($Action.ToLowerInvariant()) {
        'plan' { return (Get-Plan) }
        'status' { return (Get-Status) }
        'doctor' { return (Get-Doctor) }
        'install' { return (Install-Runtime) }
        'update' { return (Install-Runtime -Update $true) }
        'start' { return (Start-Runtime) }
        'open' { $null = Invoke-Control -ControlAction 'open'; $result = Get-Status; $result.command = 'open'; $result.opened = $true; $result.reason = 'authenticated local Web UI handoff requested'; return $result }
        'stop' { $stop = Stop-Runtime; $result = Get-Status; $result.command = 'stop'; $result.reason = [string]$stop.reason; $result.nextAction = 'start when needed'; return $result }
        'uninstall' { return (Uninstall-Runtime) }
        default { throw 'unknown-command' }
    }
}

if ($InternalSupervisor) {
    try { Start-Supervisor -LaunchDirectory $Workspace -WorkspaceForUi $RequestedWorkspace -Route $AuthRoute -PortNumber $Port -RuntimeDirectory $Runtime; exit 0 }
    catch {
        try { [IO.File]::AppendAllText($script:LogPath, "PhaseZero supervisor error: $($_.Exception.GetType().Name)`n") } catch { }
        exit 1
    }
}

$commandName = $Action.ToLowerInvariant()
if ($commandName -eq 'supervise') { $commandName = 'start' }
try {
    $result = Invoke-Action
    # Plan/status are reports; JSON carries blocked/degraded state. Keep their
    # process exit code successful when the diagnostic itself completed.
    $exitCode = if ($Action.ToLowerInvariant() -in @('plan','status')) { 0 } elseif ($result.ok -eq $false) { 1 } else { 0 }
} catch {
    if ($env:PZ_DSH_DEBUG) { [Console]::Error.WriteLine($_.Exception.ToString() + "`n" + $_.ScriptStackTrace) }
    $code = [string]$_.Exception.Message
    if ($code -notmatch '^[a-z0-9-]{3,64}$') { $code = 'operation-failed' }
    $next = switch ($code) {
        'runtime-not-installed' { 'install' }
        'port-occupied' { 'select another PZ_DSH_PORT or stop its owner' }
        'workspace-unavailable' { 'choose an existing folder' }
        'auth-route-required' { 'choose account or api explicitly' }
        'registry-or-dependency-failed' { 'check registry and retry; prior version remains active' }
        'integrity-mismatch' { 'keep current runtime; review pinned checksum' }
        'runtime-crashed' { 'doctor; inspect redacted local log' }
        'health-timeout' { 'doctor; inspect redacted local log' }
        'different-route-running-stop-first' { 'stop current runtime, then choose the other route' }
        'supervisor-unreachable-runtime-preserved' { 'doctor; no process was killed' }
        default { 'doctor' }
    }
    $result = New-Result -Command $commandName -Ok $false -State 'blocked' -Reason $code -NextAction $next -Extra @{ error = @{ code = $code; message = $code; errorType = $_.Exception.GetType().Name } }
    $exitCode = 2
}
exit (Write-JsonResult -Value $result -Code $exitCode)
