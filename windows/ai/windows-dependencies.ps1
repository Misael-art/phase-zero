# Shared preparer/Autofix contract. Load from prepare-host.ps1 after bootstrap-tools.

function Get-PhaseZeroDependencyTarget {
    $windowsRoot = [Environment]::GetFolderPath('Windows')
    $systemRoot = [IO.Path]::GetPathRoot($windowsRoot)
    $drive = [IO.DriveInfo]::new($systemRoot)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $machine = Read-BootstrapDependencyRegistry -Key 'SOFTWARE\Microsoft\Cryptography' -View Registry64 -Names MachineGuid
    $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $systemRoot.TrimEnd('\')) -OperationTimeoutSec 5 -ErrorAction Stop
    $hardware = Get-CimInstance Win32_ComputerSystemProduct -OperationTimeoutSec 5 -ErrorAction Stop
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop
    $boot = $os.LastBootUpTime
    $windowsId = ''; $hostId = ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        if ($machine -and $machine.MachineGuid -and $disk.VolumeSerialNumber) {
            $key = '{0}|{1}' -f $machine.MachineGuid, $disk.VolumeSerialNumber
            $windowsId = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-', '')
        }
        if ($hardware.UUID -and $hardware.UUID -notmatch '^([0Ff-])+$') {
            $hostId = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$hardware.UUID))).Replace('-', '')
        }
    } finally { $sha.Dispose() }
    [pscustomobject]@{
        windowsRoot = $windowsRoot; systemDrive = $systemRoot; windowsId = $windowsId; hostId = $hostId
        volumeLabel = $drive.VolumeLabel; freeBytes = $drive.AvailableFreeSpace; architecture = Get-BootstrapWindowsArchitecture
        build = $os.BuildNumber; boot = if ($boot) { $boot.ToUniversalTime().ToString('o') } else { '' }
        caller = $identity.User.Value; elevated = Test-IsAdmin
        pendingRestart = @(Get-BootstrapPendingRebootReasons)
        winget = [bool](Resolve-CommandPath -Name winget)
    }
}

function Get-PhaseZeroStoreDependencies {
    try {
        if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { throw 'Get-AppxPackage indisponivel.' }
        $packages = @(Get-AppxPackage -PackageTypeFilter Framework -ErrorAction Stop |
            Where-Object { $_.Name -match '^Microsoft\.(VCLibs\.|DirectXRuntime|NET\.Native\.)' } |
            ForEach-Object {
                [pscustomobject]@{ name = $_.Name; version = [string]$_.Version; architecture = [string]$_.Architecture; health = [string]$_.Status }
            })
        return [pscustomobject]@{ status = if ($packages.Count) { 'observed' } else { 'missing' }; scope = 'current-user'; packages = $packages; detail = '' }
    } catch {
        return [pscustomobject]@{ status = 'unknown'; scope = 'current-user'; packages = @(); detail = $_.Exception.Message }
    }
}

function Get-PhaseZeroDependencyDefinitions {
    $catalog = Get-BootstrapComponentCatalog
    $definitions = [ordered]@{}
    foreach ($entry in $catalog.Values) {
        if ($entry.PSObject.Properties['DependencyProbe']) { $definitions[$entry.Name] = $entry }
    }
    return $definitions
}

function Resolve-PhaseZeroDependencyRequirements {
    param([string]$RequirementFile, $Definitions, [string]$ApplicationArchitecture)
    $requirements = @{}
    if (-not $RequirementFile) { return $requirements }
    $file = Get-Item -LiteralPath $RequirementFile -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 1MB) { throw 'Escolha um arquivo de requisitos com ate 1 MiB.' }
    $arch = if ($ApplicationArchitecture) { $ApplicationArchitecture } else { Get-BootstrapWindowsArchitecture }
    if ($file.Extension -eq '.vcxproj') {
        $requirements['msvc-build-env'] = @{ version = ''; policy = 'minimum' }
        return $requirements
    }
    $document = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($file.Name -eq 'global.json') {
        $sdk = $document.PSObject.Properties['sdk']
        if (-not $sdk -or -not $sdk.Value.PSObject.Properties['version']) { throw 'global.json sem sdk.version.' }
        $version = ConvertTo-BootstrapDependencyVersion $sdk.Value.version
        if (-not $version) { throw 'SDK preview ou versao invalida. Selecione o SDK na lista ou siga o arquivo do projeto.' }
        $id = "dotnet-sdk-$($version.Major)-$arch"
        if (-not $Definitions.Contains($id)) { throw "SDK $($version.Major) ($arch) fora do catalogo." }
        $roll = $sdk.Value.PSObject.Properties['rollForward']
        # Broader policies accept compatible SDKs in the requested major/minor.
        $policy = if (-not $roll -or $roll.Value -in @('patch','latestPatch')) { 'sdk-band' }
            elseif ($roll.Value -eq 'disable') { 'exact' }
            elseif ($roll.Value -in @('feature','latestFeature','minor','latestMinor','major','latestMajor')) { 'minimum' }
            else { throw "Politica rollForward desconhecida: $($roll.Value)." }
        $requirements[$id] = @{ version = [string]$sdk.Value.version; policy = $policy }
    } elseif ($file.Name -like '*.runtimeconfig.json') {
        $options = $document.PSObject.Properties['runtimeOptions']
        if (-not $options -or -not $options.Value) { throw 'runtimeconfig.json sem runtimeOptions.' }
        $roll = $options.Value.PSObject.Properties['rollForward']
        $patch = $options.Value.PSObject.Properties['applyPatches']
        foreach ($field in 'framework', 'frameworks') {
            $frameworks = $options.Value.PSObject.Properties[$field]
            if (-not $frameworks) { continue }
            foreach ($framework in @($frameworks.Value)) {
                $family = @{ 'Microsoft.NETCore.App' = 'runtime'; 'Microsoft.WindowsDesktop.App' = 'desktop' }[[string]$framework.name]
                if (-not $family) { throw "Framework fora do catalogo: $($framework.name)." }
                $version = ConvertTo-BootstrapDependencyVersion $framework.version
                if (-not $version) { throw "Versao fora do catalogo: $($framework.version)." }
                $id = "dotnet-$family-$($version.Major)-$arch"
                if (-not $Definitions.Contains($id)) { throw "Runtime $($version.Major) ($arch) fora do catalogo." }
                if ($requirements.ContainsKey($id)) { throw "Requisitos repetidos para $id." }
                $policy = if (($roll -and $roll.Value -eq 'Disable') -or ($patch -and $patch.Value -eq $false)) { 'exact' } else { 'minimum' }
                $requirements[$id] = @{ version = [string]$framework.version; policy = $policy }
            }
        }
        if (-not $requirements.Count) { throw 'Nenhum framework compartilhado declarado. Confira se o aplicativo usa um runtime proprio.' }
    } else {
        if (-not $document.PSObject.Properties['schemaVersion'] -or $document.schemaVersion -ne 1 -or -not $document.PSObject.Properties['requirements']) {
            throw 'Use global.json, runtimeconfig.json, .vcxproj ou um manifesto PhaseZero schemaVersion 1.'
        }
        foreach ($requirement in @($document.requirements)) {
            $id = [string]$requirement.id
            if (-not $Definitions.Contains($id) -or $requirements.ContainsKey($id)) { throw "Requisito desconhecido ou repetido: $id." }
            $version = $requirement.PSObject.Properties['minimumVersion']
            $minimum = if ($version) { [string]$version.Value } else { '' }
            if ($minimum -and (-not $Definitions[$id].MinimumVersion -or -not (ConvertTo-BootstrapDependencyVersion $minimum))) {
                throw "Versao minima invalida para $id."
            }
            $requirements[$id] = @{ version = $minimum; policy = 'minimum' }
        }
    }
    return $requirements
}

function Get-PhaseZeroDependencyStatus {
    param($Definition, $Requirements)
    $requirement = $Requirements[$Definition.Name]
    if (-not $requirement) { return (Get-BootstrapWindowsDependencyStatus -Definition $Definition) }
    return (Get-BootstrapWindowsDependencyStatus -Definition $Definition -MinimumVersion $requirement.version -ExactVersion:($requirement.policy -eq 'exact') -SdkBand:($requirement.policy -eq 'sdk-band'))
}

function Get-PhaseZeroDependencyReceiptPath {
    return (Join-Path (Get-BootstrapAiInstallRoot -InstallRoot '') 'logs\windows-dependencies.json')
}

function Get-PhaseZeroDependencyReport {
    param([string]$RequirementFile, [string]$ApplicationArchitecture, [switch]$OnlyRequired)

    $requirementHash = if ($RequirementFile) { (Get-FileHash -LiteralPath $RequirementFile -Algorithm SHA256 -ErrorAction Stop).Hash } else { '' }
    $definitions = Get-PhaseZeroDependencyDefinitions
    $requirements = Resolve-PhaseZeroDependencyRequirements -RequirementFile $RequirementFile -Definitions $definitions -ApplicationArchitecture $ApplicationArchitecture
    $target = $null; $targetError = ''
    try { $target = Get-PhaseZeroDependencyTarget } catch { $targetError = $_.Exception.Message }
    $previous = $null; $receiptError = ''
    try { $previous = Read-BootstrapJsonFile -Path (Get-PhaseZeroDependencyReceiptPath) } catch { $receiptError = $_.Exception.Message }
    if ($previous -and ($null -eq $target -or -not $target.windowsId -or $previous['windowsId'] -ne $target.windowsId)) { $previous = $null }
    $items = @(foreach ($definition in $definitions.Values) {
        $required = $requirements.ContainsKey($definition.Name)
        if ($OnlyRequired -and -not $required) { continue }
        $item = Get-PhaseZeroDependencyStatus -Definition $definition -Requirements $requirements
        if ($item.status -eq 'not-applicable' -and -not $required) { continue }
        if ($definition.PSObject.Properties['DependencyMajor'] -and $definition.DependencyMajor -in (6..9) -and $item.status -eq 'missing' -and -not $required) { continue }
        $item | Add-Member -NotePropertyName required -NotePropertyValue $required -PassThru
    })
    [pscustomobject]@{
        schemaVersion = 1; at = [DateTime]::UtcNow.ToString('o'); target = $target; targetError = $targetError
        requirementFile = $RequirementFile; requirementHash = $requirementHash; applicationArchitecture = $ApplicationArchitecture; items = $items; store = Get-PhaseZeroStoreDependencies
        previousRun = $previous; receiptError = $receiptError
    }
}

function Invoke-PhaseZeroDependencySelection {
    param([string[]]$Selected, [string]$RequirementFile, [switch]$AllowLargeDownloads, [string]$ExpectedTarget, [string]$ExpectedCaller, [string]$ApplicationArchitecture, [string]$ExpectedRequirementHash)

    $definitions = Get-PhaseZeroDependencyDefinitions
    if ($ExpectedRequirementHash -and (-not $RequirementFile -or (Get-FileHash -LiteralPath $RequirementFile -Algorithm SHA256 -ErrorAction Stop).Hash -ne $ExpectedRequirementHash)) {
        throw 'O arquivo de requisitos mudou. Verifique a selecao novamente.'
    }
    $requirements = Resolve-PhaseZeroDependencyRequirements -RequirementFile $RequirementFile -Definitions $definitions -ApplicationArchitecture $ApplicationArchitecture
    if (-not $Selected.Count) { throw 'Selecione ao menos uma dependencia.' }
    foreach ($name in $Selected) {
        if (-not $definitions.Contains($name)) { throw "Dependencia desconhecida: $name." }
    }
    $target = Get-PhaseZeroDependencyTarget
    if (-not $target.windowsId -or -not $target.boot -or ($ExpectedTarget -and $ExpectedTarget -ne $target.windowsId) -or
        ($ExpectedCaller -and $ExpectedCaller -ne $target.caller)) { throw 'Identidade do Windows ou da conta mudou. Reabra a verificacao na conta original.' }
    if ([IO.Path]::GetPathRoot($repoRoot) -ine $target.systemDrive) {
        throw 'Abra a copia do PhaseZero na instalacao Windows em execucao. Um cartao montado offline nao pode receber instaladores.'
    }
    $plan = Resolve-BootstrapComponents -SelectedComponents $Selected
    $queue = @($plan.ResolvedComponents | Where-Object { $definitions.Contains($_) })
    $receiptPath = Get-PhaseZeroDependencyReceiptPath
    $mutex = [Threading.Mutex]::new($false, 'Global\PhaseZeroWindowsDependencies')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Outra fila de dependencias do PhaseZero esta em execucao.' }
        $previous = Read-BootstrapJsonFile -Path $receiptPath
        if ($previous -and $previous['windowsId'] -eq $target.windowsId -and $previous['boot'] -eq $target.boot -and $previous['state'] -eq 'restart-required') {
            throw 'O instalador anterior pediu reinicio. Reinicie o Windows antes de retomar.'
        }
        $receipt = [ordered]@{
            schemaVersion = 1; state = 'running'; at = [DateTime]::UtcNow.ToString('o'); windowsId = $target.windowsId
            hostId = $target.hostId; boot = $target.boot; selected = @($Selected); requirementFile = $RequirementFile; applicationArchitecture = $ApplicationArchitecture
            log = $script:LogPath; results = [ordered]@{}
        }
        $state = @{ Completed = @{}; Winget = Resolve-CommandPath -Name winget; DependencyRequirements = $requirements }
        foreach ($name in $queue) { $receipt.results[$name] = @{ status = 'queued' } }
        Write-BootstrapJsonFile -Path $receiptPath -Value $receipt
        foreach ($name in $queue) {
            $definition = $definitions[$name]
            $before = Get-PhaseZeroDependencyStatus -Definition $definition -Requirements $requirements
            $receipt.results[$name] = @{ status = 'running'; before = $before.status; version = $before.version }
            Write-BootstrapJsonFile -Path $receiptPath -Value $receipt
            try {
                if ($before.status -ne 'satisfied') {
                    $blocked = @($definition.DependsOn | Where-Object { $receipt.results.Contains($_) -and $receipt.results[$_].status -ne 'verified' })
                    if ($blocked.Count) { throw "Requisito anterior pendente: $($blocked -join ', ')." }
                    if ($before.largeDownload -and -not $AllowLargeDownloads) { throw "Download grande. Autorize na selecao ou use a fonte oficial: $($before.officialUrl)" }
                    if ($definition.Kind -eq 'windows-dependency') {
                        Invoke-BootstrapComponent -Name $name -State $state
                    } else {
                        $requiredVersion = if ($requirements.ContainsKey($name)) { $requirements[$name].version } else { '' }
                        $null = Ensure-BootstrapWindowsDependency -Definition $definition -WingetPath $state.Winget -MinimumVersion $requiredVersion
                    }
                }
                $after = Get-PhaseZeroDependencyStatus -Definition $definition -Requirements $requirements
                if ($after.status -ne 'satisfied') { throw $after.detail }
                $receipt.results[$name] = @{ status = 'verified'; before = $before.status; after = $after.status; version = $after.version; detail = $after.detail }
            } catch {
                $info = Get-BootstrapBlockedErrorInfo -ErrorRecord $_
                $after = Get-PhaseZeroDependencyStatus -Definition $definition -Requirements $requirements
                $receipt.results[$name] = @{ status = 'pending'; before = $before.status; after = $after.status; version = $after.version; detail = $_.Exception.Message; blocker = [string]$info.Kind; exitCode = $_.Exception.Data['DependencyExitCode'] }
                if ($info.Kind -eq 'pending-reboot-msi') { $receipt.state = 'restart-required' }
            }
            Write-BootstrapJsonFile -Path $receiptPath -Value $receipt
            if ($receipt.state -eq 'restart-required' -or $receipt.results[$name]['blocker'] -in @('winget-msi-busy', 'installer-timeout', 'cancelled', 'winget-missing', 'elevation-required', 'download-unavailable')) { break }
        }
        if ($receipt.state -eq 'running') {
            $receipt.state = if (@($receipt.results.Values | Where-Object { $_.status -ne 'verified' }).Count) { 'pending' } else { 'verified' }
        }
        Write-BootstrapJsonFile -Path $receiptPath -Value $receipt
        return $receipt
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Start-PhaseZeroDependencyWorker {
    param([string]$EntryPoint, [string[]]$Selected, $Report, [switch]$AllowLargeDownloads)

    $ids = $Selected -join ','
    if ($ids -notmatch '^[a-z0-9-]+(,[a-z0-9-]+)*$') { throw 'Selecao invalida.' }
    $target = $Report.target
    if (-not $target -or -not $target.windowsId) { throw 'Identidade do Windows indisponivel. Verifique novamente.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $EntryPoint + '" -Action InstallDependencies -DependencyIds ' + $ids +
        ' -ExpectedTarget ' + $target.windowsId + ' -ExpectedCaller ' + $target.caller
    if ($Report.requirementFile) { $arguments += ' -RequirementFile "' + $Report.requirementFile + '"' }
    if ($Report.applicationArchitecture) { $arguments += ' -ApplicationArchitecture ' + $Report.applicationArchitecture }
    if ($Report.requirementHash) { $arguments += ' -ExpectedRequirementHash ' + $Report.requirementHash }
    if ($AllowLargeDownloads) { $arguments += ' -AllowLargeDownloads' }
    $exe = Join-Path (Get-BootstrapDependencySystemDirectory (Get-BootstrapWindowsArchitecture) (Get-BootstrapWindowsArchitecture)) 'WindowsPowerShell\v1.0\powershell.exe'
    $start = @{ FilePath = $exe; ArgumentList = $arguments; PassThru = $true; ErrorAction = 'Stop' }
    if (-not (Test-IsAdmin)) { $start.Verb = 'RunAs' }
    try { return (Start-Process @start) }
    catch [ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 1223) { throw 'Permissao administrativa cancelada. A selecao continua pendente.' }
        throw
    }
}

function Ensure-PhaseZeroHostCodexRuntime {
    $runtime = Get-BootstrapCodexRuntimeComponent
    $dependency = Get-BootstrapWindowsDependencyStatus -Definition $runtime
    if ($dependency.status -eq 'satisfied') { return }
    if ($dependency.status -notin @('missing', 'partial', 'insufficient')) { throw $dependency.detail }
    if (Test-IsAdmin) {
        $null = Invoke-PhaseZeroDependencySelection -Selected @($runtime.Name)
    } else {
        $target = Get-PhaseZeroDependencyTarget
        $request = @{ target = $target; requirementFile = ''; applicationArchitecture = ''; requirementHash = '' }
        $child = Start-PhaseZeroDependencyWorker -EntryPoint (Join-Path $repoRoot 'windows/ai/prepare-host.ps1') -Selected @($runtime.Name) -Report $request
        try {
            $child.WaitForExit()
            if ($child.ExitCode -ne 0) { throw 'Visual C++ continua pendente. Confira o resultado em Dependencias de aplicativos e projetos.' }
        } finally { $child.Dispose() }
    }
    $verified = Get-BootstrapWindowsDependencyStatus -Definition $runtime
    if ($verified.status -ne 'satisfied') { throw $verified.detail }
}
