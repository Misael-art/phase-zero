# Local application adapters owned by PhaseZero. Selection and pins belong to
# the caller's reviewed packages.lock.json; no download or account migration.
function Resolve-PhaseZeroCachedLocalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path -match '^\\\\|["\r\n]') { throw 'Use um caminho local absoluto para o pacote.' }
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Caminho de pacote redirecionado.' }
        }
        $parent = Split-Path -Path $cursor -Parent
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Get-PhaseZeroCachedApplication {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CacheDirectory, [Parameter(Mandatory = $true)][string]$Id)
    $definitions = @{
        'OpenAI.Codex' = @{ component = 'codex-cli'; kind = 'zip'; command = 'codex.exe' }
        'Anthropic.ClaudeCode' = @{ component = 'claude-code'; kind = 'portable'; command = 'claude.exe' }
        'Anthropic.Claude' = @{ component = 'claude-desktop'; kind = 'msix'; command = '' }
        '9PLM9XGG6VKS' = @{ component = 'codex-desktop'; kind = 'msix'; command = '' }
    }
    if (-not $definitions.ContainsKey($Id)) { throw 'Aplicativo sem adaptador local aprovado.' }
    $cache = Resolve-PhaseZeroCachedLocalPath $CacheDirectory
    $manifestPath = Resolve-PhaseZeroCachedLocalPath (Join-Path $cache 'packages\packages.lock.json')
    $manifest = Read-BootstrapJsonFile -Path $manifestPath
    if ($manifest.schemaVersion -ne 1 -or $manifest.wingetCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'Manifesto de pacotes sem revisao fixada.' }
    $rows = @($manifest.packages | Where-Object { $_.id -ceq $Id })
    if ($rows.Count -ne 1) { throw 'O pacote deve conter uma unica entrada do aplicativo.' }
    $row = $rows[0]; $definition = $definitions[$Id]
    $versionPattern = if ($Id -eq '9PLM9XGG6VKS') { '^\d+\.\d+\.\d+\.\d+$' } else { '^\d+\.\d+\.\d+$' }
    if ($row.version -cnotmatch $versionPattern -or $row.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $row.installerType -cne $definition.kind) { throw 'Identidade ou formato do pacote local invalido.' }
    $origin = switch ($Id) {
        'OpenAI.Codex' { '^' + [regex]::Escape('https://github.com/openai/codex/releases/download/rust-v' + $row.version + '/codex-x86_64-pc-windows-msvc.exe.zip') + '$' }
        'Anthropic.ClaudeCode' { '^' + [regex]::Escape('https://downloads.claude.ai/claude-code-releases/' + $row.version + '/win32-x64/claude.exe') + '$' }
        'Anthropic.Claude' { '^' + [regex]::Escape('https://downloads.claude.ai/releases/win32/x64/' + $row.version + '/Claude-') + '[a-f0-9]{40}\.msix$' }
        '9PLM9XGG6VKS' { '^https://persistent\.oaistatic\.com/codex-app-prod/ChatGPT-x64\.msix$' }
    }
    $extension = if ($definition.kind -eq 'portable') { 'exe' } else { $definition.kind }
    if ($row.url -cnotmatch $origin -or $row.file -cne ('packages/' + $row.sha256 + '.' + $extension)) { throw 'Origem ou nome do payload difere do contrato oficial.' }
    $payload = Resolve-PhaseZeroCachedLocalPath (Join-Path $cache $row.file)
    if (-not [IO.File]::Exists($payload) -or (Get-Item -LiteralPath $payload).Length -ne $row.size -or (Get-BootstrapFileSha256 $payload) -cne $row.sha256) { throw 'Pacote local ausente ou corrompido; o arquivo foi preservado.' }
    $licensePath = ''
    if ($Id -eq '9PLM9XGG6VKS') {
        $assets = @($row.assets)
        if ($assets.Count -ne 1 -or $assets[0].id -cne 'OpenAI.Desktop.OfflineLicense' -or $assets[0].purpose -cne 'vendor-offline-license' -or $assets[0].url -cne 'https://persistent.oaistatic.com/codex-app-prod/ChatGPT-License.xml' -or $assets[0].sha256 -cnotmatch '^[a-f0-9]{64}$' -or $assets[0].file -cne ('packages/' + $assets[0].sha256 + '.xml') -or $assets[0].size -le 0 -or $assets[0].size -gt 1MB) { throw 'Licenca offline OpenAI ausente ou sem contrato aprovado.' }
        $licensePath = Resolve-PhaseZeroCachedLocalPath (Join-Path $cache $assets[0].file)
        if ((Get-Item -LiteralPath $licensePath).Length -ne $assets[0].size -or (Get-BootstrapFileSha256 $licensePath) -cne $assets[0].sha256) { throw 'Licenca offline ausente ou corrompida.' }
        $settings = [Xml.XmlReaderSettings]::new(); $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($licensePath, $settings)
        try { while ($reader.Read()) {} } finally { $reader.Dispose() }
    }
    return @{ row = $row; definition = $definition; path = $payload; licensePath = $licensePath; manifestSha256 = Get-BootstrapFileSha256 $manifestPath }
}

function Get-PhaseZeroCachedManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    $path = Get-BootstrapAiToolManifestPath -InstallRoot $InstallRoot
    if (Test-Path -LiteralPath $path) {
        $null = Resolve-PhaseZeroCachedLocalPath $path
        $current = Read-BootstrapJsonFile -Path $path
        if ($current.schemaVersion -ne 1 -or $current.managedBy -cne 'PhaseZero') { throw 'Inventario PhaseZero desconhecido; preserve e revise a recuperacao.' }
    }
    return Read-BootstrapAiToolManifest -InstallRoot $InstallRoot
}

function Get-PhaseZeroCachedZipEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Archive)
    $seen = @{}; $expanded = [long]0
    foreach ($item in $Archive.Entries) {
        $name = $item.FullName.Replace('\', '/')
        if (-not $name -or $name -match '(^/|:|(^|/)\.\.(/|$)|(^|/)\.(/|$)|(^|/)[^/]*[. ](/|$)|(^|/)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|/|$))' -or ($item.ExternalAttributes -shr 16 -band 61440) -eq 40960 -or ($item.ExternalAttributes -band 1024) -or $seen.ContainsKey($name)) { throw 'ZIP com caminho invalido, link ou entrada duplicada.' }
        $seen[$name] = $true; $expanded += $item.Length
        if ($expanded -gt 2GB) { throw 'ZIP excede o tamanho preparado para o cliente.' }
        $item
    }
}

function Get-PhaseZeroCachedMsixIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Package)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Package.path)
    try {
        $xmlEntry = $archive.GetEntry('AppxManifest.xml')
        if ($null -eq $xmlEntry -or $xmlEntry.Length -gt 1MB) { throw 'Manifesto MSIX ausente ou excessivo.' }
        $reader = [IO.StreamReader]::new($xmlEntry.Open())
        try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $settings = [Xml.XmlReaderSettings]::new(); $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit; $settings.XmlResolver = $null
        $xmlReader = [Xml.XmlReader]::Create([IO.StringReader]::new($xmlText), $settings)
        try { $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null; $xml.Load($xmlReader) } finally { $xmlReader.Dispose() }
        $name = if ($Package.row.id -eq '9PLM9XGG6VKS') { 'OpenAI.Codex' } else { 'Claude' }
        $version = if ($Package.row.id -eq '9PLM9XGG6VKS') { $Package.row.version } else { $Package.row.version + '.0' }
        if ($xml.Package.Identity.Name -cne $name -or $xml.Package.Identity.Version -cne $version -or $xml.Package.Identity.ProcessorArchitecture -cne 'x64') { throw 'Identidade MSIX diferente do manifesto fixado.' }
        if ($Package.row.id -eq '9PLM9XGG6VKS' -and $xml.Package.Identity.Publisher -cne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B') { throw 'Editor MSIX OpenAI diferente da distribuicao oficial conferida.' }
        return @{ name = $name; publisher = [string]$xml.Package.Identity.Publisher; version = [string]$xml.Package.Identity.Version }
    } finally { $archive.Dispose() }
}

function Get-PhaseZeroCachedExpectedFileMap {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Package)
    if ($Package.definition.kind -eq 'portable') { return @{ 'claude.exe' = @{ sha256 = $Package.row.sha256; size = $Package.row.size } } }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Package.path)
    try {
        $files = @{}
        foreach ($item in @(Get-PhaseZeroCachedZipEntry $archive)) {
            if (-not $item.Name) { continue }
            $stream = $item.Open(); $hash = [Security.Cryptography.SHA256]::Create()
            try { $checksum = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() } finally { $stream.Dispose(); $hash.Dispose() }
            $files[$item.FullName.Replace('\', '/')] = @{ sha256 = $checksum; size = $item.Length }
        }
        if (-not $files.ContainsKey('codex-x86_64-pc-windows-msvc.exe') -or $files.ContainsKey('codex.exe')) { throw 'Entrada principal Codex ausente ou ambigua.' }
        $files['codex.exe'] = $files['codex-x86_64-pc-windows-msvc.exe']
        return $files
    } finally { $archive.Dispose() }
}

function Test-PhaseZeroCachedApplication {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Package, [Parameter(Mandatory = $true)]$Target, [Parameter(Mandatory = $true)][hashtable]$Entry)
    if ($Entry['windowsId'] -cne $Target.windowsId -or $Entry['caller'] -cne $Target.caller -or $Entry['sourceSha256'] -cne $Package.row.sha256 -or $Entry['version'] -cne $Package.row.version) { return $false }
    if ($Package.definition.kind -eq 'msix') {
        $identity = Get-PhaseZeroCachedMsixIdentity $Package
        $apps = @(Get-AppxPackage -Name $identity.name -ErrorAction Stop | Where-Object { $_.Name -ceq $identity.name })
        return ($apps.Count -eq 1 -and [string]$apps[0].Version -ceq $identity.version -and [string]$apps[0].Publisher -ceq $identity.publisher -and [string]$apps[0].Status -eq 'Ok')
    }
    $directory = Resolve-PhaseZeroCachedLocalPath ([string]$Entry['directory'])
    $root = Get-BootstrapAiInstallRoot -InstallRoot ''
    $expectedDirectory = [IO.Path]::GetFullPath((Join-Path $root ('apps\' + $Package.definition.component + '\' + $Package.row.sha256)))
    if ($directory -ine $expectedDirectory) { throw 'O inventario aponta para fora do aplicativo gerenciado.' }
    if (-not [IO.Directory]::Exists($directory)) { return $false }
    # Expected bytes come from the pinned payload, never from a writable local
    # receipt. Walk directories without following a junction or symbolic link.
    $expected = Get-PhaseZeroCachedExpectedFileMap $Package
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($directory); $observed = @{}
    while ($queue.Count) {
        foreach ($child in Get-ChildItem -LiteralPath $queue.Dequeue() -Force -ErrorAction Stop) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Arvore instalada redirecionada.' }
            if ($child.PSIsContainer) { $queue.Enqueue($child.FullName) } else { $observed[$child.FullName.Substring($directory.Length + 1).Replace('\', '/')] = $true }
        }
    }
    if ($observed.Count -ne $expected.Count) { return $false }
    foreach ($name in $expected.Keys) {
        if (-not $observed.ContainsKey($name)) { return $false }
        $path = Resolve-PhaseZeroCachedLocalPath (Join-Path $directory $name)
        if ((Get-Item -LiteralPath $path).Length -ne $expected[$name].size -or (Get-BootstrapFileSha256 $path) -cne $expected[$name].sha256) { return $false }
    }
    # Client execution belongs to the interactive user. An elevated caller only
    # verifies bytes; the disposable native CI exercises --version separately.
    return $true
}

function Invoke-PhaseZeroCachedStreamCopy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][IO.Stream]$SourceStream, [Parameter(Mandatory = $true)][string]$Destination, [Parameter(Mandatory = $true)][scriptblock]$Progress)
    $out = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $buffer = New-Object byte[] (1MB)
        while (($count = $SourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) { $out.Write($buffer, 0, $count); & $Progress }
        $out.Flush($true)
    } finally { $out.Dispose() }
}

function Invoke-PhaseZeroCachedBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [long]$OutputBytes = 2GB)
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop
    $available = [double]$os.FreePhysicalMemory * 1KB; $total = [double]$os.TotalVisibleMemorySize * 1KB
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($InstallRoot))
    # Application admission, including a small supervised guest. The caller
    # still owns the physical host reserve, thermal gates and VM supervision.
    if ($available - 256MB -lt [Math]::Max(512MB, .25 * $total) -or $drive.AvailableFreeSpace -lt 10GB + $OutputBytes) { throw 'Aguarde margem de RAM e disco para instalar pelo cache.' }
}

function Get-PhaseZeroCachedApplicationStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CacheDirectory, [Parameter(Mandatory = $true)][string]$Id)
    $target = Get-PhaseZeroDependencyTarget
    $root = Get-BootstrapAiInstallRoot -InstallRoot ''
    $mutex = [Threading.Mutex]::new($false, 'Global\PhaseZeroWindowsDependencies'); $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Outra operacao PhaseZero esta em execucao. Aguarde antes de verificar.' }
        $package = Get-PhaseZeroCachedApplication $CacheDirectory $Id
        $manifest = Get-PhaseZeroCachedManifest $root
        $entry = $manifest['tools'][$package.definition.component]
        $verified = $false
        if ($entry -and $entry['source'] -ceq 'offline-cache' -and $entry['state'] -ceq 'verified') { $verified = Test-PhaseZeroCachedApplication $package $target $entry }
        $binary = if ($verified -and $package.definition.command) { Join-Path $entry['directory'] $package.definition.command } else { '' }
        return @{ schemaVersion = 1; id = $Id; version = $package.row.version; verified = $verified; binary = $binary; authentication = 'pending'; functionTest = 'pending-interactive-user'; windowsId = $target.windowsId; caller = $target.caller }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Invoke-PhaseZeroCachedApplication {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$CacheDirectory, [Parameter(Mandatory = $true)][string]$Id)
    $target = Get-PhaseZeroDependencyTarget
    if (-not $target.windowsId -or -not $target.caller -or -not $target.boot -or [IO.Path]::GetPathRoot($repoRoot) -ine $target.systemDrive) { throw 'Use o PhaseZero do Windows em execucao, na conta correta.' }
    if ($Id -eq '9PLM9XGG6VKS' -and -not $target.elevated) { throw 'Abra a instalacao pelo preparador para autorizar o provisionamento na mesma conta Windows.' }
    $root = Get-BootstrapAiInstallRoot -InstallRoot ''
    $null = Resolve-PhaseZeroCachedLocalPath $root
    $mutex = [Threading.Mutex]::new($false, 'Global\PhaseZeroWindowsDependencies'); $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Outra operacao de dependencias do PhaseZero esta em execucao.' }
        Invoke-PhaseZeroCachedBudget $root
        $dependencyDefinitions = Get-PhaseZeroDependencyDefinitions
        $runtime = Get-PhaseZeroDependencyStatus -Definition $dependencyDefinitions['vcpp-redist'] -Requirements @{}
        if ($runtime.status -ne 'satisfied') { throw 'Prepare o Visual C++ x64 pelo cache de dependencias antes de instalar os clientes locais.' }
        $package = Get-PhaseZeroCachedApplication $CacheDirectory $Id
        if (-not $PSCmdlet.ShouldProcess($package.row.name, 'Instalar pacote local verificado')) { return @{ id = $Id; state = 'not-executed' } }
        $signature = if ($package.definition.kind -eq 'zip') { @{ Status = 'NotApplicable' } } else { Get-AuthenticodeSignature -LiteralPath $package.path -ErrorAction Stop }
        if ($signature.Status -notin @('Valid', 'NotSigned', 'NotApplicable')) { throw 'Assinatura do payload local invalida.' }
        if ($package.definition.kind -eq 'msix' -and $signature.Status -ne 'Valid') { throw 'O pacote MSIX exige assinatura valida.' }
        if ($Id -eq '9PLM9XGG6VKS' -and $signature.SignerCertificate.Subject -cne 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B') { throw 'Assinatura MSIX OpenAI diferente da origem conferida.' }
        if ($signature.Status -eq 'Valid' -and $Id -like 'Anthropic.*' -and $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -notin @('Anthropic PBC', 'Anthropic, PBC')) { throw 'Editor Anthropic diferente do esperado.' }
        if ($package.definition.kind -eq 'msix') { $identity = Get-PhaseZeroCachedMsixIdentity $package }
        if ($package.definition.kind -eq 'zip') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $inputArchive = [IO.Compression.ZipFile]::OpenRead($package.path)
            try { $null = @(Get-PhaseZeroCachedZipEntry $inputArchive) } finally { $inputArchive.Dispose() }
        }
        $manifest = Get-PhaseZeroCachedManifest $root
        $component = $package.definition.component
        $previous = $manifest['tools'][$component]
        if ($previous -and $previous['source'] -ceq 'offline-cache') {
            if ($previous['state'] -cne 'verified') { throw 'A preparacao anterior foi interrompida. Preserve o staging e confira o inventario antes de retomar.' }
            if (Test-PhaseZeroCachedApplication $package $target $previous) { return @{ id = $Id; state = 'verified'; version = $package.row.version; reused = $true; authentication = 'pending'; functionTest = 'pending-interactive-user' } }
        }
        $directory = Join-Path $root ('apps\' + $component + '\' + $package.row.sha256)
        $stage = $directory + '.partial'
        foreach ($path in @($directory, $stage)) { $null = Resolve-PhaseZeroCachedLocalPath $path; if (Test-Path -LiteralPath $path) { throw 'Destino existente sem recibo correspondente; preserve e confira os arquivos.' } }
        $entry = @{ source = 'offline-cache'; sourceSha256 = $package.row.sha256; version = $package.row.version; windowsId = $target.windowsId; caller = $target.caller; boot = $target.boot; cacheManifestSha256 = $package.manifestSha256; state = 'preparing'; directory = $directory; staging = $stage; files = @{}; at = [DateTime]::UtcNow.ToString('o') }
        if ($previous) {
            $entry['previousRecord'] = @{}
            foreach ($key in $previous.Keys) { if ($key -ne 'previousRecord') { $entry['previousRecord'][$key] = $previous[$key] } }
        }
        $manifest['tools'][$component] = $entry
        $null = Write-BootstrapAiToolManifest -InstallRoot $root -Manifest $manifest
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $checkResources = ${function:Invoke-PhaseZeroCachedBudget}
        $progress = { if ($clock.Elapsed.TotalSeconds -ge 20) { & $checkResources $root; $clock.Restart() } }.GetNewClosure()
        if ($package.definition.kind -eq 'msix') {
            $entry['publisher'] = $identity.publisher
            if ($Id -eq '9PLM9XGG6VKS') {
                # Public vendor offline license, never SkipLicense. Provision
                # once, then register the family for this bound Windows user.
                Add-AppxProvisionedPackage -Online -PackagePath $package.path -LicensePath $package.licensePath -Regions all -ErrorAction Stop | Out-Null
                Add-AppxPackage -RegisterByFamilyName -MainPackage 'OpenAI.Codex_2p2nqsd0c76g0' -ErrorAction Stop
            } else { Add-AppxPackage -Path $package.path -ErrorAction Stop }
        } else {
            [void][IO.Directory]::CreateDirectory($stage)
            if ($package.definition.kind -eq 'portable') {
                $sourceStream = [IO.File]::OpenRead($package.path)
                try { Invoke-PhaseZeroCachedStreamCopy $sourceStream (Join-Path $stage 'claude.exe') $progress } finally { $sourceStream.Dispose() }
            } else {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $archive = [IO.Compression.ZipFile]::OpenRead($package.path)
                try {
                    foreach ($item in @(Get-PhaseZeroCachedZipEntry $archive)) {
                        $path = Join-Path $stage $item.FullName
                        if (-not $item.Name) { [void][IO.Directory]::CreateDirectory($path); continue }
                        [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
                        $stream = $item.Open()
                        try { Invoke-PhaseZeroCachedStreamCopy $stream $path $progress } finally { $stream.Dispose() }
                    }
                } finally { $archive.Dispose() }
                $layout = Read-BootstrapJsonFile -Path (Join-Path $stage 'codex-package.json')
                if ($layout.layoutVersion -ne 1 -or $layout.version -cne $package.row.version -or $layout.target -cne 'x86_64-pc-windows-msvc' -or $layout.entrypoint -cne 'codex-x86_64-pc-windows-msvc.exe') { throw 'Layout Codex nao corresponde ao pacote aprovado.' }
                New-Item -ItemType HardLink -Path (Join-Path $stage 'codex.exe') -Target (Join-Path $stage $layout.entrypoint) -ErrorAction Stop | Out-Null
            }
            foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) { & $progress; $name = $file.FullName.Substring($stage.Length + 1); $entry['files'][$name] = Get-BootstrapFileSha256 $file.FullName }
            Move-Item -LiteralPath $stage -Destination $directory -ErrorAction Stop
        }
        if (-not (Test-PhaseZeroCachedApplication $package $target $entry)) { throw 'Instalacao local ainda nao confirmada; o recibo continua pendente.' }
        if ($package.definition.command) { Ensure-PathUserContainsFirst -Dir $directory }
        $entry['state'] = 'verified'; $entry['authentication'] = 'pending'; $entry['functionTest'] = 'pending-interactive-user'
        $null = Write-BootstrapAiToolManifest -InstallRoot $root -Manifest $manifest
        return @{ id = $Id; state = 'verified'; version = $package.row.version; authentication = 'pending'; functionTest = 'pending-interactive-user' }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
