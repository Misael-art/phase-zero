param(
    [string]$UiStatePath,
    [string]$UiLogPath,
    [switch]$SmokeTest,
    [switch]$SmokeTestWindow
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

function Repair-UiWindowsEnvironment {
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot) -and -not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
        $env:SystemRoot = $env:WINDIR
    }
    if ([string]::IsNullOrWhiteSpace($env:WINDIR) -and -not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $env:WINDIR = $env:SystemRoot
    }
}

Repair-UiWindowsEnvironment

function Get-UiPendingRebootReasons {
    $reasons = New-Object System.Collections.Generic.List[string]
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            $reasons.Add('Component Based Servicing')
        }
    } catch {
    }
    try {
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            $reasons.Add('Windows Update')
        }
    } catch {
    }
    try {
        $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
        if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
            $reasons.Add('PendingFileRenameOperations')
        }
    } catch {
    }
    try {
        $updateExeVolatile = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Updates' -Name 'UpdateExeVolatile' -ErrorAction SilentlyContinue
        if ($updateExeVolatile -and ($updateExeVolatile.UpdateExeVolatile -as [int]) -gt 0) {
            $reasons.Add('UpdateExeVolatile')
        }
    } catch {
    }
    return @($reasons | Select-Object -Unique)
}

function Get-UiStorageRootCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:USERPROFILE) {
        $candidates.Add((Join-Path $env:USERPROFILE '.bootstrap-tools'))
    }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'bootstrap-tools'))
    }
    if ($env:TEMP) {
        $candidates.Add((Join-Path $env:TEMP 'bootstrap-tools'))
    }

    $cwdRoot = Join-Path (Get-Location).Path 'bootstrap-tools'
    $candidates.Add($cwdRoot)

    return @($candidates | Select-Object -Unique)
}

function Test-UiParentPathWritable {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $parent = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($parent)) { return $false }

    try {
        [void][System.IO.Directory]::CreateDirectory($parent)
        $probePath = Join-Path $parent ('.bootstrap-ui-write-probe-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes('probe')
            $stream = [System.IO.File]::Open($probePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            } finally {
                $stream.Dispose()
            }
            [System.IO.File]::Delete($probePath)
            return $true
        } catch {
            try {
                if ([System.IO.File]::Exists($probePath)) {
                    [System.IO.File]::Delete($probePath)
                }
            } catch {
            }
            return $false
        }
    } catch {
        return $false
    }
}

function Resolve-UiStorageRoot {
    foreach ($candidate in @(Get-UiStorageRootCandidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $probeFile = Join-Path $candidate 'ui-state.probe.json'
        if (Test-UiParentPathWritable -Path $probeFile) {
            return $candidate
        }
    }

    throw 'Bootstrap UI não encontrou um diretório gravável para logs e estado local.'
}

function Resolve-UiWritablePath {
    param(
        [string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$FallbackRelativePath
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (Test-UiParentPathWritable -Path $RequestedPath) {
            return $RequestedPath
        }
    }

    return (Join-Path $script:UiStorageRoot $FallbackRelativePath)
}

$script:UiStorageRoot = Resolve-UiStorageRoot
$UiStatePath = Resolve-UiWritablePath -RequestedPath $UiStatePath -FallbackRelativePath 'ui-state.json'
$script:UiLogPath = Resolve-UiWritablePath -RequestedPath $UiLogPath -FallbackRelativePath (Join-Path 'logs' ("bootstrap-ui_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date)))

if (-not [string]::IsNullOrWhiteSpace($UiLogPath) -and ($script:UiLogPath -ne $UiLogPath)) {
    try {
        Write-Host ("[bootstrap-ui] UiLogPath fallback ativado: {0}" -f $script:UiLogPath)
    } catch {
    }
}
$uiLogParent = Split-Path -Path $script:UiLogPath -Parent
if ($uiLogParent) { $null = New-Item -Path $uiLogParent -ItemType Directory -Force }

function Write-UiLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    try {
        $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
        Add-Content -Path $script:UiLogPath -Value $line -Encoding utf8
    } catch {
    }
}

trap {
    try { Write-UiLog -Level 'ERROR' -Message (($_ | Out-String).Trim()) } catch { }
    throw
}

function Get-WindowsPowerShellExePath {
    $systemRoot = if ($env:SystemRoot) { $env:SystemRoot } else { $env:WINDIR }
    $system32 = Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $sysnative = Join-Path $systemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path $sysnative) { return $sysnative }
    }
    return $system32
}

function ConvertTo-CommandLineArgument {
    param([AllowNull()][string]$Token)

    if ($null -eq $Token) { return '""' }
    $text = [string]$Token
    if ($text.Length -eq 0) { return '""' }
    if ($text -notmatch '[\s"`&\(\)\^]') { return $text }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($ch -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($ch -eq [char]'"') {
            if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
            [void]$builder.Append('\"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-ArgumentString {
    param([string[]]$Tokens)
    return [string]::Join(' ', @($Tokens | ForEach-Object { ConvertTo-CommandLineArgument -Token ([string]$_) }))
}

function Restart-InWindowsPowerShell {
    $powershellExe = Get-WindowsPowerShellExePath
    if (-not (Test-Path $powershellExe)) {
        throw "Windows PowerShell 5.1 não encontrado em $powershellExe"
    }

    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (-not $SmokeTest) { $argumentList += '-STA' }
    $argumentList += @('-File', $PSCommandPath, '-UiStatePath', $UiStatePath, '-UiLogPath', $script:UiLogPath)
    if ($SmokeTest) { $argumentList += '-SmokeTest' }
    if ($SmokeTestWindow) { $argumentList += '-SmokeTestWindow' }

    Write-UiLog -Message ("Relaunching in Windows PowerShell. Exe={0}  Args={1}" -f $powershellExe, (ConvertTo-Json $argumentList -Compress))

    if ($SmokeTest) {
        & $powershellExe @argumentList
        exit $LASTEXITCODE
    }

    Start-Process -FilePath $powershellExe -ArgumentList (ConvertTo-ArgumentString -Tokens $argumentList) | Out-Null
    exit 0
}

function Test-UiEnvironment {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Bootstrap UI requer Windows com interface desktop.'
    }

    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        Restart-InWindowsPowerShell
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "Bootstrap UI requer Windows PowerShell 5.1+. Versão atual: $($PSVersionTable.PSVersion)"
    }

    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "Bootstrap UI requer FullLanguage. Modo atual: $($ExecutionContext.SessionState.LanguageMode)"
    }

    if (-not $SmokeTest -and -not [Environment]::UserInteractive) {
        throw 'Bootstrap UI requer uma sessão de usuário interativa.'
    }
}

Write-UiLog -Message ("Start. PSEdition={0}  PSVersion={1}  OS64={2}  Proc64={3}  User={4}  LangMode={5}  Interactive={6}  UiStatePath={7}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, [Environment]::Is64BitOperatingSystem, [Environment]::Is64BitProcess, $env:USERNAME, $ExecutionContext.SessionState.LanguageMode, [Environment]::UserInteractive, $UiStatePath)
Test-UiEnvironment

$backendScriptPath = Join-Path $PSScriptRoot 'bootstrap-tools.ps1'
if (-not (Test-Path $backendScriptPath)) {
    Write-UiLog -Level 'ERROR' -Message "bootstrap-tools.ps1 not found at $backendScriptPath"
    throw "bootstrap-tools.ps1 not found at $backendScriptPath"
}

. $backendScriptPath -BootstrapUiLibraryMode

#
# UI Helpers / Strings
#

function Get-UiLanguages {
    return @('pt-BR', 'en-US')
}

function Get-UiPageIds {
    return @('health', 'welcome', 'selection', 'host-setup', 'app-tuning', 'ai-tools', 'api-center', 'api-catalog', 'steamdeck-control', 'dual-boot', 'review', 'run')
}

function Get-UiWizardStepIds {
    # Sequencia linear do fluxo (botoes Voltar/Avancar e contador de passo). Exclui 'health'
    # (dashboard de entrada) e 'api-catalog' (drill-down de detalhe), que sao acessados pela
    # navegacao lateral e por botoes proprios -- nao fazem parte do passo a passo.
    return @('welcome', 'selection', 'host-setup', 'app-tuning', 'ai-tools', 'api-center', 'steamdeck-control', 'dual-boot', 'review', 'run')
}

function Get-UiStartPageId {
    return 'health'
}

function Get-UiStrings {
    param([Parameter(Mandatory = $true)][string]$Language)
    switch ($Language) {
        'en-US' {
            return @{
                WindowTitle        = 'Bootstrap Tools Control Center'
                WelcomeTitle       = 'Bootstrap Tools + Steam Deck'
                WelcomeSubtitle    = 'Simple host setup, Steam Deck control and post-install maintenance.'
                Language           = 'Language'
                QuickPresets       = 'Quick Presets'
                CustomPresets      = 'Custom Presets'
                PresetName         = 'Preset name'
                SavePreset         = 'Save preset'
                LoadPreset         = 'Load preset'
                DeletePreset       = 'Delete preset'
                SelectionTitle     = 'Guided Profile Selection'
                ClearAllSelection  = 'Clear all selections'
                Filter             = 'Filter'
                Profiles           = 'Ready-made profiles'
                Components         = 'Tools to install'
                Excludes           = 'Do not install'
                SelectionDetails   = 'What this option does'
                QuickOptions       = 'Quick options'
                OptClaudePlugins   = 'Claude Code: plugins'
                OptClaudeProjectMcps = 'Claude Code: project MCP sync'
                OptOpenWebUI       = 'Local AI: Open WebUI (Docker)'
                OptSkipManualRequirements = 'Skip blocking manual requirements'
                OptIgnoreManualRequirements = 'Ignore manual requirements (log only)'
                OptRequireNoPendingReboot = 'Abort if Windows reports pending reboot (preflight)'
                OptOfflineMode     = 'Offline mode (local cache)'
                OptEnableResume    = 'Resume interrupted install'
                HostSetupTitle     = 'Prepare this PC'
                AppTuningTitle      = 'Optimize Apps'
                AppTuningSubtitle   = 'Pre-configure installed tools by category and profile, with safe defaults.'
                AppTuningMode       = 'App tuning'
                AppTuningCategories = 'Categories'
                AppTuningItems      = 'Items'
                AppTuningRecommended = 'Mark recommended'
                AppTuningMarkCategory = 'Mark category'
                AppTuningClearCategory = 'Clear category'
                AppTuningAudit      = 'Refresh status'
                AppTuningInstall    = 'Install'
                AppTuningConfigure  = 'Configure/Optimize'
                AppTuningUpdate     = 'Update'
                AppTuningRunNow     = 'Run now'
                AppTuningOpenFolder = 'Open folder'
                AppTuningViewLog    = 'View log'
                AppTuningStatus     = 'Safe and reversible app tuning. Category app-install lists individual apps for on-demand installs.'
                HealthTitle         = 'Health'
                HealthSummary       = 'Local support diagnostics, export bundle and manual repair queue.'
                HealthStatus        = 'Run diagnostics to refresh local health.'
                HealthDoctor        = 'Run diagnostics'
                HealthSupportBundle = 'Export support package'
                HealthRepairPlan    = 'View repairs'
                HealthCopyDiagnostic = 'Copy diagnostic'
                HealthDeckStatus    = 'Steam Deck: not checked.'
                HealthGithubStatus  = 'GitHub CLI: not checked.'
                AiToolsTitle        = 'AI Coding Tools'
                AiToolsStatus       = 'Install, validate, configure, uninstall, or open official docs for optional AI coding tools.'
                AiToolsInstall      = 'Install'
                AiToolsValidate     = 'Validate'
                AiToolsConfigure    = 'Configure'
                AiToolsUninstall    = 'Uninstall'
                AiToolsDocs         = 'Open docs'
                ApiCenterTitle      = 'API Keys Center'
                ApiProviderSummary  = 'Providers overview'
                ApiCredentials      = 'Saved keys (masked)'
                ApiUsage            = 'Where keys are used'
                ApiCreate           = 'Create new keys'
                ApiRefresh          = 'Refresh inventory'
                ApiSave             = 'Save credential'
                ApiValidate         = 'Test selected key'
                ApiValidateAll      = 'Test all keys'
                ApiActivate         = 'Use this key now'
                ApiImport           = 'Import raw file'
                ApiApply            = 'Configure apps'
                ApiCatalog          = 'Full catalog'
                ApiCatalogTitle     = 'Full Key Catalog'
                ApiCatalogSubtitle  = 'Researched provider list with possession, configured state, purpose, requirements and official links.'
                ApiCatalogBack      = '<- API Center'
                HostHealth         = 'Maintenance level'
                SteamDeckVersion   = 'Steam Deck model'
                WorkspaceRoot      = 'Workspace Root'
                CloneBaseDir       = 'Clone Base Dir'
                Browse             = 'Browse'
                AdminNeeds         = 'Admin Review'
                SteamDeckCenterTitle = 'Steam Deck Control Center'
                MonitorProfiles    = 'Monitor Profiles'
                MonitorFamilies    = 'Monitor Families'
                GenericExternal    = 'Generic External Fallback'
                SessionProfiles    = 'Session Profiles'
                WatcherStatus      = 'Watcher Status'
                SaveSettings       = 'Save Settings'
                ReloadSettings     = 'Reload Settings'
                UnknownMonitorHint = 'Unknown external monitors stay unclassified until you choose Monitor/Dev or TV/Game. Safe fallback: Desktop/Dev.'
                PendingExternal    = 'Pending unknown external display'
                ClassifyMonitor    = 'Monitor/Dev'
                ClassifyTv         = 'TV/Game'
                ReviewTitle        = 'Review'
                RefreshReview      = 'Refresh Review'
                ReviewSummary      = 'Preview equivalent to dry-run'
                ReviewSideEffects  = 'Side effects'
                RunTitle           = 'Run'
                StartRun           = '>  Start Execution'
                OpenLog            = 'Open Log'
                OpenResult         = 'Open Result'
                OpenSettings       = 'Open Settings'
                OpenReports        = 'Open Reports'
                IdleStatus         = 'Ready.'
                SavingSettings     = 'Settings saved.'
                RunStarted         = 'Execution started.'
                RunCompleted       = 'Execution completed.'
                RunFailed          = 'Execution failed.'
                RunPhaseInstalling = 'Phase: installing packages.'
                RunPhaseValidating = 'Phase: validating artifacts.'
                RunPhaseRunning    = 'Phase: running.'
                PendingRebootBanner = 'Pending reboot detected: {0}. Reboot recommended.'
                PendingRebootBannerBlocking = 'Pending reboot detected: {0}. winget/MSI may block until reboot.'
                UserCanceledElevation = 'Execution canceled or elevation denied.'
                Back               = '<- Back'
                Next               = 'Next ->'
                Finish             = 'Close'
                Welcome            = 'Welcome'
                Selection          = 'Selection'
                HostSetup          = 'Host Setup'
                Health             = 'Health'
                AppTuning          = 'Optimize Apps'
                ApiCenter          = 'API Keys'
                SteamDeckControl   = 'Steam Deck Center'
                DualBoot           = 'Windows + Linux'
                Review             = 'Review'
                Run                = 'Run'
                GenericMode        = 'Mode'
                GenericLayout      = 'Layout'
                GenericResolution  = 'Resolution'
                DisplayMode        = 'Windows display mode'
                SessionHandheld    = 'HANDHELD'
                SessionDockedTv    = 'DOCKED_TV'
                SessionDockedMonitor = 'DOCKED_MONITOR'
            }
        }
        default {
            return @{
                WindowTitle        = 'Central Bootstrap Tools'
                WelcomeTitle       = 'Bootstrap Tools + Steam Deck'
                WelcomeSubtitle    = 'Setup simples do host, controle do Steam Deck e manutenção pós-instalação.'
                Language           = 'Idioma'
                QuickPresets       = 'Presets rápidos'
                CustomPresets      = 'Presets Personalizados'
                PresetName         = 'Nome do preset'
                SavePreset         = 'Salvar preset'
                LoadPreset         = 'Carregar preset'
                DeletePreset       = 'Excluir preset'
                SelectionTitle     = 'Escolha guiada de perfis'
                ClearAllSelection  = 'Limpar todas as selecoes'
                Filter             = 'Filtro'
                Profiles           = 'Perfis prontos'
                Components         = 'Ferramentas para instalar'
                Excludes           = 'Não instalar'
                SelectionDetails   = 'O que esta opcao faz'
                QuickOptions       = 'Opções rápidas'
                OptClaudePlugins   = 'Claude Code: plugins'
                OptClaudeProjectMcps = 'Claude Code: conexões do projeto'
                OptOpenWebUI       = 'IA local: Open WebUI (Docker)'
                OptSkipManualRequirements = 'Pular requisitos manuais (bloqueantes)'
                OptIgnoreManualRequirements = 'Ignorar requisitos manuais (apenas log)'
                OptRequireNoPendingReboot = 'Parar se houver reinício pendente'
                OptOfflineMode     = 'Modo Offline (usa cache local)'
                OptEnableResume    = 'Retomar instalação interrompida'
                HostSetupTitle     = 'Preparação deste PC'
                AppTuningTitle      = 'Otimizar apps'
                AppTuningSubtitle   = 'Pré-configure ferramentas instaladas por categoria e perfil, com padrões seguros.'
                AppTuningMode       = 'Modo de ajuste'
                AppTuningCategories = 'Categorias'
                AppTuningItems      = 'Itens'
                AppTuningRecommended = 'Marcar recomendados'
                AppTuningMarkCategory = 'Marcar categoria'
                AppTuningClearCategory = 'Limpar categoria'
                AppTuningAudit      = 'Atualizar status'
                AppTuningInstall    = 'Instalar'
                AppTuningConfigure  = 'Configurar/Otimizar'
                AppTuningUpdate     = 'Atualizar'
                AppTuningRunNow     = 'Executar agora'
                AppTuningOpenFolder = 'Abrir pasta'
                AppTuningViewLog    = 'Ver log'
                AppTuningStatus     = 'Ajustes seguros e reversíveis. A categoria de instalação lista apps individuais sob demanda.'
                HealthTitle         = 'Saúde'
                HealthSummary       = 'Diagnóstico local, pacote de suporte e fila manual de reparo.'
                HealthStatus        = 'Rode o diagnóstico para atualizar a saúde local.'
                HealthDoctor        = 'Rodar diagnóstico'
                HealthSupportBundle = 'Exportar pacote'
                HealthRepairPlan    = 'Ver reparos'
                HealthCopyDiagnostic = 'Copiar diagnóstico'
                HealthDeckStatus    = 'Steam Deck: não verificado.'
                HealthGithubStatus  = 'GitHub CLI: não verificado.'
                AiToolsTitle        = 'Ferramentas de IA'
                AiToolsStatus       = 'Marque uma ou mais ferramentas e instale, valide, configure, desinstale ou abra docs oficiais.'
                AiToolsInstall      = 'Instalar marcadas'
                AiToolsValidate     = 'Validar marcadas'
                AiToolsConfigure    = 'Configurar marcadas'
                AiToolsUninstall    = 'Desinstalar marcadas'
                AiToolsDocs         = 'Abrir docs'
                ApiCenterTitle      = 'Central de Chaves e APIs'
                ApiProviderSummary  = 'Resumo dos provedores'
                ApiCredentials      = 'Chaves salvas (mascaradas)'
                ApiUsage            = 'Onde cada API sera usada'
                ApiCreate           = 'Criar novas chaves'
                ApiRefresh          = 'Atualizar inventario'
                ApiSave             = 'Salvar ou atualizar chave'
                ApiValidate         = 'Testar chave selecionada'
                ApiValidateAll      = 'Testar todas'
                ApiActivate         = 'Usar esta chave agora'
                ApiImport           = 'Importar arquivo bruto'
                ApiApply            = 'Configurar apps'
                ApiCatalog          = 'Catálogo completo'
                ApiCatalogTitle     = 'Catálogo completo de chaves'
                ApiCatalogSubtitle  = 'Lista pesquisada de provedores com posse, uso configurado, finalidade, requisitos e links oficiais.'
                ApiCatalogBack      = '<- Central de APIs'
                HostHealth         = 'Nível de manutenção'
                SteamDeckVersion   = 'Modelo do Steam Deck'
                WorkspaceRoot      = 'Pasta de trabalho'
                CloneBaseDir       = 'Pasta base de clones'
                Browse             = 'Selecionar'
                AdminNeeds         = 'Revisão de Admin'
                SteamDeckCenterTitle = 'Central do Steam Deck'
                MonitorProfiles    = 'Monitores especificos'
                MonitorFamilies    = 'Familias de monitores'
                GenericExternal    = 'Regra padrao para monitor externo'
                SessionProfiles    = 'Perfis de uso'
                WatcherStatus      = 'Status do Watcher'
                SaveSettings       = 'Salvar Settings'
                ReloadSettings     = 'Recarregar Settings'
                UnknownMonitorHint = 'Monitores externos desconhecidos ficam pendentes ate voce escolher Monitor/Dev ou TV/Game. Fallback seguro: Desktop/Dev.'
                PendingExternal    = 'Monitor externo desconhecido pendente'
                ClassifyMonitor    = 'Monitor/Dev'
                ClassifyTv         = 'TV/Game'
                ReviewTitle        = 'Revisão'
                RefreshReview      = 'Atualizar Revisão'
                ReviewSummary      = 'Preview equivalente ao dry-run'
                ReviewSideEffects  = 'Efeitos colaterais'
                RunTitle           = 'Execução'
                StartRun           = '▶  Iniciar Execução'
                OpenLog            = 'Abrir Log'
                OpenResult         = 'Abrir Resultado'
                OpenSettings       = 'Abrir Settings'
                OpenReports        = 'Abrir Relatórios'
                IdleStatus         = 'Pronto.'
                SavingSettings     = 'Settings salvos.'
                RunStarted         = 'Execução iniciada.'
                RunCompleted       = 'Execução concluída.'
                RunFailed          = 'Execução falhou.'
                RunPhaseInstalling = 'Fase: instalando pacotes.'
                RunPhaseValidating = 'Fase: validando artefatos.'
                RunPhaseRunning    = 'Fase: executando.'
                PendingRebootBanner = 'Reinício pendente detectado: {0}. Recomendo reiniciar.'
                PendingRebootBannerBlocking = 'Reinício pendente detectado: {0}. Pode travar winget/MSI até reiniciar.'
                UserCanceledElevation = 'Execução cancelada ou elevação negada.'
                Back               = 'Voltar'
                Next               = 'Avançar'
                Finish             = 'Fechar'
                Welcome            = 'Início'
                Selection          = 'Escolher'
                HostSetup          = 'Configurar PC'
                Health             = 'Saúde'
                AppTuning          = 'Otimizar apps'
                ApiCenter          = 'Chaves (APIs)'
                SteamDeckControl   = 'Steam Deck'
                DualBoot           = 'Windows e Linux'
                Review             = 'Revisar'
                Run                = 'Executar'
                GenericMode        = 'Modo'
                GenericLayout      = 'Layout'
                GenericResolution  = 'Resolução'
                DisplayMode        = 'Modo de exibição'
                SessionHandheld    = 'HANDHELD'
                SessionDockedTv    = 'DOCKED_TV'
                SessionDockedMonitor = 'DOCKED_MONITOR'
            }
        }
    }
}

function Get-UiStateDefaults {
    param($Contract)
    return [ordered]@{
        language           = 'pt-BR'
        selectedProfiles   = @('safe-base')
        selectedComponents = @()
        excludedComponents = @()
        enableClaudeCodeProjectMcps = $false
        hostHealth         = 'off'
        appTuningMode      = 'off'
        selectedAppTuningCategories = @()
        selectedAppTuningItems = @()
        excludedAppTuningItems = @()
        selectedAiTools    = @()
        skipManualRequirements = $false
        ignoreManualRequirements = $false
        requireNoPendingReboot = $false
        offlineMode        = $false
        enableResume       = $false
        cacheDir           = ''
        steamDeckVersion   = 'Auto'
        workspaceRoot      = [string]$Contract.defaults.workspaceRoot
        cloneBaseDir       = (Get-Location).Path
        customPresets      = @{}
        lastLogPath        = $null
        lastResultPath     = $null
        lastReportPath     = $null
        lastSettingsPath   = Get-BootstrapSteamDeckSettingsPath
    }
}

function Normalize-UiScalarPath {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return ([string]$Value).Trim() }
    if ($Value -is [System.ValueType]) { return ([string]$Value).Trim() }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @($Value)
        if ($items.Count -eq 1 -and $items[0] -is [string]) { return ([string]$items[0]).Trim() }
        return ''
    }
    return ''
}

function Normalize-UiState {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)]$Contract
    )
    $defaults   = Get-UiStateDefaults -Contract $Contract
    $normalized = Merge-BootstrapData -Defaults $defaults -Current $State
    $normalized = ConvertTo-BootstrapHashtable -InputObject $normalized
    $normalized['selectedProfiles']   = @(Normalize-BootstrapNames -Names @($normalized['selectedProfiles']))
    $normalized['selectedComponents'] = @(Normalize-BootstrapNames -Names @($normalized['selectedComponents']))
    $normalized['excludedComponents'] = @(Normalize-BootstrapNames -Names @($normalized['excludedComponents']))
    $normalized['selectedAppTuningCategories'] = @(Normalize-BootstrapNames -Names @($normalized['selectedAppTuningCategories']))
    $normalized['selectedAppTuningItems'] = @(Normalize-BootstrapNames -Names @($normalized['selectedAppTuningItems']))
    $normalized['excludedAppTuningItems'] = @(Normalize-BootstrapNames -Names @($normalized['excludedAppTuningItems']))
    $normalized['selectedAiTools'] = @(Normalize-BootstrapNames -Names @($normalized['selectedAiTools']))
    $normalized['enableClaudeCodeProjectMcps'] = [bool]$normalized['enableClaudeCodeProjectMcps']
    if (-not $normalized.ContainsKey('requireNoPendingReboot')) { $normalized['requireNoPendingReboot'] = $false }
    $normalized['requireNoPendingReboot'] = [bool]$normalized['requireNoPendingReboot']
    $language = [string]$normalized['language']
    if ((Get-UiLanguages) -notcontains $language) { $normalized['language'] = 'pt-BR' }
    if ([string]::IsNullOrWhiteSpace([string]$normalized['hostHealth'])) {
        $normalized['hostHealth'] = 'off'
    } else {
        $normalized['hostHealth'] = Normalize-BootstrapHostHealthMode -Mode ([string]$normalized['hostHealth'])
    }
    if ([string]::IsNullOrWhiteSpace([string]$normalized['appTuningMode'])) {
        $normalized['appTuningMode'] = 'off'
    } else {
        $normalized['appTuningMode'] = Normalize-BootstrapAppTuningMode -Mode ([string]$normalized['appTuningMode'])
    }
    if ([string]::IsNullOrWhiteSpace([string]$normalized['steamDeckVersion'])) {
        $normalized['steamDeckVersion'] = 'Auto'
    }
    if (-not $normalized.ContainsKey('customPresets') -or -not ($normalized['customPresets'] -is [hashtable])) {
        $normalized['customPresets'] = @{}
    }
    foreach ($pathField in @('lastLogPath', 'lastResultPath', 'lastReportPath', 'lastSettingsPath', 'workspaceRoot', 'cloneBaseDir', 'cacheDir')) {
        if ($normalized.ContainsKey($pathField)) {
            $normalized[$pathField] = Normalize-UiScalarPath -Value $normalized[$pathField]
        }
    }
    return $normalized
}

function Read-UiState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Contract
    )
    $current = $null
    if (Test-Path $Path) {
        try { $current = Get-Content -Path $Path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $current = $null }
    }
    return (Normalize-UiState -State $current -Contract $Contract)
}

function Save-UiState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )
    Write-BootstrapJsonFile -Path $Path -Value (ConvertTo-BootstrapHashtable -InputObject $State)
}

#
# Bootstrap / SmokeTest
#

$Script:UiContractMinSupported = '1.0.0'
$Script:UiContractMaxSupported  = '1.99.99'

function Test-UiContractVersionCompat {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Min,
        [Parameter(Mandatory = $true)][string]$Max
    )
    function ConvertTo-Tuple([string]$v) {
        $parts = $v -split '\.'
        if ($parts.Count -lt 3) { return $null }
        try { return [int[]]@([int]$parts[0], [int]$parts[1], [int]$parts[2]) } catch { return $null }
    }
    $vT = ConvertTo-Tuple $Version
    $mn = ConvertTo-Tuple $Min
    $mx = ConvertTo-Tuple $Max
    if (-not $vT -or -not $mn -or -not $mx) {
        return @{ status = 'invalid'; severity = 'error'; message = "Versao invalida do contrato: '$Version'" }
    }
    if ($vT[0] -gt $mx[0]) {
        return @{ status = 'cli-too-new'; severity = 'error'; message = "UI desatualizada: contrato $Version > suportado $Max. Atualize a UI." }
    }
    if ($vT[0] -lt $mn[0]) {
        return @{ status = 'cli-too-old'; severity = 'error'; message = "CLI desatualizada: contrato $Version < suportado $Min. Atualize o bootstrap." }
    }
    if (($vT[0] -eq $mx[0]) -and ($vT[1] -gt $mx[1] -or ($vT[1] -eq $mx[1] -and $vT[2] -gt $mx[2]))) {
        return @{ status = 'minor-newer'; severity = 'warning'; message = "Contrato $Version e mais novo que o esperado por esta UI ($Max). Continuando." }
    }
    return @{ status = 'ok'; severity = 'info'; message = "Contrato compativel: $Version" }
}

$contract = Get-BootstrapUiContract

$contractVersion = ''
try { $contractVersion = [string]$contract.schemaVersion } catch { $contractVersion = '' }
if ([string]::IsNullOrWhiteSpace($contractVersion)) {
    Write-UiLog -Level 'WARN' -Message "Contrato sem schemaVersion (CLI antiga)."
} else {
    $compat = Test-UiContractVersionCompat -Version $contractVersion -Min $Script:UiContractMinSupported -Max $Script:UiContractMaxSupported
    $compatLevel = 'INFO'
    if ($compat.severity -eq 'error') { $compatLevel = 'ERROR' }
    elseif ($compat.severity -eq 'warning') { $compatLevel = 'WARN' }
    Write-UiLog -Level $compatLevel -Message $compat.message
    if ($compat.severity -eq 'error' -and -not $SmokeTest) {
        throw $compat.message
    }
}

$state    = Read-UiState -Path $UiStatePath -Contract $contract

if ($SmokeTest) {
    Save-UiState -State $state -Path $UiStatePath
    [ordered]@{
        pages    = @(Get-UiPageIds)
        startPage = Get-UiStartPageId
        primaryAction = 'doctor'
        languages = @(Get-UiLanguages)
        statePath = $UiStatePath
        backend  = $backendScriptPath
    } | ConvertTo-Json -Depth 8
    return
}

#
# Ensure STA thread
#

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $powershellExe = Get-WindowsPowerShellExePath
    $argumentList  = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath, '-UiStatePath', $UiStatePath, '-UiLogPath', $script:UiLogPath)
    if ($SmokeTest) { $argumentList += '-SmokeTest' }
    if ($SmokeTestWindow) { $argumentList += '-SmokeTestWindow' }
    Write-UiLog -Message ("Relaunching STA. Exe={0}  Args={1}" -f $powershellExe, (ConvertTo-Json $argumentList -Compress))
    Start-Process -FilePath $powershellExe -ArgumentList (ConvertTo-ArgumentString -Tokens $argumentList) | Out-Null
    exit 0
}

#
# WPF Assemblies
#

try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms   # still needed for FolderBrowserDialog
    Add-Type -AssemblyName System.Drawing
    Write-UiLog -Message 'WPF assemblies loaded.'
} catch {
    Write-UiLog -Level 'ERROR' -Message ("Failed to load WPF assemblies: {0}" -f (($_ | Out-String).Trim()))
    throw
}

function Get-UiBrush {
    param([Parameter(Mandatory = $true)][string]$Color)

    $converter = New-Object System.Windows.Media.BrushConverter
    return $converter.ConvertFromString($Color)
}

function Get-UiStatusHex {
    # Mapeia os 5 estados de status para hex legivel no tema escuro.
    param([string]$Status)
    switch ([string]$Status) {
        'error'                  { return '#EF4444' } # vermelho
        'not-installed'          { return '#FFFFFF' } # branco
        'installed-unconfigured' { return '#FACC15' } # amarelo
        'configured'             { return '#3B82F6' } # azul
        'optimized-tested'       { return '#22C55E' } # verde
        default                  { return '#CBD5E1' } # neutro
    }
}

function Get-UiStatusBrush {
    param([string]$Status)
    return (Get-UiBrush (Get-UiStatusHex -Status $Status))
}

function Get-UiStatusLabel {
    param([string]$Status)
    switch ([string]$Status) {
        'error'                  { return 'erro' }
        'not-installed'          { return 'nao instalado' }
        'installed-unconfigured' { return 'instalado, nao configurado' }
        'configured'             { return 'instalado e configurado' }
        'optimized-tested'       { return 'instalado, configurado, otimizado e testado' }
        default                  { return 'desconhecido' }
    }
}

function ConvertTo-UiCanonicalStatus {
    # Normaliza os varios vocabularios de status (componentes, AI tools, MCPs) para os 5 estados
    # canonicos de cor usados por Get-UiStatusHex. Retorna '' quando nao reconhece (cor neutra).
    param([string]$Raw)
    switch -Regex (([string]$Raw).Trim().ToLowerInvariant()) {
        '^(error|unhealthy|auth-failed|blocked|failed|broken)$'                            { return 'error' }
        '^(optimized-tested|optimized|tested)$'                                             { return 'optimized-tested' }
        '^(configured|healthy|ready|active|passed|ok)$'                                     { return 'configured' }
        '^(installed|installed-unconfigured|manual|login-required|needs-config|degraded)$'  { return 'installed-unconfigured' }
        '^(not-installed|missing|absent|none|unavailable|)$'                                { return 'not-installed' }
        default                                                                            { return '' }
    }
}

function Get-UiAppTuningCanonicalStatus {
    # Mapeia os estados do AppTuning (installed/configured/updated) para os 5 estados canonicos.
    param([string]$Installed, [string]$Configured, [string]$Updated)
    $inst = ([string]$Installed).Trim().ToLowerInvariant()
    $conf = ([string]$Configured).Trim().ToLowerInvariant()
    $upd = ([string]$Updated).Trim().ToLowerInvariant()
    if ($inst -eq 'missing' -or [string]::IsNullOrWhiteSpace($inst)) { return 'not-installed' }
    if ($conf -eq 'not-configured') { return 'installed-unconfigured' }
    if ($conf -in @('configured', 'planned')) {
        if ($upd -in @('current', 'ok', 'up-to-date', 'updated', 'optimized')) { return 'optimized-tested' }
        return 'configured'
    }
    return 'installed-unconfigured'
}

function Get-UiApiCanonicalStatus {
    # Mapeia o estado de validacao de credencial/provider para os 5 estados canonicos.
    param([string]$State)
    switch (([string]$State).Trim().ToLowerInvariant()) {
        'passed' { return 'optimized-tested' }
        'failed' { return 'error' }
        'rejected' { return 'error' }
        'expired' { return 'error' }
        'error' { return 'error' }
        'pending' { return 'installed-unconfigured' }
        'running' { return 'installed-unconfigured' }
        'untested' { return 'installed-unconfigured' }
        default { return 'not-installed' }
    }
}

function Get-UiHealthTextCanonicalStatus {
    # Deriva o estado canonico a partir do rotulo no texto "Card: LABEL - detalhe".
    param([string]$Text)
    $t = [string]$Text
    $label = if ($t -match ':\s*([^-\r\n]+)') { ($matches[1]).Trim() } else { $t.Trim() }
    switch -Regex ($label) {
        '^OK$'                  { return 'optimized-tested' }
        '^Aten'                 { return 'installed-unconfigured' }
        '^(Critico|Cr.tico)$'   { return 'error' }
        '^Bloqueado$'           { return 'error' }
        '^Ausente$'             { return 'not-installed' }
        default                 { return '' }
    }
}

#
# XAML Definition
#

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Bootstrap Tools" Width="1180" Height="800"
        Background="#0F1117" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Foreground="#E2E8F0"
        ResizeMode="CanResize">

    <Window.Resources>
        <!-- Colors -->
        <SolidColorBrush x:Key="BgBrush"       Color="#0F1117"/>
        <SolidColorBrush x:Key="SurfaceBrush"  Color="#1A1D2E"/>
        <SolidColorBrush x:Key="BorderBrush"   Color="#2D3148"/>
        <SolidColorBrush x:Key="AccentBrush"   Color="#7C3AED"/>
        <SolidColorBrush x:Key="AccentHover"   Color="#9D5CF5"/>
        <SolidColorBrush x:Key="AccentActive"  Color="#6D28D9"/>
        <SolidColorBrush x:Key="TextPrimary"   Color="#E2E8F0"/>
        <SolidColorBrush x:Key="TextSecondary" Color="#94A3B8"/>
        <SolidColorBrush x:Key="InputBg"       Color="#252840"/>
        <SolidColorBrush x:Key="SuccessBrush"  Color="#10B981"/>
        <SolidColorBrush x:Key="ErrorBrush"    Color="#EF4444"/>
        <SolidColorBrush x:Key="WarnBrush"     Color="#F59E0B"/>
        <SolidColorBrush x:Key="FocusVisualBrush" Color="#FBBF24"/>
        <SolidColorBrush x:Key="SidebarBg"     Color="#13162B"/>
        <SolidColorBrush x:Key="NavHoverBg"    Color="#1E2240"/>
        <SolidColorBrush x:Key="NavActiveBg"   Color="#2D1B69"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.WindowBrushKey}" Color="#252840"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.WindowTextBrushKey}" Color="#E2E8F0"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.ControlBrushKey}" Color="#252840"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.ControlTextBrushKey}" Color="#E2E8F0"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#7C3AED"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.GrayTextBrushKey}" Color="#94A3B8"/>

        <x:Array x:Key="SteamDeckExternalModes" Type="{x:Type sys:String}">
            <sys:String>HANDHELD</sys:String>
            <sys:String>DOCKED_MONITOR</sys:String>
            <sys:String>DOCKED_TV</sys:String>
        </x:Array>

        <x:Array x:Key="SteamDeckDisplayModes" Type="{x:Type sys:String}">
            <sys:String>extend</sys:String>
            <sys:String>internal</sys:String>
            <sys:String>external</sys:String>
            <sys:String>clone</sys:String>
        </x:Array>

        <!-- Base TextBox style -->
        <Style x:Key="DarkInput" TargetType="TextBox">
            <Setter Property="Background"       Value="#252840"/>
            <Setter Property="Foreground"       Value="#E2E8F0"/>
            <Setter Property="BorderBrush"      Value="#2D3148"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Padding"          Value="8,5"/>
            <Setter Property="CaretBrush"       Value="#7C3AED"/>
            <Setter Property="SelectionBrush"   Value="#7C3AED"/>
            <Setter Property="SelectionTextBrush" Value="#FFFFFF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="InputBorder"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost"
                                          Margin="{TemplateBinding Padding}"
                                          VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="InputBorder" Property="BorderBrush" Value="{StaticResource FocusVisualBrush}"/>
                                <Setter TargetName="InputBorder" Property="BorderThickness" Value="2"/>
                            </Trigger>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="InputBorder" Property="BorderBrush" Value="{StaticResource FocusVisualBrush}"/>
                                <Setter TargetName="InputBorder" Property="BorderThickness" Value="2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Readonly TextBox -->
        <Style x:Key="DarkReadonly" TargetType="TextBox" BasedOn="{StaticResource DarkInput}">
            <Setter Property="IsReadOnly"  Value="True"/>
            <Setter Property="Background" Value="#1A1D2E"/>
            <Setter Property="Foreground" Value="#94A3B8"/>
        </Style>

        <!-- ComboBox style -->
        <Style x:Key="DarkCombo" TargetType="ComboBox">
            <Setter Property="Background"      Value="#252840"/>
            <Setter Property="Foreground"      Value="#E2E8F0"/>
            <Setter Property="BorderBrush"     Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="8,5"/>
            <Setter Property="Height"          Value="34"/>
            <Setter Property="FontSize"        Value="13"/>
            <Setter Property="TextElement.Foreground" Value="#E2E8F0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ComboToggle"
                                          Focusable="False"
                                          ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="ComboBorder"
                                                Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                BorderThickness="{Binding BorderThickness, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                CornerRadius="6">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="30"/>
                                                </Grid.ColumnDefinitions>
                                                <ContentPresenter Grid.Column="0"
                                                                  Margin="10,0,6,0"
                                                                  VerticalAlignment="Center"
                                                                  HorizontalAlignment="Left"
                                                                  IsHitTestVisible="False"
                                                                  Content="{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                                  ContentTemplate="{Binding SelectionBoxItemTemplate, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                                  ContentTemplateSelector="{Binding ItemTemplateSelector, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                                                                  TextElement.Foreground="{Binding Foreground, RelativeSource={RelativeSource AncestorType=ComboBox}}"/>
                                                <Border Grid.Column="1" Background="#1A1D2E" CornerRadius="0,6,6,0" IsHitTestVisible="False">
                                                    <Path Data="M 0 0 L 4 4 L 8 0 Z"
                                                          Fill="#CBD5E1"
                                                          Width="8"
                                                          Height="4"
                                                          HorizontalAlignment="Center"
                                                          VerticalAlignment="Center"/>
                                                </Border>
                                            </Grid>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#7C3AED"/>
                                            </Trigger>
                                            <Trigger Property="IsChecked" Value="True">
                                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#9D5CF5"/>
                                            </Trigger>
                                            <Trigger Property="IsEnabled" Value="False">
                                                <Setter TargetName="ComboBorder" Property="Background" Value="#1E293B"/>
                                                <Setter TargetName="ComboBorder" Property="BorderBrush" Value="#334155"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>

                            <Popup x:Name="PART_Popup"
                                   Placement="Bottom"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True"
                                   Focusable="False"
                                   PopupAnimation="Fade">
                                <Border Background="#1A1D2E"
                                        BorderBrush="#2D3148"
                                        BorderThickness="1"
                                        CornerRadius="6"
                                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                                    <ScrollViewer Margin="2" SnapsToDevicePixels="True">
                                        <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="HasItems" Value="False">
                                <Setter TargetName="PART_Popup" Property="MinHeight" Value="20"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter Property="BorderBrush" Value="#9D5CF5"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#64748B"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkComboItem" TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#1A1D2E"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="Padding" Value="8,6"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#312E81"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="ComboBoxItem" BasedOn="{StaticResource DarkComboItem}"/>

        <!-- Primary button -->
        <Style x:Key="PrimaryBtn" TargetType="Button">
            <Setter Property="Background"   Value="#7C3AED"/>
            <Setter Property="Foreground"   Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding"      Value="18,9"/>
            <Setter Property="FontWeight"   Value="SemiBold"/>
            <Setter Property="Cursor"       Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#9D5CF5"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#6D28D9"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource FocusVisualBrush}"/>
                                <Setter TargetName="border" Property="BorderThickness" Value="2"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#374151"/>
                                <Setter Property="Foreground" Value="#94A3B8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Ghost / secondary button -->
        <Style x:Key="GhostBtn" TargetType="Button">
            <Setter Property="Background"   Value="Transparent"/>
            <Setter Property="Foreground"   Value="#94A3B8"/>
            <Setter Property="BorderBrush"  Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"      Value="14,7"/>
            <Setter Property="Cursor"       Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="7"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1E2240"/>
                                <Setter Property="Foreground" Value="#E2E8F0"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#252840"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource FocusVisualBrush}"/>
                                <Setter TargetName="border" Property="BorderThickness" Value="2"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#94A3B8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Preset quick-select button -->
        <Style x:Key="PresetBtn" TargetType="Button">
            <Setter Property="Background"   Value="#1A1D2E"/>
            <Setter Property="Foreground"   Value="#CBD5E1"/>
            <Setter Property="BorderBrush"  Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding"      Value="14,9"/>
            <Setter Property="Margin"       Value="0,4"/>
            <Setter Property="Cursor"       Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="7"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#252A44"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#7C3AED"/>
                                <Setter Property="Foreground" Value="#E2E8F0"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource FocusVisualBrush}"/>
                                <Setter TargetName="border" Property="BorderThickness" Value="2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Sidebar nav button -->
        <Style x:Key="NavBtn" TargetType="ToggleButton">
            <Setter Property="Background"            Value="Transparent"/>
            <Setter Property="Foreground"            Value="#94A3B8"/>
            <Setter Property="BorderThickness"       Value="0"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding"               Value="16,12"/>
            <Setter Property="Cursor"                Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="8"
                                Margin="8,2"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2D1B69"/>
                                <Setter Property="Foreground" Value="#E2E8F0"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1E2240"/>
                                <Setter Property="Foreground" Value="#E2E8F0"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource FocusVisualBrush}"/>
                                <Setter TargetName="border" Property="BorderThickness" Value="2"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Card border style for GroupBox replacement -->
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background"      Value="#1A1D2E"/>
            <Setter Property="BorderBrush"     Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius"    Value="12"/>
            <Setter Property="Padding"         Value="16"/>
        </Style>

        <!-- Clickable health card: looks like a Card but is an actionable Button (validacao por escopo) -->
        <Style x:Key="HealthCardButton" TargetType="Button">
            <Setter Property="Cursor"                   Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment"   Value="Top"/>
            <Setter Property="Foreground"               Value="#CBD5E1"/>
            <Setter Property="SnapsToDevicePixels"      Value="True"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="CardBorder" Background="#1A1D2E" BorderBrush="#2D3148" BorderThickness="1" CornerRadius="12" Padding="16">
                            <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Top"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CardBorder" Property="BorderBrush" Value="#4F46E5"/>
                                <Setter TargetName="CardBorder" Property="Background"  Value="#1F2336"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="CardBorder" Property="BorderBrush" Value="#6366F1"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="CardBorder" Property="Opacity" Value="0.55"/>
                                <Setter Property="Cursor" Value="Wait"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Section label -->
        <Style x:Key="SectionLabel" TargetType="TextBlock">
            <Setter Property="Foreground"  Value="#94A3B8"/>
            <Setter Property="FontSize"    Value="11"/>
            <Setter Property="FontWeight"  Value="SemiBold"/>
            <Setter Property="Margin"      Value="0,0,0,6"/>
        </Style>

        <!-- Page title -->
        <Style x:Key="PageTitle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="FontSize"   Value="22"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Margin"     Value="0,0,0,4"/>
        </Style>

        <!-- Page subtitle -->
        <Style x:Key="PageSubtitle" TargetType="TextBlock">
            <Setter Property="Foreground" Value="#94A3B8"/>
            <Setter Property="FontSize"   Value="13"/>
            <Setter Property="Margin"     Value="0,0,0,24"/>
        </Style>

        <!-- DataGrid style -->
        <Style x:Key="DarkGrid" TargetType="DataGrid">
            <Setter Property="Background"            Value="#1A1D2E"/>
            <Setter Property="Foreground"            Value="#CBD5E1"/>
            <Setter Property="BorderBrush"           Value="#2D3148"/>
            <Setter Property="BorderThickness"       Value="1"/>
            <Setter Property="RowBackground"         Value="#1A1D2E"/>
            <Setter Property="AlternatingRowBackground" Value="#1E2240"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#2D3148"/>
            <Setter Property="VerticalGridLinesBrush"   Value="#2D3148"/>
            <Setter Property="ColumnHeaderHeight"    Value="32"/>
            <Setter Property="RowHeight"             Value="28"/>
            <Setter Property="SelectionMode"         Value="Single"/>
            <Setter Property="AutoGenerateColumns"   Value="False"/>
            <Setter Property="RowHeaderWidth"        Value="0"/>
            <Setter Property="CanUserAddRows"        Value="True"/>
            <Setter Property="CanUserDeleteRows"     Value="True"/>
            <Setter Property="EnableRowVirtualization" Value="True"/>
            <Setter Property="EnableColumnVirtualization" Value="True"/>
            <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/>
            <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>
            <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
            <Setter Property="ScrollViewer.IsDeferredScrollingEnabled" Value="True"/>
        </Style>

        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#252840"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Setter Property="BorderBrush" Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="Padding" Value="8,0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>

        <Style TargetType="DataGridCell">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{Binding Foreground, RelativeSource={RelativeSource AncestorType=DataGridRow}}"/>
            <Setter Property="BorderBrush" Value="#2D3148"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="Padding" Value="6,0"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="DataGridRow">
            <Setter Property="Foreground" Value="#CBD5E1"/>
            <Setter Property="Background" Value="Transparent"/>
            <Style.Triggers>
                <DataTrigger Binding="{Binding statusCanonical}" Value="error">
                    <Setter Property="Foreground" Value="#EF4444"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding statusCanonical}" Value="not-installed">
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding statusCanonical}" Value="installed-unconfigured">
                    <Setter Property="Foreground" Value="#FACC15"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding statusCanonical}" Value="configured">
                    <Setter Property="Foreground" Value="#3B82F6"/>
                </DataTrigger>
                <DataTrigger Binding="{Binding statusCanonical}" Value="optimized-tested">
                    <Setter Property="Foreground" Value="#22C55E"/>
                </DataTrigger>
                <Trigger Property="IsKeyboardFocusWithin" Value="True">
                    <Setter Property="BorderBrush" Value="{StaticResource FocusVisualBrush}"/>
                    <Setter Property="BorderThickness" Value="1"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- CheckBox style -->
        <Style x:Key="DarkCheck" TargetType="CheckBox">
            <Setter Property="Foreground"   Value="#CBD5E1"/>
            <Setter Property="Margin"       Value="0,3"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="TextElement.Foreground" Value="#CBD5E1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <BulletDecorator Background="Transparent">
                            <BulletDecorator.Bullet>
                                <Border x:Name="CheckBorder"
                                        Width="16"
                                        Height="16"
                                        Margin="0,0,8,0"
                                        VerticalAlignment="Center"
                                        BorderThickness="1.5"
                                        CornerRadius="3"
                                        Background="#11162A"
                                        BorderBrush="#64748B">
                                    <Path x:Name="CheckMark"
                                          StrokeThickness="2.2"
                                          Stroke="#FFFFFF"
                                          Stretch="Uniform"
                                          Data="M 1 7 L 5 11 L 13 2"
                                          Visibility="Collapsed"/>
                                </Border>
                            </BulletDecorator.Bullet>
                            <ContentPresenter VerticalAlignment="Center"
                                              TextElement.Foreground="{TemplateBinding Foreground}"/>
                        </BulletDecorator>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="CheckBorder" Property="BorderBrush" Value="#A78BFA"/>
                                <Setter TargetName="CheckBorder" Property="Background" Value="#1A2140"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckBorder" Property="Background" Value="#7C3AED"/>
                                <Setter TargetName="CheckBorder" Property="BorderBrush" Value="#C4B5FD"/>
                                <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True">
                                <Setter TargetName="CheckBorder" Property="BorderBrush" Value="{StaticResource FocusVisualBrush}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#64748B"/>
                                <Setter TargetName="CheckBorder" Property="Background" Value="#1E293B"/>
                                <Setter TargetName="CheckBorder" Property="BorderBrush" Value="#475569"/>
                                <Setter TargetName="CheckMark" Property="Stroke" Value="#94A3B8"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DarkGridCheckBoxElement" TargetType="CheckBox" BasedOn="{StaticResource DarkCheck}">
            <Setter Property="HorizontalAlignment" Value="Center"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="ToolTip" Value="Marque para incluir a otimização; desmarque para excluir."/>
            <Setter Property="Focusable" Value="False"/>
        </Style>

        <Style x:Key="DarkGridCheckBoxEditing" TargetType="CheckBox" BasedOn="{StaticResource DarkCheck}">
            <Setter Property="HorizontalAlignment" Value="Center"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Margin" Value="0"/>
            <Setter Property="ToolTip" Value="Marque para incluir a otimização; desmarque para excluir."/>
        </Style>

        <!-- ListBox item style -->
        <Style x:Key="DarkListItem" TargetType="ListBoxItem">
            <Setter Property="Foreground"  Value="#CBD5E1"/>
            <Setter Property="Padding"     Value="8,4"/>
            <Setter Property="Background"  Value="Transparent"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#1E2240"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="ListBoxItem" BasedOn="{StaticResource DarkListItem}"/>

        <!-- TreeView item -->
        <Style x:Key="DarkTreeItem" TargetType="TreeViewItem">
            <Setter Property="Foreground"  Value="#CBD5E1"/>
            <Setter Property="Padding"     Value="4,3"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#2D1B69"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="44"/>
        </Grid.RowDefinitions>

        <!--  SIDEBAR  -->
        <Border Grid.Column="0" Grid.Row="0" Grid.RowSpan="2"
                Background="#13162B"
                BorderBrush="#2D3148" BorderThickness="0,0,1,0">
            <DockPanel>
                <!-- Logo / app name -->
                <StackPanel DockPanel.Dock="Top" Margin="20,24,20,28">
                    <TextBlock Text="Z Bootstrap" FontSize="16" FontWeight="Bold"
                               Foreground="#7C3AED"/>
                    <TextBlock Text="Tools Control Center" FontSize="11"
                               Foreground="#94A3B8" Margin="0,2,0,0"/>
                </StackPanel>

                <!-- Nav items -->
                <StackPanel x:Name="NavPanel" DockPanel.Dock="Top" Margin="0,0,0,0">
                    <TextBlock Text="Instalação" Foreground="#64748B" FontSize="10" FontWeight="SemiBold" Margin="22,0,0,6"/>
                    <ToggleButton x:Name="NavHealth"    Style="{StaticResource NavBtn}" IsChecked="True">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="+" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavHealthText" Text="Saúde" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavWelcome"      Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="⌂" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavWelcomeText" Text="Início" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavSelection"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="▣" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavSelectionText" Text="Escolher" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavHostSetup"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="⚙" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavHostSetupText" Text="Configurar PC" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavAppTuning"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="◈" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavAppTuningText" Text="Otimizar Apps" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavAiTools"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="AI" FontSize="12" FontWeight="SemiBold" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavAiToolsText" Text="AI Coding Tools" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <TextBlock Text="Credenciais" Foreground="#64748B" FontSize="10" FontWeight="SemiBold" Margin="22,12,0,6"/>
                    <ToggleButton x:Name="NavApiCenter"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="●" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavApiCenterText" Text="Chaves (APIs)" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <TextBlock Text="Steam Deck" Foreground="#64748B" FontSize="10" FontWeight="SemiBold" Margin="22,12,0,6"/>
                    <ToggleButton x:Name="NavSteamDeck"    Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="▤" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavSteamDeckText" Text="Steam Deck" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <TextBlock Text="Sistema avançado" Foreground="#64748B" FontSize="10" FontWeight="SemiBold" Margin="22,12,0,6"/>
                    <ToggleButton x:Name="NavDualBoot"       Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="⏻" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavDualBootText" Text="Dual Boot" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavReview"       Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="✓" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavReviewText" Text="Revisar" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton x:Name="NavRun"          Style="{StaticResource NavBtn}">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="▶" FontSize="15" Margin="0,0,10,0"/>
                            <TextBlock x:Name="NavRunText" Text="Executar" VerticalAlignment="Center"/>
                        </StackPanel>
                    </ToggleButton>
                </StackPanel>

                <!-- Bottom nav actions -->
                <StackPanel DockPanel.Dock="Bottom" Margin="12,16">
                    <Button x:Name="BackButton"   Style="{StaticResource GhostBtn}" Content="Voltar"  Margin="0,4" Height="34"/>
                    <Button x:Name="NextButton"   Style="{StaticResource PrimaryBtn}" Content="Avançar" Margin="0,4" Height="34"/>
                    <Button x:Name="FinishButton" Style="{StaticResource GhostBtn}" Content="Fechar"     Margin="0,4" Height="34"/>
                </StackPanel>
            </DockPanel>
        </Border>

        <!--  CONTENT AREA  -->
        <Grid Grid.Column="1" Grid.Row="0">

            <!--  WELCOME PAGE  -->
            <ScrollViewer x:Name="PageWelcome" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="WelcomeTitleLabel"    Style="{StaticResource PageTitle}"    Text="Bootstrap Tools + Steam Deck"/>
                    <TextBlock x:Name="WelcomeSubtitleLabel" Style="{StaticResource PageSubtitle}" Text="Setup simples do host, controle do Steam Deck e manutenção pós-instalação."
                               TextWrapping="Wrap"/>

                    <!-- Language selector -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <StackPanel>
                            <TextBlock Style="{StaticResource SectionLabel}" Text="IDIOMA / LANGUAGE"/>
                            <ComboBox x:Name="LanguageCombo" Style="{StaticResource DarkCombo}" Width="200" HorizontalAlignment="Left"/>
                        </StackPanel>
                    </Border>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="16"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="16"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Quick Presets -->
                        <Border Grid.Row="0" Grid.Column="0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="QuickPresetsLabel" Style="{StaticResource SectionLabel}" Text="PRESETS RÁPIDOS"/>
                                <Button x:Name="PresetRecommended"      Style="{StaticResource PresetBtn}" Tag="recommended"      Content="*  recommended"/>
                                <Button x:Name="PresetLegacy"           Style="{StaticResource PresetBtn}" Tag="legacy"           Content="  legacy"/>
                                <Button x:Name="PresetFull"             Style="{StaticResource PresetBtn}" Tag="full"             Content="  full"/>
                                <Button x:Name="PresetSteamdeckRec"     Style="{StaticResource PresetBtn}" Tag="steamdeck-recommended" Content="  steamdeck-recommended"/>
                                <Button x:Name="PresetSteamdeckFull"    Style="{StaticResource PresetBtn}" Tag="steamdeck-full"   Content="  steamdeck-full"/>
                            </StackPanel>
                        </Border>

                        <!-- Custom Presets -->
                        <Border Grid.Row="0" Grid.Column="2" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="CustomPresetsLabel" Style="{StaticResource SectionLabel}" Text="PRESETS PERSONALIZADOS"/>
                                <TextBlock x:Name="PresetNameLabel" Foreground="#94A3B8" FontSize="12" Text="Nome do preset" Margin="0,0,0,4"/>
                                <TextBox x:Name="PresetNameTextBox" Style="{StaticResource DarkInput}" Margin="0,0,0,8" Height="32"/>
                                <Button x:Name="SavePresetButton" Style="{StaticResource GhostBtn}" Margin="0,0,0,12" Height="32" HorizontalAlignment="Stretch" Content="  Salvar preset atual"/>
                                <Separator Background="#2D3148" Margin="0,0,0,12"/>
                                <ComboBox x:Name="CustomPresetCombo" Style="{StaticResource DarkCombo}" Margin="0,0,0,8"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition/>
                                        <ColumnDefinition Width="8"/>
                                        <ColumnDefinition/>
                                    </Grid.ColumnDefinitions>
                                    <Button x:Name="LoadPresetButton"   Grid.Column="0" Style="{StaticResource GhostBtn}" Content=" Carregar" Height="32"/>
                                    <Button x:Name="DeletePresetButton" Grid.Column="2" Style="{StaticResource GhostBtn}" Content=" Excluir"  Height="32"/>
                                </Grid>
                            </StackPanel>
                        </Border>

                        <!-- Maintenance Card -->
                        <Border Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="3" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="MaintenanceLabel" Style="{StaticResource SectionLabel}" DockPanel.Dock="Top" Text="MANUTENÇÃO E RESILIÊNCIA"/>
                                <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                                    <Button x:Name="DoctorQuickButton" Style="{StaticResource GhostBtn}" Content="  Diagnóstico" Height="32" Margin="0,0,12,0"/>
                                    <Button x:Name="SupportBundleQuickButton" Style="{StaticResource GhostBtn}" Content="  Pacote de suporte" Height="32" Margin="0,0,12,0"/>
                                    <Button x:Name="AuditIntegrityButton" Style="{StaticResource GhostBtn}" Content="  Verificar integridade" Height="32" Margin="0,0,12,0"/>
                                    <Button x:Name="RollbackChangesButton" Style="{StaticResource GhostBtn}" Content="  Reverter ajustes" Foreground="{StaticResource WarnBrush}" Height="32" Margin="0,0,12,0"/>
                                    <TextBlock Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="400"
                                               Text="A reversão desfaz apenas ajustes de registro e sistema. Apps instalados devem ser removidos manualmente."/>
                                </StackPanel>
                            </DockPanel>
                        </Border>
                    </Grid>
                </StackPanel>
            </ScrollViewer>

            <!--  SELECTION PAGE  -->
            <Grid x:Name="PageSelection" Visibility="Collapsed" Margin="32,28">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0">
                    <TextBlock x:Name="SelectionTitleLabel" Style="{StaticResource PageTitle}" Text="Perfis e Componentes"/>
                    <!-- Filter bar -->
                    <Grid Margin="0,0,0,16">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                            <TextBlock Grid.Column="0" Text="" FontSize="16" VerticalAlignment="Center" Margin="0,0,8,0" Foreground="#94A3B8"/>
                        <TextBox x:Name="FilterTextBox" Grid.Column="1" Style="{StaticResource DarkInput}" Height="34" ToolTip="Filtro por nome ou descrição. Várias palavras: todas devem aparecer (ex.: dotnet core). Hífens são ignorados (dotnetcore encontra dotnet-core)."/>
                        <Button x:Name="RefreshStatusButton" Grid.Column="2" Style="{StaticResource GhostBtn}" Content="Atualizar status" Margin="10,0,0,0" Height="34" ToolTip="Recalcula o status de cada componente ao vivo (instalado/configurado), inclusive apps winget portateis, e recolore a lista."/>
                        <Button x:Name="ClearAllSelectionButton" Grid.Column="3" Style="{StaticResource GhostBtn}" Content=" Limpar tudo" Margin="10,0,0,0" Height="34"/>
                    </Grid>
                </StackPanel>

                <Grid Grid.Row="2">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="260"/>
                    </Grid.ColumnDefinitions>

                    <!-- Profiles Tree -->
                    <Border Grid.Column="0" Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="ProfilesLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="PERFIS"/>
                            <TreeView x:Name="ProfilesTree" Background="Transparent" BorderThickness="0"
                                      Foreground="#CBD5E1" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>

                    <!-- Components Tree -->
                    <Border Grid.Column="2" Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="ComponentsLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="COMPONENTES"/>
                            <WrapPanel DockPanel.Dock="Top" Margin="0,2,0,4">
                                <TextBlock Text="Status:" Foreground="#94A3B8" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                <TextBlock Text="&#9679; nao instalado" Foreground="#FFFFFF" FontSize="11" Margin="0,0,10,0"/>
                                <TextBlock Text="&#9679; nao configurado" Foreground="#FACC15" FontSize="11" Margin="0,0,10,0"/>
                                <TextBlock Text="&#9679; configurado" Foreground="#3B82F6" FontSize="11" Margin="0,0,10,0"/>
                                <TextBlock Text="&#9679; otimizado/testado" Foreground="#22C55E" FontSize="11" Margin="0,0,10,0"/>
                                <TextBlock Text="&#9679; erro" Foreground="#EF4444" FontSize="11" Margin="0,0,10,0"/>
                            </WrapPanel>
                            <TreeView x:Name="ComponentsTree" Background="Transparent" BorderThickness="0"
                                      Foreground="#CBD5E1" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>

                    <!-- Excludes + Details -->
                    <Grid Grid.Column="4">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="12"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="12"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="QuickOptionsLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="OPÇÕES RÁPIDAS"/>
                                <StackPanel Margin="0,6,0,0">
                                    <CheckBox x:Name="OptClaudePluginsCheckBox" Style="{StaticResource DarkCheck}" Content="Claude Code: plugins"/>
                                    <CheckBox x:Name="OptClaudeProjectMcpsCheckBox" Style="{StaticResource DarkCheck}" Content="Claude Code: conexões do projeto"/>
                                    <CheckBox x:Name="OptOpenWebUICheckBox" Style="{StaticResource DarkCheck}" Content="IA local: Open WebUI (Docker)"/>
                                    <CheckBox x:Name="OptSkipManualRequirementsCheckBox" Style="{StaticResource DarkCheck}" Content="Pular requisitos manuais (bloqueantes)"/>
                                    <CheckBox x:Name="OptIgnoreManualRequirementsCheckBox" Style="{StaticResource DarkCheck}" Content="Ignorar requisitos manuais (apenas log)"/>
                                    <CheckBox x:Name="OptRequireNoPendingRebootCheckBox" Style="{StaticResource DarkCheck}" Content="Parar se houver reinício pendente"/>
                                    <CheckBox x:Name="OptOfflineModeCheckBox" Style="{StaticResource DarkCheck}" Content="Modo Offline (usa cache local)"/>
                                    <CheckBox x:Name="OptEnableResumeCheckBox" Style="{StaticResource DarkCheck}" Content="Retomar instalacao interrompida"/>
                                </StackPanel>
                            </DockPanel>
                        </Border>
                        <Border Grid.Row="2" Style="{StaticResource Card}">
                            <DockPanel>
                            <TextBlock x:Name="ExcludeLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="EXCLUSÕES OPCIONAIS"/>
                                <ListBox x:Name="ExcludeList" Background="Transparent" BorderThickness="0"
                                         Foreground="#CBD5E1" Margin="0,4,0,0"/>
                            </DockPanel>
                        </Border>
                        <Border Grid.Row="4" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="DetailsLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="DETALHES"/>
                                <StackPanel x:Name="ConfigActionsPanel" DockPanel.Dock="Bottom" Margin="0,8,0,0">
                                    <TextBlock x:Name="ConfigActionsLabel" Style="{StaticResource SectionLabel}" Text="AÇÕES DE CONFIGURAÇÃO (item selecionado)"/>
                                    <WrapPanel Margin="0,4,0,0">
                                        <Button x:Name="CfgConfigureButton" Style="{StaticResource GhostBtn}" Content="Configurar/Otimizar" Margin="0,0,6,6" Height="30"/>
                                        <Button x:Name="CfgResetButton" Style="{StaticResource GhostBtn}" Content="Reverter (fábrica)" Margin="0,0,6,6" Height="30"/>
                                        <Button x:Name="CfgExportButton" Style="{StaticResource GhostBtn}" Content="Exportar" Margin="0,0,6,6" Height="30"/>
                                        <Button x:Name="CfgImportButton" Style="{StaticResource GhostBtn}" Content="Importar" Margin="0,0,6,6" Height="30"/>
                                    </WrapPanel>
                                    <WrapPanel Margin="0,2,0,0">
                                        <Button x:Name="CfgBatchResetButton" Style="{StaticResource GhostBtn}" Content="Lote: reverter amarelos" Margin="0,0,6,6" Height="30"/>
                                        <Button x:Name="InstallWebappsButton" Style="{StaticResource GhostBtn}" Content="Instalar todos os Web Apps" Margin="0,0,6,6" Height="30"/>
                                    </WrapPanel>
                                </StackPanel>
                                <TextBox x:Name="DetailsTextBox" Style="{StaticResource DarkReadonly}"
                                         TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
                            </DockPanel>
                        </Border>
                    </Grid>
                </Grid>

                <!-- Summary -->
                <Border Grid.Row="3" Background="#1A1D2E" CornerRadius="8" Padding="12,8" Margin="0,10,0,0">
                    <StackPanel>
                        <TextBlock x:Name="SelectionSummaryLabel" Foreground="#94A3B8" FontSize="12"/>
                        <TextBlock x:Name="SelectionErrorLabel"   Foreground="#EF4444" FontSize="12" TextWrapping="Wrap"/>
                    </StackPanel>
                </Border>
            </Grid>

            <!--  HOST SETUP PAGE  -->
            <ScrollViewer x:Name="PageHostSetup" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="HostTitleLabel" Style="{StaticResource PageTitle}" Text="Configuração do Host"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Configurações de ambiente e saúde do sistema." TextWrapping="Wrap"/>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="200"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="12"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <TextBlock x:Name="HostHealthLabel"       Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Nível de manutenção"/>
                            <ComboBox  x:Name="HostHealthCombo"       Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkCombo}"/>
                            <TextBlock x:Name="SteamDeckVersionLabel" Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Versão Steam Deck"/>
                            <ComboBox  x:Name="SteamDeckVersionCombo" Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkCombo}"/>
                        </Grid>
                    </Border>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="200"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="110"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="12"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <TextBlock x:Name="WorkspaceRootLabel"  Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Workspace Root"/>
                            <TextBox   x:Name="WorkspaceRootTextBox" Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                            <Button    x:Name="WorkspaceBrowseButton" Grid.Row="0" Grid.Column="2" Style="{StaticResource GhostBtn}" Content=" Selecionar" Margin="8,0,0,0" Height="32"/>
                            <TextBlock x:Name="CloneBaseDirLabel"   Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Clone Base Dir"/>
                            <TextBox   x:Name="CloneBaseDirTextBox"  Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                            <Button    x:Name="CloneBrowseButton"    Grid.Row="2" Grid.Column="2" Style="{StaticResource GhostBtn}" Content=" Selecionar" Margin="8,0,0,0" Height="32"/>
                        </Grid>
                    </Border>

                    <Border Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="AdminNeedsTitleLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="REVISÃO DE ADMIN"/>
                            <TextBox   x:Name="AdminNeedsTextBox" Style="{StaticResource DarkReadonly}"
                                       Height="160" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  HEALTH PAGE  -->
            <ScrollViewer x:Name="PageHealth" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="HealthTitleLabel" Style="{StaticResource PageTitle}" Text="Saúde"/>
                    <TextBlock x:Name="HealthSummaryLabel" Style="{StaticResource PageSubtitle}" Text="Diagnóstico local, pacote de suporte e fila manual de reparo." TextWrapping="Wrap"/>
                    <WrapPanel Margin="0,0,0,10">
                        <TextBlock Text="Após rodar diagnóstico:" Foreground="#94A3B8" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock Text="&#9679; OK" Foreground="#22C55E" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; atenção" Foreground="#FACC15" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; ausente" Foreground="#FFFFFF" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; crítico/bloqueado" Foreground="#EF4444" FontSize="11" Margin="0,0,10,0"/>
                    </WrapPanel>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <StackPanel>
                            <TextBlock Style="{StaticResource SectionLabel}" Text="STATUS"/>
                            <TextBlock x:Name="HealthStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="Rode o diagnóstico para atualizar a saúde local."/>
                        </StackPanel>
                    </Border>

                    <UniformGrid Columns="4" Margin="0,0,0,16">
                        <Button x:Name="HealthWslCard" Tag="wsl" Style="{StaticResource HealthCardButton}" Margin="0,0,8,8" ToolTip="Validar somente WSL">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="WSL"/>
                                <TextBlock x:Name="HealthWslStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="WSL: Ausente"/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthWingetCard" Tag="winget" Style="{StaticResource HealthCardButton}" Margin="0,0,8,8" ToolTip="Validar somente winget">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="winget"/>
                                <TextBlock x:Name="HealthWingetStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="winget: Ausente"/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthRebootCard" Tag="reboot" Style="{StaticResource HealthCardButton}" Margin="0,0,8,8" ToolTip="Validar somente reinício pendente">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="Reinício"/>
                                <TextBlock x:Name="HealthRebootStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="Reinício: OK"/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthSecretsCard" Tag="secrets" Style="{StaticResource HealthCardButton}" Margin="0,0,0,8" ToolTip="Validar somente chaves e provedores">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="Chaves"/>
                                <TextBlock x:Name="HealthSecretsStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="Chaves: Atenção"/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthGithubCard" Tag="github" Style="{StaticResource HealthCardButton}" Margin="0,0,8,0" ToolTip="Validar somente GitHub CLI">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="GitHub CLI"/>
                                <TextBlock x:Name="HealthGithubStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="GitHub CLI: não verificado."/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthAiUsagebarCard" Tag="ai-usagebar" Style="{StaticResource HealthCardButton}" Margin="0,0,8,0" ToolTip="Validar somente ai-usagebar">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="ai-usagebar"/>
                                <TextBlock x:Name="HealthAiUsagebarStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="ai-usagebar: Ausente"/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthAiMemoryCard" Tag="ai-memory" Style="{StaticResource HealthCardButton}" Margin="0,0,8,0" ToolTip="Instalar, reparar, sincronizar e proteger memória">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="ai-memory"/>
                                <TextBlock x:Name="HealthAiMemoryStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="ai-memory: Ausente"/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthAionUiCard" Tag="aionui" Style="{StaticResource HealthCardButton}" Margin="0,0,8,0" ToolTip="Validar somente AionUI">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="AionUI"/>
                                <TextBlock x:Name="HealthAionUiStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="AionUI: Ausente"/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthDeckCard" Tag="steamdeck" Style="{StaticResource HealthCardButton}" Margin="0,0,8,0" ToolTip="Validar somente Steam Deck">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="Steam Deck"/>
                                <TextBlock x:Name="HealthDeckStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="Steam Deck: não verificado."/>
                            </StackPanel>
                        </Button>
                        <Button x:Name="HealthRollbackCard" Tag="rollback" Style="{StaticResource HealthCardButton}" Margin="0,0,0,0" ToolTip="Validar somente reversão segura">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="Reversão"/>
                                <TextBlock x:Name="HealthRollbackStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="Reversão: Crítico/Bloqueado se confirmação faltar."/>
                            </StackPanel>
                        </Button>
                    </UniformGrid>

                    <Grid Margin="0,0,0,16">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="12"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="12"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="DIAGNÓSTICO"/>
                                <TextBlock Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,10" Text="Verifica WSL, winget, reinício, chaves, contrato da UI e logs."/>
                                <Button x:Name="HealthDoctorButton" Style="{StaticResource PrimaryBtn}" Content="Rodar diagnóstico" Height="34"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="PACOTE DE SUPORTE"/>
                                <TextBlock Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,10" Text="Exporta diagnóstico local sem segredos para suporte."/>
                                <Button x:Name="HealthSupportBundleButton" Style="{StaticResource GhostBtn}" Content="Exportar pacote" Height="34"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="4" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="REPAROS"/>
                                <TextBlock Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,10" Text="Fila de ações com risco, admin e reversão; execução manual."/>
                                <Button x:Name="HealthRepairPlanButton" Style="{StaticResource GhostBtn}" Content="Ver reparos" Height="34"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                    <WrapPanel Margin="0,0,0,16">
                        <Button x:Name="HealthAgentToolsButton" Style="{StaticResource PrimaryBtn}" Content="Memória e eficiência" Height="32" Margin="0,0,8,8" ToolTip="Escolher projeto, perfil por agente, comparar saída local e revisar componentes."/>
                        <Button x:Name="HealthAgentToolsRepairButton" Style="{StaticResource GhostBtn}" Content="Reparar tokens/memória" Height="32" Margin="0,0,8,8" ToolTip="Repara somente itens ausentes desse grupo, com confirmação e sem gravar segredos."/>
                        <Button x:Name="HealthMsvcButton" Style="{StaticResource GhostBtn}" Content="Compilador Windows" Height="32" Margin="0,0,8,8" ToolTip="Valida ferramentas de compilação e bibliotecas do Windows usadas por dependências nativas."/>
                        <Button x:Name="HealthWindowsOptButton" Style="{StaticResource GhostBtn}" Content="Otimizar Windows" Height="32" Margin="0,0,8,8" ToolTip="Mostra recomendações seguras de desempenho e manutenção sem aplicar alterações automáticas."/>
                        <Button x:Name="HealthValidateMcpButton" Style="{StaticResource GhostBtn}" Content="Validar conexões de IA" Height="32" Margin="0,0,8,8" ToolTip="Valida as conexões locais usadas pelos IDEs e CLIs de IA, sem reparar."/>
                        <Button x:Name="HealthCopyDiagnosticButton" Style="{StaticResource GhostBtn}" Content="Copiar diagnóstico" Height="32" Margin="0,0,8,8"/>
                        <Button x:Name="HealthRepairMcpButton" Style="{StaticResource GhostBtn}" Content="Reparar conexões de IA" Height="32" Margin="0,0,8,8" ToolTip="Corrige comandos de conexão local incompatíveis e cria backup antes de gravar."/>
                        <Button x:Name="HealthDriftCheckButton" Style="{StaticResource GhostBtn}" Content="Verificar mudanças" Height="32" Margin="0,0,8,8" ToolTip="Compara a saúde atual com a última referência e mostra o que piorou."/>
                        <Button x:Name="HealthDriftScheduleButton" Style="{StaticResource GhostBtn}" Content="Agendar verificação semanal" Height="32" Margin="0,0,0,8" ToolTip="Liga ou desliga uma verificação semanal em segundo plano para este usuário."/>
                    </WrapPanel>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Top">
                                <TextBlock Style="{StaticResource SectionLabel}" Text="DRIVES E PARTIÇÕES"/>
                                <TextBlock x:Name="HealthDriveLabelsStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,10" Text="Diagnostique discos, partições Windows/Linux/SteamOS e rótulos sugeridos antes de aplicar qualquer alteração."/>
                                <WrapPanel Margin="0,0,0,10">
                                    <Button x:Name="HealthDriveLabelsButton" Style="{StaticResource PrimaryBtn}" Content="Diagnosticar drives" Height="32" Margin="0,0,8,8" ToolTip="Lê discos/partições e monta um mapa pedagógico. Não altera nada."/>
                                    <CheckBox x:Name="HealthDriveLabelsAdvancedCheck" Style="{StaticResource DarkCheck}" Content="Modo avançado" Margin="0,7,12,8" ToolTip="Libera a ação de aplicar rótulos apenas após confirmação explícita."/>
                                    <Button x:Name="HealthDriveLabelsApplyButton" Style="{StaticResource GhostBtn}" Content="Aplicar rótulos seguros" Height="32" Margin="0,0,8,8" IsEnabled="False" ToolTip="Renomeia somente volumes de dados Windows elegíveis. Exige modo avançado e token digitado."/>
                                </WrapPanel>
                            </StackPanel>
                            <DataGrid x:Name="HealthDriveLabelsGrid" Style="{StaticResource DarkGrid}" Height="190" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False" IsReadOnly="True">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Partição" Binding="{Binding identity}" Width="0.65*"/>
                                    <DataGridTextColumn Header="Drive" Binding="{Binding drive}" Width="0.45*"/>
                                    <DataGridTextColumn Header="Papel" Binding="{Binding role}" Width="1.0*"/>
                                    <DataGridTextColumn Header="Atual" Binding="{Binding currentLabel}" Width="0.75*"/>
                                    <DataGridTextColumn Header="Sugerido" Binding="{Binding proposedLabel}" Width="0.85*"/>
                                    <DataGridTextColumn Header="Ação" Binding="{Binding action}" Width="0.75*"/>
                                    <DataGridTextColumn Header="Motivo" Binding="{Binding reasons}" Width="1.5*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>

                    <Border Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock Style="{StaticResource SectionLabel}" DockPanel.Dock="Top" Text="ÚLTIMO RESULTADO"/>
                            <TextBox x:Name="HealthDoctorTextBox" Style="{StaticResource DarkReadonly}" Height="220" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  APP TUNING PAGE  -->
            <ScrollViewer x:Name="PageAppTuning" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="AppTuningTitleLabel" Style="{StaticResource PageTitle}" Text="Otimizar apps"/>
                    <TextBlock x:Name="AppTuningSubtitleLabel" Style="{StaticResource PageSubtitle}" Text="Pré-configure ferramentas instaladas por categoria e perfil, com padrões seguros." TextWrapping="Wrap"/>
                    <WrapPanel Margin="0,0,0,10">
                        <TextBlock Text="Status:" Foreground="#94A3B8" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock Text="&#9679; nao instalado" Foreground="#FFFFFF" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; nao configurado" Foreground="#FACC15" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; configurado" Foreground="#3B82F6" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; otimizado/atualizado" Foreground="#22C55E" FontSize="11" Margin="0,0,10,0"/>
                    </WrapPanel>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="130"/>
                            <ColumnDefinition Width="170"/>
                            <ColumnDefinition Width="70"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="80"/>
                            <ColumnDefinition Width="145"/>
                            <ColumnDefinition Width="70"/>
                            <ColumnDefinition Width="150"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="10"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <TextBlock x:Name="AppTuningModeLabel" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Modo de ajuste"/>
                        <ComboBox x:Name="AppTuningModeCombo" Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkCombo}" Margin="0,0,12,0"/>
                        <TextBlock Grid.Row="0" Grid.Column="2" Foreground="#94A3B8" VerticalAlignment="Center" Text="Busca" ToolTip="Filtre por categoria, app, ID, nome da otimização, descrição ou componente."/>
                        <TextBox x:Name="AppTuningSearchBox" Grid.Row="0" Grid.Column="3" Style="{StaticResource DarkInput}" Height="34" Margin="0,0,12,0" ToolTip="Digite parte do nome do app, categoria, item ou componente para buscar."/>
                        <TextBlock Grid.Row="0" Grid.Column="4" Foreground="#94A3B8" VerticalAlignment="Center" Text="Status" ToolTip="All: tudo | installed: instalado | missing: ausente | planned: planejado | not-configured: não configurado | update-check: requer verificação."/>
                        <ComboBox x:Name="AppTuningStatusFilterCombo" Grid.Row="0" Grid.Column="5" Style="{StaticResource DarkCombo}" ToolTip="Filtre os itens pelo estado atual para focar na ação necessária."/>

                        <TextBlock Grid.Row="0" Grid.Column="6" Foreground="#94A3B8" VerticalAlignment="Center" Text="Risco" ToolTip="Filtre por risco: conservative, advanced, aggressive."/>
                        <ComboBox x:Name="AppTuningRiskFilterCombo" Grid.Row="0" Grid.Column="7" Style="{StaticResource DarkCombo}" ToolTip="Filtre itens por risco operacional."/>

                        <TextBlock x:Name="AppTuningStatusLabel" Grid.Row="2" Grid.Column="0" Grid.ColumnSpan="3" Foreground="#94A3B8" VerticalAlignment="Center" TextWrapping="Wrap"/>
                        <WrapPanel Grid.Row="2" Grid.Column="3" Grid.ColumnSpan="5" HorizontalAlignment="Right">
                            <Button x:Name="AppTuningRecommendedButton" Style="{StaticResource GhostBtn}" Content="Marcar recomendados" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningMarkCategoryButton" Style="{StaticResource GhostBtn}" Content="Marcar categoria" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningClearCategoryButton" Style="{StaticResource GhostBtn}" Content="Limpar categoria" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningAuditButton" Style="{StaticResource GhostBtn}" Content="Atualizar status" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningClearAllButton" Style="{StaticResource GhostBtn}" Content="Limpar tudo" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningInstallButton" Style="{StaticResource GhostBtn}" Content="Instalar" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningConfigureButton" Style="{StaticResource PrimaryBtn}" Content="Configurar/Otimizar" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningUpdateButton" Style="{StaticResource GhostBtn}" Content="Atualizar" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningRunNowButton" Style="{StaticResource PrimaryBtn}" Content="Executar agora" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningOpenFolderButton" Style="{StaticResource GhostBtn}" Content="Abrir pasta" Margin="0,0,8,0" Height="32"/>
                            <Button x:Name="AppTuningViewLogButton" Style="{StaticResource GhostBtn}" Content="Ver log" Height="32"/>
                        </WrapPanel>
                        <TextBlock x:Name="AppTuningRiskWarningLabel" Grid.Row="3" Grid.Column="0" Grid.ColumnSpan="8" Margin="0,8,0,0" Foreground="#F59E0B" TextWrapping="Wrap" ToolTip="Aviso para itens com impacto de segurança ou risco operacional."/>
                    </Grid>
                </Border>

                <Grid Height="470">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="300"/>
                        <ColumnDefinition Width="14"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Border Grid.Column="0" Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="AppTuningCategoriesLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="CATEGORIAS"/>
                            <ListBox x:Name="AppTuningCategoryList" Background="Transparent" BorderThickness="0" Foreground="#CBD5E1" Margin="0,4,0,0"/>
                        </DockPanel>
                    </Border>

                    <Border Grid.Column="2" Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="AppTuningItemsLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="ITENS"/>
                            <DataGrid x:Name="AppTuningItemsGrid" Style="{StaticResource DarkGrid}" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False" SelectionMode="Extended" ToolTip="Selos: Seguro, Manual, Docker, chave própria">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Ativo" Binding="{Binding active, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="70" ElementStyle="{StaticResource DarkGridCheckBoxElement}" EditingElementStyle="{StaticResource DarkGridCheckBoxEditing}"/>
                                    <DataGridTextColumn Header="Id" Binding="{Binding id}" Width="0" Visibility="Collapsed"/>
                                    <DataGridTextColumn Header="Componentes" Binding="{Binding installComponents}" Width="0" Visibility="Collapsed"/>
                                    <DataGridTextColumn Header="Categoria" Binding="{Binding category}" Width="1.1*"/>
                                    <DataGridTextColumn Header="App" Binding="{Binding app}" Width="1.2*"/>
                                    <DataGridTextColumn Header="Otimização" Binding="{Binding optimization}" Width="1.8*"/>
                                    <DataGridTextColumn Header="Perfil" Binding="{Binding profile}" Width="1.2*"/>
                                    <DataGridTextColumn Header="Risco" Binding="{Binding risk}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Selos" Binding="{Binding badges}" Width="1.0*"/>
                                    <DataGridTextColumn Header="Impacto de segurança" Binding="{Binding securityImpact}" Width="0" Visibility="Collapsed"/>
                                    <DataGridTextColumn Header="Reversão" Binding="{Binding rollbackScope}" Width="0.9*"/>
                                    <DataGridTextColumn Header="Instalado" Binding="{Binding installed}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Configurado" Binding="{Binding configured}" Width="0.9*"/>
                                    <DataGridTextColumn Header="Atualizado" Binding="{Binding updated}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Admin" Binding="{Binding admin}" Width="0.7*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>
                </Grid>

                <Border Background="#1A1D2E" CornerRadius="8" Padding="12,8" Margin="0,10,0,0">
                    <TextBlock x:Name="AppTuningHintLabel" Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap"/>
                </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  AI CODING TOOLS PAGE  -->
            <ScrollViewer x:Name="PageAiTools" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="AiToolsTitleLabel" Style="{StaticResource PageTitle}" Text="AI Coding Tools"/>
                    <TextBlock x:Name="AiToolsSubtitleLabel" Style="{StaticResource PageSubtitle}" Text="Marque (coluna Ativo) uma ou mais ferramentas; as acoes abaixo atuam em TODAS as marcadas. Use Limpar selecao para desmarcar tudo." TextWrapping="Wrap"/>

                    <Border Background="#1A1D2E" CornerRadius="8" Padding="14,10" Margin="0,0,0,14">
                        <DockPanel>
                            <WrapPanel DockPanel.Dock="Right" HorizontalAlignment="Right">
                                <Button x:Name="AiToolsInstallButton" Style="{StaticResource PrimaryBtn}" Content="Instalar marcadas" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="AiToolsConfigureButton" Style="{StaticResource GhostBtn}" Content="Configurar marcadas" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="AiToolsValidateButton" Style="{StaticResource GhostBtn}" Content="Validar marcadas" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="AiToolsUninstallButton" Style="{StaticResource GhostBtn}" Foreground="{StaticResource WarnBrush}" Content="Desinstalar marcadas" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="AiToolsClearButton" Style="{StaticResource GhostBtn}" Content="Limpar selecao" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="AiToolsDocsButton" Style="{StaticResource GhostBtn}" Content="Abrir docs" Height="32"/>
                            </WrapPanel>
                            <TextBlock x:Name="AiToolsStatusLabel" Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center"/>
                        </DockPanel>
                    </Border>

                    <Border Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock Style="{StaticResource SectionLabel}" DockPanel.Dock="Top" Text="FERRAMENTAS OPCIONAIS"/>
                            <WrapPanel DockPanel.Dock="Top" Margin="0,2,0,4">
                                <TextBlock Text="Status:" Foreground="#94A3B8" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                <TextBlock Text="&#9679; nao instalado" Foreground="#FFFFFF" FontSize="11" Margin="0,0,10,0"/>
                                <TextBlock Text="&#9679; nao configurado" Foreground="#FACC15" FontSize="11" Margin="0,0,10,0"/>
                                <TextBlock Text="&#9679; configurado" Foreground="#3B82F6" FontSize="11" Margin="0,0,10,0"/>
                                <TextBlock Text="&#9679; otimizado/testado" Foreground="#22C55E" FontSize="11" Margin="0,0,10,0"/>
                                <TextBlock Text="&#9679; erro" Foreground="#EF4444" FontSize="11" Margin="0,0,10,0"/>
                            </WrapPanel>
                            <DataGrid x:Name="AiToolsGrid" Style="{StaticResource DarkGrid}" Height="500" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False" SelectionMode="Extended" IsReadOnly="False">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Ativo" Binding="{Binding active, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="70" ElementStyle="{StaticResource DarkGridCheckBoxElement}" EditingElementStyle="{StaticResource DarkGridCheckBoxEditing}"/>
                                    <DataGridTextColumn Header="Tool" Binding="{Binding tool}" Width="1.0*" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Nome" Binding="{Binding name}" Width="1.4*" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Status" Binding="{Binding status}" Width="0.9*" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Versão" Binding="{Binding version}" Width="1.1*" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Suporte" Binding="{Binding support}" Width="1.0*" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Comando" Binding="{Binding commandPath}" Width="1.7*" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Mensagem" Binding="{Binding message}" Width="2.2*" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Docs" Binding="{Binding docs}" Width="1.5*" IsReadOnly="True"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  API CENTER PAGE  -->
            <ScrollViewer x:Name="PageApiCenter" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="ApiCenterTitleLabel" Style="{StaticResource PageTitle}" Text="Central de APIs"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Inventario seguro de chaves, validacao, rotacao e uso por app. Segredos ficam mascarados por padrao." TextWrapping="Wrap"/>
                    <WrapPanel Margin="0,0,0,10">
                        <TextBlock Text="Validacao:" Foreground="#94A3B8" FontSize="11" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock Text="&#9679; sem credencial" Foreground="#FFFFFF" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; pendente" Foreground="#FACC15" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; validada" Foreground="#22C55E" FontSize="11" Margin="0,0,10,0"/>
                        <TextBlock Text="&#9679; falhou/expirou" Foreground="#EF4444" FontSize="11" Margin="0,0,10,0"/>
                    </WrapPanel>

                    <Border Background="#1A1D2E" CornerRadius="10" Padding="14,10" Margin="0,0,0,14">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="ApiRefreshButton" Style="{StaticResource GhostBtn}" Content="Atualizar APIs" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="ApiValidateAllButton" Style="{StaticResource GhostBtn}" Content="Validar tudo" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="ApiImportButton" Style="{StaticResource GhostBtn}" Content="Importar arquivo bruto" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="ApiCatalogButton" Style="{StaticResource GhostBtn}" Content="Catálogo completo" Margin="0,0,8,0" Height="32"/>
                                <Button x:Name="ApiApplyButton" Style="{StaticResource PrimaryBtn}" Content="Aplicar nos apps" Height="32"/>
                            </StackPanel>
                            <StackPanel>
                                <TextBlock x:Name="ApiStatusLabel" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
                                <TextBlock x:Name="ApiStatusLinksLabel" Foreground="#94A3B8" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed">
                                    <Hyperlink x:Name="ApiSignupLink"><Run Text="Criar chave"/></Hyperlink>
                                    <Run Text="  |  "/>
                                    <Hyperlink x:Name="ApiDocsLink"><Run Text="Docs"/></Hyperlink>
                                    <Run Text="  |  "/>
                                    <Hyperlink x:Name="ApiPricingLink"><Run Text="Preços"/></Hyperlink>
                                </TextBlock>
                                <TextBlock x:Name="ApiSecretsLinksLabel" Foreground="#94A3B8" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed">
                                    <Hyperlink x:Name="ApiSecretsFileLink"><Run Text="Abrir arquivo"/></Hyperlink>
                                    <Run Text="  |  "/>
                                    <Hyperlink x:Name="ApiSecretsFolderLink"><Run Text="Abrir pasta"/></Hyperlink>
                                </TextBlock>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                        <DockPanel>
                            <TextBlock x:Name="ApiProviderSummaryLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="RESUMO POR PROVEDOR"/>
                            <DataGrid x:Name="ApiProviderSummaryGrid" Style="{StaticResource DarkGrid}" Height="170" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Provedor" Binding="{Binding provider}" Width="1.1*"/>
                                    <DataGridTextColumn Header="Chaves" Binding="{Binding total}" Width="0.6*"/>
                                    <DataGridTextColumn Header="Em uso agora" Binding="{Binding active}" Width="1.1*"/>
                                    <DataGridTextColumn Header="Teste" Binding="{Binding state}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Apps automaticos" Binding="{Binding autoApps}" Width="1.5*"/>
                                    <DataGridTextColumn Header="Apps manuais" Binding="{Binding manualApps}" Width="1.2*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>

                    <Grid Margin="0,0,0,14">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="1.1*"/>
                            <ColumnDefinition Width="14"/>
                            <ColumnDefinition Width="0.9*"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="ApiCredentialsLabel" Style="{StaticResource SectionLabel}" Text="CREDENCIAIS"/>
                                <DataGrid x:Name="ApiCredentialGrid" Style="{StaticResource DarkGrid}" Height="220" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Provedor" Binding="{Binding provider}" Width="0.9*"/>
                                        <DataGridTextColumn Header="Identificacao segura" Binding="{Binding id}" Width="1.6*"/>
                                        <DataGridTextColumn Header="Nome amigavel" Binding="{Binding display}" Width="1.1*"/>
                                        <DataGridTextColumn Header="Ativa" Binding="{Binding active}" Width="0.6*"/>
                                        <DataGridTextColumn Header="Teste" Binding="{Binding state}" Width="0.8*"/>
                                        <DataGridTextColumn Header="Mascara" Binding="{Binding preview}" Width="0.8*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </StackPanel>
                        </Border>

                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Style="{StaticResource SectionLabel}" Text="ADICIONAR / EDITAR"/>
                                <TextBlock Foreground="#94A3B8" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,8" Text="Selecione provedor e credencial. O campo segredo fica vazio ao editar; preencha apenas para criar ou trocar a chave."/>
                                <TextBlock Foreground="#94A3B8" Text="Provedor"/>
                                <ComboBox x:Name="ApiProviderCombo" Style="{StaticResource DarkCombo}" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Chave cadastrada"/>
                                <ComboBox x:Name="ApiCredentialCombo" Style="{StaticResource DarkCombo}" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Nome para voce reconhecer"/>
                                <TextBox x:Name="ApiDisplayNameTextBox" Style="{StaticResource DarkInput}" Height="32" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Segredo / API key"/>
                                <PasswordBox x:Name="ApiSecretBox" Background="#252840" Foreground="#E2E8F0" BorderBrush="#2D3148" BorderThickness="1" Height="32" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Base URL"/>
                                <TextBox x:Name="ApiBaseUrlTextBox" Style="{StaticResource DarkInput}" Height="32" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Organizacao"/>
                                <TextBox x:Name="ApiOrganizationTextBox" Style="{StaticResource DarkInput}" Height="32" Margin="0,2,0,8"/>
                                <TextBlock Foreground="#94A3B8" Text="Project Ref"/>
                                <TextBox x:Name="ApiProjectRefTextBox" Style="{StaticResource DarkInput}" Height="32" Margin="0,2,0,12"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button x:Name="ApiSaveButton" Style="{StaticResource PrimaryBtn}" Content="Salvar credencial" Margin="0,0,8,0" Height="32"/>
                                    <Button x:Name="ApiValidateButton" Style="{StaticResource GhostBtn}" Content="Validar" Margin="0,0,8,0" Height="32"/>
                                    <Button x:Name="ApiActivateButton" Style="{StaticResource GhostBtn}" Content="Ativar" Height="32"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="14"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="ApiUsageLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="USO NOS APPS"/>
                                <DataGrid x:Name="ApiUsageGrid" Style="{StaticResource DarkGrid}" Height="190" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Sistema" Binding="{Binding app}" Width="0.8*"/>
                                        <DataGridTextColumn Header="Configurado sozinho" Binding="{Binding autoApplied}" Width="1.4*"/>
                                        <DataGridTextColumn Header="Manual" Binding="{Binding manualOnly}" Width="1.1*"/>
                                        <DataGridTextColumn Header="Disponivel" Binding="{Binding available}" Width="1.6*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </DockPanel>
                        </Border>

                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <DockPanel>
                                <TextBlock x:Name="ApiCreateLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="CRIAR OU ASSINAR"/>
                                <DataGrid x:Name="ApiCreateGrid" Style="{StaticResource DarkGrid}" Height="190" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Provedor" Binding="{Binding provider}" Width="0.9*"/>
                                        <DataGridTextColumn Header="Voce vai precisar" Binding="{Binding fields}" Width="1.2*"/>
                                        <DataGridTemplateColumn Header="Criar chave" Width="1.2*">
                                            <DataGridTemplateColumn.CellTemplate>
                                                <DataTemplate>
                                                    <TextBlock ToolTip="{Binding signup}">
                                                        <Hyperlink NavigateUri="{Binding signup}">
                                                            <Run Text="Abrir"/>
                                                        </Hyperlink>
                                                    </TextBlock>
                                                </DataTemplate>
                                            </DataGridTemplateColumn.CellTemplate>
                                        </DataGridTemplateColumn>
                                        <DataGridTemplateColumn Header="Ajuda" Width="1.2*">
                                            <DataGridTemplateColumn.CellTemplate>
                                                <DataTemplate>
                                                    <TextBlock ToolTip="{Binding docs}">
                                                        <Hyperlink NavigateUri="{Binding docs}">
                                                            <Run Text="Abrir"/>
                                                        </Hyperlink>
                                                    </TextBlock>
                                                </DataTemplate>
                                            </DataGridTemplateColumn.CellTemplate>
                                        </DataGridTemplateColumn>
                                    </DataGrid.Columns>
                                </DataGrid>
                            </DockPanel>
                        </Border>
                    </Grid>
                </StackPanel>
            </ScrollViewer>

            <!--  API CATALOG PAGE  -->
            <ScrollViewer x:Name="PageApiCatalog" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="ApiCatalogTitleLabel" Style="{StaticResource PageTitle}" Text="Catálogo completo de chaves"/>
                    <TextBlock x:Name="ApiCatalogSubtitleLabel" Style="{StaticResource PageSubtitle}" Text="Lista pesquisada de provedores com posse, uso configurado, finalidade, requisitos e links oficiais." TextWrapping="Wrap"/>

                    <Border Background="#1A1D2E" CornerRadius="10" Padding="14,10" Margin="0,0,0,14">
                        <DockPanel>
                            <Button x:Name="ApiCatalogBackButton" DockPanel.Dock="Right" Style="{StaticResource GhostBtn}" Content="&lt;- Central de APIs" Height="32"/>
                            <TextBlock x:Name="ApiCatalogStatusLabel" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
                        </DockPanel>
                    </Border>

                    <Border Style="{StaticResource Card}">
                        <DockPanel>
                            <TextBlock x:Name="ApiFullCatalogLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="TODAS AS CHAVES POSSIVEIS"/>
                            <DataGrid x:Name="ApiFullCatalogGrid" Style="{StaticResource DarkGrid}" Height="520" Margin="0,4,0,0" CanUserAddRows="False" CanUserDeleteRows="False">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Ja possui" Binding="{Binding hasCredential}" Width="0.7*"/>
                                    <DataGridTextColumn Header="Quantidade" Binding="{Binding quantity}" Width="0.7*"/>
                                    <DataGridTextColumn Header="Configuradas" Binding="{Binding configured}" Width="0.8*"/>
                                    <DataGridTextColumn Header="Provedor" Binding="{Binding provider}" Width="1.1*"/>
                                    <DataGridTextColumn Header="O que faz" Binding="{Binding description}" Width="2.2*"/>
                                    <DataGridTextColumn Header="Voce vai precisar" Binding="{Binding fields}" Width="1.2*"/>
                                    <DataGridTemplateColumn Header="Criar Chave" Width="1.0*">
                                        <DataGridTemplateColumn.CellTemplate>
                                            <DataTemplate>
                                                <TextBlock ToolTip="{Binding signup}">
                                                    <Hyperlink NavigateUri="{Binding signup}">
                                                        <Run Text="Abrir"/>
                                                    </Hyperlink>
                                                </TextBlock>
                                            </DataTemplate>
                                        </DataGridTemplateColumn.CellTemplate>
                                    </DataGridTemplateColumn>
                                    <DataGridTemplateColumn Header="Ajuda" Width="1.0*">
                                        <DataGridTemplateColumn.CellTemplate>
                                            <DataTemplate>
                                                <TextBlock ToolTip="{Binding docs}">
                                                    <Hyperlink NavigateUri="{Binding docs}">
                                                        <Run Text="Abrir"/>
                                                    </Hyperlink>
                                                </TextBlock>
                                            </DataTemplate>
                                        </DataGridTemplateColumn.CellTemplate>
                                    </DataGridTemplateColumn>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  STEAM DECK CONTROL PAGE  -->
            <ScrollViewer x:Name="PageSteamDeck" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="SteamDeckTitleLabel" Style="{StaticResource PageTitle}" Text="Central Steam Deck"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Configure perfis de monitor, sessoes e o fallback generico." TextWrapping="Wrap"/>

                    <!-- Monitor Profiles -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                        <StackPanel>
                            <TextBlock x:Name="MonitorProfilesLabel" Style="{StaticResource SectionLabel}" Text="MONITOR PROFILES"/>
                            <DataGrid  x:Name="MonitorProfilesGrid"  Style="{StaticResource DarkGrid}" Height="160" Margin="0,4,0,0">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Principal"     Binding="{Binding primary, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="80"/>
                                    <DataGridTextColumn Header="Alvo"              Binding="{Binding target}"            Width="90" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Status"            Binding="{Binding status}"            Width="130" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Fabricante"        Binding="{Binding manufacturer}"      Width="*"/>
                                    <DataGridTextColumn Header="Modelo"            Binding="{Binding product}"           Width="*"/>
                                    <DataGridTextColumn Header="Serial"            Binding="{Binding serial}"            Width="*"/>
                                    <DataGridComboBoxColumn Header="Perfil"        SelectedItemBinding="{Binding mode, UpdateSourceTrigger=PropertyChanged}" ItemsSource="{StaticResource SteamDeckExternalModes}" Width="*"/>
                                    <DataGridTextColumn Header="Layout"            Binding="{Binding layout}"            Width="*"/>
                                    <DataGridTextColumn Header="Resolução"         Binding="{Binding resolutionPolicy}"  Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                                <TextBlock Foreground="#94A3B8" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"
                                       Text="Se esta lista estiver vazia, tudo bem: o Steam Deck ainda usa as familias conhecidas e a regra padrao para monitor externo."/>
                        </StackPanel>
                    </Border>

                    <!-- Monitor Families -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                        <StackPanel>
                            <TextBlock x:Name="MonitorFamiliesLabel" Style="{StaticResource SectionLabel}" Text="MONITOR FAMILIES"/>
                            <DataGrid  x:Name="MonitorFamiliesGrid"  Style="{StaticResource DarkGrid}" Height="160" Margin="0,4,0,0">
                                <DataGrid.Columns>
                                    <DataGridCheckBoxColumn Header="Principal"     Binding="{Binding primary, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="80"/>
                                    <DataGridTextColumn Header="Status"            Binding="{Binding status}"            Width="120" IsReadOnly="True"/>
                                    <DataGridTextColumn Header="Fabricante"        Binding="{Binding manufacturer}"      Width="*"/>
                                    <DataGridTextColumn Header="Modelo"            Binding="{Binding product}"           Width="*"/>
                                    <DataGridTextColumn Header="Padrao do nome"    Binding="{Binding namePattern}"       Width="*"/>
                                    <DataGridComboBoxColumn Header="Perfil"        SelectedItemBinding="{Binding mode, UpdateSourceTrigger=PropertyChanged}" ItemsSource="{StaticResource SteamDeckExternalModes}" Width="*"/>
                                    <DataGridTextColumn Header="Layout"            Binding="{Binding layout}"            Width="*"/>
                                    <DataGridTextColumn Header="Resolução"         Binding="{Binding resolutionPolicy}"  Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                                <TextBlock Foreground="#94A3B8" FontSize="11" Margin="0,8,0,0" TextWrapping="Wrap"
                                       Text="Familias permitem reconhecer monitores parecidos sem cadastrar serial por serial."/>
                        </StackPanel>
                    </Border>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="16"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <!-- Generic External -->
                        <Border Grid.Column="0" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="GenericGroupLabel" Style="{StaticResource SectionLabel}" Text="FALLBACK GENERICO"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="130"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <TextBlock x:Name="GenericModeLabel"       Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Modo"/>
                                    <ComboBox  x:Name="GenericModeCombo"       Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkCombo}"/>
                                    <TextBlock x:Name="GenericLayoutLabel"     Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Layout"/>
                                    <TextBox   x:Name="GenericLayoutTextBox"   Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="GenericResolutionLabel" Grid.Row="4" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Resolução"/>
                                    <TextBox   x:Name="GenericResolutionTextBox" Grid.Row="4" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="DisplayModeLabel"       Grid.Row="6" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Display"/>
                                    <ComboBox  x:Name="DisplayModeCombo"       Grid.Row="6" Grid.Column="1" Style="{StaticResource DarkCombo}" ItemsSource="{StaticResource SteamDeckDisplayModes}"/>
                                </Grid>
                            </StackPanel>
                        </Border>

                        <!-- Session Profiles -->
                        <Border Grid.Column="2" Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock x:Name="SessionGroupLabel" Style="{StaticResource SectionLabel}" Text="SESSION PROFILES"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="160"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                        <RowDefinition Height="8"/>
                                        <RowDefinition Height="Auto"/>
                                    </Grid.RowDefinitions>
                                    <TextBlock x:Name="HandheldSessionLabel"      Grid.Row="0" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="HANDHELD"/>
                                    <TextBox   x:Name="HandheldSessionTextBox"    Grid.Row="0" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="DockTvSessionLabel"        Grid.Row="2" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="DOCKED_TV"/>
                                    <TextBox   x:Name="DockTvSessionTextBox"      Grid.Row="2" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                    <TextBlock x:Name="DockMonitorSessionLabel"   Grid.Row="4" Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="DOCKED_MONITOR"/>
                                    <TextBox   x:Name="DockMonitorSessionTextBox" Grid.Row="4" Grid.Column="1" Style="{StaticResource DarkInput}" Height="32"/>
                                </Grid>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <!-- Unknown external classifier -->
                    <Border Style="{StaticResource Card}" Margin="0,14,0,0" BorderBrush="{StaticResource WarnBrush}">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="ClassifyMonitorButton" Style="{StaticResource PrimaryBtn}" Content=" Monitor/Dev" Margin="0,0,8,0" Width="140" Height="34"/>
                                <Button x:Name="ClassifyTvButton"      Style="{StaticResource GhostBtn}"   Content=" TV/Game" Width="120" Height="34"/>
                            </StackPanel>
                            <StackPanel>
                                <TextBlock x:Name="PendingExternalLabel" Style="{StaticResource SectionLabel}" Text="MONITOR EXTERNO DESCONHECIDO"/>
                                <TextBlock x:Name="PendingExternalStatusLabel" Foreground="#CBD5E1" FontSize="12" TextWrapping="Wrap" Margin="0,4,12,0"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <!-- Watcher status + save buttons -->
                    <Border Background="#1A1D2E" CornerRadius="8" Padding="14,10" Margin="0,14,0,0">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button x:Name="ReloadSettingsButton" Style="{StaticResource GhostBtn}"   Content=" Recarregar" Margin="0,0,8,0" Height="34"/>
                                <Button x:Name="SaveSettingsButton"   Style="{StaticResource PrimaryBtn}" Content=" Salvar Settings" Height="34"/>
                            </StackPanel>
                            <StackPanel>
                    <TextBlock x:Name="WatcherStatusLabel"  Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap"/>
                    <TextBlock x:Name="UnknownMonitorHintLabel" Foreground="#94A3B8" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>
                </StackPanel>
            </ScrollViewer>

            <!--  DUAL BOOT PAGE  -->
            <ScrollViewer x:Name="PageDualBoot" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="32,28">
                <StackPanel>
                    <TextBlock x:Name="DualBootTitleLabel" Style="{StaticResource PageTitle}" Text="Windows e Linux"/>
                    <TextBlock Style="{StaticResource PageSubtitle}" Text="Validacao de guardrails e gerenciamento do cenario Windows + Linux." TextWrapping="Wrap"/>

                    <!-- Status -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="STATUS DO SISTEMA"/>
                            <TextBlock x:Name="DualBootStatusText" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,8,0,0"/>
                        </DockPanel>
                    </Border>

                    <!-- Pre-reqs -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="PR-REQUISITOS (WINDOWS)"/>
                            <StackPanel Margin="0,8,0,0">
                                <TextBlock x:Name="DualBootPrereqsText" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                <Button x:Name="FixFastStartupButton" Style="{StaticResource PrimaryBtn}" Content=" Desabilitar Fast Startup" Width="220" HorizontalAlignment="Left" Height="34"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <!-- Reboot to Linux -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="REBOOT SEGURO (ONE-TIME BOOT)"/>
                            <Grid Margin="0,8,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <ComboBox x:Name="DualBootTargetCombo" Grid.Column="0" Style="{StaticResource DarkCombo}" Margin="0,0,12,0"/>
                                <Button x:Name="RebootToLinuxButton" Grid.Column="1" Style="{StaticResource PrimaryBtn}" Background="#EF4444" Content=" Reiniciar para Linux" Width="200" Height="34"/>
                            </Grid>
                        </DockPanel>
                    </Border>

                    <!-- Windows Boot Manager -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="WINDOWS BOOT MANAGER (BCD)"/>
                            <StackPanel Margin="0,8,0,0">
                                <TextBlock x:Name="WindowsBootStatusText" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,8"/>
                                <DataGrid x:Name="WindowsBootEntriesGrid" Style="{StaticResource DarkGrid}" Height="190" Margin="0,0,0,10" CanUserAddRows="False" CanUserDeleteRows="False">
                                    <DataGrid.Columns>
                                        <DataGridTextColumn Header="Padrao" Binding="{Binding isDefault}" Width="0.6*"/>
                                        <DataGridTextColumn Header="Atual" Binding="{Binding isCurrent}" Width="0.6*"/>
                                        <DataGridTextColumn Header="Menu" Binding="{Binding inDisplayOrder}" Width="0.6*"/>
                                        <DataGridTextColumn Header="Id" Binding="{Binding id}" Width="1.5*"/>
                                        <DataGridTextColumn Header="Descricao" Binding="{Binding description}" Width="1.6*"/>
                                        <DataGridTextColumn Header="Device" Binding="{Binding device}" Width="1.3*"/>
                                        <DataGridTextColumn Header="OSDevice" Binding="{Binding osdevice}" Width="1.3*"/>
                                        <DataGridTextColumn Header="Orfa" Binding="{Binding isPhantom}" Width="0.6*"/>
                                    </DataGrid.Columns>
                                </DataGrid>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="110"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="80"/>
                                        <ColumnDefinition Width="120"/>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Foreground="#94A3B8" VerticalAlignment="Center" Text="Padrao"/>
                                    <ComboBox x:Name="WindowsBootDefaultCombo" Grid.Column="1" Style="{StaticResource DarkCombo}" Margin="0,0,12,0"/>
                                    <TextBlock Grid.Column="2" Foreground="#94A3B8" VerticalAlignment="Center" Text="Timeout"/>
                                    <TextBox x:Name="WindowsBootTimeoutTextBox" Grid.Column="3" Style="{StaticResource DarkInput}" Height="34" Margin="0,0,12,0"/>
                                    <Button x:Name="BackupWindowsBootButton" Grid.Column="4" Style="{StaticResource GhostBtn}" Content="Backup BCD" Height="34" Margin="0,0,8,0"/>
                                    <Button x:Name="ApplyWindowsBootButton" Grid.Column="5" Style="{StaticResource PrimaryBtn}" Content="Aplicar BCD" Height="34"/>
                                </Grid>
                                <TextBlock Text="Recuperacao: restaure o BCD a partir de um backup criado por este app, caso algo de errado." Foreground="#94A3B8" FontSize="11" TextWrapping="Wrap" Margin="0,12,0,4"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <ComboBox x:Name="BcdBackupCombo" Grid.Column="0" Style="{StaticResource DarkCombo}" Margin="0,0,12,0"/>
                                    <Button x:Name="RestoreBcdButton" Grid.Column="1" Style="{StaticResource GhostBtn}" Foreground="{StaticResource WarnBrush}" Content="Restaurar BCD do backup" Height="34"/>
                                </Grid>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <!-- BCD Cleanup -->
                    <Border Style="{StaticResource Card}" Margin="0,0,0,16" BorderBrush="{StaticResource WarnBrush}">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="LIMPEZA DE BCD (MENU DO WINDOWS)"/>
                            <StackPanel Margin="0,8,0,0">
                                <TextBlock x:Name="BcdCleanupStatusText" Foreground="#CBD5E1" TextWrapping="Wrap" Margin="0,0,0,12"/>
                                <Button x:Name="BcdCleanupButton" Style="{StaticResource PrimaryBtn}" Background="#F59E0B" Foreground="Black" Content=" Verificar e limpar menu falso" Width="230" HorizontalAlignment="Left" Height="34"/>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="BTRFS (STEAMOS) - LEITURA/ESCRITA"/>
                            <StackPanel Margin="0,8,0,0">
                                <TextBlock Foreground="#94A3B8" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,8" Text="Acessa as particoes Btrfs do SteamOS no Windows via WinBtrfs (R/W). Requer Fast Startup OFF. Este modulo NUNCA formata nada."/>
                                <TextBlock x:Name="BtrfsStatusText" Foreground="#CBD5E1" FontSize="13" TextWrapping="Wrap" Text="Clique em Verificar Btrfs."/>
                                <WrapPanel Margin="0,10,0,0">
                                    <Button x:Name="BtrfsCheckButton" Style="{StaticResource GhostBtn}" Content="Verificar Btrfs" Height="34" Margin="0,0,8,0"/>
                                    <Button x:Name="BtrfsInstallButton" Style="{StaticResource PrimaryBtn}" Content="WinBtrfs (release oficial)" Height="34"/>
                                </WrapPanel>
                            </StackPanel>
                        </DockPanel>
                    </Border>

                    <Button x:Name="RefreshDualBootButton" Style="{StaticResource GhostBtn}" Content=" Recarregar Status" Width="180" HorizontalAlignment="Left" Height="34"/>
                </StackPanel>
            </ScrollViewer>

            <!--  REVIEW PAGE  -->
            <Grid x:Name="PageReview" Visibility="Collapsed" Margin="32,28">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0">
                    <TextBlock x:Name="ReviewTitleLabel" Style="{StaticResource PageTitle}" Text="Revisão"/>
                </StackPanel>

                <Border Grid.Row="1" Background="#1A1D2E" CornerRadius="8" Padding="14,10" Margin="0,0,0,14">
                    <DockPanel>
                        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                            <CheckBox x:Name="ReviewAcceptedCheckBox" Style="{StaticResource DarkCheck}" Content="Aceito esta revisão" Margin="0,0,12,0"/>
                            <Button x:Name="RefreshReviewButton" Style="{StaticResource GhostBtn}" Content=" Atualizar" Height="32"/>
                        </StackPanel>
                        <StackPanel>
                            <TextBlock x:Name="ReviewMetaLabel" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"/>
                            <TextBlock x:Name="ReviewLinksLabel" Foreground="#94A3B8" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap" Visibility="Collapsed">
                                <Hyperlink x:Name="ReviewSettingsLink"><Run Text="Abrir Settings"/></Hyperlink>
                                <Run Text="  |  "/>
                                <Hyperlink x:Name="ReviewUiStateLink"><Run Text="Abrir UI state"/></Hyperlink>
                            </TextBlock>
                        </StackPanel>
                    </DockPanel>
                </Border>

                <Border Grid.Row="2" Style="{StaticResource Card}">
                    <DockPanel>
                        <TextBlock x:Name="ReviewSummaryLabel" DockPanel.Dock="Top" Style="{StaticResource SectionLabel}" Text="PREVIEW DO PLAN (DRY-RUN)"/>
                        <TextBlock x:Name="ReviewSideEffectsLabel" Foreground="#94A3B8" FontSize="12" Margin="0,6,0,0" Text="Efeitos colaterais"/>
                        <TextBox x:Name="ReviewSideEffectsTextBox" Style="{StaticResource DarkReadonly}"
                                 AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                                 FontFamily="Consolas" FontSize="12" Height="86" Margin="0,6,0,10"/>
                        <TextBox x:Name="ReviewTextBox" Style="{StaticResource DarkReadonly}"
                                 AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                                 FontFamily="Consolas" FontSize="12" Margin="0,4,0,0"/>
                    </DockPanel>
                </Border>
            </Grid>

            <!--  RUN PAGE  -->
            <Grid x:Name="PageRun" Visibility="Collapsed" Margin="32,28">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" x:Name="RunTitleLabel" Style="{StaticResource PageTitle}" Text="Execução"/>

                <!-- Action bar -->
                <Border Grid.Row="1" Background="#1A1D2E" CornerRadius="10" Padding="16,12" Margin="0,0,0,12">
                    <DockPanel>
                        <Button x:Name="StartRunButton" DockPanel.Dock="Right" Style="{StaticResource PrimaryBtn}"
                                Content="▶  Iniciar Execução" FontSize="15" Height="40"/>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Button x:Name="OpenLogButton"     Style="{StaticResource GhostBtn}" Content=" Log"        Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenResultButton"  Style="{StaticResource GhostBtn}" Content=" Resultado"  Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenSettingsButton" Style="{StaticResource GhostBtn}" Content="⚙ Settings"   Margin="0,0,8,0" Height="34"/>
                            <Button x:Name="OpenReportsButton" Style="{StaticResource GhostBtn}" Content=" Relatórios" Height="34"/>
                        </StackPanel>
                    </DockPanel>
                </Border>

                <!-- Run timeline -->
                <Border Grid.Row="2" Background="#1A1D2E" CornerRadius="10" Padding="16,12" Margin="0,0,0,12">
                    <StackPanel x:Name="RunTimelineBar" Orientation="Horizontal" VerticalAlignment="Center">
                        <StackPanel Orientation="Vertical" Margin="0,0,28,0">
                            <Border x:Name="RunTimelineStep1Dot" Width="14" Height="14" CornerRadius="7" Background="#3A405A" Margin="0,0,0,4"/>
                            <TextBlock x:Name="RunTimelineStep1Label" Text="Preparando" Foreground="#94A3B8" FontSize="11"/>
                        </StackPanel>
                        <TextBlock Text="—" Foreground="#3A405A" VerticalAlignment="Top" Margin="0,2,28,0" FontSize="14"/>
                        <StackPanel Orientation="Vertical" Margin="0,0,28,0">
                            <Border x:Name="RunTimelineStep2Dot" Width="14" Height="14" CornerRadius="7" Background="#3A405A" Margin="0,0,0,4"/>
                            <TextBlock x:Name="RunTimelineStep2Label" Text="Dry-run" Foreground="#94A3B8" FontSize="11"/>
                        </StackPanel>
                        <TextBlock Text="—" Foreground="#3A405A" VerticalAlignment="Top" Margin="0,2,28,0" FontSize="14"/>
                        <StackPanel Orientation="Vertical" Margin="0,0,28,0">
                            <Border x:Name="RunTimelineStep3Dot" Width="14" Height="14" CornerRadius="7" Background="#3A405A" Margin="0,0,0,4"/>
                            <TextBlock x:Name="RunTimelineStep3Label" Text="Executando" Foreground="#94A3B8" FontSize="11"/>
                        </StackPanel>
                        <TextBlock Text="—" Foreground="#3A405A" VerticalAlignment="Top" Margin="0,2,28,0" FontSize="14"/>
                        <StackPanel Orientation="Vertical" Margin="0,0,28,0">
                            <Border x:Name="RunTimelineStep4Dot" Width="14" Height="14" CornerRadius="7" Background="#3A405A" Margin="0,0,0,4"/>
                            <TextBlock x:Name="RunTimelineStep4Label" Text="result.json" Foreground="#94A3B8" FontSize="11"/>
                        </StackPanel>
                        <TextBlock Text="—" Foreground="#3A405A" VerticalAlignment="Top" Margin="0,2,28,0" FontSize="14"/>
                        <StackPanel Orientation="Vertical" Margin="0,0,0,0">
                            <Border x:Name="RunTimelineStep5Dot" Width="14" Height="14" CornerRadius="7" Background="#3A405A" Margin="0,0,0,4"/>
                            <TextBlock x:Name="RunTimelineStep5Label" Text="Pacote/Logs" Foreground="#94A3B8" FontSize="11"/>
                        </StackPanel>
                    </StackPanel>
                </Border>

                <!-- Log area -->
                <Border Grid.Row="3" Style="{StaticResource Card}">
                    <DockPanel>
                        <Border x:Name="PendingRebootBanner" DockPanel.Dock="Top" Background="#2B1D0A" CornerRadius="8" Padding="10,8" Margin="0,0,0,8" Visibility="Collapsed">
                            <TextBlock x:Name="PendingRebootBannerLabel" Foreground="#FBBF24" FontSize="12" TextWrapping="Wrap"/>
                        </Border>
                        <TextBlock x:Name="RunStatusLabel" DockPanel.Dock="Top" Foreground="#94A3B8" FontSize="12" Margin="0,0,0,8"/>
                        <TextBox x:Name="RunLogTextBox" Style="{StaticResource DarkReadonly}"
                                 AcceptsReturn="True" VerticalScrollBarVisibility="Auto"
                                 FontFamily="Consolas" FontSize="12"/>
                    </DockPanel>
                </Border>
            </Grid>
        </Grid>

        <!--  STATUS BAR  -->
        <Border Grid.Column="1" Grid.Row="1"
                Background="#13162B" BorderBrush="#2D3148" BorderThickness="0,1,0,0"
                Padding="24,0">
            <DockPanel VerticalAlignment="Center">
                <TextBlock x:Name="StepLabel"   DockPanel.Dock="Right" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center"/>
                <TextBlock x:Name="StatusLabel" Foreground="#94A3B8" FontSize="12" VerticalAlignment="Center"/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
'@

#
# Load WPF Window from XAML
#

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$window.AddHandler([System.Windows.Documents.Hyperlink]::RequestNavigateEvent, [System.Windows.Navigation.RequestNavigateEventHandler]{
    param($sender, $e)
    try {
        if ($e.Uri -and -not [string]::IsNullOrWhiteSpace([string]$e.Uri.OriginalString)) {
            if ($e.Uri.IsFile) {
                $localPath = [System.Uri]::UnescapeDataString($e.Uri.LocalPath)
                if ($localPath -match '^/([A-Za-z]:)') { $localPath = $localPath.Substring(1) }
                $ext = [System.IO.Path]::GetExtension($localPath).ToLowerInvariant()
                if ($ext -in @('.ps1', '.psm1', '.psd1') -and (Test-Path -LiteralPath $localPath)) {
                    $selectArg = if ($localPath -match '\s') { '/select,"{0}"' -f ($localPath -replace '"', '""') } else { '/select,{0}' -f $localPath }
                    Start-Process -FilePath 'explorer.exe' -ArgumentList $selectArg | Out-Null
                } else {
                    Start-Process ([string]$e.Uri.OriginalString)
                }
            } else {
                Start-Process ([string]$e.Uri.OriginalString)
            }
        }
    } catch {
    }
    $e.Handled = $true
})

function Get-Control {
    param([Parameter(Mandatory=$true)][string]$Name)
    $ctrl = $window.FindName($Name)
    if (-not $ctrl) { throw "Control not found: $Name" }
    return $ctrl
}

#
# Control references
#

$ui = [ordered]@{
    Contract              = $contract
    State                 = $state
    Strings               = Get-UiStrings -Language ([string]$state.language)
    CurrentPageIndex      = 0
    Preview               = $null
    SettingsBundle        = Get-BootstrapSteamDeckSettingsData -RequestedSteamDeckVersion ([string]$state.steamDeckVersion) -ResolvedSteamDeckVersion 'lcd'
    SettingsBackupPath    = $null
    SuppressSelectionEvents = $false
    SuppressApiEvents     = $false
    SuppressAppTuningEvents = $false
    # Byte offset no ficheiro CurrentLogPath (Append-RunLog le apenas bytes novos; evita OOM em logs grandes).
    LogOffset             = 0
    CurrentLogPath        = $null
    CurrentResultPath     = $null
    CurrentStdoutPath     = $null
    CurrentStderrPath     = $null
    CurrentBackendWasElevated = $false
    RunProcess            = $null
    ExecutionScopeOverride = $null
    CurrentExecutionScopeLabel = ''
    CurrentRunPhase       = ''
    RunFinalized          = $false
    PendingRebootReasons  = @()
    # 'none' = instalação/perfil normal; 'audit' / 'rollback' apenas quando disparado pelos botões de manutenção.
    MaintenanceMode          = 'none'
    # Escopo do Doctor por card/area (default 'all'); cada card clicado define o seu antes do run.
    DoctorScope              = 'all'
    # Card de saude atualmente em verificacao (para atualizar so ele ao terminar).
    DoctorScopeCard          = ''

    # Window
    Window                = $window

    # Nav
    NavWelcome            = (Get-Control 'NavWelcome')
    NavSelection          = (Get-Control 'NavSelection')
    NavHostSetup          = (Get-Control 'NavHostSetup')
    NavHealth             = (Get-Control 'NavHealth')
    NavAppTuning          = (Get-Control 'NavAppTuning')
    NavAiTools            = (Get-Control 'NavAiTools')
    NavApiCenter          = (Get-Control 'NavApiCenter')
    NavSteamDeck          = (Get-Control 'NavSteamDeck')
    NavDualBoot           = (Get-Control 'NavDualBoot')
    NavReview             = (Get-Control 'NavReview')
    NavRun                = (Get-Control 'NavRun')
    NavWelcomeText        = (Get-Control 'NavWelcomeText')
    NavSelectionText      = (Get-Control 'NavSelectionText')
    NavHostSetupText      = (Get-Control 'NavHostSetupText')
    NavHealthText         = (Get-Control 'NavHealthText')
    NavAppTuningText      = (Get-Control 'NavAppTuningText')
    NavAiToolsText        = (Get-Control 'NavAiToolsText')
    NavApiCenterText      = (Get-Control 'NavApiCenterText')
    NavSteamDeckText      = (Get-Control 'NavSteamDeckText')
    NavDualBootText       = (Get-Control 'NavDualBootText')
    NavReviewText         = (Get-Control 'NavReviewText')
    NavRunText            = (Get-Control 'NavRunText')

    # Bottom nav
    BackButton            = (Get-Control 'BackButton')
    NextButton            = (Get-Control 'NextButton')
    FinishButton          = (Get-Control 'FinishButton')
    StatusLabel           = (Get-Control 'StatusLabel')
    StepLabel             = (Get-Control 'StepLabel')

    # Welcome
    WelcomeTitleLabel     = (Get-Control 'WelcomeTitleLabel')
    WelcomeSubtitleLabel  = (Get-Control 'WelcomeSubtitleLabel')
    LanguageCombo         = (Get-Control 'LanguageCombo')
    QuickPresetsLabel     = (Get-Control 'QuickPresetsLabel')
    CustomPresetsLabel    = (Get-Control 'CustomPresetsLabel')
    PresetNameLabel       = (Get-Control 'PresetNameLabel')
    PresetNameTextBox     = (Get-Control 'PresetNameTextBox')
    SavePresetButton      = (Get-Control 'SavePresetButton')
    CustomPresetCombo     = (Get-Control 'CustomPresetCombo')
    LoadPresetButton      = (Get-Control 'LoadPresetButton')
    DeletePresetButton    = (Get-Control 'DeletePresetButton')
    PresetButtons         = @{
        'recommended'          = (Get-Control 'PresetRecommended')
        'legacy'               = (Get-Control 'PresetLegacy')
        'full'                 = (Get-Control 'PresetFull')
        'steamdeck-recommended' = (Get-Control 'PresetSteamdeckRec')
        'steamdeck-full'       = (Get-Control 'PresetSteamdeckFull')
    }

    # Selection
    SelectionTitleLabel   = (Get-Control 'SelectionTitleLabel')
    FilterTextBox         = (Get-Control 'FilterTextBox')
    ClearAllSelectionButton = (Get-Control 'ClearAllSelectionButton')
    RefreshStatusButton    = (Get-Control 'RefreshStatusButton')
    ProfilesLabel         = (Get-Control 'ProfilesLabel')
    ProfilesTree          = (Get-Control 'ProfilesTree')
    ComponentsLabel       = (Get-Control 'ComponentsLabel')
    ComponentsTree        = (Get-Control 'ComponentsTree')
    QuickOptionsLabel     = (Get-Control 'QuickOptionsLabel')
    OptClaudePluginsCheckBox = (Get-Control 'OptClaudePluginsCheckBox')
    OptClaudeProjectMcpsCheckBox = (Get-Control 'OptClaudeProjectMcpsCheckBox')
    OptOpenWebUICheckBox  = (Get-Control 'OptOpenWebUICheckBox')
    OptSkipManualRequirementsCheckBox = (Get-Control 'OptSkipManualRequirementsCheckBox')
    OptIgnoreManualRequirementsCheckBox = (Get-Control 'OptIgnoreManualRequirementsCheckBox')
    OptRequireNoPendingRebootCheckBox = (Get-Control 'OptRequireNoPendingRebootCheckBox')
    OptOfflineModeCheckBox = (Get-Control 'OptOfflineModeCheckBox')
    OptEnableResumeCheckBox = (Get-Control 'OptEnableResumeCheckBox')
    ExcludeLabel          = (Get-Control 'ExcludeLabel')
    ExcludeList           = (Get-Control 'ExcludeList')
    DetailsLabel          = (Get-Control 'DetailsLabel')
    DetailsTextBox        = (Get-Control 'DetailsTextBox')
    CfgConfigureButton    = (Get-Control 'CfgConfigureButton')
    CfgResetButton        = (Get-Control 'CfgResetButton')
    CfgExportButton       = (Get-Control 'CfgExportButton')
    CfgImportButton       = (Get-Control 'CfgImportButton')
    CfgBatchResetButton   = (Get-Control 'CfgBatchResetButton')
    InstallWebappsButton  = (Get-Control 'InstallWebappsButton')
    SelectionSummaryLabel = (Get-Control 'SelectionSummaryLabel')
    SelectionErrorLabel   = (Get-Control 'SelectionErrorLabel')

    # Host Setup
    HostTitleLabel        = (Get-Control 'HostTitleLabel')
    HostHealthLabel       = (Get-Control 'HostHealthLabel')
    HostHealthCombo       = (Get-Control 'HostHealthCombo')
    SteamDeckVersionLabel = (Get-Control 'SteamDeckVersionLabel')
    SteamDeckVersionCombo = (Get-Control 'SteamDeckVersionCombo')
    WorkspaceRootLabel    = (Get-Control 'WorkspaceRootLabel')
    WorkspaceRootTextBox  = (Get-Control 'WorkspaceRootTextBox')
    WorkspaceBrowseButton = (Get-Control 'WorkspaceBrowseButton')
    CloneBaseDirLabel     = (Get-Control 'CloneBaseDirLabel')
    CloneBaseDirTextBox   = (Get-Control 'CloneBaseDirTextBox')
    CloneBrowseButton     = (Get-Control 'CloneBrowseButton')
    AdminNeedsTitleLabel  = (Get-Control 'AdminNeedsTitleLabel')
    AdminNeedsTextBox     = (Get-Control 'AdminNeedsTextBox')
    DoctorQuickButton     = (Get-Control 'DoctorQuickButton')
    SupportBundleQuickButton = (Get-Control 'SupportBundleQuickButton')
    AuditIntegrityButton  = (Get-Control 'AuditIntegrityButton')
    RollbackChangesButton = (Get-Control 'RollbackChangesButton')

    # Health
    HealthTitleLabel      = (Get-Control 'HealthTitleLabel')
    HealthSummaryLabel    = (Get-Control 'HealthSummaryLabel')
    HealthStatusText      = (Get-Control 'HealthStatusText')
    HealthWslStatusText   = (Get-Control 'HealthWslStatusText')
    HealthWingetStatusText = (Get-Control 'HealthWingetStatusText')
    HealthRebootStatusText = (Get-Control 'HealthRebootStatusText')
    HealthSecretsStatusText = (Get-Control 'HealthSecretsStatusText')
    HealthDeckStatusText  = (Get-Control 'HealthDeckStatusText')
    HealthGithubStatusText = (Get-Control 'HealthGithubStatusText')
    HealthAiUsagebarStatusText = (Get-Control 'HealthAiUsagebarStatusText')
    HealthAiMemoryStatusText = (Get-Control 'HealthAiMemoryStatusText')
    HealthAionUiStatusText = (Get-Control 'HealthAionUiStatusText')
    HealthRollbackStatusText = (Get-Control 'HealthRollbackStatusText')
    HealthDoctorButton    = (Get-Control 'HealthDoctorButton')
    HealthSupportBundleButton = (Get-Control 'HealthSupportBundleButton')
    HealthRepairPlanButton = (Get-Control 'HealthRepairPlanButton')
    HealthCopyDiagnosticButton = (Get-Control 'HealthCopyDiagnosticButton')
    HealthRepairMcpButton = (Get-Control 'HealthRepairMcpButton')
    HealthDriftCheckButton = (Get-Control 'HealthDriftCheckButton')
    HealthDriftScheduleButton = (Get-Control 'HealthDriftScheduleButton')
    HealthDoctorTextBox   = (Get-Control 'HealthDoctorTextBox')
    # Cards de saude clicaveis (validacao por escopo) + botoes de gestao
    HealthWslCard          = (Get-Control 'HealthWslCard')
    HealthWingetCard       = (Get-Control 'HealthWingetCard')
    HealthRebootCard       = (Get-Control 'HealthRebootCard')
    HealthSecretsCard      = (Get-Control 'HealthSecretsCard')
    HealthGithubCard       = (Get-Control 'HealthGithubCard')
    HealthAiUsagebarCard   = (Get-Control 'HealthAiUsagebarCard')
    HealthAiMemoryCard     = (Get-Control 'HealthAiMemoryCard')
    HealthAionUiCard       = (Get-Control 'HealthAionUiCard')
    HealthDeckCard         = (Get-Control 'HealthDeckCard')
    HealthRollbackCard     = (Get-Control 'HealthRollbackCard')
    HealthAgentToolsButton = (Get-Control 'HealthAgentToolsButton')
    HealthAgentToolsRepairButton = (Get-Control 'HealthAgentToolsRepairButton')
    HealthMsvcButton       = (Get-Control 'HealthMsvcButton')
    HealthWindowsOptButton = (Get-Control 'HealthWindowsOptButton')
    HealthValidateMcpButton = (Get-Control 'HealthValidateMcpButton')
    HealthDriveLabelsStatusText = (Get-Control 'HealthDriveLabelsStatusText')
    HealthDriveLabelsButton = (Get-Control 'HealthDriveLabelsButton')
    HealthDriveLabelsAdvancedCheck = (Get-Control 'HealthDriveLabelsAdvancedCheck')
    HealthDriveLabelsApplyButton = (Get-Control 'HealthDriveLabelsApplyButton')
    HealthDriveLabelsGrid = (Get-Control 'HealthDriveLabelsGrid')

    # App Tuning
    AppTuningTitleLabel   = (Get-Control 'AppTuningTitleLabel')
    AppTuningSubtitleLabel = (Get-Control 'AppTuningSubtitleLabel')
    AppTuningModeLabel    = (Get-Control 'AppTuningModeLabel')
    AppTuningModeCombo    = (Get-Control 'AppTuningModeCombo')
    AppTuningSearchBox    = (Get-Control 'AppTuningSearchBox')
    AppTuningStatusFilterCombo = (Get-Control 'AppTuningStatusFilterCombo')
    AppTuningRiskFilterCombo = (Get-Control 'AppTuningRiskFilterCombo')
    AppTuningStatusLabel  = (Get-Control 'AppTuningStatusLabel')
    AppTuningRiskWarningLabel = (Get-Control 'AppTuningRiskWarningLabel')
    AppTuningRecommendedButton = (Get-Control 'AppTuningRecommendedButton')
    AppTuningMarkCategoryButton = (Get-Control 'AppTuningMarkCategoryButton')
    AppTuningClearCategoryButton = (Get-Control 'AppTuningClearCategoryButton')
    AppTuningAuditButton  = (Get-Control 'AppTuningAuditButton')
    AppTuningClearAllButton = (Get-Control 'AppTuningClearAllButton')
    AppTuningInstallButton = (Get-Control 'AppTuningInstallButton')
    AppTuningConfigureButton = (Get-Control 'AppTuningConfigureButton')
    AppTuningUpdateButton = (Get-Control 'AppTuningUpdateButton')
    AppTuningRunNowButton = (Get-Control 'AppTuningRunNowButton')
    AppTuningOpenFolderButton = (Get-Control 'AppTuningOpenFolderButton')
    AppTuningViewLogButton = (Get-Control 'AppTuningViewLogButton')
    AppTuningCategoriesLabel = (Get-Control 'AppTuningCategoriesLabel')
    AppTuningCategoryList = (Get-Control 'AppTuningCategoryList')
    AppTuningItemsLabel   = (Get-Control 'AppTuningItemsLabel')
    AppTuningItemsGrid    = (Get-Control 'AppTuningItemsGrid')
    AppTuningHintLabel    = (Get-Control 'AppTuningHintLabel')

    # AI Coding Tools
    AiToolsTitleLabel     = (Get-Control 'AiToolsTitleLabel')
    AiToolsSubtitleLabel  = (Get-Control 'AiToolsSubtitleLabel')
    AiToolsStatusLabel    = (Get-Control 'AiToolsStatusLabel')
    AiToolsGrid           = (Get-Control 'AiToolsGrid')
    AiToolsInstallButton  = (Get-Control 'AiToolsInstallButton')
    AiToolsValidateButton = (Get-Control 'AiToolsValidateButton')
    AiToolsConfigureButton = (Get-Control 'AiToolsConfigureButton')
    AiToolsUninstallButton = (Get-Control 'AiToolsUninstallButton')
    AiToolsClearButton    = (Get-Control 'AiToolsClearButton')
    AiToolsDocsButton     = (Get-Control 'AiToolsDocsButton')

    # API Center
    ApiCenterTitleLabel   = (Get-Control 'ApiCenterTitleLabel')
    ApiProviderSummaryLabel = (Get-Control 'ApiProviderSummaryLabel')
    ApiCredentialsLabel   = (Get-Control 'ApiCredentialsLabel')
    ApiUsageLabel         = (Get-Control 'ApiUsageLabel')
    ApiCreateLabel        = (Get-Control 'ApiCreateLabel')
    ApiStatusLabel        = (Get-Control 'ApiStatusLabel')
    ApiStatusLinksLabel   = (Get-Control 'ApiStatusLinksLabel')
    ApiSignupLink         = (Get-Control 'ApiSignupLink')
    ApiDocsLink           = (Get-Control 'ApiDocsLink')
    ApiPricingLink        = (Get-Control 'ApiPricingLink')
    ApiSecretsLinksLabel  = (Get-Control 'ApiSecretsLinksLabel')
    ApiSecretsFileLink    = (Get-Control 'ApiSecretsFileLink')
    ApiSecretsFolderLink  = (Get-Control 'ApiSecretsFolderLink')
    ApiRefreshButton      = (Get-Control 'ApiRefreshButton')
    ApiValidateAllButton  = (Get-Control 'ApiValidateAllButton')
    ApiImportButton       = (Get-Control 'ApiImportButton')
    ApiCatalogButton      = (Get-Control 'ApiCatalogButton')
    ApiApplyButton        = (Get-Control 'ApiApplyButton')
    ApiSaveButton         = (Get-Control 'ApiSaveButton')
    ApiValidateButton     = (Get-Control 'ApiValidateButton')
    ApiActivateButton     = (Get-Control 'ApiActivateButton')
    ApiProviderSummaryGrid = (Get-Control 'ApiProviderSummaryGrid')
    ApiCredentialGrid     = (Get-Control 'ApiCredentialGrid')
    ApiUsageGrid          = (Get-Control 'ApiUsageGrid')
    ApiCreateGrid         = (Get-Control 'ApiCreateGrid')
    ApiProviderCombo      = (Get-Control 'ApiProviderCombo')
    ApiCredentialCombo    = (Get-Control 'ApiCredentialCombo')
    ApiDisplayNameTextBox = (Get-Control 'ApiDisplayNameTextBox')
    ApiSecretBox          = (Get-Control 'ApiSecretBox')
    ApiBaseUrlTextBox     = (Get-Control 'ApiBaseUrlTextBox')
    ApiOrganizationTextBox = (Get-Control 'ApiOrganizationTextBox')
    ApiProjectRefTextBox  = (Get-Control 'ApiProjectRefTextBox')
    ApiCatalogTitleLabel  = (Get-Control 'ApiCatalogTitleLabel')
    ApiCatalogSubtitleLabel = (Get-Control 'ApiCatalogSubtitleLabel')
    ApiCatalogBackButton  = (Get-Control 'ApiCatalogBackButton')
    ApiCatalogStatusLabel = (Get-Control 'ApiCatalogStatusLabel')
    ApiFullCatalogLabel   = (Get-Control 'ApiFullCatalogLabel')
    ApiFullCatalogGrid    = (Get-Control 'ApiFullCatalogGrid')

    # Steam Deck Control
    SteamDeckTitleLabel   = (Get-Control 'SteamDeckTitleLabel')
    MonitorProfilesLabel  = (Get-Control 'MonitorProfilesLabel')
    MonitorProfilesGrid   = (Get-Control 'MonitorProfilesGrid')
    MonitorFamiliesLabel  = (Get-Control 'MonitorFamiliesLabel')
    MonitorFamiliesGrid   = (Get-Control 'MonitorFamiliesGrid')
    GenericGroupLabel     = (Get-Control 'GenericGroupLabel')
    GenericModeLabel      = (Get-Control 'GenericModeLabel')
    GenericModeCombo      = (Get-Control 'GenericModeCombo')
    GenericLayoutLabel    = (Get-Control 'GenericLayoutLabel')
    GenericLayoutTextBox  = (Get-Control 'GenericLayoutTextBox')
    GenericResolutionLabel = (Get-Control 'GenericResolutionLabel')
    GenericResolutionTextBox = (Get-Control 'GenericResolutionTextBox')
    DisplayModeLabel     = (Get-Control 'DisplayModeLabel')
    DisplayModeCombo     = (Get-Control 'DisplayModeCombo')
    SessionGroupLabel     = (Get-Control 'SessionGroupLabel')
    HandheldSessionLabel  = (Get-Control 'HandheldSessionLabel')
    HandheldSessionTextBox = (Get-Control 'HandheldSessionTextBox')
    DockTvSessionLabel    = (Get-Control 'DockTvSessionLabel')
    DockTvSessionTextBox  = (Get-Control 'DockTvSessionTextBox')
    DockMonitorSessionLabel = (Get-Control 'DockMonitorSessionLabel')
    DockMonitorSessionTextBox = (Get-Control 'DockMonitorSessionTextBox')
    PendingExternalLabel  = (Get-Control 'PendingExternalLabel')
    PendingExternalStatusLabel = (Get-Control 'PendingExternalStatusLabel')
    ClassifyMonitorButton = (Get-Control 'ClassifyMonitorButton')
    ClassifyTvButton      = (Get-Control 'ClassifyTvButton')
    WatcherStatusLabel    = (Get-Control 'WatcherStatusLabel')
    UnknownMonitorHintLabel = (Get-Control 'UnknownMonitorHintLabel')
    ReloadSettingsButton  = (Get-Control 'ReloadSettingsButton')
    SaveSettingsButton    = (Get-Control 'SaveSettingsButton')

    # Dual Boot
    DualBootTitleLabel    = (Get-Control 'DualBootTitleLabel')
    DualBootStatusText    = (Get-Control 'DualBootStatusText')
    DualBootPrereqsText   = (Get-Control 'DualBootPrereqsText')
    FixFastStartupButton  = (Get-Control 'FixFastStartupButton')
    DualBootTargetCombo   = (Get-Control 'DualBootTargetCombo')
    RebootToLinuxButton   = (Get-Control 'RebootToLinuxButton')
    WindowsBootStatusText = (Get-Control 'WindowsBootStatusText')
    WindowsBootEntriesGrid = (Get-Control 'WindowsBootEntriesGrid')
    WindowsBootDefaultCombo = (Get-Control 'WindowsBootDefaultCombo')
    WindowsBootTimeoutTextBox = (Get-Control 'WindowsBootTimeoutTextBox')
    BackupWindowsBootButton = (Get-Control 'BackupWindowsBootButton')
    ApplyWindowsBootButton = (Get-Control 'ApplyWindowsBootButton')
    BcdBackupCombo        = (Get-Control 'BcdBackupCombo')
    RestoreBcdButton      = (Get-Control 'RestoreBcdButton')
    BcdCleanupStatusText  = (Get-Control 'BcdCleanupStatusText')
    BcdCleanupButton      = (Get-Control 'BcdCleanupButton')
    RefreshDualBootButton = (Get-Control 'RefreshDualBootButton')
    BtrfsStatusText       = (Get-Control 'BtrfsStatusText')
    BtrfsCheckButton      = (Get-Control 'BtrfsCheckButton')
    BtrfsInstallButton    = (Get-Control 'BtrfsInstallButton')

    # Review
    ReviewTitleLabel      = (Get-Control 'ReviewTitleLabel')
    ReviewSummaryLabel    = (Get-Control 'ReviewSummaryLabel')
    ReviewSideEffectsLabel = (Get-Control 'ReviewSideEffectsLabel')
    ReviewSideEffectsTextBox = (Get-Control 'ReviewSideEffectsTextBox')
    ReviewAcceptedCheckBox = (Get-Control 'ReviewAcceptedCheckBox')
    RefreshReviewButton   = (Get-Control 'RefreshReviewButton')
    ReviewMetaLabel       = (Get-Control 'ReviewMetaLabel')
    ReviewLinksLabel      = (Get-Control 'ReviewLinksLabel')
    ReviewSettingsLink    = (Get-Control 'ReviewSettingsLink')
    ReviewUiStateLink     = (Get-Control 'ReviewUiStateLink')
    ReviewTextBox         = (Get-Control 'ReviewTextBox')

    # Run
    RunTitleLabel         = (Get-Control 'RunTitleLabel')
    RunStatusLabel        = (Get-Control 'RunStatusLabel')
    PendingRebootBanner   = (Get-Control 'PendingRebootBanner')
    PendingRebootBannerLabel = (Get-Control 'PendingRebootBannerLabel')
    StartRunButton        = (Get-Control 'StartRunButton')
    OpenLogButton         = (Get-Control 'OpenLogButton')
    OpenResultButton      = (Get-Control 'OpenResultButton')
    OpenSettingsButton    = (Get-Control 'OpenSettingsButton')
    OpenReportsButton     = (Get-Control 'OpenReportsButton')
    RunLogTextBox         = (Get-Control 'RunLogTextBox')
    RunTimelineStep1Dot   = (Get-Control 'RunTimelineStep1Dot')
    RunTimelineStep1Label = (Get-Control 'RunTimelineStep1Label')
    RunTimelineStep2Dot   = (Get-Control 'RunTimelineStep2Dot')
    RunTimelineStep2Label = (Get-Control 'RunTimelineStep2Label')
    RunTimelineStep3Dot   = (Get-Control 'RunTimelineStep3Dot')
    RunTimelineStep3Label = (Get-Control 'RunTimelineStep3Label')
    RunTimelineStep4Dot   = (Get-Control 'RunTimelineStep4Dot')
    RunTimelineStep4Label = (Get-Control 'RunTimelineStep4Label')
    RunTimelineStep5Dot   = (Get-Control 'RunTimelineStep5Dot')
    RunTimelineStep5Label = (Get-Control 'RunTimelineStep5Label')

    # Pages (panels identified by WPF name)
    PageNames             = @('PageHealth', 'PageWelcome', 'PageSelection', 'PageHostSetup', 'PageAppTuning', 'PageAiTools', 'PageApiCenter', 'PageApiCatalog', 'PageSteamDeck', 'PageDualBoot', 'PageReview', 'PageRun')
}

#
# DispatcherTimer (replaces WinForms Timer)
#

$logTimer = New-Object System.Windows.Threading.DispatcherTimer
$logTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$ui.LogTimer = $logTimer

$appTuningRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$appTuningRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$ui.AppTuningRefreshTimer = $appTuningRefreshTimer

#
# Helper: WPF DataGrid population
#

function ConvertTo-UiBoolean {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    return @('1', 'true', 'yes', 'y', 'sim', 'on') -contains $text
}

function Load-WpfGridRows {
    param(
        [Parameter(Mandatory=$true)]$Grid,
        [Parameter(Mandatory=$true)]$Items,
        [Parameter(Mandatory=$true)][string[]]$Columns
    )
    $table = New-Object System.Data.DataTable
    foreach ($col in $Columns) {
        if (@('primary', 'active') -contains $col) {
            [void]$table.Columns.Add($col, [bool])
        } else {
            [void]$table.Columns.Add($col)
        }
    }
    foreach ($item in @($Items)) {
        $row = $table.NewRow()
        foreach ($col in $Columns) {
            $value = if ($item -is [System.Collections.IDictionary] -and $item.Contains($col)) { $item[$col] }
                     elseif ($item.PSObject.Properties[$col]) { $item.$col }
                     else { $null }
            if (@('primary', 'active') -contains $col) {
                $row[$col] = ConvertTo-UiBoolean -Value $value
            } else {
                $row[$col] = if ($null -eq $value) { '' } else { [string]$value }
            }
        }
        $table.Rows.Add($row)
    }
    $Grid.ItemsSource = $table.DefaultView
}

function Complete-UiGridEdit {
    param([Parameter(Mandatory=$true)]$Grid)

    try { [void]$Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell, $true) } catch { [void]$_.Exception }
    try { [void]$Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) } catch { [void]$_.Exception }
}

function Read-WpfGridRows {
    param(
        [Parameter(Mandatory=$true)]$Grid,
        [Parameter(Mandatory=$true)][string[]]$Columns
    )
    $rows = @()
    if ($null -eq $Grid.ItemsSource) { return $rows }
    Complete-UiGridEdit -Grid $Grid
    foreach ($rowView in $Grid.ItemsSource) {
        $row = $rowView.Row
        $item = [ordered]@{}
        $hasData = $false
        foreach ($col in $Columns) {
            $val = [string]$row[$col]
            if ((@('primary', 'active', 'status') -notcontains $col) -and -not [string]::IsNullOrWhiteSpace($val)) { $hasData = $true }
            $item[$col] = $val
        }
        if ($hasData) { $rows += @($item) }
    }
    return @($rows)
}

function Get-SteamDeckEditableModes {
    return @('DOCKED_MONITOR', 'DOCKED_TV')
}

function Validate-SteamDeckGridModeRows {
    param(
        [Parameter(Mandatory=$true)]$Rows,
        [Parameter(Mandatory=$true)][string]$GridName
    )
    $validModes = @(Get-SteamDeckEditableModes)
    $index = 0
    foreach ($row in @($Rows)) {
        $index++
        $rowData = ConvertTo-BootstrapHashtable -InputObject $row
        $mode = ([string]$rowData['mode']).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($mode)) {
            throw "$GridName linha $index sem modo. Use DOCKED_MONITOR ou DOCKED_TV."
        }
        if ($validModes -notcontains $mode) {
            throw "$GridName linha $index com modo invalido: $mode. Use DOCKED_MONITOR ou DOCKED_TV."
        }
        $row['mode'] = $mode
    }
}

function Get-UiObjectValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory=$true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-UiObjectArray {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IDictionary]) {
        if (@($Value.Keys).Count -eq 0) { return @() }
        return @($Value)
    }
    if ($Value -is [pscustomobject]) {
        if (@($Value.PSObject.Properties).Count -eq 0) { return @() }
        return @($Value)
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        return @($Value)
    }
    return @($Value)
}

function Normalize-UiDisplayValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return '' }
    $text = ([string]$Value) -replace "`0", ''
    $text = [regex]::Replace($text.Trim(), '\s+', ' ')
    return $text.ToLowerInvariant()
}

function Test-UiDisplayMatch {
    param(
        [AllowNull()]$Display,
        [AllowNull()]$Matcher,
        [switch]$RequireSerial
    )

    if ($null -eq $Display -or $null -eq $Matcher) { return $false }
    $displayManufacturer = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Display -Name 'manufacturer')
    $displayProduct = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Display -Name 'product')
    $matcherManufacturer = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Matcher -Name 'manufacturer')
    $matcherProduct = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Matcher -Name 'product')
    if ($displayManufacturer -ne $matcherManufacturer -or $displayProduct -ne $matcherProduct) { return $false }

    if ($RequireSerial) {
        $matcherSerial = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Matcher -Name 'serial')
        if (-not [string]::IsNullOrWhiteSpace($matcherSerial)) {
            $displaySerial = Normalize-UiDisplayValue (Get-UiObjectValue -Object $Display -Name 'serial')
            if ($displaySerial -ne $matcherSerial) { return $false }
        }
    }

    return $true
}

function Get-UiSteamDeckLiveDetectionData {
    param([Parameter(Mandatory=$true)]$Settings)

    $automationRoot = Get-BootstrapSteamDeckAutomationRoot
    $detectScript = Join-Path $automationRoot 'Detect-Mode.ps1'
    if (-not (Test-Path $detectScript)) {
        return (ConvertTo-BootstrapHashtable -InputObject (Get-BootstrapSteamDeckCurrentDetectionData).Data)
    }

    $tempPath = Join-Path $env:TEMP ("steamdeck-ui-detect-settings_{0}.json" -f ([guid]::NewGuid().ToString('N')))
    try {
        $jsonSettings = $Settings | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($tempPath, $jsonSettings, [System.Text.UTF8Encoding]::new($false))
        $json = & $detectScript -SettingsPath $tempPath 2>$null
        $text = (@($json) -join [Environment]::NewLine).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return (ConvertTo-BootstrapHashtable -InputObject ($text | ConvertFrom-Json -ErrorAction Stop))
        }
    } catch {
        try { Write-UiLog -Level 'WARN' -Message "Steam Deck live detection failed: $($_.Exception.Message)" } catch { }
    } finally {
        if (Test-Path $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }

    return (ConvertTo-BootstrapHashtable -InputObject (Get-BootstrapSteamDeckCurrentDetectionData).Data)
}

function Get-UiSteamDeckDisplayStatus {
    param(
        [AllowNull()]$Detection,
        [Parameter(Mandatory=$true)]$Matcher,
        [switch]$Internal,
        [switch]$Family
    )

    if (-not ($Detection -is [hashtable])) { return 'status desconhecido' }

    if ($Internal) {
        $internal = Get-UiObjectValue -Object $Detection -Name 'internalDisplay'
        if ($internal) {
            $suffix = if (ConvertTo-UiBoolean (Get-UiObjectValue -Object $internal -Name 'isPrimary')) { ' / principal no Windows' } else { '' }
            return "ativo$suffix"
        }
        $externalCount = [int](Get-UiObjectValue -Object $Detection -Name 'externalDisplayCount' -Default 0)
        if ($externalCount -gt 0) { return 'desativado: so desktop externo' }
        return 'não detectado'
    }

    $selected = Get-UiObjectValue -Object $Detection -Name 'selectedDisplay'
    if (Test-UiDisplayMatch -Display $selected -Matcher $Matcher -RequireSerial:(-not $Family)) {
        $suffix = if (ConvertTo-UiBoolean (Get-UiObjectValue -Object $selected -Name 'isPrimary')) { ' / principal no Windows' } else { '' }
        return "ativo$suffix"
    }

    foreach ($display in @(Get-UiObjectArray -Value (Get-UiObjectValue -Object $Detection -Name 'externalDisplays'))) {
        if (Test-UiDisplayMatch -Display $display -Matcher $Matcher -RequireSerial:(-not $Family)) {
            return 'ativo'
        }
    }

    return 'cadastrado'
}

function Get-UiSteamDeckProfileRows {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Settings,
        [AllowNull()]$Detection
    )

    $internal = ConvertTo-BootstrapHashtable -InputObject (Get-UiObjectValue -Object $Settings -Name 'internalDisplay' -Default @{})
    if (-not ($internal -is [hashtable])) { $internal = @{} }

    $rows = @()
    $rows += @([ordered]@{
        primary = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $internal -Name 'primary' -Default $false)
        target = 'internal'
        status = Get-UiSteamDeckDisplayStatus -Detection $Detection -Matcher $internal -Internal
        manufacturer = [string](Get-UiObjectValue -Object $internal -Name 'manufacturer' -Default 'VLV')
        product = [string](Get-UiObjectValue -Object $internal -Name 'product' -Default 'ANX7530 U')
        serial = [string](Get-UiObjectValue -Object $internal -Name 'serial' -Default '')
        mode = 'HANDHELD'
        layout = [string](Get-UiObjectValue -Object $internal -Name 'layout' -Default 'internal-panel')
        resolutionPolicy = [string](Get-UiObjectValue -Object $internal -Name 'resolutionPolicy' -Default '1280x800')
    })

    foreach ($profile in @(Get-UiObjectArray -Value (Get-UiObjectValue -Object $Settings -Name 'monitorProfiles'))) {
        $profileMap = ConvertTo-BootstrapHashtable -InputObject $profile
        $rows += @([ordered]@{
            primary = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $profileMap -Name 'primary' -Default $false)
            target = 'profile'
            status = Get-UiSteamDeckDisplayStatus -Detection $Detection -Matcher $profileMap
            manufacturer = [string](Get-UiObjectValue -Object $profileMap -Name 'manufacturer')
            product = [string](Get-UiObjectValue -Object $profileMap -Name 'product')
            serial = [string](Get-UiObjectValue -Object $profileMap -Name 'serial')
            mode = [string](Get-UiObjectValue -Object $profileMap -Name 'mode' -Default 'DOCKED_MONITOR')
            layout = [string](Get-UiObjectValue -Object $profileMap -Name 'layout')
            resolutionPolicy = [string](Get-UiObjectValue -Object $profileMap -Name 'resolutionPolicy')
        })
    }

    return @($rows)
}

function Get-UiSteamDeckFamilyRows {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Settings,
        [AllowNull()]$Detection
    )

    $rows = @()
    foreach ($family in @(Get-UiObjectArray -Value (Get-UiObjectValue -Object $Settings -Name 'monitorFamilies'))) {
        $familyMap = ConvertTo-BootstrapHashtable -InputObject $family
        $rows += @([ordered]@{
            primary = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $familyMap -Name 'primary' -Default $false)
            status = Get-UiSteamDeckDisplayStatus -Detection $Detection -Matcher $familyMap -Family
            manufacturer = [string](Get-UiObjectValue -Object $familyMap -Name 'manufacturer')
            product = [string](Get-UiObjectValue -Object $familyMap -Name 'product')
            namePattern = [string](Get-UiObjectValue -Object $familyMap -Name 'namePattern')
            mode = [string](Get-UiObjectValue -Object $familyMap -Name 'mode' -Default 'DOCKED_MONITOR')
            layout = [string](Get-UiObjectValue -Object $familyMap -Name 'layout')
            resolutionPolicy = [string](Get-UiObjectValue -Object $familyMap -Name 'resolutionPolicy')
        })
    }

    return @($rows)
}

function Remove-UiGridRuntimeColumns {
    param(
        [Parameter(Mandatory=$true)]$Rows,
        [string[]]$RuntimeColumns = @('target', 'status')
    )

    $result = @()
    foreach ($row in @($Rows)) {
        $map = [ordered]@{}
        foreach ($key in @($row.Keys)) {
            if ($RuntimeColumns -contains [string]$key) { continue }
            $map[$key] = $row[$key]
        }
        $result += @($map)
    }
    return @($result)
}

#
# Helpers (same logic, updated control references)
#

function Open-ExistingPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -in @('.ps1', '.psm1', '.psd1')) {
        # Start-Process no .ps1 dispara "Abrir com" (associação Open); mostrar no Explorador em vez de executar.
        $selectArg = if ($Path -match '\s') { '/select,"{0}"' -f ($Path -replace '"', '""') } else { '/select,{0}' -f $Path }
        Start-Process -FilePath 'explorer.exe' -ArgumentList $selectArg | Out-Null
        return
    }
    Start-Process -FilePath $Path | Out-Null
}

function Get-SelectionDetailsText {
    param(
        [AllowNull()]$Item,
        [Parameter(Mandatory=$true)][string]$Kind
    )
    if ($null -eq $Item) { return '' }
    if ($Kind -eq 'profile') {
        return @(
            "Name: $($Item.name)"
            "Description: $($Item.description)"
            "Items: $(@($Item.items) -join ', ')"
        ) -join [Environment]::NewLine
    }
    $name = [string]$Item.name
    $impact = Get-UiComponentImpact -ComponentName $name -Component $Item
    return @(
        "Name: $($Item.name)"
        "Description: $($Item.description)"
        "DependsOn: $(@($Item.dependsOn) -join ', ')"
        "Kind: $($Item.kind)"
        "Stage: $($Item.stage)"
        "Optional: $($Item.optional)"
        "Value: $($Item.valueReason)"
        "SelectedBy: $($impact.selectedBy)"
        "CanExclude: $($impact.canExclude)"
        "Dependents: $(@($impact.dependents) -join ', ')"
        "RequiresAdmin: $($impact.requiresAdmin)"
        "RequiresNetwork: $($impact.requiresNetwork)"
        "ManualRequired: $($impact.manualRequired)"
        "Reversible: $($impact.reversible)"
        "RollbackNotes: $($impact.rollbackNotes)"
    ) -join [Environment]::NewLine
}

function Apply-QuickPreset {
    param([Parameter(Mandatory=$true)][string]$PresetName)
    $ui.State.selectedProfiles   = @($PresetName)
    $ui.State.selectedComponents = @()
    $ui.State.excludedComponents = @()
    $ui.State.hostHealth         = if ($PresetName -eq 'legacy') { 'off' } else { 'conservador' }
    $ui.State.appTuningMode      = if ($PresetName -eq 'legacy') { 'off' } else { 'recommended' }
    $ui.State.selectedAppTuningCategories = @()
    $ui.State.selectedAppTuningItems = @()
    $ui.State.excludedAppTuningItems = @()
    $ui.State.selectedAiTools = @()
    $ui.State.steamDeckVersion   = 'Auto'
}

function Remove-UiStringValue {
    param(
        [AllowNull()]$Values,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $items = @($Values | ForEach-Object { [string]$_ })
    return @($items -ne $Value)
}

function Test-UiComponentCanExclude {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [AllowNull()]$Component = $null
    )

    if (-not $Component) {
        $lookup = Get-UiComponentCatalogLookup
        if ($lookup.ContainsKey($ComponentName)) { $Component = $lookup[$ComponentName] }
    }
    return [bool]($Component -and [bool]$Component.optional)
}

function Repair-UiExcludedComponents {
    $catalogLookup = Get-UiComponentCatalogLookup
    $kept = @()
    $removed = @()
    foreach ($componentName in @(Normalize-BootstrapNames -Names @($ui.State.excludedComponents))) {
        if ([string]::IsNullOrWhiteSpace([string]$componentName)) { continue }
        $component = if ($catalogLookup.ContainsKey([string]$componentName)) { $catalogLookup[[string]$componentName] } else { $null }
        if (Test-UiComponentCanExclude -ComponentName ([string]$componentName) -Component $component) {
            $kept += @([string]$componentName)
        } else {
            $removed += @([string]$componentName)
        }
    }
    if ($removed.Count -gt 0) {
        $ui.State.excludedComponents = @($kept)
        Save-UiState -State $ui.State -Path $UiStatePath
    }
    return @($removed)
}

function Clear-UiAllSelections {
    $ui.State.selectedProfiles = @()
    $ui.State.selectedComponents = @()
    $ui.State.excludedComponents = @()
    $ui.State.hostHealth = 'off'
    $ui.State.appTuningMode = 'off'
    $ui.State.selectedAppTuningCategories = @()
    $ui.State.selectedAppTuningItems = @()
    $ui.State.excludedAppTuningItems = @()
    $ui.State.selectedAiTools = @()
    $ui.State.steamDeckVersion = 'Auto'
    $ui.State.enableClaudeCodeProjectMcps = $false
    $ui.State.skipManualRequirements = $false
    $ui.State.ignoreManualRequirements = $false
    $ui.State.requireNoPendingReboot = $false
    $ui.State.offlineMode = $false
    $ui.State.enableResume = $false
    try { $ui.ExecutionScopeOverride = $null; $ui.CurrentExecutionScopeLabel = '' } catch { }
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionTrees
    Refresh-SelectionSummary
    Refresh-HostSetupControls
    Refresh-AppTuningControls
    Set-AppTuningActionFeedback -Message 'Selecao limpa. Nenhum perfil/componente/host health/app tuning ativo.' -Level 'info'
}

function Refresh-CustomPresets {
    $ui.CustomPresetCombo.Items.Clear()
    foreach ($presetName in @($ui.State.customPresets.Keys | Sort-Object)) {
        [void]$ui.CustomPresetCombo.Items.Add($presetName)
    }
}

function Refresh-LocalizedText {
    $ui.Strings = Get-UiStrings -Language ([string]$ui.State.language)
    $ui.Window.Title                   = $ui.Strings.WindowTitle
    $ui.WelcomeTitleLabel.Text         = $ui.Strings.WelcomeTitle
    $ui.WelcomeSubtitleLabel.Text      = $ui.Strings.WelcomeSubtitle
    $ui.QuickPresetsLabel.Text         = $ui.Strings.QuickPresets.ToUpper()
    $ui.CustomPresetsLabel.Text        = $ui.Strings.CustomPresets.ToUpper()
    $ui.PresetNameLabel.Text           = $ui.Strings.PresetName
    $ui.SavePresetButton.Content       = "  $($ui.Strings.SavePreset)"
    $ui.LoadPresetButton.Content       = "  $($ui.Strings.LoadPreset)"
    $ui.DeletePresetButton.Content     = "  $($ui.Strings.DeletePreset)"
    $ui.SelectionTitleLabel.Text       = $ui.Strings.SelectionTitle
    $ui.ClearAllSelectionButton.Content = " $($ui.Strings.ClearAllSelection)"
    $ui.ProfilesLabel.Text             = $ui.Strings.Profiles.ToUpper()
    $ui.ComponentsLabel.Text           = $ui.Strings.Components.ToUpper()
    $ui.QuickOptionsLabel.Text         = $ui.Strings.QuickOptions.ToUpper()
    $ui.OptClaudePluginsCheckBox.Content = $ui.Strings.OptClaudePlugins
    $ui.OptClaudeProjectMcpsCheckBox.Content = $ui.Strings.OptClaudeProjectMcps
    $ui.OptOpenWebUICheckBox.Content   = $ui.Strings.OptOpenWebUI
    $ui.OptSkipManualRequirementsCheckBox.Content = $ui.Strings.OptSkipManualRequirements
    $ui.OptIgnoreManualRequirementsCheckBox.Content = $ui.Strings.OptIgnoreManualRequirements
    $ui.OptRequireNoPendingRebootCheckBox.Content = $ui.Strings.OptRequireNoPendingReboot
    $ui.OptOfflineModeCheckBox.Content = $ui.Strings.OptOfflineMode
    $ui.OptEnableResumeCheckBox.Content = $ui.Strings.OptEnableResume
    $ui.ExcludeLabel.Text              = $ui.Strings.Excludes.ToUpper()
    $ui.DetailsLabel.Text              = $ui.Strings.SelectionDetails.ToUpper()
    $ui.HostTitleLabel.Text            = $ui.Strings.HostSetupTitle
    $ui.AppTuningTitleLabel.Text       = $ui.Strings.AppTuningTitle
    $ui.AppTuningSubtitleLabel.Text    = $ui.Strings.AppTuningSubtitle
    $ui.AppTuningModeLabel.Text        = $ui.Strings.AppTuningMode
    $ui.AppTuningCategoriesLabel.Text  = $ui.Strings.AppTuningCategories.ToUpper()
    $ui.AppTuningItemsLabel.Text       = $ui.Strings.AppTuningItems.ToUpper()
    $ui.AppTuningRecommendedButton.Content = $ui.Strings.AppTuningRecommended
    $ui.AppTuningMarkCategoryButton.Content = $ui.Strings.AppTuningMarkCategory
    $ui.AppTuningClearCategoryButton.Content = $ui.Strings.AppTuningClearCategory
    $ui.AppTuningAuditButton.Content   = $ui.Strings.AppTuningAudit
    $ui.AppTuningClearAllButton.Content = $ui.Strings.ClearAllSelection
    $ui.AppTuningInstallButton.Content = $ui.Strings.AppTuningInstall
    $ui.AppTuningConfigureButton.Content = $ui.Strings.AppTuningConfigure
    $ui.AppTuningUpdateButton.Content  = $ui.Strings.AppTuningUpdate
    $ui.AppTuningRunNowButton.Content  = $ui.Strings.AppTuningRunNow
    $ui.AppTuningOpenFolderButton.Content = $ui.Strings.AppTuningOpenFolder
    $ui.AppTuningViewLogButton.Content = $ui.Strings.AppTuningViewLog
    $ui.AppTuningHintLabel.Text        = $ui.Strings.AppTuningStatus
    $ui.AiToolsTitleLabel.Text         = $ui.Strings.AiToolsTitle
    $ui.AiToolsSubtitleLabel.Text      = $ui.Strings.AiToolsStatus
    $ui.AiToolsStatusLabel.Text        = $ui.Strings.AiToolsStatus
    $ui.AiToolsInstallButton.Content   = $ui.Strings.AiToolsInstall
    $ui.AiToolsValidateButton.Content  = $ui.Strings.AiToolsValidate
    $ui.AiToolsConfigureButton.Content = $ui.Strings.AiToolsConfigure
    $ui.AiToolsUninstallButton.Content = $ui.Strings.AiToolsUninstall
    $ui.AiToolsDocsButton.Content      = $ui.Strings.AiToolsDocs
    $ui.ApiCenterTitleLabel.Text       = $ui.Strings.ApiCenterTitle
    $ui.ApiProviderSummaryLabel.Text   = $ui.Strings.ApiProviderSummary.ToUpper()
    $ui.ApiCredentialsLabel.Text       = $ui.Strings.ApiCredentials.ToUpper()
    $ui.ApiUsageLabel.Text             = $ui.Strings.ApiUsage.ToUpper()
    $ui.ApiCreateLabel.Text            = $ui.Strings.ApiCreate.ToUpper()
    $ui.ApiRefreshButton.Content       = $ui.Strings.ApiRefresh
    $ui.ApiValidateAllButton.Content   = $ui.Strings.ApiValidateAll
    $ui.ApiImportButton.Content        = $ui.Strings.ApiImport
    $ui.ApiCatalogButton.Content       = $ui.Strings.ApiCatalog
    $ui.ApiApplyButton.Content         = $ui.Strings.ApiApply
    $ui.ApiSaveButton.Content          = $ui.Strings.ApiSave
    $ui.ApiValidateButton.Content      = $ui.Strings.ApiValidate
    $ui.ApiActivateButton.Content      = $ui.Strings.ApiActivate
    $ui.ApiCatalogTitleLabel.Text      = $ui.Strings.ApiCatalogTitle
    $ui.ApiCatalogSubtitleLabel.Text   = $ui.Strings.ApiCatalogSubtitle
    $ui.ApiCatalogBackButton.Content   = $ui.Strings.ApiCatalogBack
    $ui.ApiFullCatalogLabel.Text       = $ui.Strings.ApiCatalogTitle.ToUpper()
    $ui.HostHealthLabel.Text           = $ui.Strings.HostHealth
    $ui.SteamDeckVersionLabel.Text     = $ui.Strings.SteamDeckVersion
    $ui.WorkspaceRootLabel.Text        = $ui.Strings.WorkspaceRoot
    $ui.CloneBaseDirLabel.Text         = $ui.Strings.CloneBaseDir
    $ui.WorkspaceBrowseButton.Content  = " $($ui.Strings.Browse)"
    $ui.CloneBrowseButton.Content      = " $($ui.Strings.Browse)"
    $ui.AdminNeedsTitleLabel.Text      = $ui.Strings.AdminNeeds.ToUpper()
    $ui.DoctorQuickButton.Content      = " $($ui.Strings.HealthDoctor)"
    $ui.SupportBundleQuickButton.Content = " $($ui.Strings.HealthSupportBundle)"
    $ui.HealthTitleLabel.Text          = $ui.Strings.HealthTitle
    $ui.HealthSummaryLabel.Text        = $ui.Strings.HealthSummary
    $ui.HealthStatusText.Text          = $ui.Strings.HealthStatus
    $ui.HealthWslStatusText.Text       = 'WSL: Ausente'
    $ui.HealthWingetStatusText.Text    = 'winget: Ausente'
    $ui.HealthRebootStatusText.Text    = 'Reboot: OK'
    $ui.HealthSecretsStatusText.Text   = 'Secrets: Atenção'
    $ui.HealthDeckStatusText.Text      = $ui.Strings.HealthDeckStatus
    $ui.HealthGithubStatusText.Text    = $ui.Strings.HealthGithubStatus
    $ui.HealthAiUsagebarStatusText.Text = 'ai-usagebar: Ausente'
    $ui.HealthAiMemoryStatusText.Text  = 'ai-memory: Ausente'
    $ui.HealthAionUiStatusText.Text    = 'AionUI: Ausente'
    $ui.HealthRollbackStatusText.Text  = 'Reversão: OK'
    $ui.HealthDoctorButton.Content     = $ui.Strings.HealthDoctor
    $ui.HealthSupportBundleButton.Content = $ui.Strings.HealthSupportBundle
    $ui.HealthRepairPlanButton.Content = $ui.Strings.HealthRepairPlan
    $ui.HealthCopyDiagnosticButton.Content = $ui.Strings.HealthCopyDiagnostic
    $ui.SteamDeckTitleLabel.Text       = $ui.Strings.SteamDeckCenterTitle
    $ui.MonitorProfilesLabel.Text      = $ui.Strings.MonitorProfiles.ToUpper()
    $ui.MonitorFamiliesLabel.Text      = $ui.Strings.MonitorFamilies.ToUpper()
    $ui.GenericGroupLabel.Text         = $ui.Strings.GenericExternal.ToUpper()
    $ui.GenericModeLabel.Text          = $ui.Strings.GenericMode
    $ui.GenericLayoutLabel.Text        = $ui.Strings.GenericLayout
    $ui.GenericResolutionLabel.Text    = $ui.Strings.GenericResolution
    $ui.DisplayModeLabel.Text          = $ui.Strings.DisplayMode
    $ui.SessionGroupLabel.Text         = $ui.Strings.SessionProfiles.ToUpper()
    $ui.HandheldSessionLabel.Text      = $ui.Strings.SessionHandheld
    $ui.DockTvSessionLabel.Text        = $ui.Strings.SessionDockedTv
    $ui.DockMonitorSessionLabel.Text   = $ui.Strings.SessionDockedMonitor
    $ui.PendingExternalLabel.Text      = $ui.Strings.PendingExternal.ToUpper()
    $ui.ClassifyMonitorButton.Content  = " $($ui.Strings.ClassifyMonitor)"
    $ui.ClassifyTvButton.Content       = " $($ui.Strings.ClassifyTv)"
    $ui.UnknownMonitorHintLabel.Text   = $ui.Strings.UnknownMonitorHint
    $ui.SaveSettingsButton.Content     = " $($ui.Strings.SaveSettings)"
    $ui.ReloadSettingsButton.Content   = " $($ui.Strings.ReloadSettings)"
    $ui.ReviewTitleLabel.Text          = $ui.Strings.ReviewTitle
    $ui.ReviewSummaryLabel.Text        = "$($ui.Strings.ReviewSummary)"
    $ui.ReviewSideEffectsLabel.Text    = $ui.Strings.ReviewSideEffects
    $ui.RefreshReviewButton.Content    = " $($ui.Strings.RefreshReview)"
    $ui.RunTitleLabel.Text             = $ui.Strings.RunTitle
    $ui.StartRunButton.Content         = $ui.Strings.StartRun
    $ui.OpenLogButton.Content          = " $($ui.Strings.OpenLog)"
    $ui.OpenResultButton.Content       = " $($ui.Strings.OpenResult)"
    $ui.OpenSettingsButton.Content     = "[gear] $($ui.Strings.OpenSettings)"
    $ui.OpenReportsButton.Content      = " $($ui.Strings.OpenReports)"
    $ui.BackButton.Content             = $ui.Strings.Back
    $ui.NextButton.Content             = $ui.Strings.Next
    $ui.FinishButton.Content           = $ui.Strings.Finish
    $ui.StatusLabel.Text               = $ui.Strings.IdleStatus
    # Sidebar nav text
    $ui.NavWelcomeText.Text    = $ui.Strings.Welcome
    $ui.NavSelectionText.Text  = $ui.Strings.Selection
    $ui.NavHostSetupText.Text  = $ui.Strings.HostSetup
    $ui.NavHealthText.Text     = $ui.Strings.Health
    $ui.NavAppTuningText.Text  = $ui.Strings.AppTuning
    $ui.NavAiToolsText.Text    = $ui.Strings.AiToolsTitle
    $ui.NavApiCenterText.Text  = $ui.Strings.ApiCenter
    $ui.NavSteamDeckText.Text  = $ui.Strings.SteamDeckControl
    $ui.NavDualBootText.Text   = $ui.Strings.DualBoot
    $ui.DualBootTitleLabel.Text = $ui.Strings.DualBoot
    $ui.NavReviewText.Text     = $ui.Strings.Review
    $ui.NavRunText.Text        = $ui.Strings.Run
}

function Get-UiResolvedComponentNameSet {
    $lookup = @{}
    try {
        $selection = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents @() -SelectedHostHealth $ui.State.hostHealth
        $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents @()
        foreach ($componentName in @($resolution.ResolvedComponents)) {
            if ([string]::IsNullOrWhiteSpace([string]$componentName)) { continue }
            if (@($ui.State.excludedComponents) -contains [string]$componentName) { continue }
            $lookup[[string]$componentName] = $true
        }
    } catch {
    }
    return $lookup
}

function Get-UiComponentCatalogLookup {
    $lookup = @{}
    foreach ($component in @($ui.Contract.components)) {
        $name = [string]$component.name
        if (-not [string]::IsNullOrWhiteSpace($name)) { $lookup[$name] = $component }
    }
    return $lookup
}

function Get-UiComponentDependents {
    param([Parameter(Mandatory = $true)][string]$ComponentName)

    $dependents = New-Object System.Collections.Generic.List[string]
    foreach ($component in @($ui.Contract.components)) {
        $name = [string]$component.name
        if ([string]::IsNullOrWhiteSpace($name) -or $name -eq $ComponentName) { continue }
        if (@($component.dependsOn) -contains $ComponentName) { $dependents.Add($name) }
    }
    return @($dependents.ToArray())
}

function Get-UiComponentImpact {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentName,
        [AllowNull()]$Component = $null
    )

    if (-not $Component) {
        $lookup = Get-UiComponentCatalogLookup
        if ($lookup.ContainsKey($ComponentName)) { $Component = $lookup[$ComponentName] }
    }

    $resolved = @{}
    if ($ui.Preview -and $ui.Preview.Resolution) {
        foreach ($name in @($ui.Preview.Resolution.ResolvedComponents)) { $resolved[[string]$name] = $true }
    } else {
        $resolved = Get-UiResolvedComponentNameSet
    }

    $explicit = (@($ui.State.selectedComponents) -contains $ComponentName)
    $excluded = (@($ui.State.excludedComponents) -contains $ComponentName)
    $isResolved = $resolved.ContainsKey($ComponentName)
    $selectedBy = if ($excluded) { 'excluded' } elseif ($explicit) { 'explicit' } elseif ($isResolved) { 'profile/dependency' } else { 'not-selected' }
    $dependents = @(Get-UiComponentDependents -ComponentName $ComponentName)
    $reversibility = if ($Component -and $Component.reversibility) { $Component.reversibility } else { $null }
    $reversible = if ($reversibility) { [string]$reversibility.reversible } else { 'unknown' }
    $rollbackNotes = if ($reversibility) { [string]$reversibility.rollbackNotes } else { 'Sem contrato de reversibilidade.' }

    return [ordered]@{
        name = $ComponentName
        selectedBy = $selectedBy
        canExclude = [bool]($Component -and [bool]$Component.optional)
        dependents = @($dependents)
        requiresAdmin = [bool]($Component -and ($Component.kind -match 'wsl|steamdeck|service|driver'))
        requiresNetwork = [bool]($Component -and ($Component.kind -match 'winget|npm|uvtool|repo|wsl|git|node|python|claude|opencode|openclaw|goose|codex'))
        manualRequired = [bool]($Component -and [string]$Component.kind -eq 'manual-required')
        stage = if ($Component) { [string]$Component.stage } else { '' }
        reversible = $reversible
        rollbackNotes = $rollbackNotes
    }
}

function Get-UiSelectionImpact {
    $impact = [ordered]@{
        total = 0
        explicit = @($ui.State.selectedComponents).Count
        inherited = 0
        excluded = @($ui.State.excludedComponents).Count
        manual = 0
        admin = 0
        network = 0
        partialOrManualRollback = 0
    }
    if (-not ($ui.Preview -and $ui.Preview.Resolution)) { return $impact }
    $catalogLookup = Get-UiComponentCatalogLookup
    $resolved = @($ui.Preview.Resolution.ResolvedComponents)
    $impact.total = $resolved.Count
    foreach ($componentName in $resolved) {
        $name = [string]$componentName
        if (@($ui.State.selectedComponents) -notcontains $name) { $impact.inherited++ }
        if (-not $catalogLookup.ContainsKey($name)) { continue }
        $component = $catalogLookup[$name]
        $componentImpact = Get-UiComponentImpact -ComponentName $name -Component $component
        if ($componentImpact.manualRequired) { $impact.manual++ }
        if ($componentImpact.requiresAdmin) { $impact.admin++ }
        if ($componentImpact.requiresNetwork) { $impact.network++ }
        if (@('partial', 'manual', 'none') -contains [string]$componentImpact.reversible) { $impact.partialOrManualRollback++ }
    }
    return $impact
}

function Test-UiContractSelectionFilter {
    param(
        [string]$Name,
        [string]$Description,
        [string]$FilterNormalized
    )
    if ([string]::IsNullOrWhiteSpace($FilterNormalized)) { return $true }
    $nameL = if ($Name) { $Name.ToLowerInvariant() } else { '' }
    $descL = if ($Description) { $Description.ToLowerInvariant() } else { '' }
    $compactName = $nameL.Replace('-', '').Replace('_', '')
    $hay = ('{0} {1} {2}' -f $nameL, $descL, $compactName).Replace('-', ' ').Replace('_', ' ')
    if ($hay.Contains($FilterNormalized)) { return $true }
    $tokens = @($FilterNormalized -split '\s+', [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($tokens.Count -lt 2) { return $false }
    foreach ($t in $tokens) {
        if (-not $hay.Contains($t)) { return $false }
    }
    return $true
}

function Get-UiComponentSafetyBadges {
    param([AllowNull()]$Component)

    if (-not $Component) { return @() }
    $badges = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($badge in @($Component.badges)) {
            $text = [string]$badge
            if (-not [string]::IsNullOrWhiteSpace($text) -and -not $badges.Contains($text)) {
                $badges.Add($text) | Out-Null
            }
        }
    } catch { }

    if ($badges.Count -eq 0) {
        $riskLevel = [string]$Component.riskLevel
        switch ($riskLevel) {
            'safe' { $badges.Add('Seguro') | Out-Null }
            'experimental' { $badges.Add('Experimental') | Out-Null }
            'manual' { $badges.Add('Manual') | Out-Null }
        }
        if ([bool]$Component.requiresGpu) { $badges.Add('Requer GPU') | Out-Null }
        if ([bool]$Component.requiresInteractiveLogin) { $badges.Add('Requer login') | Out-Null }
    }
    return @($badges.ToArray())
}

function Format-UiComponentSafetySuffix {
    param([AllowNull()]$Component)

    $badges = @(Get-UiComponentSafetyBadges -Component $Component)
    if ($badges.Count -eq 0) { return '' }
    return ('[{0}]' -f ($badges -join ', '))
}

function Refresh-SelectionTrees {
    $invalidExcludes = @(Repair-UiExcludedComponents)
    $filter = ($ui.FilterTextBox.Text).Trim().ToLowerInvariant()
    $resolvedComponentLookup = Get-UiResolvedComponentNameSet
    $ui.SuppressSelectionEvents = $true
    try {
        $ui.ProfilesTree.Items.Clear()
        $familyNodes = [ordered]@{}
        foreach ($profile in @($ui.Contract.profiles | Where-Object {
            Test-UiContractSelectionFilter -Name ([string]$_.name) -Description ([string]$_.description) -FilterNormalized $filter
        })) {
            $familyName = [string]$profile.family
            if ([string]::IsNullOrWhiteSpace($familyName)) { $familyName = 'Geral' }
            if (-not $familyNodes.Contains($familyName)) {
                $familyItem = New-Object System.Windows.Controls.TreeViewItem
                $familyHeader = New-Object System.Windows.Controls.TextBlock
                $familyHeader.Text = $familyName
                $familyHeader.FontWeight = 'Bold'
                $familyHeader.Foreground = Get-UiBrush '#94A3B8'
                $familyItem.Header = $familyHeader
                $familyItem.IsExpanded = $true
                $familyNodes[$familyName] = $familyItem
                [void]$ui.ProfilesTree.Items.Add($familyItem)
            }
            $item = New-Object System.Windows.Controls.TreeViewItem
            $item.Header   = $profile.name
            $item.Tag      = @{ kind = 'profile'; item = $profile }
            $item.Foreground = Get-UiBrush '#CBD5E1'
            # CheckBox inside item header
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content    = $profile.name
            $cb.IsChecked  = (@($ui.State.selectedProfiles) -contains $profile.name)
            $cb.Foreground = Get-UiBrush '#CBD5E1'
            $cb.Tag        = @{ kind = 'profile'; item = $profile; name = $profile.name }
            $cb.Style      = $window.FindResource('DarkCheck')
            $cb.ToolTip    = "Perfil: $([string]$profile.name)`nDescrição: $([string]$profile.description)`nInclui: $(@($profile.items) -join ', ')"
            $item.Header   = $cb
            $cb.Add_Checked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                if (-not (@($ui.State.selectedProfiles) -contains $name)) {
                    $ui.State.selectedProfiles = @(@($ui.State.selectedProfiles) + $name)
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-SelectionTrees
                    Refresh-SelectionSummary
                }
            })
            $cb.Add_Unchecked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                $ui.State.selectedProfiles = @(Remove-UiStringValue -Values $ui.State.selectedProfiles -Value $name)
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionTrees
                Refresh-SelectionSummary
            })
            $item.Add_Selected({
                if ($this.Tag -and $this.Tag.item) {
                    $ui.DetailsTextBox.Text = Get-SelectionDetailsText -Item $this.Tag.item -Kind $this.Tag.kind
                }
            })
            [void]$familyNodes[$familyName].Items.Add($item)
        }

        $ui.ComponentsTree.Items.Clear()
        foreach ($component in @($ui.Contract.components | Where-Object {
            Test-UiContractSelectionFilter -Name ([string]$_.name) -Description ([string]$_.description) -FilterNormalized $filter
        })) {
            $item = New-Object System.Windows.Controls.TreeViewItem
            $item.Tag = @{ kind = 'component'; item = $component }
            $cb = New-Object System.Windows.Controls.CheckBox
            $componentName = [string]$component.name
            $isExplicitComponent = (@($ui.State.selectedComponents) -contains $componentName)
            $isResolvedComponent = $resolvedComponentLookup.ContainsKey($componentName)
            $isExcludedComponent = (@($ui.State.excludedComponents) -contains $componentName)
            $canExcludeComponent = Test-UiComponentCanExclude -ComponentName $componentName -Component $component
            $badgeSuffix = Format-UiComponentSafetySuffix -Component $component
            $cb.Content   = if ([string]::IsNullOrWhiteSpace($badgeSuffix)) { $componentName } else { "$componentName $badgeSuffix" }
            $cb.IsChecked = (($isExplicitComponent -or $isResolvedComponent) -and -not $isExcludedComponent)
            $componentStatus = if ($component.PSObject.Properties.Name -contains 'status') { [string]$component.status } else { '' }
            if (($ui.ContainsKey('ComponentStatusLive')) -and ($null -ne $ui.ComponentStatusLive) -and ($ui.ComponentStatusLive.Contains($componentName))) {
                $componentStatus = [string]$ui.ComponentStatusLive[$componentName]
            }
            $cb.Foreground = Get-UiStatusBrush -Status $componentStatus
            $cb.Style = $window.FindResource('DarkCheck')
            $cb.Tag = @{ kind = 'component'; item = $component; name = $componentName; explicit = $isExplicitComponent; resolved = $isResolvedComponent; excluded = $isExcludedComponent; canExclude = $canExcludeComponent }
            $safetyTooltip = "Componente: $componentName`nStatus: $(Get-UiStatusLabel -Status $componentStatus)`nDescrição: $([string]$component.description)`nTipo: $([string]$component.kind)`nEstágio: $([string]$component.stage)`nRisco: $([string]$component.riskLevel)`nSelos: $(@(Get-UiComponentSafetyBadges -Component $component) -join ', ')`nFonte oficial: $([string]$component.officialSource)`nManual: $([string]$component.manualReason)`nGPU: $([string]$component.requiresGpu)`nLogin: $([string]$component.requiresInteractiveLogin)`nDepende de: $(@($component.dependsOn) -join ', ')"
            $cb.ToolTip = $safetyTooltip
            if ($isResolvedComponent -and -not $isExplicitComponent) {
                $cb.Opacity = 0.82
                $cb.ToolTip = if ($canExcludeComponent) { "$safetyTooltip`nIncluído pelo perfil selecionado. Desmarcar item vindo de perfil adiciona em Não instalar." } else { "$safetyTooltip`nComponente obrigatório/dependência base. Remova o perfil ou componente que depende dele." }
            }
            $item.Header = $cb
            $cb.Add_Checked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                if (@($ui.State.excludedComponents) -contains $name) {
                    $ui.State.excludedComponents = @(Remove-UiStringValue -Values $ui.State.excludedComponents -Value $name)
                }
                if (-not [bool]$this.Tag.resolved -and -not (@($ui.State.selectedComponents) -contains $name)) {
                    $ui.State.selectedComponents = @(@($ui.State.selectedComponents) + $name)
                }
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionTrees
                Refresh-SelectionSummary
            })
            $cb.Add_Unchecked({
                if ($ui.SuppressSelectionEvents) { return }
                $name = [string]$this.Tag.name
                if ([bool]$this.Tag.resolved -and -not [bool]$this.Tag.canExclude) {
                    Refresh-SelectionTrees
                    Refresh-SelectionSummary
                    $ui.SelectionErrorLabel.Text = "O componente $name e obrigatorio/dependencia base; remova o perfil ou componente que depende dele."
                    return
                }
                if ([bool]$this.Tag.resolved -and -not (@($ui.State.excludedComponents) -contains $name)) {
                    # Desmarcar item vindo de perfil adiciona em Não instalar.
                    $ui.State.excludedComponents = @(@($ui.State.excludedComponents) + $name)
                }
                if ([bool]$this.Tag.explicit) {
                    $ui.State.selectedComponents = @(Remove-UiStringValue -Values $ui.State.selectedComponents -Value $name)
                }
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionTrees
                Refresh-SelectionSummary
            })
            $item.Add_Selected({
                if ($this.Tag -and $this.Tag.item) {
                    $ui.DetailsTextBox.Text = Get-SelectionDetailsText -Item $this.Tag.item -Kind $this.Tag.kind
                }
            })
            [void]$ui.ComponentsTree.Items.Add($item)
        }

        $ui.OptClaudePluginsCheckBox.IsChecked = $resolvedComponentLookup.ContainsKey('claude-plugins')
        $ui.OptOpenWebUICheckBox.IsChecked     = $resolvedComponentLookup.ContainsKey('openwebui')
        $ui.OptClaudeProjectMcpsCheckBox.IsChecked = [bool]$ui.State.enableClaudeCodeProjectMcps
        $ui.OptSkipManualRequirementsCheckBox.IsChecked = [bool]$ui.State.skipManualRequirements
        $ui.OptIgnoreManualRequirementsCheckBox.IsChecked = [bool]$ui.State.ignoreManualRequirements
        $ui.OptRequireNoPendingRebootCheckBox.IsChecked = [bool]$ui.State.requireNoPendingReboot
        $ui.OptOfflineModeCheckBox.IsChecked = [bool]$ui.State.offlineMode
        $ui.OptEnableResumeCheckBox.IsChecked = [bool]$ui.State.enableResume
    } catch {
        $message = "Falha ao atualizar selecao: $($_.Exception.Message)"
        Write-UiLog -Level 'ERROR' -Message $message
        try { $ui.SelectionErrorLabel.Text = $message } catch { }
    } finally {
        $ui.SuppressSelectionEvents = $false
    }
    if ($invalidExcludes.Count -gt 0) {
        $ui.SelectionErrorLabel.Text = "Exclusoes invalidas removidas: $(@($invalidExcludes) -join ', ')"
    }
}

function Refresh-ExcludeList {
    $ui.ExcludeList.Items.Clear()
    try {
        $null = Repair-UiExcludedComponents
        $selection     = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents @() -SelectedHostHealth $ui.State.hostHealth
        $baseResolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents @()
        $catalogLookup = Get-UiComponentCatalogLookup
        foreach ($componentName in @($baseResolution.ResolvedComponents)) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content   = $componentName
            $cb.IsChecked = (@($ui.State.excludedComponents) -contains $componentName)
            $cb.Style     = $window.FindResource('DarkCheck')
            $cb.Foreground = Get-UiBrush '#CBD5E1'
            $component = if ($catalogLookup.ContainsKey([string]$componentName)) { $catalogLookup[[string]$componentName] } else { $null }
            $canExclude = Test-UiComponentCanExclude -ComponentName ([string]$componentName) -Component $component
            $cb.Tag = @{ name = [string]$componentName; canExclude = $canExclude }
            if (-not $canExclude) {
                $cb.IsEnabled = $false
                $cb.ToolTip = 'Componente obrigatorio/dependencia base. Remova o perfil ou componente que depende dele.'
            }
            $cb.Add_Checked({
                $tname = [string]$this.Tag.name
                if (-not [bool]$this.Tag.canExclude) {
                    $ui.SelectionErrorLabel.Text = "O componente $tname é obrigatório/dependência base e não pode ser excluído."
                    $this.IsChecked = $false
                    return
                }
                if (-not (@($ui.State.excludedComponents) -contains $tname)) {
                    $ui.State.excludedComponents = @(@($ui.State.excludedComponents) + $tname)
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-SelectionTrees
                    Refresh-SelectionSummary
                }
            })
            $cb.Add_Unchecked({
                $tname = [string]$this.Tag.name
                $ui.State.excludedComponents = @(Remove-UiStringValue -Values $ui.State.excludedComponents -Value $tname)
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-SelectionTrees
                Refresh-SelectionSummary
            })
            $li = New-Object System.Windows.Controls.ListBoxItem
            $li.Content = $cb
            $li.Background = [System.Windows.Media.Brushes]::Transparent
            [void]$ui.ExcludeList.Items.Add($li)
        }
    } catch { }
}

function Refresh-SelectionSummary {
    $invalidExcludes = @(Repair-UiExcludedComponents)
    Refresh-ExcludeList
    try {
        $ui.Preview = Get-BootstrapPreviewData -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -RequestedSteamDeckVersion $ui.State.steamDeckVersion -RequestedHostHealthMode $ui.State.hostHealth -RequestedAppTuningMode $ui.State.appTuningMode -RequestedAppTuningCategories $ui.State.selectedAppTuningCategories -RequestedAppTuningItems $ui.State.selectedAppTuningItems -ExcludedAppTuningItems $ui.State.excludedAppTuningItems -RequestedWorkspaceRoot $ui.State.workspaceRoot -ExplicitCloneBaseDir $ui.State.cloneBaseDir
        $impact = Get-UiSelectionImpact
        $ui.SelectionSummaryLabel.Text = "Selecionados: $($impact.total) | Explícitos: $($impact.explicit) | Herdados/deps: $($impact.inherited) | Excluídos: $($impact.excluded) | Manual: $($impact.manual) | Admin: $($impact.admin) | Rede: $($impact.network) | Reversão parcial/manual: $($impact.partialOrManualRollback) | Manutenção: $($ui.Preview.ResolvedHostHealthMode) | Ajustes de apps: $($ui.Preview.ResolvedAppTuningMode)"
        $ui.SelectionErrorLabel.Text   = if ($invalidExcludes.Count -gt 0) { "Exclusoes invalidas removidas: $(@($invalidExcludes) -join ', ')" } else { '' }
    } catch {
        $ui.Preview = $null
        $ui.SelectionSummaryLabel.Text = ''
        $ui.SelectionErrorLabel.Text   = $_.Exception.Message
    }
}

function Refresh-HostSetupControls {
    $ui.HostHealthCombo.SelectedItem       = [string]$ui.State.hostHealth
    $ui.SteamDeckVersionCombo.SelectedItem = [string]$ui.State.steamDeckVersion
    $ui.WorkspaceRootTextBox.Text          = [string]$ui.State.workspaceRoot
    $ui.CloneBaseDirTextBox.Text           = [string]$ui.State.cloneBaseDir
    $ui.AdminNeedsTextBox.Text = if ($ui.Preview -and @($ui.Preview.AdminReasons).Count -gt 0) {
        @($ui.Preview.AdminReasons) -join [Environment]::NewLine
    } else { '-' }
}

function Get-UiAppTuningPreview {
    $selection = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents $ui.State.excludedComponents -SelectedHostHealth $ui.State.hostHealth -SelectedAppTuning $ui.State.appTuningMode -SelectedAppTuningCategories $ui.State.selectedAppTuningCategories -SelectedAppTuningItems $ui.State.selectedAppTuningItems -ExcludedAppTuningItems $ui.State.excludedAppTuningItems
    $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents $selection.Excludes
    return Resolve-BootstrapAppTuningSelection -Mode $selection.AppTuning -Categories $selection.AppTuningCategories -Items $selection.AppTuningItems -ExcludedItems $selection.ExcludedAppTuningItems -Selection $selection -Resolution $resolution
}

function Get-UiAppTuningCategoryCounts {
    param([Parameter(Mandatory=$true)]$Plan)

    $catalog = Get-BootstrapAppTuningCatalog
    $selected = @{}
    foreach ($item in @($Plan.items)) { $selected[[string]$item.id] = $true }
    $counts = @{}
    foreach ($category in @($catalog.categories)) {
        $items = @($catalog.items | Where-Object { [string]$_.category -eq [string]$category.id })
        $active = @($items | Where-Object { $selected.ContainsKey([string]$_.id) }).Count
        $counts[[string]$category.id] = [ordered]@{ active = $active; total = $items.Count }
    }
    return $counts
}

function Repair-UiAppTuningState {
    $catalog = Get-BootstrapAppTuningCatalog
    $validCategories = @{}
    foreach ($category in @($catalog.categories)) {
        $validCategories[[string]$category.id] = $true
    }
    $validItems = @{}
    foreach ($item in @($catalog.items)) {
        $validItems[[string]$item.id] = $true
    }

    $normalizedCategories = @(Normalize-BootstrapNames -Names $ui.State.selectedAppTuningCategories)
    $normalizedItems = @(Normalize-BootstrapNames -Names $ui.State.selectedAppTuningItems)
    $normalizedExcludedItems = @(Normalize-BootstrapNames -Names $ui.State.excludedAppTuningItems)
    $modeWarning = ''
    try {
        $normalizedMode = Normalize-BootstrapAppTuningMode -Mode ([string]$ui.State.appTuningMode)
        if ([string]::IsNullOrWhiteSpace($normalizedMode)) {
            $normalizedMode = 'recommended'
        }
    } catch {
        $normalizedMode = 'recommended'
        $modeWarning = "Modo de ajuste inválido no estado atual. Ajustado para 'recommended'."
    }

    $keptCategories = @()
    $removedCategories = @()
    foreach ($categoryId in @($normalizedCategories)) {
        if ($validCategories.ContainsKey($categoryId)) {
            $keptCategories += @($categoryId)
        } else {
            $removedCategories += @($categoryId)
        }
    }

    $keptItems = @()
    $removedItems = @()
    foreach ($itemId in @($normalizedItems)) {
        if ($validItems.ContainsKey($itemId)) {
            $keptItems += @($itemId)
        } else {
            $removedItems += @($itemId)
        }
    }

    $keptExcludedItems = @()
    $removedExcludedItems = @()
    foreach ($itemId in @($normalizedExcludedItems)) {
        if ($validItems.ContainsKey($itemId)) {
            $keptExcludedItems += @($itemId)
        } else {
            $removedExcludedItems += @($itemId)
        }
    }

    $changed = $false
    if ((@($ui.State.selectedAppTuningCategories) -join '|') -ne (@($keptCategories) -join '|')) {
        $ui.State.selectedAppTuningCategories = @($keptCategories)
        $changed = $true
    }
    if ((@($ui.State.selectedAppTuningItems) -join '|') -ne (@($keptItems) -join '|')) {
        $ui.State.selectedAppTuningItems = @($keptItems)
        $changed = $true
    }
    if ((@($ui.State.excludedAppTuningItems) -join '|') -ne (@($keptExcludedItems) -join '|')) {
        $ui.State.excludedAppTuningItems = @($keptExcludedItems)
        $changed = $true
    }
    if ([string]$ui.State.appTuningMode -ne $normalizedMode) {
        $ui.State.appTuningMode = $normalizedMode
        $changed = $true
    }

    $warnings = @()
    if ($removedCategories.Count -gt 0) {
        $warnings += @("Categorias removidas por não existirem mais no catálogo: $(@($removedCategories) -join ', ').")
    }
    if ($removedItems.Count -gt 0) {
        $warnings += @("Itens removidos da seleção por não existirem mais no catálogo: $(@($removedItems) -join ', ').")
    }
    if ($removedExcludedItems.Count -gt 0) {
        $warnings += @("Itens removidos da lista de exclusão por não existirem mais no catálogo: $(@($removedExcludedItems) -join ', ').")
    }
    if (-not [string]::IsNullOrWhiteSpace($modeWarning)) {
        $warnings += @($modeWarning)
    }

    return [ordered]@{
        Changed = $changed
        Warnings = @($warnings)
    }
}

function Format-UiAppTuningState {
    param([AllowNull()][string]$State)

    switch ([string]$State) {
        'installed' { return '[x] instalado' }
        'missing' { return '[ ] ausente' }
        'configured' { return '[x] configurado' }
        'planned' { return '[~] planejado' }
        'not-configured' { return '[ ] não' }
        'check' { return '[?] verificar' }
        'not-installed' { return '-' }
        default { return [string]$State }
    }
}

function Refresh-AppTuningControls {
    try {
        $repair = Repair-UiAppTuningState
        if ([bool]$repair.Changed) {
            Save-UiState -State $ui.State -Path $UiStatePath
        }

        $ui.AppTuningModeCombo.SelectedItem = [string]$ui.State.appTuningMode
        if (-not $ui.AppTuningStatusFilterCombo.SelectedItem) {
            $ui.AppTuningStatusFilterCombo.SelectedItem = 'all'
        }
        if ($ui.AppTuningRiskFilterCombo -and -not $ui.AppTuningRiskFilterCombo.SelectedItem) {
            $ui.AppTuningRiskFilterCombo.SelectedItem = 'all'
        }
        $planWarnings = @()
        try {
            $plan = Get-UiAppTuningPreview
        } catch {
            $plan = [ordered]@{
                mode = [string]$ui.State.appTuningMode
                categories = @()
                requestedCategories = @()
                requestedItems = @()
                excludedItems = @()
                items = @()
                skippedItems = @()
                installedInventory = $null
            }
            $planWarnings += @("Não foi possível resolver a seleção completa dos ajustes de apps: $($_.Exception.Message)")
        }
        $catalog = Get-BootstrapAppTuningCatalog
        $counts = Get-UiAppTuningCategoryCounts -Plan $plan
        $activeMap = @{}
        $itemStateMap = @{}
        foreach ($item in @($plan.items)) {
            $activeMap[[string]$item.id] = $true
            $itemStateMap[[string]$item.id] = $item
        }
        $excludedFromState = @{}
        foreach ($ex in @(Normalize-BootstrapNames -Names @($ui.State.excludedAppTuningItems))) {
            if (-not [string]::IsNullOrWhiteSpace($ex)) { $excludedFromState[$ex] = $true }
        }

        $ui.SuppressAppTuningEvents = $true
        try {
            $ui.AppTuningCategoryList.Items.Clear()
            foreach ($category in @($catalog.categories)) {
                $categoryId = [string]$category.id
                $categoryName = [string]$category.displayName
                $count = $counts[$categoryId]
                $cb = New-Object System.Windows.Controls.CheckBox
                if ([string]::IsNullOrWhiteSpace($categoryName)) {
                    $cb.Content = "{0} ({1}/{2})" -f $categoryId, [int]$count.active, [int]$count.total
                } else {
                    $cb.Content = "{0} ({1}/{2})" -f $categoryName, [int]$count.active, [int]$count.total
                }
                $cb.Tag = $categoryId
                $cb.Foreground = Get-UiBrush '#CBD5E1'
                $cb.Style = $window.FindResource('DarkCheck')
                $cb.IsChecked = (@($ui.State.selectedAppTuningCategories) -contains $categoryId)
                $cb.ToolTip = "Categoria: $categoryName`nId: $categoryId`nDescrição: $([string]$category.description)"
                $cb.Add_Checked({
                    if ($ui.SuppressAppTuningEvents) { return }
                    $id = [string]$this.Tag
                    if (-not (@($ui.State.selectedAppTuningCategories) -contains $id)) {
                        $ui.State.selectedAppTuningCategories = @(@($ui.State.selectedAppTuningCategories) + $id)
                    }
                    $ui.State.appTuningMode = 'custom'
                    Save-UiState -State $ui.State -Path $UiStatePath
                    Refresh-AppTuningControls
                })
                $cb.Add_Unchecked({
                if ($ui.SuppressAppTuningEvents) { return }
                $id = [string]$this.Tag
                $ui.State.selectedAppTuningCategories = @(Remove-UiStringValue -Values $ui.State.selectedAppTuningCategories -Value $id)
                $ui.State.appTuningMode = 'custom'
                Save-UiState -State $ui.State -Path $UiStatePath
                Refresh-AppTuningControls
                })
                $li = New-Object System.Windows.Controls.ListBoxItem
                $li.Content = $cb
                $li.Tag = $categoryId
                $li.Background = [System.Windows.Media.Brushes]::Transparent
                [void]$ui.AppTuningCategoryList.Items.Add($li)
            }
        } finally {
            $ui.SuppressAppTuningEvents = $false
        }

        $rows = @()
        $filter = if ($ui.AppTuningSearchBox) { $ui.AppTuningSearchBox.Text.Trim().ToLowerInvariant() } else { '' }
        $statusFilter = if ($ui.AppTuningStatusFilterCombo -and $ui.AppTuningStatusFilterCombo.SelectedItem) { [string]$ui.AppTuningStatusFilterCombo.SelectedItem } else { 'all' }
        $riskFilter = if ($ui.AppTuningRiskFilterCombo -and $ui.AppTuningRiskFilterCombo.SelectedItem) { [string]$ui.AppTuningRiskFilterCombo.SelectedItem } else { 'all' }
        $statusRows = @(Get-BootstrapAppTuningStatusRows -Plan $plan)
        $filteredCount = 0
        foreach ($item in @($statusRows)) {
            $itemId = [string]$item.id
            $haystack = ("{0} {1} {2} {3} {4} {5}" -f $item.id, $item.category, $item.app, $item.displayName, $item.description, (@($item.installComponents) -join ' ')).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($filter) -and -not $haystack.Contains($filter)) { continue }
            if ($riskFilter -ne 'all' -and [string]$item.risk -ne $riskFilter) { continue }
            if ($statusFilter -eq 'missing' -and [string]$item.installedState -ne 'missing') { continue }
            if ($statusFilter -eq 'installed' -and [string]$item.installedState -ne 'installed') { continue }
            if ($statusFilter -eq 'planned' -and [string]$item.configuredState -ne 'planned') { continue }
            if ($statusFilter -eq 'not-configured' -and [string]$item.configuredState -ne 'not-configured') { continue }
            if ($statusFilter -eq 'update-check' -and [string]$item.updatedState -ne 'check') { continue }
            $filteredCount++
            $rows += @([ordered]@{
                active = ($activeMap.ContainsKey($itemId) -and -not $excludedFromState.ContainsKey($itemId))
                id = $itemId
                category = [string]$item.category
                app = [string]$item.app
                optimization = [string]$item.displayName
                description = [string]$item.description
                profile = (@($item.profiles) -join ', ')
                risk = [string]$item.risk
                badges = [string]$item.badges
                securityImpact = [string]([bool]$item.securityImpact)
                rollbackScope = [string]$item.rollbackScope
                safetyNotes = (@($item.safetyNotes) -join '; ')
                installed = Format-UiAppTuningState -State ([string]$item.installedState)
                configured = Format-UiAppTuningState -State ([string]$item.configuredState)
                updated = Format-UiAppTuningState -State ([string]$item.updatedState)
                installedStateRaw = [string]$item.installedState
                configuredStateRaw = [string]$item.configuredState
                updatedStateRaw = [string]$item.updatedState
                statusCanonical = (Get-UiAppTuningCanonicalStatus -Installed ([string]$item.installedState) -Configured ([string]$item.configuredState) -Updated ([string]$item.updatedState))
                admin = [string]$item.requiresAdmin
                installComponents = (@($item.installComponents) -join ', ')
            })
        }
        Load-WpfGridRows -Grid $ui.AppTuningItemsGrid -Items $rows -Columns @('active','id','installComponents','category','app','optimization','description','profile','risk','badges','securityImpact','rollbackScope','safetyNotes','installed','configured','updated','installedStateRaw','configuredStateRaw','updatedStateRaw','statusCanonical','admin')
        $installedCount = @($statusRows | Where-Object { [string]$_.installedState -eq 'installed' }).Count
        $configuredCount = @($statusRows | Where-Object { [string]$_.configuredState -in @('configured','planned') }).Count
        $securityImpactCount = @($plan.items | Where-Object { [bool]$_.securityImpact }).Count
        $riskyCount = @($plan.items | Where-Object { [string]$_.riskTier -in @('advanced','aggressive') }).Count
        $ui.AppTuningStatusLabel.Text = "Ajustes: $($plan.mode) | apps: $installedCount/$(@($statusRows).Count) instalados | config: $configuredCount | selecionados: $(@($plan.items).Count) | exibidos: $filteredCount/$(@($statusRows).Count) | status: $statusFilter | risco: $riskFilter"
        if ($ui.AppTuningRiskWarningLabel) {
            if ($securityImpactCount -gt 0) {
                $ui.AppTuningRiskWarningLabel.Text = "Impacto de segurança: $securityImpactCount item(ns) selecionado(s). A revisão mostra reversão; execução exige confirmação."
            } elseif ($riskyCount -gt 0) {
                $ui.AppTuningRiskWarningLabel.Text = "Risco avancado: $riskyCount item(ns) selecionado(s), sem impacto de seguranca declarado."
            } else {
                $ui.AppTuningRiskWarningLabel.Text = ''
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($filter)) {
            $ui.AppTuningStatusLabel.Text += " | busca: '$filter'"
        }
        if ($filteredCount -eq 0) {
            $ui.AppTuningStatusLabel.Text += " | nenhum item corresponde aos filtros atuais."
        }
        if (@($repair.Warnings).Count -gt 0) {
            $ui.AppTuningStatusLabel.Text += " | " + (@($repair.Warnings) -join ' ')
        }
        if (@($planWarnings).Count -gt 0) {
            $ui.AppTuningStatusLabel.Text += " | " + (@($planWarnings) -join ' ')
        }
    } catch {
        $ui.AppTuningStatusLabel.Text = "Erro nos ajustes de apps: $($_.Exception.Message)"
    }
}

function Request-AppTuningRefresh {
    if ($ui.AppTuningRefreshTimer) {
        $ui.AppTuningRefreshTimer.Stop()
        $ui.AppTuningRefreshTimer.Start()
    } else {
        Refresh-AppTuningControls
    }
}

function Capture-AppTuningStateFromControls {
    if ($ui.AppTuningModeCombo.SelectedItem) {
        $ui.State.appTuningMode = [string]$ui.AppTuningModeCombo.SelectedItem
    }

    # Sempre sincronizar a grade (recommended/custom/off): o modo isolado e o backend usam
    # selectedAppTuningItems / excludedAppTuningItems; antes o early-return em recommended deixava
    # a selecao vazia apesar das caixas "Ativo" na UI.
    $rows = @(Read-WpfGridRows -Grid $ui.AppTuningItemsGrid -Columns @('active','id','installComponents','category','app','optimization','profile','risk','securityImpact','rollbackScope','safetyNotes','installed','configured','updated','admin'))
    if ($rows.Count -eq 0) {
        Save-UiState -State $ui.State -Path $UiStatePath
        return
    }

    $selectedItems = @()
    $excludedItems = @()
    foreach ($row in @($rows)) {
        $id = [string]$row['id']
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (ConvertTo-UiBoolean -Value $row['active']) {
            $selectedItems += @($id)
        } else {
            $excludedItems += @($id)
        }
    }
    $ui.State.selectedAppTuningItems = @(Normalize-BootstrapNames -Names $selectedItems)
    $ui.State.excludedAppTuningItems = @(Normalize-BootstrapNames -Names $excludedItems)
    Save-UiState -State $ui.State -Path $UiStatePath
}

function Get-SelectedAppTuningRows {
    $rows = @()
    foreach ($selected in @($ui.AppTuningItemsGrid.SelectedItems)) {
        $rowData = $null
        if ($selected -and $selected.PSObject.Properties['Row']) {
            $rowData = $selected.Row
        } elseif ($selected -is [System.Collections.IDictionary]) {
            $rowData = $selected
        }
        if ($rowData) {
            $row = [ordered]@{}
            foreach ($column in @('active','id','installComponents','category','app','optimization','profile','risk','securityImpact','rollbackScope','safetyNotes','installed','configured','updated','admin')) {
                if ($rowData -is [System.Collections.IDictionary]) {
                    $row[$column] = if ($rowData.Contains($column)) { [string]$rowData[$column] } else { '' }
                } else {
                    $row[$column] = [string]$rowData[$column]
                }
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$row['id'])) {
                $rows += @($row)
            }
        }
    }
    if ($rows.Count -gt 0) { return @($rows) }
    return @(Get-CheckedAppTuningRowList)
}

function Get-CheckedAppTuningRowList {
    return @(Read-WpfGridRows -Grid $ui.AppTuningItemsGrid -Columns @('active','id','installComponents','category','app','optimization','profile','risk','securityImpact','rollbackScope','safetyNotes','installed','configured','updated','admin','installedStateRaw','configuredStateRaw','updatedStateRaw') | Where-Object { ConvertTo-UiBoolean -Value $_['active'] })
}

function Get-ActiveAppTuningRows {
    return @(Read-WpfGridRows -Grid $ui.AppTuningItemsGrid -Columns @('active','id','installComponents','category','app','optimization','profile','risk','securityImpact','rollbackScope','safetyNotes','installed','configured','updated','admin','installedStateRaw','configuredStateRaw','updatedStateRaw') | Where-Object { ConvertTo-UiBoolean -Value $_['active'] })
}

function Add-UiSelectedComponents {
    param([string[]]$Components)

    $componentCatalog = Get-BootstrapComponentCatalog
    $added = @()
    foreach ($componentName in @(Normalize-BootstrapNames -Names $Components)) {
        if ([string]::IsNullOrWhiteSpace($componentName)) { continue }
        if (-not (Test-BootstrapMapContainsKey -Map $componentCatalog -Key $componentName)) { continue }
        if (@($ui.State.excludedComponents) -contains $componentName) {
            $ui.State.excludedComponents = @(@($ui.State.excludedComponents) | Where-Object { $_ -ne $componentName })
        }
        if (-not (@($ui.State.selectedComponents) -contains $componentName)) {
            $ui.State.selectedComponents = @(@($ui.State.selectedComponents) + $componentName)
            $added += @($componentName)
        }
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    return @($added)
}

function Get-UiFriendlyActionError {
    param(
        [Parameter(Mandatory = $true)][string]$ActionLabel,
        [Parameter(Mandatory = $true)][System.Exception]$Exception
    )

    return ("Não foi possível concluir {0}. Tente novamente. Se persistir, consulte o log da UI." -f $ActionLabel)
}

function Set-AppTuningActionFeedback {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('info', 'warning', 'error')][string]$Level = 'info'
    )

    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $ui.StatusLabel.Text = $Message
    try {
        $current = [string]$ui.AppTuningStatusLabel.Text
        if ([string]::IsNullOrWhiteSpace($current)) {
            $ui.AppTuningStatusLabel.Text = "Ultima acao: $Message"
        } else {
            $base = $current -replace '\s*\|\s*Ultima acao:.*$', ''
            $ui.AppTuningStatusLabel.Text = "$base | Ultima acao: $Message"
        }
    } catch {
        $ui.AppTuningStatusLabel.Text = "Ultima acao: $Message"
    }
    if ($Level -eq 'warning') {
        Write-UiLog -Level 'WARN' -Message $Message
    } elseif ($Level -eq 'error') {
        Write-UiLog -Level 'ERROR' -Message $Message
    } else {
        Write-UiLog -Message $Message
    }
}

function Prompt-AppTuningNavigateToReview {
    param([Parameter(Mandatory = $true)][string]$ActionMessage)

    $prompt = @(
        $ActionMessage
        ''
        'A acao foi apenas planejada. Nada foi executado ainda.'
        'Deseja ir para Revisão agora para confirmar e executar?'
    ) -join [Environment]::NewLine
    $answer = [System.Windows.MessageBox]::Show(
        $prompt,
        'Bootstrap UI - Proximo passo',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Information
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    try {
        Refresh-ReviewPage
        $pageIds = @(Get-UiPageIds)
        $reviewIndex = [Array]::IndexOf($pageIds, 'review')
        if ($reviewIndex -ge 0) {
            Navigate-ToPage -Index $reviewIndex
        } else {
            Navigate-ToPage -Index 8
        }
    } catch {
        Write-UiLog -Level 'WARN' -Message ("Falha ao navegar para Revisão após AppTuning: {0}" -f $_.Exception.Message)
    }
}

function Clear-ExecutionScopeOverride {
    $ui.ExecutionScopeOverride = $null
    $ui.CurrentExecutionScopeLabel = ''
}

function Normalize-UiComponentOnlyExecutionScope {
    param([Parameter(Mandatory = $true)]$Snapshot)

    $hasProfiles = (@($Snapshot.selectedProfiles).Count -gt 0)
    $hasComponents = (@($Snapshot.selectedComponents).Count -gt 0)
    if ($hasComponents -and -not $hasProfiles) {
        $Snapshot.scopeLabel = 'Instalação isolada (somente componentes selecionados)'
        $Snapshot.hostHealth = 'off'
        if (@($Snapshot.selectedAppTuningCategories).Count -eq 0 -and @($Snapshot.selectedAppTuningItems).Count -eq 0) {
            $Snapshot.appTuningMode = 'off'
            $Snapshot.excludedAppTuningItems = @()
        }
    }
    return $Snapshot
}

function New-ExecutionScopeSnapshot {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Scope,
        [string]$Source = 'unknown'
    )

    $rawScopeMode = [string]$Scope.scopeMode
    if ([string]::IsNullOrWhiteSpace($rawScopeMode)) { $rawScopeMode = 'profile' }
    $scopeMode = $rawScopeMode.Trim().ToLowerInvariant()
    if ($scopeMode -ne 'isolated') { $scopeMode = 'profile' }

    $snapshot = [ordered]@{
        scopeMode = $scopeMode
        scopeLabel = [string]$Scope.scopeLabel
        selectedProfiles = @(Normalize-BootstrapNames -Names @($Scope.selectedProfiles))
        selectedComponents = @(Normalize-BootstrapNames -Names @($Scope.selectedComponents))
        excludedComponents = @(Normalize-BootstrapNames -Names @($Scope.excludedComponents))
        hostHealth = Normalize-BootstrapHostHealthMode -Mode ([string]$Scope.hostHealth)
        appTuningMode = Normalize-BootstrapAppTuningMode -Mode ([string]$Scope.appTuningMode)
        selectedAppTuningCategories = @(Normalize-BootstrapNames -Names @($Scope.selectedAppTuningCategories))
        selectedAppTuningItems = @(Normalize-BootstrapNames -Names @($Scope.selectedAppTuningItems))
        excludedAppTuningItems = @(Normalize-BootstrapNames -Names @($Scope.excludedAppTuningItems))
        source = [string]$Source
    }

    if ([string]::IsNullOrWhiteSpace([string]$snapshot.scopeLabel)) {
        $snapshot.scopeLabel = if ($scopeMode -eq 'isolated') { 'Isolado (somente AppTuning selecionado)' } else { 'Perfil atual' }
    }

    if ($scopeMode -eq 'isolated') {
        # Whitelist forte: escopo isolado ignora historico global e campos fora do contrato.
        $snapshot.selectedProfiles = @()
        $snapshot.excludedComponents = @()
        $snapshot.hostHealth = 'off'
        $snapshot.appTuningMode = 'custom'
        $snapshot.selectedAppTuningCategories = @()
        $snapshot.excludedAppTuningItems = @()
    }

    $snapshot = Normalize-UiComponentOnlyExecutionScope -Snapshot $snapshot
    return $snapshot
}

function Get-CurrentExecutionScopeSnapshot {
    $baseScope = [ordered]@{
        scopeMode = 'profile'
        scopeLabel = 'Perfil atual'
        selectedProfiles = @($ui.State.selectedProfiles)
        selectedComponents = @($ui.State.selectedComponents)
        excludedComponents = @($ui.State.excludedComponents)
        hostHealth = [string]$ui.State.hostHealth
        appTuningMode = [string]$ui.State.appTuningMode
        selectedAppTuningCategories = @($ui.State.selectedAppTuningCategories)
        selectedAppTuningItems = @($ui.State.selectedAppTuningItems)
        excludedAppTuningItems = @($ui.State.excludedAppTuningItems)
    }
    if ($ui.ExecutionScopeOverride) {
        return (New-ExecutionScopeSnapshot -Scope ([hashtable]$ui.ExecutionScopeOverride) -Source 'override')
    }
    return (New-ExecutionScopeSnapshot -Scope $baseScope -Source 'state')
}

function Assert-ExecutionScopeSnapshot {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Scope
    )

    if ([string]$Scope.scopeMode -eq 'isolated') {
        if (@($Scope.excludedAppTuningItems).Count -gt 0) {
            throw 'Escopo isolado invalido: ExcludeAppTuningItem deve estar vazio para evitar reaproveitar historico.'
        }
        if (@($Scope.selectedProfiles).Count -gt 0) {
            throw 'Escopo isolado inválido: perfil não pode ser enviado no modo isolado.'
        }
        if (@($Scope.selectedAppTuningCategories).Count -gt 0) {
            throw 'Escopo isolado inválido: categorias AppTuning não são permitidas no modo isolado.'
        }
        $isolatedComponentCount = @($Scope.selectedComponents).Count
        $isolatedItemCount = @($Scope.selectedAppTuningItems).Count
        if ($isolatedComponentCount -eq 0 -and $isolatedItemCount -eq 0) {
            throw 'Escopo isolado invalido: selecione ao menos um item AppTuning antes de executar.'
        }
    }
}

function Get-IsolatedAppTuningExecutionOverride {
    $plannedComponentSet = @{}
    $selectedItemSet = @{}
    $statusRows = @()
    foreach ($itemId in @(Normalize-BootstrapNames -Names @($ui.State.selectedAppTuningItems))) {
        if ([string]::IsNullOrWhiteSpace([string]$itemId)) { continue }
        $selectedItemSet[[string]$itemId] = $true
    }

    if ($selectedItemSet.Count -gt 0) {
        try {
            $plan = Get-UiAppTuningPreview
            $statusRows = @(Get-BootstrapAppTuningStatusRows -Plan $plan)
        } catch {
            $statusRows = @()
        }

        foreach ($row in @($statusRows)) {
            $itemId = [string]$row.id
            if ([string]::IsNullOrWhiteSpace($itemId) -or -not $selectedItemSet.ContainsKey($itemId)) { continue }
            foreach ($component in @([string[]]$row.installComponents)) {
                $name = [string]$component
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $plannedComponentSet[$name] = $true
            }
        }
    }

    return (New-ExecutionScopeSnapshot -Source 'isolated-builder' -Scope ([ordered]@{
        scopeMode = 'isolated'
        scopeLabel = 'Isolado (somente AppTuning selecionado)'
        selectedProfiles = @()
        selectedComponents = @($plannedComponentSet.Keys | Sort-Object)
        excludedComponents = @()
        hostHealth = 'off'
        appTuningMode = 'custom'
        selectedAppTuningCategories = @()
        selectedAppTuningItems = @($selectedItemSet.Keys | Sort-Object)
        excludedAppTuningItems = @()
    }))
}

function Get-IsolatedComponentExecutionOverride {
    return (New-ExecutionScopeSnapshot -Source 'isolated-component-builder' -Scope ([ordered]@{
        scopeMode = 'isolated'
        scopeLabel = 'Somente componentes selecionados'
        selectedProfiles = @()
        selectedComponents = @($ui.State.selectedComponents)
        excludedComponents = @()
        hostHealth = 'off'
        appTuningMode = 'off'
        selectedAppTuningCategories = @()
        selectedAppTuningItems = @()
        excludedAppTuningItems = @()
    }))
}

function Confirm-UiExecutionScope {
    param(
        [ValidateSet('none', 'audit', 'rollback', 'doctor', 'support-bundle', 'repair-plan', 'partition-labels', 'partition-labels-apply')]
        [string]$MaintenanceIntent = 'none'
    )

    if ([string]$MaintenanceIntent -ne 'none') { return $true }
    if ($ui.ExecutionScopeOverride) { return $true }

    $profileCount = @($ui.State.selectedProfiles).Count
    $componentCount = @($ui.State.selectedComponents).Count
    if ($profileCount -eq 0 -or $componentCount -eq 0) { return $true }

    $profiles = @($ui.State.selectedProfiles) -join ', '
    $components = @($ui.State.selectedComponents) -join ', '
    $message = @(
        'Escopo ambíguo: ha perfil e componente isolado selecionados.'
        ''
        "Perfis: $profiles"
        "Componentes: $components"
        ''
        'Sim = Somente componentes selecionados (sem perfil, HostHealth off, AppTuning off).'
        'Não = Perfil atual + componentes.'
        'Cancelar = voltar para revisar.'
    ) -join [Environment]::NewLine

    $answer = [System.Windows.MessageBox]::Show(
        $message,
        'Bootstrap UI - Escopo de execução',
        [System.Windows.MessageBoxButton]::YesNoCancel,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($answer -eq [System.Windows.MessageBoxResult]::Cancel) {
        $ui.StatusLabel.Text = 'Execução cancelada: escopo ambíguo não confirmado.'
        return $false
    }
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
        $ui.ExecutionScopeOverride = Get-IsolatedComponentExecutionOverride
        $ui.CurrentExecutionScopeLabel = 'Somente componentes selecionados'
        return $true
    }

    $ui.ExecutionScopeOverride = Get-ProfileExecutionOverride
    $ui.CurrentExecutionScopeLabel = 'Perfil atual + componentes'
    return $true
}

function Get-ProfileExecutionOverride {
    return (New-ExecutionScopeSnapshot -Source 'profile-builder' -Scope ([ordered]@{
        scopeMode = 'profile'
        scopeLabel = 'Perfil atual'
        selectedProfiles = @($ui.State.selectedProfiles)
        selectedComponents = @($ui.State.selectedComponents)
        excludedComponents = @($ui.State.excludedComponents)
        hostHealth = [string]$ui.State.hostHealth
        appTuningMode = [string]$ui.State.appTuningMode
        selectedAppTuningCategories = @($ui.State.selectedAppTuningCategories)
        selectedAppTuningItems = @($ui.State.selectedAppTuningItems)
        excludedAppTuningItems = @($ui.State.excludedAppTuningItems)
    }))
}

function Get-AppTuningInstallComponentsByAppName {
    param([string]$AppName)

    if ([string]::IsNullOrWhiteSpace($AppName)) { return @() }
    $components = New-Object System.Collections.Generic.List[string]
    try {
        $statusRows = @(Get-BootstrapAppTuningStatusRows -Plan (Get-UiAppTuningPreview))
        foreach ($statusRow in @($statusRows | Where-Object { ([string]$_.app).ToLowerInvariant() -eq ([string]$AppName).ToLowerInvariant() })) {
            foreach ($component in @([string[]]$statusRow.installComponents)) {
                if ([string]::IsNullOrWhiteSpace([string]$component)) { continue }
                if (-not $components.Contains([string]$component)) { $components.Add([string]$component) }
            }
        }
    } catch {
    }
    return @($components.ToArray())
}

function Confirm-AppTuningSecurityImpact {
    param([AllowNull()][object[]]$Rows = $null)

    $sourceRows = if ($null -ne $Rows) { @($Rows) } else { @(Get-SelectedAppTuningRows) }
    $risky = @($sourceRows | Where-Object {
        (ConvertTo-UiBoolean -Value $_['securityImpact']) -or ([string]$_['risk'] -eq 'aggressive')
    })
    if ($risky.Count -eq 0) { return $true }

    $names = @($risky | ForEach-Object { [string]$_['id'] } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $message = @(
        'Itens com impacto de segurança ou risco agressivo selecionados:'
        ''
        (@($names) -join [Environment]::NewLine)
        ''
        'Confirme somente se deseja aplicar ajustes sensíveis e com reversão registrada.'
    ) -join [Environment]::NewLine
    $answer = [System.Windows.MessageBox]::Show(
        $message,
        'Bootstrap UI - impacto de segurança',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}

function Queue-AppTuningInstallOrUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$ActionName,
        [AllowNull()][object[]]$Rows = $null
    )

    $components = @()
    $sourceRows = if ($null -ne $Rows) { @($Rows) } else { @(Get-SelectedAppTuningRows) }
    foreach ($row in @($sourceRows)) {
        foreach ($component in (([string]$row['installComponents']) -split ',')) {
            if ([string]::IsNullOrWhiteSpace($component)) { continue }
            $components += @($component.Trim())
        }
    }
    if ($components.Count -eq 0) {
        $message = "$ActionName não planejado: item sem componente instalável. Use Configurar/Otimizar se o app já estiver instalado."
        Set-AppTuningActionFeedback -Message $message -Level 'warning'
        return [ordered]@{ status = 'warning'; message = $message; added = @() }
    }

    $added = @(Add-UiSelectedComponents -Components $components)
    Refresh-SelectionSummary
    Refresh-AppTuningControls
    $message = if ($added.Count -gt 0) {
        "$ActionName planejado (não executado): $(@($added) -join ', ')"
    } else {
        "${ActionName}: nenhum componente novo para marcar (já estava planejado, não executado)."
    }
    Set-AppTuningActionFeedback -Message $message -Level 'info'
    return [ordered]@{ status = 'success'; message = $message; added = @($added) }
}

function Queue-AppTuningConfigure {
    param(
        [AllowNull()][object[]]$Rows = $null,
        [switch]$AutoIncludeMissingInstall
    )

    $ids = @()
    $missingInstallRows = New-Object System.Collections.Generic.List[string]
    $autoInstallComponents = New-Object System.Collections.Generic.List[string]
    $sourceRows = if ($Rows) { @($Rows) } else { @(Get-SelectedAppTuningRows) }
    if (-not (Confirm-AppTuningSecurityImpact -Rows $sourceRows)) {
        $message = 'Configuração/otimização cancelada: impacto de segurança não confirmado.'
        Set-AppTuningActionFeedback -Message $message -Level 'warning'
        return [ordered]@{ status = 'warning'; message = $message; ids = @() }
    }
    foreach ($row in @($sourceRows)) {
        $id = [string]$row['id']
        if (-not [string]::IsNullOrWhiteSpace($id)) { $ids += @($id) }
        $installedRaw = [string]$row['installedStateRaw']
        $rowInstallComponents = @(([string]$row['installComponents'] -split ',') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
        if ($installedRaw -eq 'missing' -and $rowInstallComponents.Count -eq 0) {
            $display = [string]$row['optimization']
            if ([string]::IsNullOrWhiteSpace($display)) { $display = [string]$row['app'] }
            if (-not [string]::IsNullOrWhiteSpace($display)) { $missingInstallRows.Add($display) }
            foreach ($component in @(Get-AppTuningInstallComponentsByAppName -AppName ([string]$row['app']))) {
                if (-not $autoInstallComponents.Contains([string]$component)) { $autoInstallComponents.Add([string]$component) }
            }
        }
    }
    if ($ids.Count -eq 0) {
        $message = 'Config/Otimização não planejada: selecione ao menos um item.'
        Set-AppTuningActionFeedback -Message $message -Level 'warning'
        return [ordered]@{ status = 'warning'; message = $message; ids = @() }
    }

    $autoAdded = @()
    if ($AutoIncludeMissingInstall -and $autoInstallComponents.Count -gt 0) {
        $autoAdded = @(Add-UiSelectedComponents -Components @($autoInstallComponents.ToArray()))
        Refresh-SelectionSummary
    }

    $ui.State.appTuningMode = 'custom'
    foreach ($id in @(Normalize-BootstrapNames -Names $ids)) {
        if (-not (@($ui.State.selectedAppTuningItems) -contains $id)) {
            $ui.State.selectedAppTuningItems = @(@($ui.State.selectedAppTuningItems) + $id)
        }
        if (@($ui.State.excludedAppTuningItems) -contains $id) {
            $ui.State.excludedAppTuningItems = @(Remove-UiStringValue -Values $ui.State.excludedAppTuningItems -Value $id)
        }
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-AppTuningControls
    $message = "Config/Otimização planejada (não executada): $(@($ids) -join ', ')"
    $status = 'success'
    if ($missingInstallRows.Count -gt 0) {
        $message += " | App ausente detectado: $(@($missingInstallRows.ToArray()) -join ', ')"
        if ($autoAdded.Count -gt 0) {
            $message += " | Instalação adicionada automaticamente: $(@($autoAdded) -join ', ')"
        } else {
            $message += ' | Para aplicar de fato, planeje tambem a instalacao do app.'
        }
        $status = 'warning'
    }
    Set-AppTuningActionFeedback -Message $message -Level $(if ($status -eq 'warning') { 'warning' } else { 'info' })
    return [ordered]@{ status = $status; message = $message; ids = @($ids); autoAdded = @($autoAdded) }
}

function Get-CurrentAppTuningRow {
    $selected = $ui.AppTuningItemsGrid.SelectedItem
    if ($null -eq $selected) { return $null }

    $rowData = $null
    if ($selected -and $selected.PSObject.Properties['Row']) {
        $rowData = $selected.Row
    } elseif ($selected -is [System.Collections.IDictionary]) {
        $rowData = $selected
    }
    if ($null -eq $rowData) { return $null }

    $row = [ordered]@{}
    foreach ($column in @('active','id','installComponents','category','app','optimization','profile','risk','securityImpact','rollbackScope','safetyNotes','installed','configured','updated','admin','installedStateRaw','configuredStateRaw','updatedStateRaw')) {
        if ($rowData -is [System.Collections.IDictionary]) {
            $row[$column] = if ($rowData.Contains($column)) { [string]$rowData[$column] } else { '' }
        } else {
            $row[$column] = [string]$rowData[$column]
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$row['id'])) { return $null }
    return $row
}

function Invoke-AppTuningSingleRowAction {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][ValidateSet('install', 'configure', 'update')][string]$Action
    )

    $rowId = [string]$Row['id']
    $rowName = [string]$Row['optimization']
    if ([string]::IsNullOrWhiteSpace($rowName)) { $rowName = [string]$Row['app'] }
    Set-AppTuningActionFeedback -Message "Processando $Action para '$rowName'..." -Level 'info'
    try {
        $result = $null
        switch ($Action) {
            'install' { $result = Queue-AppTuningInstallOrUpdate -ActionName 'Instalação' -Rows @($Row) }
            'configure' {
                $autoIncludeInstall = $false
                if ([string]$Row['installedStateRaw'] -eq 'missing') {
                    $answer = [System.Windows.MessageBox]::Show(
                        "O app base de '$rowName' ainda aparece como ausente. Deseja planejar instalacao automatica junto com a configuracao?",
                        'Bootstrap UI - AppTuning',
                        [System.Windows.MessageBoxButton]::YesNo,
                        [System.Windows.MessageBoxImage]::Question
                    )
                    $autoIncludeInstall = ($answer -eq [System.Windows.MessageBoxResult]::Yes)
                }
                $result = Queue-AppTuningConfigure -Rows @($Row) -AutoIncludeMissingInstall:$autoIncludeInstall
            }
            'update' { $result = Queue-AppTuningInstallOrUpdate -ActionName 'Atualização' -Rows @($Row) }
        }
        if ($result -and [string]$result.status -eq 'warning') {
            [void][System.Windows.MessageBox]::Show([string]$result.message, 'Bootstrap UI - Aviso', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
        Refresh-AppTuningControls
        if ($result -and -not [string]::IsNullOrWhiteSpace([string]$result.message)) {
            Set-AppTuningActionFeedback -Message ([string]$result.message) -Level $(if ([string]$result.status -eq 'warning') { 'warning' } else { 'info' })
            Prompt-AppTuningNavigateToReview -ActionMessage ([string]$result.message)
        } else {
            Set-AppTuningActionFeedback -Message "Ação unitária concluída para '$rowId' ($Action)." -Level 'info'
            Prompt-AppTuningNavigateToReview -ActionMessage "Ação '$Action' planejada para '$rowName'."
        }
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("AppTuning ação unitária falhou | action={0} | id={1} | message={2}`n{3}" -f $Action, $rowId, $_.Exception.Message, $_.ScriptStackTrace)
        $friendly = (Get-UiFriendlyActionError -ActionLabel "a ação '$Action' no item '$rowName'" -Exception $_.Exception)
        Set-AppTuningActionFeedback -Message $friendly -Level 'error'
        [void][System.Windows.MessageBox]::Show($friendly, 'Bootstrap UI - Erro', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
}

function Get-SelectedApiProviderId {
    if ($ui.ApiProviderCombo.SelectedItem) { return [string]$ui.ApiProviderCombo.SelectedItem }
    return ''
}

function Get-SelectedApiCredentialId {
    if ($ui.ApiCredentialCombo.SelectedItem) {
        $value = [string]$ui.ApiCredentialCombo.SelectedItem
        if ($value -eq '<new>') { return '' }
        return $value
    }
    return ''
}

function Get-ApiProviderInventory {
    param([string]$ProviderId)
    if ([string]::IsNullOrWhiteSpace($ProviderId) -or -not $ui.Contains('ApiInventory')) { return $null }
    return ($ui.ApiInventory.providers | Where-Object { $_.id -eq $ProviderId } | Select-Object -First 1)
}

function Get-ApiDiagnosticsSummaryText {
    param([AllowNull()]$Summary)

    if ($null -eq $Summary) { return '' }
    $parts = @()
    $summaryMap = ConvertTo-BootstrapHashtable -InputObject $Summary
    if ($summaryMap.Contains('openAiCompatible') -and ($summaryMap['openAiCompatible'] -is [System.Collections.IDictionary])) {
        $compat = ConvertTo-BootstrapHashtable -InputObject $summaryMap['openAiCompatible']
        $compatStatus = [string]$compat['status']
        if ($compatStatus -eq 'selected') {
            $parts += @("OpenAI-compatible: $([string]$compat['provider']) ($([string]$compat['baseUrl']))")
        } else {
            $parts += @("OpenAI-compatible: sem provider utilizável (status=$compatStatus)")
        }
    }
    if ($summaryMap.Contains('claudeDesktopAccess') -and ($summaryMap['claudeDesktopAccess'] -is [System.Collections.IDictionary])) {
        $claude = ConvertTo-BootstrapHashtable -InputObject $summaryMap['claudeDesktopAccess']
        $claudeStatus = [string]$claude['status']
        if ($claudeStatus -eq 'blocked') {
            $parts += @("Claude Desktop: $([string]$claude['message']) Ação: $([string]$claude['action'])")
        } elseif ($claudeStatus -eq 'warning') {
            $parts += @("Claude Desktop: $([string]$claude['message'])")
        }
    }
    if ($summaryMap.Contains('appCoverage') -and ($summaryMap['appCoverage'] -is [System.Collections.IDictionary])) {
        $coverage = ConvertTo-BootstrapHashtable -InputObject $summaryMap['appCoverage']
        $parts += @(
            "Cobertura apps: BYOK+MCP=$([string]$coverage['byokAndMcp'])"
            "BYOK=$([string]$coverage['byokOnly'])"
            "MCP=$([string]$coverage['mcpOnly'])"
            "Pulados=$([string]$coverage['skipped'])"
        ) -join ', '
        if ((Test-BootstrapMapContainsKey -Map $coverage -Key 'apps') -and ($coverage['apps'] -is [System.Collections.IEnumerable])) {
            $pending = @()
            foreach ($entryRaw in @($coverage['apps'])) {
                $entry = ConvertTo-BootstrapHashtable -InputObject $entryRaw
                if ([string]$entry['status'] -eq 'mcp-only' -or [string]$entry['status'] -eq 'skipped') {
                    $pending += @("$([string]$entry['displayName'])=$([string]$entry['status'])")
                }
            }
            if ($pending.Count -gt 0) {
                $parts += @("Pendências: $([string]::Join('; ', $pending))")
            }
        }
    }
    return (@($parts) -join ' | ')
}

function Set-ApiCenterStatusMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Channel,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()]$Diagnostics = $null,
        [switch]$IsError
    )

    $prefix = if ($IsError) { 'API Center erro' } else { "API Center [$Channel]" }
    $text = "${prefix}: $Message"
    $diagnosticSummary = Get-ApiDiagnosticsSummaryText -Summary $Diagnostics
    if (-not [string]::IsNullOrWhiteSpace($diagnosticSummary)) {
        $text += " | Diagnostico API: $diagnosticSummary"
    }
    $ui.ApiStatusLabel.Text = $text
}

function Refresh-ApiCredentialEditor {
    $providerId = Get-SelectedApiProviderId
    $provider = Get-ApiProviderInventory -ProviderId $providerId
    $credentialId = Get-SelectedApiCredentialId

    $ui.ApiDisplayNameTextBox.Text = ''
    $ui.ApiSecretBox.Password = ''
    $ui.ApiBaseUrlTextBox.Text = ''
    $ui.ApiOrganizationTextBox.Text = ''
    $ui.ApiProjectRefTextBox.Text = ''
    $ui.ApiStatusLinksLabel.Visibility = 'Collapsed'
    $ui.ApiSignupLink.IsEnabled = $false
    $ui.ApiDocsLink.IsEnabled = $false
    $ui.ApiPricingLink.IsEnabled = $false
    $ui.ApiSignupLink.NavigateUri = $null
    $ui.ApiDocsLink.NavigateUri = $null
    $ui.ApiPricingLink.NavigateUri = $null

    if (-not $provider) { return }
    $ui.ApiStatusLabel.Text = "Provider: $($provider.displayName)"
    $hasLink = $false
    $signupUrl = [string]$provider.signupUrl
    if (-not [string]::IsNullOrWhiteSpace($signupUrl)) {
        try { $ui.ApiSignupLink.NavigateUri = [Uri]$signupUrl; $ui.ApiSignupLink.IsEnabled = $true; $hasLink = $true } catch { }
    }
    $docsUrl = [string]$provider.docsUrl
    if (-not [string]::IsNullOrWhiteSpace($docsUrl)) {
        try { $ui.ApiDocsLink.NavigateUri = [Uri]$docsUrl; $ui.ApiDocsLink.IsEnabled = $true; $hasLink = $true } catch { }
    }
    $pricingUrl = [string]$provider.pricingUrl
    if (-not [string]::IsNullOrWhiteSpace($pricingUrl)) {
        try { $ui.ApiPricingLink.NavigateUri = [Uri]$pricingUrl; $ui.ApiPricingLink.IsEnabled = $true; $hasLink = $true } catch { }
    }
    if ($hasLink) { $ui.ApiStatusLinksLabel.Visibility = 'Visible' }

    if ([string]::IsNullOrWhiteSpace($credentialId)) { return }
    $credential = $provider.credentials | Where-Object { $_.id -eq $credentialId } | Select-Object -First 1
    if ($credential) {
        $credentialData = ConvertTo-BootstrapHashtable -InputObject $credential
        $ui.ApiDisplayNameTextBox.Text = [string]$credentialData['displayName']
        $ui.ApiBaseUrlTextBox.Text = [string]$credentialData['baseUrl']
        $ui.ApiOrganizationTextBox.Text = [string]$credentialData['organizationId']
        $ui.ApiProjectRefTextBox.Text = [string]$credentialData['projectRef']
    }
}

function Refresh-ApiProviderCombos {
    $selectedProvider = Get-SelectedApiProviderId
    $selectedCredential = Get-SelectedApiCredentialId

    $ui.SuppressApiEvents = $true
    try {
        $ui.ApiProviderCombo.Items.Clear()
        foreach ($provider in @($ui.ApiInventory.providers | Sort-Object displayName)) {
            [void]$ui.ApiProviderCombo.Items.Add([string]$provider.id)
        }
        if (-not [string]::IsNullOrWhiteSpace($selectedProvider) -and @($ui.ApiProviderCombo.Items) -contains $selectedProvider) {
            $ui.ApiProviderCombo.SelectedItem = $selectedProvider
        } elseif ($ui.ApiProviderCombo.Items.Count -gt 0) {
            $ui.ApiProviderCombo.SelectedIndex = 0
        }

        $providerId = Get-SelectedApiProviderId
        $provider = Get-ApiProviderInventory -ProviderId $providerId
        $ui.ApiCredentialCombo.Items.Clear()
        [void]$ui.ApiCredentialCombo.Items.Add('<new>')
        if ($provider) {
            foreach ($credential in @($provider.credentials)) {
                [void]$ui.ApiCredentialCombo.Items.Add([string]$credential.id)
            }
            if (-not [string]::IsNullOrWhiteSpace($selectedCredential) -and @($ui.ApiCredentialCombo.Items) -contains $selectedCredential) {
                $ui.ApiCredentialCombo.SelectedItem = $selectedCredential
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$provider.activeCredentialId) -and @($ui.ApiCredentialCombo.Items) -contains [string]$provider.activeCredentialId) {
                $ui.ApiCredentialCombo.SelectedItem = [string]$provider.activeCredentialId
            } else {
                $ui.ApiCredentialCombo.SelectedIndex = 0
            }
        } else {
            $ui.ApiCredentialCombo.SelectedIndex = 0
        }
    } finally {
        $ui.SuppressApiEvents = $false
    }
    Refresh-ApiCredentialEditor
}

function Refresh-AiToolsControls {
    try {
        $installRoot = Get-BootstrapAiInstallRoot
        $rows = @(Get-BootstrapAiToolStatusRows -InstallRoot $installRoot -ProjectRoot $PSScriptRoot)
        $selectedLookup = @{}
        foreach ($toolName in @(Normalize-BootstrapNames -Names @($ui.State.selectedAiTools))) {
            if (-not [string]::IsNullOrWhiteSpace($toolName)) { $selectedLookup[$toolName] = $true }
        }
        $viewRows = @()
        foreach ($row in @($rows)) {
            $toolName = Normalize-BootstrapAiToolName -ToolName ([string]$row['tool'])
            $viewRows += @([ordered]@{
                active = $selectedLookup.ContainsKey($toolName)
                tool = [string]$row['tool']
                name = [string]$row['name']
                status = [string]$row['status']
                statusCanonical = (ConvertTo-UiCanonicalStatus -Raw ([string]$row['status']))
                version = [string]$row['version']
                support = [string]$row['support']
                commandPath = [string]$row['commandPath']
                message = [string]$row['message']
                docs = [string]$row['docs']
            })
        }
        Load-WpfGridRows -Grid $ui.AiToolsGrid -Items $viewRows -Columns @('active','tool','name','status','statusCanonical','version','support','commandPath','message','docs')
        $installedCount = @($rows | Where-Object { [string]$_['status'] -in @('installed','configured') }).Count
        $manualCount = @($rows | Where-Object { [string]$_['status'] -eq 'manual' }).Count
        $markedCount = @($selectedLookup.Keys).Count
        $ui.AiToolsStatusLabel.Text = "AI Coding Tools: $installedCount instaladas/configuradas | $manualCount requerem ação manual | marcadas: $markedCount | root: $installRoot"
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao atualizar AI Coding Tools: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.AiToolsStatusLabel.Text = "AI Coding Tools erro: $($_.Exception.Message)"
    }
}

function Get-AiToolNameFromGridItem {
    param([AllowNull()]$Item)

    if ($null -eq $Item) { return '' }
    try {
        if ($Item -and $Item.PSObject.Properties['Row']) { return [string]$Item.Row['tool'] }
    } catch { [void]$_.Exception }
    try {
        if ($Item -is [System.Collections.IDictionary] -and $Item.Contains('tool')) { return [string]$Item['tool'] }
    } catch { [void]$_.Exception }
    return ''
}

function Read-AiToolSelectionFromControl {
    $selected = @()
    $rows = @(Read-WpfGridRows -Grid $ui.AiToolsGrid -Columns @('active','tool','name','status','version','support','commandPath','message','docs'))
    foreach ($row in @($rows)) {
        if (-not (ConvertTo-UiBoolean -Value $row['active'])) { continue }
        $toolName = Normalize-BootstrapAiToolName -ToolName ([string]$row['tool'])
        if (-not [string]::IsNullOrWhiteSpace($toolName)) { $selected += @($toolName) }
    }
    $ui.State.selectedAiTools = @(Normalize-BootstrapNames -Names $selected)
    Save-UiState -State $ui.State -Path $UiStatePath
    return @($ui.State.selectedAiTools)
}

function Get-SelectedAiToolNameList {
    $toolNames = @(Read-AiToolSelectionFromControl)
    if ($toolNames.Count -gt 0) { return @($toolNames) }

    $fallback = @()
    foreach ($item in @($ui.AiToolsGrid.SelectedItems)) {
        $toolName = Normalize-BootstrapAiToolName -ToolName (Get-AiToolNameFromGridItem -Item $item)
        if (-not [string]::IsNullOrWhiteSpace($toolName) -and (@($fallback) -notcontains $toolName)) {
            $fallback += @($toolName)
        }
    }
    return @($fallback)
}

function Invoke-UiAiToolAction {
    param([Parameter(Mandatory = $true)][string]$Action)

    $toolNames = @(Get-SelectedAiToolNameList)
    if ($toolNames.Count -eq 0) {
        $ui.AiToolsStatusLabel.Text = 'Nenhuma ferramenta marcada. Marque na coluna Ativo (ou selecione uma linha) e tente de novo.'
        return
    }
    # Confirma acoes mutadoras listando exatamente as ferramentas afetadas, para evitar acao
    # acidental quando ha varias marcadas (a marcacao persiste entre sessoes).
    $actionVerb = switch ($Action) {
        'install'   { 'Instalar' }
        'configure' { 'Configurar/otimizar' }
        'uninstall' { 'Desinstalar (remove artefatos gerenciados)' }
        default     { '' }
    }
    if (-not [string]::IsNullOrWhiteSpace($actionVerb)) {
        $list = (@($toolNames) -join ', ')
        if (-not (Confirm-UiCriticalAction -Title ("Confirmar: {0}" -f $Action) -Message ("{0} {1} ferramenta(s) marcada(s):`n`n{2}" -f $actionVerb, @($toolNames).Count, $list))) {
            $ui.AiToolsStatusLabel.Text = ("Acao '{0}' cancelada. {1} marcada(s): {2}" -f $Action, @($toolNames).Count, (@($toolNames) -join ', '))
            return
        }
    }

    $summaries = @()
    foreach ($toolName in @($toolNames)) {
        try {
            $result = Invoke-BootstrapAiToolAction -ToolName $toolName -Action $Action -ProjectRoot $PSScriptRoot -Yes -NoAdmin
            $status = [string]$result['status']
            $message = [string]$result['message']
            if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$result['docs'] }
            $summaries += @("{0}: {1}" -f $toolName, $status)
            Write-UiLog -Message ("AI tool action | tool={0} | action={1} | status={2} | message={3}" -f $toolName, $Action, $status, $message)
        } catch {
            Write-UiLog -Level 'ERROR' -Message ("AI tool action failed | tool={0} | action={1} | message={2}`n{3}" -f $toolName, $Action, $_.Exception.Message, $_.ScriptStackTrace)
            $summaries += @("{0}: erro ({1})" -f $toolName, $_.Exception.Message)
        }
    }
    $ui.AiToolsStatusLabel.Text = "AI Tools / ${Action}: $($summaries -join ' | ')"
    Refresh-AiToolsControls
}

function Open-SelectedAiToolDocumentation {
    $toolNames = @(Get-SelectedAiToolNameList)
    if ($toolNames.Count -eq 0) {
        $ui.AiToolsStatusLabel.Text = 'Marque uma ou mais ferramentas.'
        return
    }
    try {
        $catalog = Get-BootstrapAiToolCatalog
        $opened = @()
        foreach ($toolName in @($toolNames)) {
            $normalized = Normalize-BootstrapAiToolName -ToolName $toolName
            if (-not $catalog.Contains($normalized)) { throw "Ferramenta desconhecida: $toolName" }
            $docs = [string]$catalog[$normalized]['DocsUrl']
            if ([string]::IsNullOrWhiteSpace($docs)) { continue }
            Start-Process $docs | Out-Null
            $opened += @($normalized)
        }
        $ui.AiToolsStatusLabel.Text = "Docs abertas: $(@($opened) -join ', ')"
    } catch {
        $ui.AiToolsStatusLabel.Text = "Erro ao abrir docs: $($_.Exception.Message)"
    }
}

function Clear-UiAiToolSelection {
    # Desmarca todas as ferramentas (estado persistido + grid) e atualiza o status.
    # Le primeiro o grid para contar corretamente as marcacoes atuais (ainda nao sincronizadas).
    $previous = @(Read-AiToolSelectionFromControl)
    $ui.State.selectedAiTools = @()
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-AiToolsControls
    if (@($previous).Count -gt 0) {
        $ui.AiToolsStatusLabel.Text = ("Selecao limpa ({0} desmarcada(s))." -f @($previous).Count)
    } else {
        $ui.AiToolsStatusLabel.Text = 'Nenhuma ferramenta estava marcada.'
    }
}

function Refresh-ApiCenterControls {
    try {
        $bundle = Get-BootstrapSecretsData
        $ui['ApiInventory'] = Get-BootstrapApiInventory -SecretsData $bundle.Data

        $providerRows = @()
        $credentialRows = @()
        foreach ($provider in @($ui.ApiInventory.providers)) {
            $providerRows += @([ordered]@{
                provider = [string]$provider.displayName
                total = [string]$provider.totalCredentials
                active = [string]$provider.activeCredentialId
                state = [string]$provider.activeValidationState
                statusCanonical = (Get-UiApiCanonicalStatus -State ([string]$provider.activeValidationState))
                autoApps = (@($provider.autoAppliedApps) -join ', ')
                manualApps = (@($provider.manualOnlyApps) -join ', ')
            })
            foreach ($credential in @($provider.credentials)) {
                $credentialRows += @([ordered]@{
                    provider = [string]$provider.id
                    id = [string]$credential.id
                    display = [string]$credential.displayName
                    active = [string]$credential.active
                    state = [string]$credential.validationState
                    statusCanonical = (Get-UiApiCanonicalStatus -State ([string]$credential.validationState))
                    preview = [string]$credential.secretPreview
                })
            }
        }

        $appCatalog = Get-BootstrapAppCapabilityCatalog
        $usageRows = @()
        foreach ($appId in @($appCatalog.Keys | Sort-Object)) {
            $app = ConvertTo-BootstrapHashtable -InputObject $appCatalog[$appId]
            $appName = [string]$app['displayName']
            if ([string]::IsNullOrWhiteSpace($appName)) { continue }

            $autoProviders = @()
            $manualProviders = @()
            $availableProviders = @()
            foreach ($provider in @($ui.ApiInventory.providers)) {
                $providerName = [string]$provider.displayName
                if ([string]::IsNullOrWhiteSpace($providerName)) { $providerName = [string]$provider.id }
                if (@($provider.autoAppliedApps) -contains $appName) {
                    $autoProviders += @($providerName)
                }
                if ((@($provider.manualOnlyApps) -contains $appName) -and ([string]$provider.activeValidationState -eq 'passed')) {
                    $manualProviders += @($providerName)
                }
                if (@($provider.availableApps) -contains $appName) {
                    $availableProviders += @($providerName)
                }
            }

            $usageRows += @([ordered]@{
                app = $appName
                autoApplied = (@($autoProviders | Sort-Object -Unique) -join ', ')
                manualOnly = (@($manualProviders | Sort-Object -Unique) -join ', ')
                available = (@($availableProviders | Sort-Object -Unique) -join ', ')
            })
        }

        $createRows = @()
        foreach ($provider in @($ui.ApiInventory.availableToCreate)) {
            $createRows += @([ordered]@{
                provider = [string]$provider.displayName
                fields = (@($provider.requiredFields) -join ', ')
                signup = [string]$provider.signupUrl
                docs = [string]$provider.docsUrl
            })
        }

        Load-WpfGridRows -Grid $ui.ApiProviderSummaryGrid -Items $providerRows -Columns @('provider','total','active','state','statusCanonical','autoApps','manualApps')
        Load-WpfGridRows -Grid $ui.ApiCredentialGrid -Items $credentialRows -Columns @('provider','id','display','active','state','statusCanonical','preview')
        Load-WpfGridRows -Grid $ui.ApiUsageGrid -Items $usageRows -Columns @('app','autoApplied','manualOnly','available')
        Load-WpfGridRows -Grid $ui.ApiCreateGrid -Items $createRows -Columns @('provider','fields','signup','docs')
        Refresh-ApiProviderCombos

        $summary = $ui.ApiInventory.summary
        $secretsPath = Get-BootstrapSecretsPath
        if ([int]$summary.totalCredentials -eq 0) {
            Set-ApiCenterStatusMessage -Channel 'Inventario' -Message "Nenhuma chave cadastrada ainda. Use Importar arquivo bruto ou Salvar chave. Arquivo: $secretsPath" -Diagnostics $summary
        } else {
            Set-ApiCenterStatusMessage -Channel 'Inventario' -Message "Provedores com chaves: $($summary.configuredProviders)/$($summary.providers) | Chaves cadastradas: $($summary.totalCredentials) | Em uso e validadas: $($summary.validatedActiveProviders) | Arquivo: $secretsPath" -Diagnostics $summary
        }
        $ui.ApiStatusLinksLabel.Visibility = 'Collapsed'
        $ui.ApiSignupLink.IsEnabled = $false
        $ui.ApiDocsLink.IsEnabled = $false
        $ui.ApiPricingLink.IsEnabled = $false
        $ui.ApiSignupLink.NavigateUri = $null
        $ui.ApiDocsLink.NavigateUri = $null
        $ui.ApiPricingLink.NavigateUri = $null
        $ui.ApiSecretsLinksLabel.Visibility = 'Collapsed'
        $ui.ApiSecretsFileLink.IsEnabled = $false
        $ui.ApiSecretsFolderLink.IsEnabled = $false
        $ui.ApiSecretsFileLink.NavigateUri = $null
        $ui.ApiSecretsFolderLink.NavigateUri = $null
        $anySecretsLink = $false
        if (-not [string]::IsNullOrWhiteSpace($secretsPath) -and (Test-Path $secretsPath)) {
            try {
                $ui.ApiSecretsFileLink.NavigateUri = [Uri]("file:///" + ($secretsPath -replace '\\','/'))
                $ui.ApiSecretsFileLink.IsEnabled = $true
                $anySecretsLink = $true
            } catch { }
        }
        $secretsDir = if (-not [string]::IsNullOrWhiteSpace($secretsPath)) { Split-Path -Path $secretsPath -Parent } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($secretsDir) -and (Test-Path $secretsDir)) {
            try {
                $ui.ApiSecretsFolderLink.NavigateUri = [Uri]("file:///" + ($secretsDir -replace '\\','/'))
                $ui.ApiSecretsFolderLink.IsEnabled = $true
                $anySecretsLink = $true
            } catch { }
        }
        if ($anySecretsLink) { $ui.ApiSecretsLinksLabel.Visibility = 'Visible' }
    } catch {
        Set-ApiCenterStatusMessage -Channel 'Inventario' -Message $_.Exception.Message -IsError
    }
}

function Refresh-ApiCatalogControls {
    try {
        $bundle = Get-BootstrapSecretsData
        $rows = @(Get-BootstrapApiCatalogRows -SecretsData $bundle.Data)
        Load-WpfGridRows -Grid $ui.ApiFullCatalogGrid -Items $rows -Columns @('hasCredential','quantity','configured','provider','description','fields','signup','docs')
        $owned = @($rows | Where-Object { [string]$_['hasCredential'] -eq '[x]' }).Count
        $configured = 0
        foreach ($row in @($rows)) {
            $configured += [int]$row['configured']
        }
        $ui.ApiCatalogStatusLabel.Text = "Catálogo: $(@($rows).Count) provedores | Já possui: $owned | Configuradas: $configured"
    } catch {
        $ui.ApiCatalogStatusLabel.Text = "Catálogo erro: $($_.Exception.Message)"
    }
}

function Refresh-SteamDeckStatus {
    $automationRoot = Get-BootstrapSteamDeckAutomationRoot
    $taskStatus = 'not found'
    try {
        $task = Get-ScheduledTask -TaskName 'BootstrapTools-SteamDeckModeWatcher' -ErrorAction Stop
        if ($task) { $taskStatus = 'registered' }
    } catch { $taskStatus = 'not found' }
    $watcherExists = Test-Path (Join-Path $automationRoot 'ModeWatcher.ps1')
    $hotkeyExists  = Test-Path (Join-Path $automationRoot 'SteamDeckHotkeys.ahk')
    $ui.WatcherStatusLabel.Text = "Task: $taskStatus  |  ModeWatcher: $watcherExists  |  Hotkeys: $hotkeyExists  |  Settings: $($ui.SettingsBundle.Path)"
}

function Refresh-PendingExternalClassification {
    try {
        $pending = Get-BootstrapSteamDeckPendingExternalDisplay
        if (-not $pending.Pending -or -not $pending.Display) {
            $ui.PendingExternalStatusLabel.Text = 'Nenhum monitor externo desconhecido pendente. Monitores conhecidos seguem suas familias/perfis.'
            $ui.ClassifyMonitorButton.IsEnabled = $false
            $ui.ClassifyTvButton.IsEnabled = $false
            return
        }

        $display = ConvertTo-BootstrapHashtable -InputObject $pending.Display
        $ui.PendingExternalStatusLabel.Text = "Pendente: $($display.manufacturer) / $($display.product) / serial $($display.serial). Escolha Monitor/Dev para bancada ou TV/Game para console."
        $ui.ClassifyMonitorButton.IsEnabled = $true
        $ui.ClassifyTvButton.IsEnabled = $true
    } catch {
        $ui.PendingExternalStatusLabel.Text = "Falha ao ler deteccao atual: $($_.Exception.Message)"
        $ui.ClassifyMonitorButton.IsEnabled = $false
        $ui.ClassifyTvButton.IsEnabled = $false
    }
}

function Refresh-SteamDeckControls {
    try {
        $ui.SettingsBundle = Get-BootstrapSteamDeckSettingsData -RequestedSteamDeckVersion ([string]$ui.State.steamDeckVersion) -ResolvedSteamDeckVersion 'lcd'
        $settings = ConvertTo-BootstrapHashtable -InputObject $ui.SettingsBundle.Data
        $detection = Get-UiSteamDeckLiveDetectionData -Settings $settings
        Load-WpfGridRows -Grid $ui.MonitorProfilesGrid -Items @(Get-UiSteamDeckProfileRows -Settings $settings -Detection $detection) -Columns @('primary','target','status','manufacturer','product','serial','mode','layout','resolutionPolicy')
        Load-WpfGridRows -Grid $ui.MonitorFamiliesGrid -Items @(Get-UiSteamDeckFamilyRows -Settings $settings -Detection $detection)  -Columns @('primary','status','manufacturer','product','namePattern','mode','layout','resolutionPolicy')
        $ui.GenericModeCombo.SelectedItem      = [string]$settings.genericExternal.mode
        $ui.GenericLayoutTextBox.Text          = [string]$settings.genericExternal.layout
        $ui.GenericResolutionTextBox.Text      = [string]$settings.genericExternal.resolutionPolicy
        $ui.DisplayModeCombo.SelectedItem      = if (Test-BootstrapMapContainsKey -Map $settings -Key 'displayMode') { [string]$settings.displayMode } else { 'extend' }
        $ui.HandheldSessionTextBox.Text        = [string]$settings.sessionProfiles.HANDHELD
        $ui.DockTvSessionTextBox.Text          = [string]$settings.sessionProfiles.DOCKED_TV
        $ui.DockMonitorSessionTextBox.Text     = [string]$settings.sessionProfiles.DOCKED_MONITOR
        Refresh-SteamDeckStatus
        Refresh-PendingExternalClassification
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao atualizar Steam Deck: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = "Steam Deck: falha ao ler configuracoes/deteccao - $($_.Exception.Message)"
    }
}

function Capture-SteamDeckSettingsFromControls {
    $settings = ConvertTo-BootstrapHashtable -InputObject $ui.SettingsBundle.Data
    $profileRows = @(Read-WpfGridRows -Grid $ui.MonitorProfilesGrid -Columns @('primary','target','status','manufacturer','product','serial','mode','layout','resolutionPolicy'))
    $internalRows = @($profileRows | Where-Object { ([string]$_['target']).Trim().ToLowerInvariant() -eq 'internal' })
    $externalProfileRows = @($profileRows | Where-Object { ([string]$_['target']).Trim().ToLowerInvariant() -ne 'internal' })
    $monitorProfiles = @(Remove-UiGridRuntimeColumns -Rows $externalProfileRows)
    $monitorFamilies = @(Remove-UiGridRuntimeColumns -Rows @(Read-WpfGridRows -Grid $ui.MonitorFamiliesGrid  -Columns @('primary','status','manufacturer','product','namePattern','mode','layout','resolutionPolicy')) -RuntimeColumns @('status'))
    Validate-SteamDeckGridModeRows -Rows $monitorProfiles -GridName 'MonitorProfiles'
    Validate-SteamDeckGridModeRows -Rows $monitorFamilies -GridName 'MonitorFamilies'

    $internalRow = if ($internalRows.Count -gt 0) { $internalRows[0] } else { $null }
    if ($internalRow) {
        $settings['internalDisplay'] = @{
            manufacturer = ([string]$internalRow['manufacturer']).Trim()
            product = ([string]$internalRow['product']).Trim()
            serial = ([string]$internalRow['serial']).Trim()
            primary = ConvertTo-UiBoolean -Value $internalRow['primary']
            layout = ([string]$internalRow['layout']).Trim()
            resolutionPolicy = ([string]$internalRow['resolutionPolicy']).Trim()
        }
    }

    $settings['monitorProfiles']  = @($monitorProfiles)
    $settings['monitorFamilies']  = @($monitorFamilies)
    $displayMode = if ($ui.DisplayModeCombo.SelectedItem) { [string]$ui.DisplayModeCombo.SelectedItem } else { 'extend' }
    if ((ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $settings['internalDisplay'] -Name 'primary' -Default $false)) -and $displayMode -eq 'external') {
        $displayMode = 'extend'
        $ui.DisplayModeCombo.SelectedItem = 'extend'
    }
    $settings['displayMode'] = $displayMode
    $settings['genericExternal']  = @{
        mode             = if ($ui.GenericModeCombo.SelectedItem) { [string]$ui.GenericModeCombo.SelectedItem } else { 'UNCLASSIFIED_EXTERNAL' }
        layout           = $ui.GenericLayoutTextBox.Text.Trim()
        resolutionPolicy = $ui.GenericResolutionTextBox.Text.Trim()
        primary          = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $settings['genericExternal'] -Name 'primary' -Default $true)
    }
    $settings['sessionProfiles']  = @{
        HANDHELD       = $ui.HandheldSessionTextBox.Text.Trim()
        DOCKED_TV      = $ui.DockTvSessionTextBox.Text.Trim()
        DOCKED_MONITOR = $ui.DockMonitorSessionTextBox.Text.Trim()
    }
    $settings['steamDeckVersion'] = [string]$ui.State.steamDeckVersion
    $ui.SettingsBundle = @{ Path = $ui.SettingsBundle.Path; Data = $settings }
}

function Save-SteamDeckSettingsInteractive {
    try {
        Capture-SteamDeckSettingsFromControls
        $saveResult = Save-BootstrapSteamDeckSettingsData -Settings $ui.SettingsBundle.Data -CreateBackup
        $ui.SettingsBackupPath         = $saveResult.BackupPath
        $ui.State.lastSettingsPath     = $saveResult.Path
        Save-UiState -State $ui.State -Path $UiStatePath
        $ui.StatusLabel.Text           = $ui.Strings.SavingSettings
        Refresh-SteamDeckStatus
        return $true
    } catch {
        $ui.StatusLabel.Text = "Settings invalidos: $($_.Exception.Message)"
        return $false
    }
}

function Classify-PendingExternalDisplay {
    param([ValidateSet('MonitorDev', 'TvGame')][string]$Choice)

    try {
        Capture-SteamDeckSettingsFromControls
        $null = Save-BootstrapSteamDeckSettingsData -Settings $ui.SettingsBundle.Data -CreateBackup
        $result = Add-BootstrapSteamDeckDisplayClassification -Choice $Choice -CreateBackup
        $ui.StatusLabel.Text = "Display classificado: $($result.Manufacturer) / $($result.Product) => $($result.Mode)"
        Refresh-SteamDeckControls
    } catch {
        $ui.StatusLabel.Text = "Falha ao classificar display: $($_.Exception.Message)"
    }
}

function Refresh-DualBootControls {
    $ui.DualBootStatusText.Text = 'Lendo UEFI firmware e gerenciador de disco...'
    $info = Get-BootstrapDualBootInfo
    $recs = Get-BootstrapDualBootRecommendations -DualBootInfo $info

    $statusLines = @()
    $statusLines += "Is Dual Boot: $($info.IsDualBoot) (Confidence: $($info.Confidence))"
    $statusLines += "Sistemas Detectados: $(($info.DetectedOS) -join ', ')"
    $statusLines += "GRUB Detectado: $($info.GrubDetected) ($($info.GrubEfiPath))"
    $statusLines += "Parties Linux: $($info.LinuxPartitions.Count)"
    $statusLines += ""
    $statusLines += ($recs -join [Environment]::NewLine)

    if (-not $info.IsAdmin) {
        $statusLines += ""
        $statusLines += "AVISO: executando sem privilegios de Administrador. Recursos avancados estao desabilitados."
        $ui.RebootToLinuxButton.IsEnabled = $false
        $ui.FixFastStartupButton.IsEnabled = $false
        $ui.DualBootTargetCombo.IsEnabled = $false
    } else {
        $ui.RebootToLinuxButton.IsEnabled = $info.IsDualBoot
        $ui.DualBootTargetCombo.IsEnabled = $true
    }
    $ui.DualBootStatusText.Text = ($statusLines -join [Environment]::NewLine)

    $prereqs = @(Test-BootstrapDualBootPrerequisites)
    $fsIssue = $prereqs | Where-Object { $_.Id -eq 'fast-startup' } | Select-Object -First 1
    if ($prereqs.Count -eq 0 -or (-not $fsIssue)) {
        $ui.FixFastStartupButton.Visibility = 'Collapsed'
    } else {
        $ui.FixFastStartupButton.Visibility = 'Visible'
    }
    if ($prereqs.Count -gt 0) {
        $ui.DualBootPrereqsText.Text = ($prereqs | ForEach-Object { "[$($_.Severity.ToUpper())] $($_.Title): $($_.Description)" }) -join [Environment]::NewLine
    } else {
        $ui.DualBootPrereqsText.Text = "Nenhum problema detectado. Todas as configuracoes do Windows estao seguras para o Linux."
    }

    $alts = Get-BootstrapAlternateBootEntries
    $ui.DualBootTargetCombo.Items.Clear()
    foreach ($a in $alts) {
        $cbi = New-Object System.Windows.Controls.ComboBoxItem
        $cbi.Content = $a.Description
        $cbi.Tag = $a.Id
        [void]$ui.DualBootTargetCombo.Items.Add($cbi)
    }
    if ($ui.DualBootTargetCombo.Items.Count -gt 0) {
        $ui.DualBootTargetCombo.SelectedIndex = 0
    }

    try {
        $bootState = Get-BootstrapWindowsBootManagerState
        Load-WpfGridRows -Grid $ui.WindowsBootEntriesGrid -Items @($bootState.Entries) -Columns @('isDefault','isCurrent','inDisplayOrder','id','description','device','osdevice','isPhantom')
        $ui.WindowsBootDefaultCombo.Items.Clear()
        foreach ($entry in @($bootState.Entries)) {
            $entryId = [string]$entry['id']
            if ([string]::IsNullOrWhiteSpace($entryId)) { continue }
            $label = "{0} - {1}" -f $entryId, [string]$entry['description']
            $cbi = New-Object System.Windows.Controls.ComboBoxItem
            $cbi.Content = $label
            $cbi.Tag = $entryId
            [void]$ui.WindowsBootDefaultCombo.Items.Add($cbi)
            if ($entryId -eq [string]$bootState.ResolvedDefault -or $entryId -eq [string]$bootState.Default) {
                $ui.WindowsBootDefaultCombo.SelectedItem = $cbi
            }
        }
        $ui.WindowsBootTimeoutTextBox.Text = if ($null -ne $bootState.Timeout) { [string]$bootState.Timeout } else { '' }
        $ui.WindowsBootStatusText.Text = "Default: $($bootState.Default) -> $($bootState.ResolvedDefault) | Atual: $($bootState.ResolvedCurrent) | Timeout: $($bootState.Timeout) | Entradas: $(@($bootState.Entries).Count) | Orfas: $(@($bootState.PhantomEntries).Count)"
        $ui.WindowsBootDefaultCombo.IsEnabled = [bool]$bootState.IsAdmin
        $ui.WindowsBootTimeoutTextBox.IsEnabled = [bool]$bootState.IsAdmin
        $ui.ApplyWindowsBootButton.IsEnabled = [bool]$bootState.IsAdmin
        $ui.BackupWindowsBootButton.IsEnabled = [bool]$bootState.IsAdmin
        $bcdBackups = @(Get-BootstrapBcdBackups)
        $ui.BcdBackupCombo.Items.Clear()
        foreach ($bk in $bcdBackups) {
            $cbi = New-Object System.Windows.Controls.ComboBoxItem
            $cbi.Content = ("{0}  ({1})" -f [string]$bk.Name, [string]$bk.Created)
            $cbi.Tag = [string]$bk.Path
            [void]$ui.BcdBackupCombo.Items.Add($cbi)
        }
        if ($ui.BcdBackupCombo.Items.Count -gt 0) { $ui.BcdBackupCombo.SelectedIndex = 0 }
        $hasBcdBackups = ($ui.BcdBackupCombo.Items.Count -gt 0)
        $ui.BcdBackupCombo.IsEnabled = $hasBcdBackups
        $ui.RestoreBcdButton.IsEnabled = ([bool]$bootState.IsAdmin -and $hasBcdBackups)
        if (-not [bool]$bootState.IsAdmin) {
            $ui.WindowsBootStatusText.Text += " | Execute como Administrador para alterar default/timeout, gerar backup ou restaurar."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$bootState.CommandError)) {
            $ui.WindowsBootStatusText.Text += " | bcdedit: $($bootState.CommandError)"
        }
    } catch {
        $ui.WindowsBootStatusText.Text = "Falha ao auditar Windows Boot Manager: $($_.Exception.Message)"
        Load-WpfGridRows -Grid $ui.WindowsBootEntriesGrid -Items @() -Columns @('isDefault','isCurrent','inDisplayOrder','id','description','device','osdevice','isPhantom')
        $ui.WindowsBootDefaultCombo.Items.Clear()
        $ui.WindowsBootDefaultCombo.IsEnabled = $false
        $ui.WindowsBootTimeoutTextBox.IsEnabled = $false
        $ui.ApplyWindowsBootButton.IsEnabled = $false
        $ui.BackupWindowsBootButton.IsEnabled = $false
        $ui.RestoreBcdButton.IsEnabled = $false
    }

    $phantomCount = -1
    $ui.BcdCleanupButton.Visibility = 'Collapsed'
    if (Test-IsAdmin) {
        $phantoms = Get-BootstrapPhantomBootEntries
        $phantomCount = $phantoms.Count
        if ($phantomCount -gt 0) {
            $ui.BcdCleanupStatusText.Text = "Detectado lixo no BCD. Existem $phantomCount entradas 'fantasmas' no Menu do Windows concorrendo pelo loader."
            $ui.BcdCleanupButton.Visibility = 'Visible'
            $ui.BcdCleanupButton.IsEnabled = $true
        } else {
            $ui.BcdCleanupStatusText.Text = "Menu de Boot limpo! Nenhuma instação órfã do Windows detectada."
        }
    } else {
        $ui.BcdCleanupStatusText.Text = "Requer privilégios de Administrador para auditar o Boot Configuration Data."
    }
}

function Refresh-ReviewPage {
    Capture-SteamDeckSettingsFromControls
    Capture-AppTuningStateFromControls
    $scopeSnapshot = Get-CurrentExecutionScopeSnapshot
    $ui.Preview = Get-BootstrapPreviewData -SelectedProfiles $scopeSnapshot.selectedProfiles -SelectedComponents $scopeSnapshot.selectedComponents -ExcludedComponents $scopeSnapshot.excludedComponents -RequestedSteamDeckVersion $ui.State.steamDeckVersion -RequestedHostHealthMode $scopeSnapshot.hostHealth -RequestedAppTuningMode $scopeSnapshot.appTuningMode -RequestedAppTuningCategories $scopeSnapshot.selectedAppTuningCategories -RequestedAppTuningItems $scopeSnapshot.selectedAppTuningItems -ExcludedAppTuningItems $scopeSnapshot.excludedAppTuningItems -RequestedWorkspaceRoot $ui.State.workspaceRoot -ExplicitCloneBaseDir $ui.State.cloneBaseDir
    $ui.ReviewTextBox.Text  = $ui.Preview.PlanText
    $resolved = @()
    try {
        $sel = New-BootstrapSelectionObject -SelectedProfiles $scopeSnapshot.selectedProfiles -SelectedComponents $scopeSnapshot.selectedComponents -ExcludedComponents $scopeSnapshot.excludedComponents -SelectedHostHealth $scopeSnapshot.hostHealth
        $res = Resolve-BootstrapComponents -SelectedProfiles $sel.Profiles -SelectedComponents $sel.Components -ExcludedComponents $sel.Excludes
        $resolved = @($res.ResolvedComponents)
    } catch { $resolved = @() }
    $effects = @()
    if ($resolved -contains 'bootstrap-secrets') { $effects += 'bootstrap-secrets: escreve manifests/settings (backup .bak) em pastas de usuario.' }
    if ($resolved -contains 'bootstrap-mcps') { $effects += 'bootstrap-mcps: escreve mcp.json / configs em apps (VS Code, Cursor, Windsurf, Trae, OpenCode, etc).' }
    if ($resolved -contains 'vscode-extensions') { $effects += 'vscode-extensions: instala extensoes + altera settings.json / configs de extensoes.' }
    if ($resolved -contains 'claude-config') { $effects += 'claude-config: atualiza ~/.claude/settings.json (backup).' }
    if ($resolved -contains 'claude-plugins') { $effects += 'claude-plugins: instala plugins via claude (rede).' }
    if ($resolved -contains 'hermes') { $effects += 'hermes: instala via npm + cria/atualiza .hermes/opencloud.json no projeto.' }
    if ([bool]$ui.State.enableClaudeCodeProjectMcps) { $effects += 'Claude Code: adiciona conexões de IA no projeto via comando oficial.' }
    $ui.ReviewSideEffectsTextBox.Text = if ($effects.Count -gt 0) { $effects -join [Environment]::NewLine } else { '-' }
    $adminText = if (@($ui.Preview.AdminReasons).Count -gt 0) { @($ui.Preview.AdminReasons) -join '; ' } else { '-' }
    $ui.ReviewMetaLabel.Text = "Escopo: $([string]$scopeSnapshot.scopeLabel)  |  Admin: $adminText  |  Configurações: $($ui.SettingsBundle.Path)  |  Estado da UI: $UiStatePath"
    $ui.ReviewLinksLabel.Visibility = 'Collapsed'
    $ui.ReviewSettingsLink.IsEnabled = $false
    $ui.ReviewUiStateLink.IsEnabled = $false
    $ui.ReviewSettingsLink.NavigateUri = $null
    $ui.ReviewUiStateLink.NavigateUri = $null
    $anyLink = $false
    $settingsPath = [string]$ui.SettingsBundle.Path
    if (-not [string]::IsNullOrWhiteSpace($settingsPath) -and (Test-Path $settingsPath)) {
        try {
            $ui.ReviewSettingsLink.NavigateUri = [Uri]("file:///" + ($settingsPath -replace '\\','/'))
            $ui.ReviewSettingsLink.IsEnabled = $true
            $anyLink = $true
        } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($UiStatePath) -and (Test-Path $UiStatePath)) {
        try {
            $ui.ReviewUiStateLink.NavigateUri = [Uri]("file:///" + ($UiStatePath -replace '\\','/'))
            $ui.ReviewUiStateLink.IsEnabled = $true
            $anyLink = $true
        } catch { }
    }
    if ($anyLink) { $ui.ReviewLinksLabel.Visibility = 'Visible' }
}

#
# Navigation
#

$navButtons = @(
    $ui.NavHealth,
    $ui.NavWelcome,
    $ui.NavSelection,
    $ui.NavHostSetup,
    $ui.NavAppTuning,
    $ui.NavAiTools,
    $ui.NavApiCenter,
    $ui.NavSteamDeck,
    $ui.NavDualBoot,
    $ui.NavReview,
    $ui.NavRun
)
$navButtonTargets = @('health', 'welcome', 'selection', 'host-setup', 'app-tuning', 'ai-tools', 'api-center', 'steamdeck-control', 'dual-boot', 'review', 'run')

function Navigate-ToPage {
    param([int]$Index)
    $pageIds = @(Get-UiPageIds)
    if ($Index -lt 0 -or $Index -ge $pageIds.Count) { return }
    $ui.CurrentPageIndex = $Index

    # Show/hide pages
    foreach ($pageName in $ui.PageNames) {
        $ctrl = $window.FindName($pageName)
        if ($ctrl) { $ctrl.Visibility = 'Collapsed' }
    }
    $activePage = $window.FindName($ui.PageNames[$Index])
    if ($activePage) { $activePage.Visibility = 'Visible' }

    # Toggle nav buttons
    $activePageId = [string]$pageIds[$Index]
    for ($i = 0; $i -lt $navButtons.Count; $i++) {
        $navButtons[$i].IsChecked = ([string]$navButtonTargets[$i] -eq $activePageId)
    }

    $stepName = switch ($pageIds[$Index]) {
        'welcome'          { $ui.Strings.Welcome }
        'selection'        { $ui.Strings.Selection }
        'host-setup'       { $ui.Strings.HostSetup }
        'health'           { $ui.Strings.Health }
        'app-tuning'       { $ui.Strings.AppTuning }
        'ai-tools'         { $ui.Strings.AiToolsTitle }
        'api-center'       { $ui.Strings.ApiCenter }
        'api-catalog'      { $ui.Strings.ApiCatalogTitle }
        'steamdeck-control' { $ui.Strings.SteamDeckControl }
        'dual-boot'        { $ui.Strings.DualBoot }
        'review'           { $ui.Strings.Review }
        default            { $ui.Strings.Run }
    }

    # Voltar/Avancar e contador seguem a sequencia do wizard (sem health/api-catalog).
    $stepIds = @(Get-UiWizardStepIds)
    $stepPos = [Array]::IndexOf($stepIds, [string]$pageIds[$Index])
    if ($stepPos -ge 0) {
        $ui.BackButton.IsEnabled = ($stepPos -gt 0)
        $ui.NextButton.IsEnabled = ($stepPos -lt ($stepIds.Count - 1))
        $ui.StepLabel.Text = "{0} / {1}  -  {2}" -f ($stepPos + 1), $stepIds.Count, $stepName
    } elseif ([string]$pageIds[$Index] -eq 'api-catalog') {
        $ui.BackButton.IsEnabled = $true   # volta para a Central de APIs
        $ui.NextButton.IsEnabled = $false
        $ui.StepLabel.Text = $stepName
    } else {
        # health (dashboard de entrada): sem passo; "Avancar" entra no fluxo.
        $ui.BackButton.IsEnabled = $false
        $ui.NextButton.IsEnabled = $true
        $ui.StepLabel.Text = $stepName
    }

    switch ($pageIds[$Index]) {
        'selection'         { Refresh-SelectionTrees; Refresh-SelectionSummary }
        'host-setup'        { Refresh-SelectionSummary; Refresh-HostSetupControls }
        'app-tuning'        { Refresh-AppTuningControls }
        'ai-tools'          { Refresh-AiToolsControls }
        'api-center'        { Refresh-ApiCenterControls }
        'api-catalog'       { Refresh-ApiCatalogControls }
        'steamdeck-control' { Refresh-SteamDeckControls }
        'dual-boot'         { Refresh-DualBootControls }
        'review'            { Refresh-ReviewPage; Refresh-HostSetupControls }
    }
}

function Navigate-WizardStep {
    # Voltar/Avancar dentro da sequencia do wizard (Get-UiWizardStepIds).
    param([Parameter(Mandatory = $true)][int]$Delta)

    $pageIds = @(Get-UiPageIds)
    $stepIds = @(Get-UiWizardStepIds)
    $currentId = [string]$pageIds[$ui.CurrentPageIndex]
    $stepPos = [Array]::IndexOf($stepIds, $currentId)

    if ($stepPos -ge 0) {
        $target = $stepPos + $Delta
        if ($target -ge 0 -and $target -lt $stepIds.Count) {
            $idx = [Array]::IndexOf($pageIds, [string]$stepIds[$target])
            if ($idx -ge 0) { Navigate-ToPage -Index $idx }
        }
        return
    }

    if ($currentId -eq 'api-catalog') {
        # Pagina de detalhe: Voltar/Avancar retornam para a Central de APIs.
        $idx = [Array]::IndexOf($pageIds, 'api-center')
        if ($idx -ge 0) { Navigate-ToPage -Index $idx }
        return
    }

    # health (dashboard de entrada): "Avancar" inicia o fluxo no primeiro passo.
    if ($Delta -gt 0) {
        $idx = [Array]::IndexOf($pageIds, [string]$stepIds[0])
        if ($idx -ge 0) { Navigate-ToPage -Index $idx }
    }
}

#
# Process helpers
#

function Build-BackendArguments {
    $tokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backendScriptPath)
    $tokens += @('-NonInteractive')
    $null = Repair-UiExcludedComponents
    function New-BackendArrayArgument {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [AllowNull()]$Values
        )

        $items = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        if ($items.Count -gt 0) {
            return @($Name, ($items -join ','))
        }
        return @()
    }

    $scopeSnapshot = Get-CurrentExecutionScopeSnapshot
    Assert-ExecutionScopeSnapshot -Scope $scopeSnapshot

    $activeProfiles = @($scopeSnapshot.selectedProfiles)
    $activeComponents = @($scopeSnapshot.selectedComponents)
    $activeExcludes = @($scopeSnapshot.excludedComponents)
    $activeHostHealth = [string]$scopeSnapshot.hostHealth
    $activeAppTuningMode = [string]$scopeSnapshot.appTuningMode
    $activeAppTuningCategories = @($scopeSnapshot.selectedAppTuningCategories)
    $activeAppTuningItems = @($scopeSnapshot.selectedAppTuningItems)
    $activeExcludedAppTuningItems = @($scopeSnapshot.excludedAppTuningItems)

    $tokens += @(New-BackendArrayArgument -Name '-Profile' -Values $activeProfiles)
    $tokens += @(New-BackendArrayArgument -Name '-Component' -Values $activeComponents)
    $tokens += @(New-BackendArrayArgument -Name '-Exclude' -Values $activeExcludes)
    if ([bool]$ui.State.enableClaudeCodeProjectMcps) { $tokens += @('-ClaudeCodeProjectMcps') }
    if ([bool]$ui.State.skipManualRequirements) { $tokens += @('-SkipManualRequirements') }
    if ([bool]$ui.State.ignoreManualRequirements) { $tokens += @('-IgnoreManualRequirements') }
    if ([bool]$ui.State.requireNoPendingReboot) { $tokens += @('-RequireNoPendingReboot') }
    if ([bool]$ui.State.offlineMode) { $tokens += @('-Offline') }
    if ([bool]$ui.State.enableResume) { $tokens += @('-Resume') }
    $maint = [string]$ui.MaintenanceMode
    if ([string]::IsNullOrWhiteSpace($maint)) { $maint = 'none' }
    if ($maint -eq 'rollback') { $tokens += @('-Rollback') }
    if ($maint -eq 'audit') { $tokens += @('-Audit') }
    if ($maint -eq 'doctor') { $tokens += @('-Doctor') }
    if ($maint -eq 'support-bundle') { $tokens += @('-SupportBundle') }
    if ($maint -eq 'repair-plan') { $tokens += @('-RepairPlan') }
    if ($maint -eq 'partition-labels') { $tokens += @('-PartitionLabels') }
    if ($maint -eq 'partition-labels-apply') { $tokens += @('-PartitionLabels', '-ApplyPartitionLabels') }
    # Doctor e RepairPlan honram o escopo selecionado (ex.: card individual ou tokens/memoria).
    if ($maint -in @('doctor', 'repair-plan')) {
        $doctorScope = [string]$ui.DoctorScope
        if ([string]::IsNullOrWhiteSpace($doctorScope)) { $doctorScope = 'all' }
        $tokens += @('-DoctorScope', $doctorScope)
    }
    $tokens += @('-SteamDeckVersion', [string]$ui.State.steamDeckVersion)
    $tokens += @('-HostHealth',       [string]$activeHostHealth)
    $tokens += @('-AppTuning',        [string]$activeAppTuningMode)
    $tokens += @(New-BackendArrayArgument -Name '-AppTuningCategory' -Values $activeAppTuningCategories)
    $tokens += @(New-BackendArrayArgument -Name '-AppTuningItem' -Values $activeAppTuningItems)
    $tokens += @(New-BackendArrayArgument -Name '-ExcludeAppTuningItem' -Values $activeExcludedAppTuningItems)
    $tokens += @('-WorkspaceRoot',    [string]$ui.State.workspaceRoot)
    $tokens += @('-CloneBaseDir',     [string]$ui.State.cloneBaseDir)
    $tokens += @('-LogPath',          [string]$ui.CurrentLogPath)
    $tokens += @('-ResultPath',       [string]$ui.CurrentResultPath)
    Write-UiLog -Message ("Execution scope snapshot. Source={0} ScopeMode={1} Profiles={2} Components={3} Excludes={4} AppItems={5} ExcludedAppItems={6}  MaintenanceMode={7}" -f [string]$scopeSnapshot.source, [string]$scopeSnapshot.scopeMode, @($activeProfiles).Count, @($activeComponents).Count, @($activeExcludes).Count, @($activeAppTuningItems).Count, @($activeExcludedAppTuningItems).Count, $maint)
    return $tokens
}

function ConvertTo-PowerShellLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'" + ([string]$Value -replace "'", "''") + "'"
}

function Get-UiBackendParameterBindingSpec {
    $valueParameters = @(
        '-CloneBaseDir',
        '-WorkspaceRoot',
        '-Profile',
        '-Component',
        '-Exclude',
        '-SteamDeckVersion',
        '-HostHealth',
        '-AppTuning',
        '-App',
        '-AppTuningCategory',
        '-AppTuningItem',
        '-ExcludeAppTuningItem',
        '-LogPath',
        '-ResultPath',
        '-SecretsImportPath',
        '-SecretsActivateProvider',
        '-SecretsActivateCredential',
        '-ChangesPath',
        '-CacheDir',
        '-ExecuteRepairPlan'
    )
    $switchParameters = @(
        '-ClaudeCodeProjectMcps',
        '-Interactive',
        '-ListProfiles',
        '-ListHostHealthModes',
        '-ListAppTuningCatalog',
        '-ListApps',
        '-ListComponents',
        '-Doctor',
        '-SupportBundle',
        '-RepairPlan',
        '-PartitionLabels',
        '-ApplyPartitionLabels',
        '-UiContractJson',
        '-BootstrapUiLibraryMode',
        '-SecretsList',
        '-SecretsValidateAll',
        '-DryRun',
        '-NonInteractive',
        '-SkipManualRequirements',
        '-IgnoreManualRequirements',
        '-RequireNoPendingReboot',
        '-AllowPendingReboot',
        '-Resume',
        '-Rollback',
        '-AggressiveRollback',
        '-Offline',
        '-Audit',
        '-AutoRollback',
        '-Repair'
    )

    $values = @{}
    foreach ($name in $valueParameters) { $values[$name.ToLowerInvariant()] = $true }
    $switches = @{}
    foreach ($name in $switchParameters) { $switches[$name.ToLowerInvariant()] = $true }

    return [pscustomobject]@{
        ValueParameters = $values
        SwitchParameters = $switches
    }
}

function ConvertTo-ElevatedBackendInvocationParts {
    param([Parameter(Mandatory = $true)][string[]]$ScriptArgs)

    $spec = Get-UiBackendParameterBindingSpec
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ScriptArgs.Count; $i++) {
        $token = [string]$ScriptArgs[$i]
        $key = $token.ToLowerInvariant()
        if ($spec.SwitchParameters.ContainsKey($key)) {
            $parts.Add($token)
            continue
        }
        if ($spec.ValueParameters.ContainsKey($key)) {
            if (($i + 1) -ge $ScriptArgs.Count) {
                throw ("Argumento backend elevado sem valor: {0}" -f $token)
            }
            $parts.Add($token)
            $i++
            $parts.Add((ConvertTo-PowerShellLiteral -Value ([string]$ScriptArgs[$i])))
            continue
        }
        throw ("Argumento backend elevado desconhecido: {0}" -f $token)
    }

    return @($parts.ToArray())
}

function Get-UiBackendTokenValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][string]$Name
    )

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        if ([string]::Equals([string]$Tokens[$i], $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (($i + 1) -lt $Tokens.Count) { return [string]$Tokens[$i + 1] }
            return ''
        }
    }
    return ''
}

function New-UiElevatedBackendWrapperCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$InvocationParts,
        [string]$StdoutPath,
        [string]$StderrPath,
        [string]$ResultPath,
        [string]$LogPath
    )

    $invokeCommand = (@('&', (ConvertTo-PowerShellLiteral -Value $ScriptPath)) + @($InvocationParts)) -join ' '
    $scriptLiteral = ConvertTo-PowerShellLiteral -Value $ScriptPath
    $stdoutLiteral = ConvertTo-PowerShellLiteral -Value $StdoutPath
    $stderrLiteral = ConvertTo-PowerShellLiteral -Value $StderrPath
    $resultLiteral = ConvertTo-PowerShellLiteral -Value $ResultPath
    $logLiteral = ConvertTo-PowerShellLiteral -Value $LogPath
    $howToFixLiteral = ConvertTo-PowerShellLiteral -Value 'Corrija o erro do wrapper elevado ou rode novamente com escopo isolado/audit para diagnosticar sem UAC.'

    $statements = @(
        '$ErrorActionPreference = ''Stop''',
        '$ProgressPreference = ''SilentlyContinue''',
        ('$scriptPath = {0}' -f $scriptLiteral),
        ('$stdoutPath = {0}' -f $stdoutLiteral),
        ('$stderrPath = {0}' -f $stderrLiteral),
        ('$resultPath = {0}' -f $resultLiteral),
        ('$logPath = {0}' -f $logLiteral),
        ('$howToFix = {0}' -f $howToFixLiteral),
        'function Write-UiElevatedWrapperLine { param([string]$Path,[string]$Level,[string]$Message,[switch]$Utf8) if ([string]::IsNullOrWhiteSpace($Path)) { return } try { $parent = Split-Path -Path $Path -Parent; if ($parent) { [void][System.IO.Directory]::CreateDirectory($parent) }; $line = ''[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}'' -f (Get-Date), $Level, $Message; if ($Utf8) { Add-Content -LiteralPath $Path -Value $line -Encoding utf8 } else { $line | Out-File -FilePath $Path -Append } } catch { } }',
        'Write-UiElevatedWrapperLine -Path $stdoutPath -Level ''INFO'' -Message (''Bootstrap UI elevated wrapper started. Script={0} WorkingDirectory={1} ResultPath={2}'' -f $scriptPath, (Get-Location).Path, $resultPath)',
        'Write-UiElevatedWrapperLine -Path $logPath -Level ''INFO'' -Message (''Bootstrap UI elevated wrapper started. Script={0} WorkingDirectory={1} ResultPath={2}'' -f $scriptPath, (Get-Location).Path, $resultPath) -Utf8',
        'try {',
        ('  {0} 1>> $stdoutPath 2>> $stderrPath' -f $invokeCommand),
        '  exit $LASTEXITCODE',
        '} catch {',
        '  $message = ''Elevated backend wrapper failed: {0}'' -f $_.Exception.Message',
        '  Write-UiElevatedWrapperLine -Path $stderrPath -Level ''ERROR'' -Message $message',
        '  Write-UiElevatedWrapperLine -Path $logPath -Level ''ERROR'' -Message $message -Utf8',
        '  try {',
        '    if (-not [string]::IsNullOrWhiteSpace($resultPath)) {',
        '      $parent = Split-Path -Path $resultPath -Parent',
        '      if ($parent) { [void][System.IO.Directory]::CreateDirectory($parent) }',
        '      $fallback = [ordered]@{ status = ''error''; mode = ''ui-elevated''; generatedAt = (Get-Date).ToString(''o''); exitCode = 1; error = $message; howToFix = $howToFix; logPath = $logPath; resultPath = $resultPath; stdoutPath = $stdoutPath; stderrPath = $stderrPath; diagnostics = @([ordered]@{ severity = ''error''; message = $message; howToFix = $howToFix }) }',
        '      [System.IO.File]::WriteAllText($resultPath, ($fallback | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))',
        '    }',
        '  } catch {',
        '    Write-UiElevatedWrapperLine -Path $stderrPath -Level ''ERROR'' -Message (''Failed to write elevated fallback result: {0}'' -f $_.Exception.Message)',
        '  }',
        '  exit 1',
        '}'
    )

    return ($statements -join '; ')
}

function Build-ElevatedBackendCommand {
    param([Parameter(Mandatory = $true)][string[]]$BackendTokens)

    $fileIndex = [Array]::IndexOf($BackendTokens, '-File')
    if ($fileIndex -lt 0 -or ($fileIndex + 1) -ge $BackendTokens.Count) {
        throw 'Argumentos backend invalidos para elevacao: -File ausente.'
    }
    $scriptPath = [string]$BackendTokens[$fileIndex + 1]
    $scriptArgs = @()
    if (($fileIndex + 2) -lt $BackendTokens.Count) {
        $scriptArgs = @($BackendTokens[($fileIndex + 2)..($BackendTokens.Count - 1)])
    }
    $invocationParts = ConvertTo-ElevatedBackendInvocationParts -ScriptArgs $scriptArgs
    $resultPath = Get-UiBackendTokenValue -Tokens $scriptArgs -Name '-ResultPath'
    $logPath = Get-UiBackendTokenValue -Tokens $scriptArgs -Name '-LogPath'
    $command = New-UiElevatedBackendWrapperCommand -ScriptPath $scriptPath -InvocationParts $invocationParts -StdoutPath ([string]$ui.CurrentStdoutPath) -StderrPath ([string]$ui.CurrentStderrPath) -ResultPath $resultPath -LogPath $logPath
    return @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command)
}

function New-UiRunArtifactSet {
    param([string]$Timestamp = (Get-Date -Format 'yyyyMMdd_HHmmss'))

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$script:UiStorageRoot)) {
        $candidates.Add((Join-Path ([string]$script:UiStorageRoot) 'ui-runs'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'bootstrap-tools\ui-runs'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $candidates.Add((Join-Path $env:TEMP 'bootstrap-tools\ui-runs'))
    }
    $candidates.Add((Join-Path $PSScriptRoot 'bootstrap-tools\ui-runs'))

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        $probeFile = Join-Path ([string]$candidate) ('.bootstrap-ui-run-probe-{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
        if (Test-UiParentPathWritable -Path $probeFile) {
            $root = [string]$candidate
            return [ordered]@{
                Root = $root
                LogPath = Join-Path $root ("bootstrap-ui_{0}.log" -f $Timestamp)
                ResultPath = Join-Path $root ("bootstrap-ui_{0}.result.json" -f $Timestamp)
                StdoutPath = Join-Path $root ("bootstrap-ui_{0}.stdout.log" -f $Timestamp)
                StderrPath = Join-Path $root ("bootstrap-ui_{0}.stderr.log" -f $Timestamp)
            }
        }
    }

    throw 'Bootstrap UI não encontrou diretório gravável para artefatos de execução.'
}

function Start-BackendWorker {
    $powershellExe   = Get-WindowsPowerShellExePath
    $backendTokens   = Build-BackendArguments
    $argumentString  = ConvertTo-ArgumentString -Tokens $backendTokens
    $adminNeededForRun = ($ui.Preview -and @($ui.Preview.AdminReasons).Count -gt 0 -and -not (Test-IsAdmin))
    $maintMode = [string]$ui.MaintenanceMode
    if ([string]::IsNullOrWhiteSpace($maintMode)) { $maintMode = 'none' }
    $maintenanceSkipsElevation = ($maintMode -in @('audit','rollback','doctor','support-bundle','repair-plan','partition-labels'))
    $maintenanceNeedsAdmin = ($maintMode -eq 'partition-labels-apply' -and -not (Test-IsAdmin))
    $needsAdmin = (($adminNeededForRun -and -not $maintenanceSkipsElevation) -or $maintenanceNeedsAdmin)
    $backendRoot = [System.IO.Path]::GetDirectoryName($backendScriptPath)
    if ([string]::IsNullOrWhiteSpace($backendRoot)) { $backendRoot = $PSScriptRoot }
    $argumentLength = 0
    try { $argumentLength = ([string]$argumentString).Length } catch { $argumentLength = 0 }
    $safeArgumentLimit = 7600
    if ($argumentLength -gt $safeArgumentLimit) {
        throw ("ArgumentList acima do limite seguro ({0}>{1}). Revise seleção/ajustes de apps e limpe histórico antes de executar." -f $argumentLength, $safeArgumentLimit)
    }
    $ui.CurrentBackendWasElevated = [bool]$needsAdmin
    Write-UiLog -Message ("Start-BackendWorker. NeedsAdmin={0}  ArgLength={1}  Exe={2}  Args={3}  WorkingDirectory={4}" -f $needsAdmin, $argumentLength, $powershellExe, $argumentString, $backendRoot)
    $sp = @{
        FilePath               = $powershellExe
        ArgumentList           = $argumentString
        WindowStyle            = 'Hidden'
        PassThru               = $true
        WorkingDirectory       = $backendRoot
    }
    if ($needsAdmin) {
        $sp['Verb'] = 'RunAs'
        $elevatedTokens = Build-ElevatedBackendCommand -BackendTokens $backendTokens
        $sp['ArgumentList'] = ConvertTo-ArgumentString -Tokens $elevatedTokens
        Write-UiLog -Message ("Backend elevated stream capture enabled inside child process. Stdout={0} Stderr={1}" -f [string]$ui.CurrentStdoutPath, [string]$ui.CurrentStderrPath)
        return (Start-Process @sp)
    }
    if (-not [string]::IsNullOrWhiteSpace($ui.CurrentStdoutPath)) {
        $sp['RedirectStandardOutput'] = [string]$ui.CurrentStdoutPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ui.CurrentStderrPath)) {
        $sp['RedirectStandardError'] = [string]$ui.CurrentStderrPath
    }
    return (Start-Process @sp)
}

function Get-RunStreamTail {
    param(
        [string]$Path,
        [int]$MaxLines = 40
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return '' }
    try {
        $lines = @(Get-Content -Path $Path -ErrorAction Stop)
        if ($lines.Count -eq 0) { return '' }
        $start = [Math]::Max(0, $lines.Count - $MaxLines)
        return (($lines[$start..($lines.Count - 1)] | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    } catch {
        return ("Falha ao ler stream {0}: {1}" -f $Path, $_.Exception.Message)
    }
}

function Write-UiFallbackResult {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$HowToFix = 'Abra stdout/stderr e o log da UI; corrija a falha indicada e execute novamente ou use -Audit para diagnostico.',
        [string]$ExitCode = 'unknown',
        [string]$EmptyStreamHint = ''
    )

    $stdoutTail = Get-RunStreamTail -Path ([string]$ui.CurrentStdoutPath)
    $stderrTail = Get-RunStreamTail -Path ([string]$ui.CurrentStderrPath)
    $finalMessage = [string]$Message
    $streamDetail = if (-not [string]::IsNullOrWhiteSpace($stderrTail)) {
        ($stderrTail -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    } elseif (-not [string]::IsNullOrWhiteSpace($stdoutTail)) {
        ($stdoutTail -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    } else {
        ''
    }
    if (-not [string]::IsNullOrWhiteSpace($streamDetail)) {
        $finalMessage = "{0} stderr/stdout: {1}" -f $finalMessage, $streamDetail
    } elseif (-not [string]::IsNullOrWhiteSpace($EmptyStreamHint)) {
        $finalMessage = "{0} {1}" -f $finalMessage, $EmptyStreamHint
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($ui.CurrentResultPath)) {
            $resultParent = Split-Path -Path $ui.CurrentResultPath -Parent
            if ($resultParent) { $null = New-Item -Path $resultParent -ItemType Directory -Force }
            $fallbackResult = [ordered]@{
                status = 'error'
                mode = 'ui'
                generatedAt = (Get-Date).ToString('o')
                logPath = $ui.CurrentLogPath
                resultPath = $ui.CurrentResultPath
                stdoutPath = $ui.CurrentStdoutPath
                stderrPath = $ui.CurrentStderrPath
                stdoutTail = $stdoutTail
                stderrTail = $stderrTail
                exitCode = $ExitCode
                error = $finalMessage
                howToFix = $HowToFix
                rollbackAvailable = $false
                artifactPaths = [ordered]@{
                    logPath = $ui.CurrentLogPath
                    resultPath = $ui.CurrentResultPath
                    stdoutPath = $ui.CurrentStdoutPath
                    stderrPath = $ui.CurrentStderrPath
                }
                diagnostics = @([ordered]@{
                    severity = 'error'
                    message = $finalMessage
                    howToFix = $HowToFix
                })
                scope = Get-CurrentExecutionScopeSnapshot
                rollback = [ordered]@{
                    available = $false
                    changesPath = ''
                    summary = $null
                }
            }
            $fallbackJson = $fallbackResult | ConvertTo-Json -Depth 8
            [System.IO.File]::WriteAllText($ui.CurrentResultPath, $fallbackJson, [System.Text.UTF8Encoding]::new($false))
        }
    } catch {
        Write-UiLog -Level 'WARN' -Message ("Falha ao escrever fallback result.json: {0}" -f $_.Exception.Message)
    }

    return [pscustomobject]@{
        Message = $finalMessage
        StdoutTail = $stdoutTail
        StderrTail = $stderrTail
    }
}

function Update-UiPendingRebootBanner {
    param([string[]]$Reasons = @())

    try {
        $items = @($Reasons | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $ui.PendingRebootReasons = @($items)
        if ($items.Count -eq 0) {
            if ($ui.PendingRebootBanner) { $ui.PendingRebootBanner.Visibility = 'Collapsed' }
            return
        }
        $summary = if ($items.Count -gt 2) { (($items | Select-Object -First 2) -join ', ') + ', ...' } else { ($items -join ', ') }
        $text = if ([bool]$ui.State.requireNoPendingReboot) {
            [string]::Format([string]$ui.Strings.PendingRebootBannerBlocking, $summary)
        } else {
            [string]::Format([string]$ui.Strings.PendingRebootBanner, $summary)
        }
        if ($ui.PendingRebootBannerLabel) { $ui.PendingRebootBannerLabel.Text = $text }
        if ($ui.PendingRebootBanner) { $ui.PendingRebootBanner.Visibility = 'Visible' }
    } catch {
    }
}

function Update-UiRunStatusPhase {
    param([string]$Phase = '')

    if ([bool]$ui.RunFinalized) { return }
    $p = ([string]$Phase).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    if ([string]$ui.CurrentRunPhase -eq $p) { return }
    $ui.CurrentRunPhase = $p

    $phaseText = ''
    if ($p -eq 'installing') { $phaseText = [string]$ui.Strings.RunPhaseInstalling }
    elseif ($p -eq 'validating') { $phaseText = [string]$ui.Strings.RunPhaseValidating }
    elseif ($p -eq 'running') { $phaseText = [string]$ui.Strings.RunPhaseRunning }

    $base = [string]$ui.Strings.RunStarted
    if (-not [string]::IsNullOrWhiteSpace([string]$ui.CurrentExecutionScopeLabel)) {
        $base = "$base Escopo: $([string]$ui.CurrentExecutionScopeLabel)"
    }
    if (-not [string]::IsNullOrWhiteSpace($phaseText)) {
        $base = "$base $phaseText"
    }
    $ui.RunStatusLabel.Text = $base
}

function Update-UiRunPhaseFromLogChunk {
    param([string]$Text = '')

    if ([bool]$ui.RunFinalized) { return }
    if ([string]::IsNullOrWhiteSpace($Text)) { return }

    $chunk = $Text.ToLowerInvariant()
    if ($chunk -match 'pos-instalacao|artefato esperado|verificado binario') {
        Update-UiRunStatusPhase -Phase 'validating'
        return
    }
    if ($chunk -match 'instalando .* via winget|winget: verificando instalacao|winget install') {
        Update-UiRunStatusPhase -Phase 'installing'
        return
    }
    if ($chunk -match 'executando preflight|executando componente|executando perfil|invokebootstrapp') {
        Update-UiRunStatusPhase -Phase 'running'
        return
    }
}

function Append-RunLog {
    try {
        if ([string]::IsNullOrWhiteSpace($ui.CurrentLogPath) -or -not (Test-Path -LiteralPath $ui.CurrentLogPath)) { return }
        $path = [string]$ui.CurrentLogPath
        $fs = $null
        $reader = $null
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $len = $fs.Length
            if ($len -le [long]$ui.LogOffset) { return }
            if ([long]$ui.LogOffset -gt $len) {
                $ui.LogOffset = 0
                $fs.Position = 0
            } else {
                $fs.Position = [long]$ui.LogOffset
            }
            $reader = New-Object System.IO.StreamReader($fs, [System.Text.UTF8Encoding]::new($false), $true, 8192, $true)
            $newText = $reader.ReadToEnd()
            if (-not [string]::IsNullOrEmpty($newText)) {
                $ui.RunLogTextBox.AppendText($newText)
                $ui.RunLogTextBox.ScrollToEnd()
                Update-UiRunPhaseFromLogChunk -Text $newText
            }
            $ui.LogOffset = [long]$len
        } finally {
            if ($null -ne $reader) { try { $reader.Dispose() } catch { } }
            if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
        }
    } catch {
        try {
            Write-UiLog -Level 'WARN' -Message ("Append-RunLog: {0}" -f $_.Exception.Message)
        } catch {
        }
    }
}

function Set-RunUiBusy {
    param([bool]$Busy)
    if ($Busy) {
        $ui.StartRunButton.IsEnabled = $false
    } else {
        $ui.StartRunButton.IsEnabled = $true
    }
}

function Test-UiBackendResultFileReady {
    param(
        [string]$Path,
        [int]$MaxWaitMs = 3000
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $stepMs = 120
    $waited = 0
    while ($waited -le $MaxWaitMs) {
        try {
            if (Test-Path -LiteralPath $Path) {
                $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($fs.Length -gt 0) { return $true }
                } finally {
                    $fs.Dispose()
                }
            }
        } catch {
        }
        Start-Sleep -Milliseconds $stepMs
        $waited += $stepMs
    }
    return $false
}

function Read-UiBackendResultWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$MaxWaitMs = 3000,
        [int]$StepMs = 120
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'result.json path vazio.' }
    $waited = 0
    $step = [Math]::Max(20, $StepMs)
    $lastError = $null
    while ($waited -le $MaxWaitMs) {
        try {
            if (Test-Path -LiteralPath $Path) {
                $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    return ($raw | ConvertFrom-Json -ErrorAction Stop)
                }
            }
        } catch {
            $lastError = $_
        }
        Start-Sleep -Milliseconds $step
        $waited += $step
    }

    if ($lastError) {
        throw ("result.json invalido ou incompleto apos {0}ms: {1}" -f $MaxWaitMs, $lastError.Exception.Message)
    }
    throw ("result.json ausente ou vazio apos {0}ms: {1}" -f $MaxWaitMs, $Path)
}

function Update-RunArtifactButtons {
    $logPath = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentLogPath)) { [string]$ui.CurrentLogPath } else { [string]$ui.State.lastLogPath }
    $resultPath = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentResultPath)) { [string]$ui.CurrentResultPath } else { [string]$ui.State.lastResultPath }
    $reportPath = [string]$ui.State.lastReportPath
    $ui.OpenLogButton.IsEnabled = (-not [string]::IsNullOrWhiteSpace($logPath) -and (Test-Path -LiteralPath $logPath))
    $ui.OpenResultButton.IsEnabled = (-not [string]::IsNullOrWhiteSpace($resultPath) -and (Test-Path -LiteralPath $resultPath))
    $ui.OpenReportsButton.IsEnabled = (-not [string]::IsNullOrWhiteSpace($reportPath) -and (Test-Path -LiteralPath $reportPath))
}

function Set-RunTimelineStage {
    param(
        [Parameter(Mandatory=$true)][ValidateSet(1,2,3,4,5)][int]$Step,
        [Parameter(Mandatory=$true)][ValidateSet('pending','running','done','error')][string]$State
    )
    $color = switch ($State) {
        'pending' { '#3A405A' }
        'running' { '#F59E0B' }
        'done'    { '#10B981' }
        'error'   { '#EF4444' }
        default   { '#3A405A' }
    }
    $labelColor = switch ($State) {
        'done'    { '#10B981' }
        'running' { '#F59E0B' }
        'error'   { '#EF4444' }
        default   { '#94A3B8' }
    }
    try {
        $dotProp   = "RunTimelineStep${Step}Dot"
        $labelProp = "RunTimelineStep${Step}Label"
        $dot   = $ui.$dotProp
        $label = $ui.$labelProp
        if ($dot)   { $dot.Background   = New-SolidColorBrush $color }
        if ($label) { $label.Foreground = New-SolidColorBrush $labelColor }
    } catch {
    }
}

function Reset-RunTimeline {
    foreach ($s in 1..5) { Set-RunTimelineStage -Step $s -State 'pending' }
}

function New-SolidColorBrush {
    param([Parameter(Mandatory=$true)][string]$Hex)
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    return $b
}

function Complete-RunExecution {
    param([Parameter(Mandatory=$true)][string]$StatusText)
    $ui.RunStatusLabel.Text = $StatusText
    $ui.State.lastLogPath    = Normalize-UiScalarPath -Value $ui.CurrentLogPath
    $ui.State.lastResultPath = Normalize-UiScalarPath -Value $ui.CurrentResultPath
    Save-UiState -State $ui.State -Path $UiStatePath
    $ui.RunFinalized = $true
    $ui.CurrentRunPhase = ''
    $ui.RunProcess = $null
    $ui.LogTimer.Stop()
    $ui.MaintenanceMode = 'none'
    Clear-ExecutionScopeOverride
    Set-RunUiBusy -Busy $false
    Update-RunArtifactButtons
    Set-RunTimelineStage -Step 5 -State 'done'
}

function Complete-RunExecutionWithoutResult {
    Append-RunLog
    $exitCode = 'unknown'
    if ($ui.RunProcess) {
        try { $exitCode = [string]$ui.RunProcess.ExitCode } catch { $exitCode = 'unknown' }
    }
    $message = "{0}  Backend saiu sem result.json. ExitCode={1}. Verifique o log para detalhes." -f $ui.Strings.RunFailed, $exitCode
    $emptyStreamHint = ''
    try {
        if ([bool]$ui.CurrentBackendWasElevated) {
            $emptyStreamHint = 'Processo elevado encerrou antes do backend inicializar; verificar wrapper/elevation/argument binding.'
        }
    } catch {
        $emptyStreamHint = ''
    }
    $fallback = Write-UiFallbackResult -Message $message -ExitCode $exitCode -EmptyStreamHint $emptyStreamHint
    Write-UiLog -Level 'ERROR' -Message ([string]$fallback.Message)
    Complete-RunExecution -StatusText ([string]$fallback.Message)
}

function Get-UiRunStatusTextFromResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Strings
    )

    $values = @{}
    foreach ($property in @($Result.PSObject.Properties)) {
        $values[[string]$property.Name] = $property.Value
    }
    $stringValues = @{}
    foreach ($property in @($Strings.PSObject.Properties)) {
        $stringValues[[string]$property.Name] = $property.Value
    }

    function Get-ResultTextValue {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [string]$Default = ''
        )
        if ($values.ContainsKey($Name) -and $null -ne $values[$Name]) {
            return [string]$values[$Name]
        }
        return $Default
    }

    function Get-ResultBoolValue {
        param([Parameter(Mandatory = $true)][string]$Name)
        if ($values.ContainsKey($Name) -and $null -ne $values[$Name]) {
            return [bool]$values[$Name]
        }
        return $false
    }

    $status = Get-ResultTextValue -Name 'status'
    $mode = Get-ResultTextValue -Name 'mode'
    $runCompleted = if ($stringValues.ContainsKey('RunCompleted')) { [string]$stringValues['RunCompleted'] } else { 'Execução concluída.' }
    $runFailed = if ($stringValues.ContainsKey('RunFailed')) { [string]$stringValues['RunFailed'] } else { 'Execução falhou.' }

    if ($status -eq 'success') {
        if ($mode -eq 'doctor') { return 'Diagnóstico concluído. Abra Resultado para ver verificações, resumo e reparos sugeridos.' }
        if ($mode -eq 'support-bundle') { return 'Pacote de suporte exportado. Abra Resultado para ver o caminho do zip.' }
        if ($mode -eq 'repair-plan') { return 'Lista de reparos gerada. Abra Resultado para revisar as ações.' }
        if ($mode -eq 'partition-labels') { return (Get-UiPartitionLabelSummaryText -Result $Result) }
        return $runCompleted
    } elseif ($status -eq 'warning') {
        if ($mode -eq 'doctor') { return 'Diagnóstico concluído com avisos. Abra Resultado para ver verificações e reparos sugeridos.' }
        if ($mode -eq 'support-bundle') { return 'Pacote de suporte exportado com avisos. Abra Resultado para ver detalhes.' }
        if ($mode -eq 'partition-labels') { return (Get-UiPartitionLabelSummaryText -Result $Result) }
        if ($mode -eq 'audit') {
            $bad = 0
            if ($values.ContainsKey('auditSummary') -and $null -ne $values['auditSummary']) {
                try { $bad = [int]$values['auditSummary'].critical } catch { }
            }
            return "Auditoria concluída com avisos: $bad componente(s) requerem instalação/reparo/ação manual. Ver log e resultado."
        } else {
            return 'Concluido com avisos. Verifique o log.'
        }
    } elseif ($status -eq 'blocked') {
        if ($mode -eq 'partition-labels') { return (Get-UiPartitionLabelSummaryText -Result $Result) }
        $err = Get-ResultTextValue -Name 'error' -Default 'ação do usuário necessária.'
        $fix = Get-ResultTextValue -Name 'howToFix' -Default 'Revise a ação indicada e execute novamente.'
        $kind = Get-ResultTextValue -Name 'blockerKind' -Default 'blocked'
        $action = Get-ResultTextValue -Name 'action'
        $prefix = if ($kind -eq 'pending-reboot-msi' -or $action -eq 'restart-required') { 'Reinício necessário' } else { 'Ação necessária' }
        return "{0}. Bloqueio: {1}. {2} Como corrigir: {3}" -f $prefix, $kind, $err, $fix
    } else {
        $err = Get-ResultTextValue -Name 'error' -Default 'sem detalhes (ver log).'
        $fix = Get-ResultTextValue -Name 'howToFix' -Default 'Abra Resultado/Log para detalhes.'
        $rollbackText = if (Get-ResultBoolValue -Name 'rollbackAvailable') { 'Reversão disponível: Sim.' } else { 'Reversão disponível: Não.' }
        $failedComponent = Get-ResultTextValue -Name 'failedComponent'
        if (-not [string]::IsNullOrWhiteSpace($failedComponent)) { $err = "Componente: $failedComponent. $err" }
        $statusText = "{0}  {1}" -f $runFailed, $err
        return ("{0} Como corrigir: {1} {2}" -f $statusText, $fix, $rollbackText)
    }
}

function Get-UiDeckStatusTextFromResult {
    param([Parameter(Mandatory = $true)]$Result)

    try {
        if (-not ($Result.PSObject.Properties.Name -contains 'doctor')) { return $ui.Strings.HealthDeckStatus }
        if ($null -eq $Result.doctor) { return $ui.Strings.HealthDeckStatus }
        if (-not ($Result.doctor.PSObject.Properties.Name -contains 'deck')) { return $ui.Strings.HealthDeckStatus }
        if ($null -eq $Result.doctor.deck) { return $ui.Strings.HealthDeckStatus }
        $deck = $Result.doctor.deck
        $status = [string]$deck.status
        $label = switch ($status) {
            'healthy' { 'OK' }
            'warning' { 'Atenção' }
            'critical' { 'Crítico' }
            'notDetected' { 'Não detectado' }
            default { $status }
        }
        $summary = ''
        if ($deck.PSObject.Properties.Name -contains 'summary') { $summary = [string]$deck.summary }
        if ([string]::IsNullOrWhiteSpace($summary)) { return "Steam Deck: $label" }
        return "Steam Deck: $label - $summary"
    } catch {
        return $ui.Strings.HealthDeckStatus
    }
}

function Get-UiHealthStatusLabel {
    param([AllowNull()][string]$Status)

    switch ([string]$Status) {
        'healthy' { return 'OK' }
        'success' { return 'OK' }
        'present' { return 'OK' }
        'configured' { return 'OK' }
        'admin' { return 'OK' }
        'notDetected' { return 'Ausente' }
        'missing' { return 'Ausente' }
        'warning' { return 'Atenção' }
        'critical' { return 'Crítico' }
        'error' { return 'Crítico' }
        'corrupt' { return 'Crítico' }
        'blocked' { return 'Bloqueado' }
        default {
            if ([string]::IsNullOrWhiteSpace([string]$Status)) { return 'Ausente' }
            return [string]$Status
        }
    }
}

function Get-UiDoctorCheckById {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Id
    )

    try {
        if (-not ($Result.PSObject.Properties.Name -contains 'doctor')) { return $null }
        if ($null -eq $Result.doctor) { return $null }
        if (-not ($Result.doctor.PSObject.Properties.Name -contains 'checks')) { return $null }
        return @($Result.doctor.checks | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)
    } catch {
        return $null
    }
}

function Get-UiDoctorHumanSummary {
    # Resumo humano (curto) do resultado do diagnóstico para mostrar acima do JSON em ÚLTIMO RESULTADO.
    param(
        [Parameter(Mandatory = $true)]$Result,
        [AllowNull()][string[]]$Scopes = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $scopeText = if (@($Scopes).Count -gt 0) { (@($Scopes) -join ', ') } else { 'all' }
    $overall = ''
    try { $overall = [string]$Result.doctor.status } catch { $overall = '' }
    if ([string]::IsNullOrWhiteSpace($overall)) { try { $overall = [string]$Result.status } catch { $overall = '' } }
    $lines.Add(("Diagnóstico [{0}] -> {1}" -f $scopeText, $(if ([string]::IsNullOrWhiteSpace($overall)) { 'concluído' } else { $overall }))) | Out-Null

    # Destaques por area presente no relatorio.
    foreach ($area in @('agentTools','windowsOptimization','mcp','msvc')) {
        try {
            $section = $Result.doctor.$area
            if ($null -eq $section) { continue }
            if ($area -eq 'agentTools') {
                $lines.Add(("Tokens/memória: {0}. {1}" -f [string]$section.status, [string]$section.summary)) | Out-Null
            } else {
                $lines.Add([string]$section.summary) | Out-Null
            }
        } catch {
            Write-Verbose $_.Exception.Message
        }
    }

    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Get-UiPartitionLabelPlanFromResult {
    param([AllowNull()]$Result)

    $plan = Get-UiObjectValue -Object $Result -Name 'plan'
    if ($null -ne $plan) { return $plan }
    $partitionLabels = Get-UiObjectValue -Object $Result -Name 'partitionLabels'
    return (Get-UiObjectValue -Object $partitionLabels -Name 'plan')
}

function Get-UiPartitionLabelRows {
    param([AllowNull()]$Result)

    $plan = Get-UiPartitionLabelPlanFromResult -Result $Result
    $entries = @(Get-UiObjectArray -Value (Get-UiObjectValue -Object $plan -Name 'entries'))
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $drive = [string](Get-UiObjectValue -Object $entry -Name 'driveLetter')
        if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'sem letra' } else { $drive = ($drive.Trim().TrimEnd(':').ToUpperInvariant() + ':') }
        $reasons = @(Get-UiObjectArray -Value (Get-UiObjectValue -Object $entry -Name 'reasons')) | ForEach-Object { [string]$_ }
        $rows.Add([ordered]@{
            identity = [string](Get-UiObjectValue -Object $entry -Name 'identity')
            drive = $drive
            role = [string](Get-UiObjectValue -Object $entry -Name 'role')
            currentLabel = [string](Get-UiObjectValue -Object $entry -Name 'currentLabel')
            proposedLabel = [string](Get-UiObjectValue -Object $entry -Name 'proposedLabel')
            action = [string](Get-UiObjectValue -Object $entry -Name 'action')
            reasons = ($reasons -join ', ')
        }) | Out-Null
    }
    return @($rows.ToArray())
}

function Get-UiPartitionLabelSummaryText {
    param([AllowNull()]$Result)

    $rows = @(Get-UiPartitionLabelRows -Result $Result)
    $counts = Get-UiObjectValue -Object $Result -Name 'counts'
    $total = [int]$rows.Count
    try {
        $countTotal = Get-UiObjectValue -Object $counts -Name 'total'
        if ($null -ne $countTotal) { $total = [int]$countTotal }
    } catch { $total = [int]$rows.Count }

    $renameable = @($rows | Where-Object { [string]$_.action -eq 'rename' }).Count
    $blocked = @($rows | Where-Object { [string]$_.action -eq 'blocked' }).Count
    $guideOnly = @($rows | Where-Object { [string]$_.action -eq 'guide-only' }).Count
    try {
        $v = Get-UiObjectValue -Object $counts -Name 'renameable'
        if ($null -ne $v) { $renameable = [int]$v }
    } catch { }
    try {
        $v = Get-UiObjectValue -Object $counts -Name 'blocked'
        if ($null -ne $v) { $blocked = [int]$v }
    } catch { }
    try {
        $v = Get-UiObjectValue -Object $counts -Name 'guideOnly'
        if ($null -ne $v) { $guideOnly = [int]$v }
    } catch { }

    $partitionLabels = Get-UiObjectValue -Object $Result -Name 'partitionLabels'
    $planResult = Get-UiObjectValue -Object $partitionLabels -Name 'result'
    $changed = 0
    $skipped = 0
    try { $changed = [int](Get-UiObjectValue -Object $planResult -Name 'changedCount' -Default 0) } catch { $changed = 0 }
    try { $skipped = [int](Get-UiObjectValue -Object $planResult -Name 'skippedCount' -Default 0) } catch { $skipped = 0 }

    $status = [string](Get-UiObjectValue -Object $Result -Name 'status' -Default 'success')
    $applyRequested = ConvertTo-UiBoolean -Value (Get-UiObjectValue -Object $Result -Name 'applyRequested' -Default $false)
    $modeText = if ($applyRequested) { 'aplicação' } else { 'diagnóstico' }
    return ("Drives: {0} particao(oes); {1} renomeavel(is); {2} bloqueada(s); {3} guia/manual; alterados={4}; pulados={5}; modo={6}; status={7}." -f $total, $renameable, $blocked, $guideOnly, $changed, $skipped, $modeText, $status)
}

function Update-UiPartitionLabelsHealthResult {
    param([Parameter(Mandatory = $true)]$Result)

    $summary = Get-UiPartitionLabelSummaryText -Result $Result
    $rows = @(Get-UiPartitionLabelRows -Result $Result)
    try {
        Load-WpfGridRows -Grid $ui.HealthDriveLabelsGrid -Items $rows -Columns @('identity','drive','role','currentLabel','proposedLabel','action','reasons')
    } catch {
        Write-UiLog -Level 'WARN' -Message ("Falha ao atualizar grade de drives: {0}" -f $_.Exception.Message)
    }
    try {
        $ui.HealthDriveLabelsStatusText.Text = $summary
        $canon = switch ([string](Get-UiObjectValue -Object $Result -Name 'status' -Default 'success')) {
            'success' { 'healthy' }
            'warning' { 'warning' }
            'blocked' { 'blocked' }
            'error' { 'critical' }
            default { 'healthy' }
        }
        $ui.HealthDriveLabelsStatusText.Foreground = Get-UiStatusBrush -Status $canon
        $ui.HealthStatusText.Text = $summary
        $json = ($Result | ConvertTo-Json -Depth 8)
        $ui.HealthDoctorTextBox.Text = ($summary + [Environment]::NewLine + [Environment]::NewLine + '--- JSON ---' + [Environment]::NewLine + $json)
    } catch {
        Write-UiLog -Level 'WARN' -Message ("Falha ao atualizar resumo de drives: {0}" -f $_.Exception.Message)
    }
}

function Set-UiHealthCardsEnabled {
    # Liga/desliga todos os cards de saude clicaveis (evita cliques concorrentes durante um run).
    param([bool]$Enabled)
    foreach ($name in @('HealthWslCard','HealthWingetCard','HealthRebootCard','HealthSecretsCard',
                        'HealthGithubCard','HealthAiUsagebarCard','HealthAiMemoryCard','HealthAionUiCard',
                        'HealthDeckCard','HealthRollbackCard')) {
        try { if ($ui.ContainsKey($name) -and $null -ne $ui[$name]) { $ui[$name].IsEnabled = $Enabled } } catch { Write-Verbose $_.Exception.Message }
    }
}

function Invoke-UiHealthScopedDoctor {
    # Handler compartilhado dos cards: valida somente o escopo do card clicado, permanecendo na tela
    # Saúde. Mostra "verificando...", desabilita os cards
    # e dispara o diagnóstico scoped; o handler de conclusão atualiza só o card e o ÚLTIMO RESULTADO.
    # O run continua produzindo log/result.json (artefatos preservados), apenas sem trocar de pagina.
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [AllowNull()]$StatusTextBlock = $null
    )
    try {
        if ($null -ne $StatusTextBlock) {
            $StatusTextBlock.Text = 'verificando...'
            $StatusTextBlock.Foreground = Get-UiBrush '#FBBF24'
        }
    } catch { Write-Verbose $_.Exception.Message }
    $ui.DoctorScopeCard = $Scope
    Set-UiHealthCardsEnabled -Enabled $false
    $ui.StatusLabel.Text = ("Saúde: validando '{0}'..." -f $Scope)
    Start-RunExecution -MaintenanceIntent 'doctor' -DoctorScope $Scope
}

function Update-UiHealthDriveLabelsApplyButton {
    try {
        $ui.HealthDriveLabelsApplyButton.IsEnabled = [bool]$ui.HealthDriveLabelsAdvancedCheck.IsChecked
    } catch {
        Write-Verbose $_.Exception.Message
    }
}

function Invoke-UiHealthPartitionLabels {
    if ($ui.RunProcess -and -not $ui.RunProcess.HasExited) {
        $ui.StatusLabel.Text = 'Aguarde a execução atual finalizar antes de diagnosticar drives.'
        return
    }
    try {
        $ui.HealthDriveLabelsStatusText.Text = 'Drives: diagnosticando discos e partições...'
        $ui.HealthDriveLabelsStatusText.Foreground = Get-UiBrush '#FBBF24'
    } catch { Write-Verbose $_.Exception.Message }
    $ui.StatusLabel.Text = 'Saúde: diagnosticando drives/partições...'
    Start-RunExecution -MaintenanceIntent 'partition-labels'
}

function Invoke-UiHealthPartitionLabelsApply {
    if ($ui.RunProcess -and -not $ui.RunProcess.HasExited) {
        $ui.StatusLabel.Text = 'Aguarde a execução atual finalizar antes de aplicar rótulos.'
        return
    }
    if (-not [bool]$ui.HealthDriveLabelsAdvancedCheck.IsChecked) {
        $ui.StatusLabel.Text = 'Rótulos de drives: marque Modo avançado antes de aplicar.'
        [void][System.Windows.MessageBox]::Show('Marque Modo avançado, rode o diagnóstico e revise a grade antes de aplicar rótulos.', 'Bootstrap UI - Drives', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $message = @(
        'Aplicar rótulos pedagógicos somente em volumes Windows de dados elegíveis.'
        ''
        'Bloqueios mantidos: EFI, Recovery, Windows do sistema, Linux/SteamOS, removíveis e partições sem letra.'
        'O backend também exige PHASEZERO_PARTITION_LABEL_APPLY=1 nesta execução.'
        ''
        'Digite o token para confirmar.'
    ) -join [Environment]::NewLine
    if (-not (Confirm-UiCriticalAction -Title 'Aplicar rótulos de drives' -Message $message -RequiredToken 'APLICAR ROTULOS')) {
        $ui.StatusLabel.Text = 'Aplicação de rótulos cancelada.'
        return
    }

    $previous = $env:PHASEZERO_PARTITION_LABEL_APPLY
    try {
        $env:PHASEZERO_PARTITION_LABEL_APPLY = '1'
        $ui.StatusLabel.Text = 'Saúde: aplicando rótulos seguros nos drives elegíveis...'
        Start-RunExecution -MaintenanceIntent 'partition-labels-apply'
    } finally {
        if ($null -ne $previous) {
            $env:PHASEZERO_PARTITION_LABEL_APPLY = $previous
        } else {
            Remove-Item Env:\PHASEZERO_PARTITION_LABEL_APPLY -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-UiHealthAgentToolsRepair {
    # Reparo seguro de tokens/memória: valida em processo, gera plano limitado ao grupo,
    # exige confirmação com a lista exata e aplica cada item pelo seu fluxo real.
    # Nenhum segredo é gravado; blocos Caveman/RTK/ai-memory/Ponytail não são sobrescritos.
    if ($ui.RunProcess -and -not $ui.RunProcess.HasExited) {
        $ui.StatusLabel.Text = 'Aguarde a execução atual finalizar antes de reparar tokens/memória.'
        return
    }

    # 1) Validacao + plano scoped, em processo (a UI carrega o backend em library mode).
    $report = $null
    $items = @()
    try {
        $report = New-BootstrapAgentToolsDoctorReport
        # checks/auditResults vazios evitam que o loop compartilhado do RepairPlan itere sobre $null.
        $plan = New-BootstrapRepairPlan -DoctorReport ([ordered]@{ agentTools = $report; checks = @(); auditResults = @() })
        $items = @($plan.items | Where-Object { [string]$_.id -like 'repair-agent-*' })
    } catch {
        $ui.StatusLabel.Text = ("Falha ao gerar plano de tokens/memória: {0}" -f $_.Exception.Message)
        return
    }
    if (@($items).Count -eq 0) {
        $ui.StatusLabel.Text = 'Tokens/memória: tudo configurado, nada a reparar.'
        return
    }

    # 2) Confirmacao com a lista exata de itens (e seus fluxos).
    $lines = @($items | ForEach-Object { ("- {0}  [{1}]  -> {2}" -f [string]$_.target, [string]$_.repairKind, [string]$_.executeCommand) })
    $msg = @(
        'Aplicar reparo de tokens/memória nos itens não configurados abaixo.'
        ''
    ) + $lines + @(
        ''
        'Nenhum segredo é gravado; itens sem reparo seguro ficam só como orientação; blocos existentes não são sobrescritos.'
        'Continuar?'
    )
    if (-not (Confirm-UiCriticalAction -Title 'Reparar tokens/memória' -Message ($msg -join [Environment]::NewLine))) {
        $ui.StatusLabel.Text = 'Reparo de tokens/memória cancelado.'
        return
    }

    # 3) Aplica os itens reparáveis, sempre produzindo result.json/log.
    $components = @($items | Where-Object { [string]$_.repairKind -eq 'component' -and -not [string]::IsNullOrWhiteSpace([string]$_.target) } | ForEach-Object { [string]$_.target })
    $appTuning  = @($items | Where-Object { [string]$_.repairKind -eq 'app-tuning' } | ForEach-Object { [string]$_.target })
    $aiTools    = @($items | Where-Object { [string]$_.repairKind -eq 'ai-tool' } | ForEach-Object { [string]$_.target })

    $launched = New-Object System.Collections.Generic.List[string]
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    if (@($components).Count -gt 0 -or @($appTuning).Count -gt 0) {
        $artifacts = New-UiRunArtifactSet -Timestamp $timestamp
        $ui.CurrentLogPath = [string]$artifacts.LogPath
        $ui.CurrentResultPath = [string]$artifacts.ResultPath
        $tokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backendScriptPath, '-NonInteractive')
        if (@($components).Count -gt 0) { $tokens += @('-Component') + @($components) }
        if (@($appTuning).Count -gt 0) { $tokens += @('-AppTuningItem') + @($appTuning) }
        $tokens += @('-LogPath', [string]$artifacts.LogPath, '-ResultPath', [string]$artifacts.ResultPath)
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $psExe -ArgumentList (ConvertTo-ArgumentString -Tokens $tokens) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
        $launched.Add(("componentes/apptuning -> {0}" -f [string]$artifacts.ResultPath)) | Out-Null
    }

    foreach ($tool in @($aiTools)) {
        $aiArtifacts = New-UiRunArtifactSet -Timestamp ("{0}-{1}" -f $timestamp, $tool)
        $installCli = Join-Path $PSScriptRoot 'install-cli.bat'
        $aiArgs = @('--tool', $tool, '--install', '--yes', '--result-path', [string]$aiArtifacts.ResultPath, '--log-path', [string]$aiArtifacts.LogPath)
        Start-Process -FilePath $installCli -ArgumentList (ConvertTo-ArgumentString -Tokens $aiArgs) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
        $launched.Add(("{0} -> {1}" -f $tool, [string]$aiArtifacts.ResultPath)) | Out-Null
    }

    Update-RunArtifactButtons
    $ui.StatusLabel.Text = ("Reparo de tokens/memória iniciado ({0} ação(ões)). Artefatos: {1}" -f @($launched).Count, (@($launched) -join '; '))
}

function Get-UiHealthCardStatusText {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Card
    )

    try {
        $cardName = ([string]$Card).ToLowerInvariant()
        if (-not ($Result.PSObject.Properties.Name -contains 'doctor') -or $null -eq $Result.doctor) {
            return ("{0}: Ausente" -f $Card)
        }
        $doctor = $Result.doctor
        switch ($cardName) {
            'wsl' {
                $wsl = $null
                if ($doctor.PSObject.Properties.Name -contains 'wslRepair') { $wsl = $doctor.wslRepair }
                if ($null -eq $wsl) { $wsl = Get-UiDoctorCheckById -Result $Result -Id 'wsl' }
                if ($null -eq $wsl) { return 'WSL: Ausente' }
                $label = Get-UiHealthStatusLabel -Status ([string]$wsl.status)
                $detail = if ($wsl.PSObject.Properties.Name -contains 'corruptionKind') { [string]$wsl.corruptionKind } elseif ($wsl.PSObject.Properties.Name -contains 'summary') { [string]$wsl.summary } else { '' }
                if ([string]::IsNullOrWhiteSpace($detail)) { return "WSL: $label" }
                return "WSL: $label - $detail"
            }
            'winget' {
                $check = Get-UiDoctorCheckById -Result $Result -Id 'winget'
                if ($null -eq $check) { return 'winget: Ausente' }
                return ("winget: {0} - {1}" -f (Get-UiHealthStatusLabel -Status ([string]$check.status)), [string]$check.summary)
            }
            'reboot' {
                $check = Get-UiDoctorCheckById -Result $Result -Id 'pending-reboot'
                if ($null -eq $check) { return 'Reinício: OK' }
                return ("Reinício: {0} - {1}" -f (Get-UiHealthStatusLabel -Status ([string]$check.status)), [string]$check.summary)
            }
            'secrets' {
                if ($doctor.PSObject.Properties.Name -contains 'secrets' -and $null -ne $doctor.secrets) {
                    $bad = @($doctor.secrets.providers | Where-Object { [string]$_.status -in @('missing','rejected','expired','unknown') })
                    if ($bad.Count -eq 0) { return 'Chaves: OK' }
                    return ("Chaves: Atenção - {0} provedor(es) precisam de ação" -f $bad.Count)
                }
                $check = Get-UiDoctorCheckById -Result $Result -Id 'secrets'
                if ($null -eq $check) { return 'Chaves: Ausente' }
                return ("Chaves: {0} - {1}" -f (Get-UiHealthStatusLabel -Status ([string]$check.status)), [string]$check.summary)
            }
            'ai-usagebar' {
                if ($doctor.PSObject.Properties.Name -contains 'aiUsagebar' -and $null -ne $doctor.aiUsagebar) {
                    $ai = $doctor.aiUsagebar
                    $ok = ([bool]$ai.installed -and [bool]$ai.configured)
                    $label = if ($ok) { 'OK' } else { 'Ausente' }
                    $vendor = if ($ai.PSObject.Properties.Name -contains 'primaryVendor') { [string]$ai.primaryVendor } else { '' }
                    if ([string]::IsNullOrWhiteSpace($vendor)) { return "ai-usagebar: $label" }
                    return "ai-usagebar: $label - $vendor"
                }
                return 'ai-usagebar: Ausente'
            }
            'ai-memory' {
                if ($doctor.PSObject.Properties.Name -contains 'aiMemory' -and $null -ne $doctor.aiMemory) {
                    $mem = $doctor.aiMemory
                    if (-not [bool]$mem.installed) { return 'ai-memory: Ausente' }
                    $server = if ([bool]$mem.serverReachable) { 'servidor ativo' } else { 'servidor parado' }
                    $label = if ([bool]$mem.configured) { 'OK' } else { 'Instalado' }
                    $sync = ''
                    if ([bool]$mem.sdCardFound) {
                        $last = if (-not [string]::IsNullOrWhiteSpace([string]$mem.lastSync)) { " ultimo sync=$([string]$mem.lastSync)" } else { '' }
                        $sync = " SDCard$last"
                    }
                    return "ai-memory: $label - $server$sync"
                }
                return 'ai-memory: Ausente'
            }
            'aionui' {
                if ($doctor.PSObject.Properties.Name -contains 'aionui' -and $null -ne $doctor.aionui) {
                    $aion = $doctor.aionui
                    if (-not [bool]$aion.installed) { return 'AionUI: Ausente' }
                    $configured = @()
                    $rejected = @()
                    if ($aion.PSObject.Properties.Name -contains 'providersConfigured') { $configured = @($aion.providersConfigured) }
                    if ($aion.PSObject.Properties.Name -contains 'providersRejected') { $rejected = @($aion.providersRejected) }
                    if ($rejected.Count -gt 0) { return ("AionUI: Atenção - {0}" -f (($rejected | Select-Object -First 3) -join ', ')) }
                    if ($configured.Count -gt 0) { return ("AionUI: OK - {0}" -f (($configured | Select-Object -First 3) -join ', ')) }
                    return 'AionUI: Atenção - sem providers'
                }
                return 'AionUI: Ausente'
            }
            'rollback' {
                $check = Get-UiDoctorCheckById -Result $Result -Id 'rollback-gate'
                if ($null -eq $check) { return 'Reversão: Ausente' }
                return ("Reversão: {0} - {1}" -f (Get-UiHealthStatusLabel -Status ([string]$check.status)), [string]$check.summary)
            }
            default { return ("{0}: Ausente" -f $Card) }
        }
    } catch {
        return ("{0}: Ausente" -f $Card)
    }
}

function Get-UiGithubCliStatusTextFromResult {
    param([Parameter(Mandatory = $true)]$Result)

    try {
        if (-not ($Result.PSObject.Properties.Name -contains 'doctor')) { return $ui.Strings.HealthGithubStatus }
        if ($null -eq $Result.doctor) { return $ui.Strings.HealthGithubStatus }
        $github = $null
        if ($Result.doctor.PSObject.Properties.Name -contains 'githubCliAuth') {
            $github = $Result.doctor.githubCliAuth
        }
        if ($null -eq $github -and ($Result.doctor.PSObject.Properties.Name -contains 'checks')) {
            $github = @($Result.doctor.checks | Where-Object { [string]$_.id -eq 'github-cli-auth' } | Select-Object -First 1)
        }
        if ($null -eq $github) { return $ui.Strings.HealthGithubStatus }

        $status = [string]$github.status
        $authStatus = if ($github.PSObject.Properties.Name -contains 'ghAuthStatus') { [string]$github.ghAuthStatus } else { '' }
        $tokenAvailable = $false
        if ($github.PSObject.Properties.Name -contains 'tokenAvailable') { $tokenAvailable = [bool]$github.tokenAvailable }
        $label = switch ($status) {
            'healthy' { 'OK' }
            'missing' { 'gh ausente' }
            'critical' { 'Crítico' }
            'warning' { if ($tokenAvailable) { 'Token disponível' } else { 'Sem autenticação' } }
            default { if ([string]::IsNullOrWhiteSpace($authStatus)) { $status } else { $authStatus } }
        }
        $summary = ''
        if ($github.PSObject.Properties.Name -contains 'summary') { $summary = [string]$github.summary }
        if ([string]::IsNullOrWhiteSpace($summary)) { return "GitHub CLI: $label" }
        return "GitHub CLI: $label - $summary"
    } catch {
        return $ui.Strings.HealthGithubStatus
    }
}

function Finalize-RunFromResult {
    Append-RunLog
    $resultPath = [string]$ui.CurrentResultPath
    try {
        $result = Read-UiBackendResultWithRetry -Path $resultPath
    } catch {
        if (-not (Test-UiBackendResultFileReady -Path $resultPath -MaxWaitMs 0)) {
            Complete-RunExecutionWithoutResult
            return
        }
        Complete-RunExecution -StatusText ("{0}  result.json invalido: {1}" -f $ui.Strings.RunFailed, $_.Exception.Message)
        return
    }
    if ([string]$result.status -eq 'success') {
        $resultProperties = @($result.PSObject.Properties.Name)
        if (($resultProperties -contains 'hostHealthReportRoot') -and -not [string]::IsNullOrWhiteSpace([string]$result.hostHealthReportRoot)) {
            $ui.State.lastReportPath = [string]$result.hostHealthReportRoot
        }
        if (($resultProperties -contains 'appTuningReportRoot') -and -not [string]::IsNullOrWhiteSpace([string]$result.appTuningReportRoot)) {
            $ui.State.lastReportPath = [string]$result.appTuningReportRoot
        }
    }
    try {
        $pending = @()
        $pending = @(Get-UiPendingRebootReasons)
        Update-UiPendingRebootBanner -Reasons $pending
    } catch {
    }
    $statusText = Get-UiRunStatusTextFromResult -Result $result -Strings $ui.Strings
    try {
        $modeText = [string]$result.mode
        if ($modeText -eq 'partition-labels') {
            Update-UiPartitionLabelsHealthResult -Result $result
        } elseif ($modeText -in @('doctor','support-bundle','repair-plan')) {
            $ui.HealthStatusText.Text = $statusText

            # Escopo do resultado: 'all' (ou ausente) atualiza todos os cards; senao so os pedidos.
            $resultScopes = @()
            try { $resultScopes = @($result.doctor.scopes) } catch { $resultScopes = @() }
            if (@($resultScopes).Count -eq 0) { try { $resultScopes = @($result.scopes) } catch { $resultScopes = @() } }
            $scopeIsAll = ((@($resultScopes).Count -eq 0) -or (@($resultScopes) -contains 'all'))
            $cardMap = @(
                @{ Scope = 'wsl';         Tb = $ui.HealthWslStatusText;        Card = 'wsl' },
                @{ Scope = 'winget';      Tb = $ui.HealthWingetStatusText;     Card = 'winget' },
                @{ Scope = 'reboot';      Tb = $ui.HealthRebootStatusText;     Card = 'reboot' },
                @{ Scope = 'secrets';     Tb = $ui.HealthSecretsStatusText;    Card = 'secrets' },
                @{ Scope = 'ai-usagebar'; Tb = $ui.HealthAiUsagebarStatusText; Card = 'ai-usagebar' },
                @{ Scope = 'ai-memory';   Tb = $ui.HealthAiMemoryStatusText;   Card = 'ai-memory' },
                @{ Scope = 'aionui';      Tb = $ui.HealthAionUiStatusText;     Card = 'aionui' },
                @{ Scope = 'rollback';    Tb = $ui.HealthRollbackStatusText;   Card = 'rollback' }
            )
            foreach ($entry in $cardMap) {
                if (-not ($scopeIsAll -or (@($resultScopes) -contains [string]$entry.Scope))) { continue }
                $tb = $entry.Tb
                if ($null -eq $tb) { continue }
                $tb.Text = Get-UiHealthCardStatusText -Result $result -Card ([string]$entry.Card)
                $canon = Get-UiHealthTextCanonicalStatus -Text ([string]$tb.Text)
                if (-not [string]::IsNullOrWhiteSpace($canon)) { $tb.Foreground = Get-UiStatusBrush -Status $canon } else { $tb.Foreground = Get-UiBrush '#CBD5E1' }
            }
            if ($scopeIsAll -or (@($resultScopes) -contains 'steamdeck')) {
                $ui.HealthDeckStatusText.Text = Get-UiDeckStatusTextFromResult -Result $result
                $canon = Get-UiHealthTextCanonicalStatus -Text ([string]$ui.HealthDeckStatusText.Text)
                if (-not [string]::IsNullOrWhiteSpace($canon)) { $ui.HealthDeckStatusText.Foreground = Get-UiStatusBrush -Status $canon } else { $ui.HealthDeckStatusText.Foreground = Get-UiBrush '#CBD5E1' }
            }
            if ($scopeIsAll -or (@($resultScopes) -contains 'github')) {
                $ui.HealthGithubStatusText.Text = Get-UiGithubCliStatusTextFromResult -Result $result
                $canon = Get-UiHealthTextCanonicalStatus -Text ([string]$ui.HealthGithubStatusText.Text)
                if (-not [string]::IsNullOrWhiteSpace($canon)) { $ui.HealthGithubStatusText.Foreground = Get-UiStatusBrush -Status $canon } else { $ui.HealthGithubStatusText.Foreground = Get-UiBrush '#CBD5E1' }
            }

            # ULTIMO RESULTADO: resumo humano primeiro, JSON completo abaixo.
            $human = Get-UiDoctorHumanSummary -Result $result -Scopes $resultScopes
            $json = ($result | ConvertTo-Json -Depth 8)
            $ui.HealthDoctorTextBox.Text = ($human + [Environment]::NewLine + [Environment]::NewLine + '--- JSON ---' + [Environment]::NewLine + $json)
        }
    } catch {
    }
    # Reabilita os cards de saude apos a verificacao (scoped ou completa).
    try { Set-UiHealthCardsEnabled -Enabled $true; $ui.DoctorScopeCard = '' } catch { Write-UiLog -Level 'WARN' -Message ("reset health cards: {0}" -f $_.Exception.Message) }
    Complete-RunExecution -StatusText $statusText
}

function Test-UiReviewAcceptedForRun {
    param([string]$MaintenanceIntent = 'none')

    if ([string]$MaintenanceIntent -ne 'none') { return $true }
    return [bool]$ui.ReviewAcceptedCheckBox.IsChecked
}

function Confirm-UiCriticalAction {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$RequiredToken = ''
    )

    if ([string]::IsNullOrWhiteSpace($RequiredToken)) {
        $choice = [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        return ($choice -eq [System.Windows.MessageBoxResult]::Yes)
    }

    $dialog = New-Object System.Windows.Window
    $dialog.Title = $Title
    $dialog.Width = 520
    $dialog.Height = 250
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Owner = $ui.Window
    $dialog.Background = Get-UiBrush '#0F1117'
    $dialog.Foreground = Get-UiBrush '#E2E8F0'
    $dialog.ResizeMode = 'NoResize'

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(18)

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Message
    $label.TextWrapping = 'Wrap'
    $label.Margin = New-Object System.Windows.Thickness(0,0,0,12)
    $root.Children.Add($label) | Out-Null

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = "Digite $RequiredToken para confirmar."
    $hint.Foreground = Get-UiBrush '#F59E0B'
    $hint.Margin = New-Object System.Windows.Thickness(0,0,0,6)
    $root.Children.Add($hint) | Out-Null

    $input = New-Object System.Windows.Controls.TextBox
    $input.Height = 32
    $input.Margin = New-Object System.Windows.Thickness(0,0,0,14)
    $root.Children.Add($input) | Out-Null

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $cancel = New-Object System.Windows.Controls.Button
    $cancel.Content = 'Cancelar'
    $cancel.Width = 100
    $cancel.Height = 32
    $cancel.Margin = New-Object System.Windows.Thickness(0,0,8,0)
    $ok = New-Object System.Windows.Controls.Button
    $ok.Content = 'Confirmar'
    $ok.Width = 110
    $ok.Height = 32
    $buttons.Children.Add($cancel) | Out-Null
    $buttons.Children.Add($ok) | Out-Null
    $root.Children.Add($buttons) | Out-Null

    $script:CriticalActionConfirmed = $false
    $cancel.Add_Click({ $dialog.DialogResult = $false; $dialog.Close() })
    $ok.Add_Click({
        if ($input.Text.Trim() -eq $RequiredToken) {
            $script:CriticalActionConfirmed = $true
            $dialog.DialogResult = $true
            $dialog.Close()
        } else {
            [void][System.Windows.MessageBox]::Show("Confirmação inválida. Digite $RequiredToken.", 'Bootstrap UI - Ação crítica', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        }
    })
    [void]$dialog.ShowDialog()
    return [bool]$script:CriticalActionConfirmed
}

function Start-RunExecution {
    param(
        [ValidateSet('none', 'audit', 'rollback', 'doctor', 'support-bundle', 'repair-plan', 'partition-labels', 'partition-labels-apply')]
        [string]$MaintenanceIntent = 'none',
        [string]$DoctorScope = 'all'
    )
    # Define o escopo do Doctor para este run; default 'all' preserva o comportamento legado.
    if ([string]::IsNullOrWhiteSpace($DoctorScope)) { $DoctorScope = 'all' }
    $ui.DoctorScope = $DoctorScope
    if ($ui.RunProcess -and -not $ui.RunProcess.HasExited) {
        $ui.RunStatusLabel.Text = "$($ui.Strings.RunStarted) Aguarde a execução atual finalizar."
        return
    }
    if (-not (Test-UiReviewAcceptedForRun -MaintenanceIntent $MaintenanceIntent)) {
        $reviewIdx = @($ui.PageNames).IndexOf('PageReview')
        if ($reviewIdx -ge 0) { Navigate-ToPage -Index $reviewIdx }
        $ui.StatusLabel.Text = 'Revisão obrigatória: aceite a revisão antes de executar.'
        [void][System.Windows.MessageBox]::Show('Revisão obrigatória: confira escopo, efeitos colaterais e artefatos, marque "Aceito esta revisão" e execute novamente.', 'Bootstrap UI - Revisão obrigatória', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    $ui.MaintenanceMode = [string]$MaintenanceIntent
    if (-not (Save-SteamDeckSettingsInteractive)) {
        $ui.MaintenanceMode = 'none'
        return
    }
    if (-not (Confirm-UiExecutionScope -MaintenanceIntent $MaintenanceIntent)) {
        $ui.MaintenanceMode = 'none'
        Clear-ExecutionScopeOverride
        return
    }

    try {
        Write-UiLog -Message ("Start-RunExecution. MaintenanceIntent={0}" -f [string]$MaintenanceIntent)
        Refresh-ReviewPage
        $timestamp           = Get-Date -Format 'yyyyMMdd_HHmmss'
        $artifacts = New-UiRunArtifactSet -Timestamp $timestamp
        $ui.CurrentLogPath   = [string]$artifacts.LogPath
        $ui.CurrentResultPath = [string]$artifacts.ResultPath
        $ui.CurrentStdoutPath = [string]$artifacts.StdoutPath
        $ui.CurrentStderrPath = [string]$artifacts.StderrPath
        $ui.CurrentBackendWasElevated = $false
        $ui.LogOffset        = 0
        $ui.RunFinalized     = $false
        $ui.CurrentRunPhase  = ''
        $ui.RunLogTextBox.Clear()
        Reset-RunTimeline
        Set-RunTimelineStage -Step 1 -State 'running'
        try {
            $pending = @(Get-UiPendingRebootReasons)
            Update-UiPendingRebootBanner -Reasons $pending
        } catch {
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$ui.CurrentExecutionScopeLabel)) {
            $ui.RunStatusLabel.Text = "$($ui.Strings.RunStarted) Escopo: $([string]$ui.CurrentExecutionScopeLabel)"
            Write-UiLog -Message ("Escopo de execução selecionado: {0}" -f [string]$ui.CurrentExecutionScopeLabel)
        } else {
            $ui.RunStatusLabel.Text = $ui.Strings.RunStarted
        }
        Update-UiRunStatusPhase -Phase 'running'
        Update-RunArtifactButtons
        Set-RunUiBusy -Busy $true
        try {
            $ui.RunProcess = Start-BackendWorker
        } catch {
            $startError = [string]$_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($startError)) { $startError = 'falha ao iniciar processo backend' }
            $fallback = Write-UiFallbackResult -Message ("Falha ao iniciar backend: {0}" -f $startError) -HowToFix 'Abra o log da UI, valide PowerShell/paths/permissao e execute novamente.' -ExitCode 'not-started'
            Write-UiLog -Level 'ERROR' -Message ([string]$fallback.Message)
            $ui.RunStatusLabel.Text = [string]$fallback.Message
            $ui.MaintenanceMode = 'none'
            Clear-ExecutionScopeOverride
            Set-RunUiBusy -Busy $false
            Update-RunArtifactButtons
            Set-RunTimelineStage -Step 1 -State 'error'
            return
        }
    } catch {
        try { Write-UiLog -Level 'ERROR' -Message ("Start-RunExecution: {0}" -f (($_ | Out-String).Trim())) } catch { }
        $ui.MaintenanceMode = 'none'
        Clear-ExecutionScopeOverride
        try { Set-RunUiBusy -Busy $false } catch { }
        $msg = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'Erro ao preparar a execução.' }
        $ui.RunStatusLabel.Text = ('Falha ao preparar execução: {0}' -f $msg)
        try {
            [void][System.Windows.MessageBox]::Show($msg, 'Bootstrap UI', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        } catch {
        }
        return
    }

    Save-UiState -State $ui.State -Path $UiStatePath
    Set-RunTimelineStage -Step 1 -State 'done'
    Set-RunTimelineStage -Step 2 -State 'running'
    Set-RunTimelineStage -Step 3 -State 'running'
    Set-RunTimelineStage -Step 4 -State 'pending'
    $ui.LogTimer.Start()
}

#
# Event Handlers
#

# Log timer
$logTimer.Add_Tick({
    try {
        Append-RunLog
        if ($ui.RunProcess -and $ui.RunProcess.HasExited) {
            Set-RunTimelineStage -Step 2 -State 'done'
            Set-RunTimelineStage -Step 3 -State 'done'
            if (Test-UiBackendResultFileReady -Path ([string]$ui.CurrentResultPath)) {
                Set-RunTimelineStage -Step 4 -State 'running'
                Finalize-RunFromResult
            } else {
                Set-RunTimelineStage -Step 4 -State 'error'
                Complete-RunExecutionWithoutResult
            }
        } else {
            if ($ui.RunProcess -and -not $ui.RunProcess.HasExited) {
                if (Test-UiBackendResultFileReady -Path ([string]$ui.CurrentResultPath)) {
                    Set-RunTimelineStage -Step 4 -State 'done'
                }
            }
        }
    } catch {
        try {
            Write-UiLog -Level 'ERROR' -Message ("LogTimer tick: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        } catch {
        }
        try {
            if (Test-UiBackendResultFileReady -Path ([string]$ui.CurrentResultPath)) {
                Finalize-RunFromResult
                return
            }
        } catch {
            $null = $_
        }
        try {
            if ($ui.RunProcess -and $ui.RunProcess.HasExited) {
                Complete-RunExecutionWithoutResult
                return
            }
        } catch {
            $null = $_
        }
        try {
            if ($null -ne $ui -and $null -ne $ui.RunStatusLabel) {
                $ui.RunStatusLabel.Text = 'Erro ao atualizar log da execução; veja ui.log (LogTimer).'
            }
        } catch {
        }
        # Failsafe: nunca deixar a UI presa em estado busy quando o tick aborta sem
        # conseguir finalizar pelo result.json nem pelo processo. Restaura os mesmos
        # invariantes de Complete-RunExecution antes de parar o timer.
        try { $ui.RunProcess = $null } catch { }
        try { $ui.MaintenanceMode = 'none' } catch { }
        try { Clear-ExecutionScopeOverride } catch { }
        try { Set-RunUiBusy -Busy $false } catch { }
        try { Update-RunArtifactButtons } catch { }
        try { $ui.LogTimer.Stop() } catch { }
    }
})

$appTuningRefreshTimer.Add_Tick({
    try {
        $ui.AppTuningRefreshTimer.Stop()
        Refresh-AppTuningControls
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("AppTuningRefreshTimer: {0}" -f $_.Exception.Message)
    }
})

# Language
$ui.LanguageCombo.Add_SelectionChanged({
    if ($ui.LanguageCombo.SelectedItem) {
        $ui.State.language = [string]$ui.LanguageCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-LocalizedText
        Navigate-ToPage -Index $ui.CurrentPageIndex
    }
})

# API Center
$ui.ApiProviderCombo.Add_SelectionChanged({
    if ($ui.SuppressApiEvents) { return }
    if ($ui.ApiProviderCombo.SelectedItem) {
        Refresh-ApiProviderCombos
    }
})

$ui.ApiCredentialCombo.Add_SelectionChanged({
    if ($ui.SuppressApiEvents) { return }
    Refresh-ApiCredentialEditor
})

$ui.ApiCredentialGrid.Add_SelectionChanged({
    if ($ui.SuppressApiEvents) { return }
    if ($ui.ApiCredentialGrid.SelectedItem -and $ui.ApiCredentialGrid.SelectedItem.Row) {
        $row = $ui.ApiCredentialGrid.SelectedItem.Row
        $providerId = [string]$row['provider']
        $credentialId = [string]$row['id']
        if (-not [string]::IsNullOrWhiteSpace($providerId)) {
            $ui.ApiProviderCombo.SelectedItem = $providerId
        }
        if (-not [string]::IsNullOrWhiteSpace($credentialId)) {
            $ui.ApiCredentialCombo.SelectedItem = $credentialId
        }
        Refresh-ApiCredentialEditor
    }
})

function Get-UiSelectedComponentName {
    try {
        $sel = $ui.ComponentsTree.SelectedItem
        if ($sel -and $sel.Tag -and $sel.Tag.item -and $sel.Tag.item.PSObject.Properties.Name -contains 'name') {
            return [string]$sel.Tag.item.name
        }
    } catch { }
    return ''
}

function Select-UiFolderDialog {
    param([string]$Description = 'Selecione a pasta')
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.BrowseForFolder(0, $Description, 0, 0)
        if ($folder -and $folder.Self -and $folder.Self.Path) { return [string]$folder.Self.Path }
    } catch { }
    return ''
}

function Start-UiConfigCli {
    # Re-spawn install-cli.ps1 com flags de ciclo de vida, oculto e nao-interativo.
    param([Parameter(Mandatory = $true)][string[]]$CliArgs)
    try {
        $cli = Join-Path $PSScriptRoot 'install-cli.ps1'
        $psExe = Get-WindowsPowerShellExePath
        $tokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cli) + @($CliArgs) + @('--yes', '--no-admin')
        Start-Process -FilePath $psExe -ArgumentList (ConvertTo-ArgumentString -Tokens $tokens) -WorkingDirectory $PSScriptRoot | Out-Null
        return $true
    } catch {
        [System.Windows.MessageBox]::Show(("Falha ao iniciar acao: {0}" -f $_.Exception.Message), 'PhaseZero') | Out-Null
        return $false
    }
}

function Invoke-UiItemConfigAction {
    param([Parameter(Mandatory = $true)][string]$Action)
    $name = Get-UiSelectedComponentName
    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.MessageBox]::Show('Selecione um componente na arvore primeiro.', 'PhaseZero', 'OK', 'Information') | Out-Null
        return
    }
    switch ($Action) {
        'configure' { if (Start-UiConfigCli -CliArgs @('--item', $name)) { [System.Windows.MessageBox]::Show(("Configurando '{0}' em segundo plano." -f $name), 'PhaseZero') | Out-Null } }
        'factory-reset' {
            $confirm = [System.Windows.MessageBox]::Show(("Reverter '{0}' para o padrao de fabrica? Um backup do estado atual sera criado." -f $name), 'Confirmar', 'YesNo', 'Warning')
            if ($confirm -eq 'Yes') { if (Start-UiConfigCli -CliArgs @('--item', $name, '--factory-reset')) { [System.Windows.MessageBox]::Show(("Revertendo '{0}' em segundo plano." -f $name), 'PhaseZero') | Out-Null } }
        }
        'export' {
            $dir = Select-UiFolderDialog -Description 'Pasta de destino do export'
            if (-not [string]::IsNullOrWhiteSpace($dir)) { if (Start-UiConfigCli -CliArgs @('--item', $name, '--export-config', $dir)) { [System.Windows.MessageBox]::Show(("Exportando '{0}' para {1}." -f $name, $dir), 'PhaseZero') | Out-Null } }
        }
        'import' {
            $dir = Select-UiFolderDialog -Description 'Pasta/bundle de origem do import'
            if (-not [string]::IsNullOrWhiteSpace($dir)) { if (Start-UiConfigCli -CliArgs @('--item', $name, '--import-config', $dir)) { [System.Windows.MessageBox]::Show(("Importando '{0}' de {1}." -f $name, $dir), 'PhaseZero') | Out-Null } }
        }
    }
}

$ui.CfgConfigureButton.Add_Click({ Invoke-UiItemConfigAction -Action 'configure' })
$ui.CfgResetButton.Add_Click({ Invoke-UiItemConfigAction -Action 'factory-reset' })
$ui.CfgExportButton.Add_Click({ Invoke-UiItemConfigAction -Action 'export' })
$ui.CfgImportButton.Add_Click({ Invoke-UiItemConfigAction -Action 'import' })
$ui.CfgBatchResetButton.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show('Reverter para fabrica TODOS os itens amarelos (instalados, nao configurados)? Backups serao criados.', 'Confirmar lote', 'YesNo', 'Warning')
    if ($confirm -eq 'Yes') { if (Start-UiConfigCli -CliArgs @('--batch', 'factory-reset')) { [System.Windows.MessageBox]::Show('Revertendo itens amarelos em segundo plano.', 'PhaseZero') | Out-Null } }
})
$ui.InstallWebappsButton.Add_Click({
    if (Start-UiConfigCli -CliArgs @('--install-webapps')) { [System.Windows.MessageBox]::Show('Instalando todos os Web Apps em segundo plano.', 'PhaseZero') | Out-Null }
})

$ui.ApiRefreshButton.Add_Click({
    Refresh-ApiCenterControls
})

$ui.ApiCatalogButton.Add_Click({
    $pageIds = @(Get-UiPageIds)
    $index = [Array]::IndexOf($pageIds, 'api-catalog')
    if ($index -ge 0) { Navigate-ToPage -Index $index }
})

$ui.ApiCatalogBackButton.Add_Click({
    $pageIds = @(Get-UiPageIds)
    $index = [Array]::IndexOf($pageIds, 'api-center')
    if ($index -ge 0) { Navigate-ToPage -Index $index }
})

$ui.ApiSaveButton.Add_Click({
    try {
        $providerId = Get-SelectedApiProviderId
        if ([string]::IsNullOrWhiteSpace($providerId)) { return }
        $fields = @{
            baseUrl = $ui.ApiBaseUrlTextBox.Text.Trim()
            organizationId = $ui.ApiOrganizationTextBox.Text.Trim()
            projectRef = $ui.ApiProjectRefTextBox.Text.Trim()
        }
        $result = Set-BootstrapApiCredential -ProviderName $providerId -CredentialId (Get-SelectedApiCredentialId) -DisplayName $ui.ApiDisplayNameTextBox.Text.Trim() -Secret $ui.ApiSecretBox.Password -Fields $fields
        $ui.ApiStatusLabel.Text = "Credencial salva: $($result.credentialId)"
        Refresh-ApiCenterControls
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao salvar credencial: $($_.Exception.Message)"
    }
})

$ui.ApiValidateButton.Add_Click({
    try {
        $providerId = Get-SelectedApiProviderId
        $credentialId = Get-SelectedApiCredentialId
        if ([string]::IsNullOrWhiteSpace($providerId) -or [string]::IsNullOrWhiteSpace($credentialId)) { return }
        $null = Invoke-BootstrapApiCredentialValidation -ProviderName $providerId -CredentialId $credentialId
        $ui.ApiStatusLabel.Text = "Credencial validada: $credentialId"
        Refresh-ApiCenterControls
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao validar: $($_.Exception.Message)"
    }
})

$ui.ApiValidateAllButton.Add_Click({
    try {
        $null = Invoke-BootstrapApiCredentialValidation -All
        $ui.ApiStatusLabel.Text = 'Validacao concluida.'
        Refresh-ApiCenterControls
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao validar tudo: $($_.Exception.Message)"
    }
})

$ui.ApiActivateButton.Add_Click({
    try {
        $providerId = Get-SelectedApiProviderId
        $credentialId = Get-SelectedApiCredentialId
        if ([string]::IsNullOrWhiteSpace($providerId) -or [string]::IsNullOrWhiteSpace($credentialId)) { return }
        $null = Set-BootstrapApiActiveCredential -ProviderName $providerId -CredentialId $credentialId
        $ui.ApiStatusLabel.Text = "Credencial ativa: $credentialId"
        Refresh-ApiCenterControls
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao ativar: $($_.Exception.Message)"
    }
})

$ui.ApiImportButton.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Importar arquivo bruto de credenciais'
        $dialog.Filter = 'Markdown/Text (*.md;*.txt)|*.md;*.txt|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $null = Import-BootstrapApiCredentialFile -Path $dialog.FileName
            $ui.ApiStatusLabel.Text = "Importado: $($dialog.FileName)"
            Refresh-ApiCenterControls
        }
    } catch {
        $ui.ApiStatusLabel.Text = "Falha ao importar: $($_.Exception.Message)"
    }
})

$ui.ApiApplyButton.Add_Click({
    try {
        # "Aplicar nos apps" grava segredos nos configs de varios apps. Antes de executar,
        # confirma listando os providers validados (state=passed) e os apps-alvo afetados.
        $usable = @()
        $targetApps = @()
        try {
            $inv = Get-BootstrapApiInventory -SecretsData (Get-BootstrapSecretsData).Data
            foreach ($p in @($inv.providers)) {
                if ([string]$p.activeValidationState -eq 'passed' -and -not [string]::IsNullOrWhiteSpace([string]$p.activeCredentialId)) {
                    $usable += @([string]$p.displayName)
                    foreach ($a in @($p.autoAppliedApps)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$a) -and (@($targetApps) -notcontains [string]$a)) { $targetApps += @([string]$a) }
                    }
                }
            }
        } catch {
            Write-UiLog -Level 'WARN' -Message ("Nao foi possivel pre-visualizar o alcance de Aplicar nos apps: {0}" -f $_.Exception.Message)
        }

        if (@($usable).Count -eq 0) {
            Set-ApiCenterStatusMessage -Channel 'Aplicacao APIs' -Message 'Nenhuma credencial ativa e validada (state=passed). Nada a aplicar: valide e ative uma credencial primeiro.'
            return
        }

        $confirmMessage = @(
            ("Gravar credenciais de {0} provider(s) validado(s) nos configs dos apps suportados:" -f @($usable).Count)
            ''
            ("Providers: {0}" -f (@($usable) -join ', '))
            ("Apps-alvo: {0}" -f $(if (@($targetApps).Count -gt 0) { (@($targetApps) -join ', ') } else { 'apps suportados detectados no host' }))
            ''
            'Segredos serao escritos nos arquivos de configuracao desses apps. Continuar?'
        ) -join [Environment]::NewLine
        if (-not (Confirm-UiCriticalAction -Title 'Confirmar: Aplicar nos apps' -Message $confirmMessage)) {
            Set-ApiCenterStatusMessage -Channel 'Aplicacao APIs' -Message ("Aplicacao cancelada. {0} provider(s) seriam aplicados: {1}" -f @($usable).Count, (@($usable) -join ', '))
            return
        }

        $applyResult = Invoke-BootstrapApiApply
        $applyDiagnostics = if ($applyResult -and $applyResult.PSObject.Properties['diagnostics']) { $applyResult.diagnostics } else { $null }
        Set-ApiCenterStatusMessage -Channel 'Aplicacao APIs' -Message 'APIs aplicadas nos apps suportados.' -Diagnostics $applyDiagnostics
        Refresh-ApiCenterControls
    } catch {
        Set-ApiCenterStatusMessage -Channel 'Aplicacao APIs' -Message $_.Exception.Message -IsError
    }
})

# Quick preset buttons
foreach ($presetEntry in $ui.PresetButtons.GetEnumerator()) {
    $btnRef     = $presetEntry.Value
    $btnRef.Tag = [string]$presetEntry.Key
    $btnRef.Add_Click({
        param($sourceControl)
        $presetName = [string]$sourceControl.Tag
        if ([string]::IsNullOrWhiteSpace($presetName)) { return }
        Apply-QuickPreset -PresetName $presetName
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-SelectionTrees
        Refresh-SelectionSummary
        Refresh-HostSetupControls
        $ui.StatusLabel.Text = "Preset: $presetName"
    })
}

# Custom preset actions
$ui.SavePresetButton.Add_Click({
    $presetName = $ui.PresetNameTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $ui.State.customPresets[$presetName] = @{
        selectedProfiles   = @($ui.State.selectedProfiles)
        selectedComponents = @($ui.State.selectedComponents)
        excludedComponents = @($ui.State.excludedComponents)
        enableClaudeCodeProjectMcps = [bool]$ui.State.enableClaudeCodeProjectMcps
        hostHealth         = [string]$ui.State.hostHealth
        appTuningMode      = [string]$ui.State.appTuningMode
        selectedAppTuningCategories = @($ui.State.selectedAppTuningCategories)
        selectedAppTuningItems = @($ui.State.selectedAppTuningItems)
        excludedAppTuningItems = @($ui.State.excludedAppTuningItems)
        steamDeckVersion   = [string]$ui.State.steamDeckVersion
        workspaceRoot      = [string]$ui.State.workspaceRoot
        cloneBaseDir       = [string]$ui.State.cloneBaseDir
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-CustomPresets
})

$ui.LoadPresetButton.Add_Click({
    $presetName = if ($ui.CustomPresetCombo.SelectedItem) { [string]$ui.CustomPresetCombo.SelectedItem } else { '' }
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $preset = $ui.State.customPresets[$presetName]
    if (-not $preset) { return }
    $ui.State.selectedProfiles   = @(Normalize-BootstrapNames -Names @($preset.selectedProfiles))
    $ui.State.selectedComponents = @(Normalize-BootstrapNames -Names @($preset.selectedComponents))
    $ui.State.excludedComponents = @(Normalize-BootstrapNames -Names @($preset.excludedComponents))
    $ui.State.enableClaudeCodeProjectMcps = [bool]$preset.enableClaudeCodeProjectMcps
    $ui.State.hostHealth         = [string]$preset.hostHealth
    $ui.State.appTuningMode      = if ($preset.appTuningMode) { [string]$preset.appTuningMode } else { 'recommended' }
    $ui.State.selectedAppTuningCategories = @(Normalize-BootstrapNames -Names @($preset.selectedAppTuningCategories))
    $ui.State.selectedAppTuningItems = @(Normalize-BootstrapNames -Names @($preset.selectedAppTuningItems))
    $ui.State.excludedAppTuningItems = @(Normalize-BootstrapNames -Names @($preset.excludedAppTuningItems))
    $ui.State.steamDeckVersion   = [string]$preset.steamDeckVersion
    $ui.State.workspaceRoot      = [string]$preset.workspaceRoot
    $ui.State.cloneBaseDir       = [string]$preset.cloneBaseDir
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionTrees
    Refresh-SelectionSummary
    Refresh-HostSetupControls
})

$ui.DeletePresetButton.Add_Click({
    $presetName = if ($ui.CustomPresetCombo.SelectedItem) { [string]$ui.CustomPresetCombo.SelectedItem } else { '' }
    if ([string]::IsNullOrWhiteSpace($presetName)) { return }
    $ui.State.customPresets.Remove($presetName)
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-CustomPresets
})

$ui.AuditIntegrityButton.Add_Click({
    $runIdx = @($ui.PageNames).IndexOf('PageRun')
    if ($runIdx -lt 0) { $runIdx = [Math]::Max(0, $ui.PageNames.Count - 1) }
    Navigate-ToPage -Index $runIdx
    Start-RunExecution -MaintenanceIntent 'audit'
})

$ui.DoctorQuickButton.Add_Click({
    $runIdx = @($ui.PageNames).IndexOf('PageRun')
    if ($runIdx -lt 0) { $runIdx = [Math]::Max(0, $ui.PageNames.Count - 1) }
    Navigate-ToPage -Index $runIdx
    Start-RunExecution -MaintenanceIntent 'doctor'
})

$ui.SupportBundleQuickButton.Add_Click({
    $runIdx = @($ui.PageNames).IndexOf('PageRun')
    if ($runIdx -lt 0) { $runIdx = [Math]::Max(0, $ui.PageNames.Count - 1) }
    Navigate-ToPage -Index $runIdx
    Start-RunExecution -MaintenanceIntent 'support-bundle'
})

$ui.HealthDoctorButton.Add_Click({
    $runIdx = @($ui.PageNames).IndexOf('PageRun')
    if ($runIdx -lt 0) { $runIdx = [Math]::Max(0, $ui.PageNames.Count - 1) }
    Navigate-ToPage -Index $runIdx
    Start-RunExecution -MaintenanceIntent 'doctor' -DoctorScope 'all'
})

# Cards de saude clicaveis: cada um valida SOMENTE o seu escopo.
$ui.HealthWslCard.Add_Click({        Invoke-UiHealthScopedDoctor -Scope 'wsl'         -StatusTextBlock $ui.HealthWslStatusText })
$ui.HealthWingetCard.Add_Click({     Invoke-UiHealthScopedDoctor -Scope 'winget'      -StatusTextBlock $ui.HealthWingetStatusText })
$ui.HealthRebootCard.Add_Click({     Invoke-UiHealthScopedDoctor -Scope 'reboot'      -StatusTextBlock $ui.HealthRebootStatusText })
$ui.HealthSecretsCard.Add_Click({    Invoke-UiHealthScopedDoctor -Scope 'secrets'     -StatusTextBlock $ui.HealthSecretsStatusText })
$ui.HealthGithubCard.Add_Click({     Invoke-UiHealthScopedDoctor -Scope 'github'      -StatusTextBlock $ui.HealthGithubStatusText })
$ui.HealthAiUsagebarCard.Add_Click({ Invoke-UiHealthScopedDoctor -Scope 'ai-usagebar' -StatusTextBlock $ui.HealthAiUsagebarStatusText })
$ui.HealthAiMemoryCard.Add_Click({
    . (Join-Path $PSScriptRoot 'windows/ai/memory-ui.ps1')
    Show-PhaseZeroMemoryWindow -Owner $window -RepoRoot $PSScriptRoot
})
$ui.HealthAionUiCard.Add_Click({     Invoke-UiHealthScopedDoctor -Scope 'aionui'      -StatusTextBlock $ui.HealthAionUiStatusText })
$ui.HealthDeckCard.Add_Click({       Invoke-UiHealthScopedDoctor -Scope 'steamdeck'   -StatusTextBlock $ui.HealthDeckStatusText })
$ui.HealthRollbackCard.Add_Click({   Invoke-UiHealthScopedDoctor -Scope 'rollback'    -StatusTextBlock $ui.HealthRollbackStatusText })

# Tokens e memória IA: valida ferramentas de contexto, memória e economia de tokens.
$ui.HealthAgentToolsButton.Add_Click({
    . (Join-Path $PSScriptRoot 'windows/ai/token-economy-ui.ps1')
    Show-PhaseZeroEconomyWindow -Owner $window -RepoRoot $PSScriptRoot
})
$ui.HealthAgentToolsRepairButton.Add_Click({ Invoke-UiHealthAgentToolsRepair })
# Otimização Windows: só diagnostica, sem aplicar ajustes automáticos.
$ui.HealthWindowsOptButton.Add_Click({ Invoke-UiHealthScopedDoctor -Scope 'windows-optimization' })
# Validar conexões de IA: somente validação, separado do reparo.
$ui.HealthValidateMcpButton.Add_Click({ Invoke-UiHealthScopedDoctor -Scope 'mcp' })
# Compilador Windows: valida cl.exe e DLLs do runtime VC++.
$ui.HealthMsvcButton.Add_Click({ Invoke-UiHealthScopedDoctor -Scope 'msvc' })
# Drives/particoes: diagnostico read-only e aplicacao protegida por modo avancado + token.
$ui.HealthDriveLabelsButton.Add_Click({ Invoke-UiHealthPartitionLabels })
$ui.HealthDriveLabelsApplyButton.Add_Click({ Invoke-UiHealthPartitionLabelsApply })
$ui.HealthDriveLabelsAdvancedCheck.Add_Checked({ Update-UiHealthDriveLabelsApplyButton })
$ui.HealthDriveLabelsAdvancedCheck.Add_Unchecked({ Update-UiHealthDriveLabelsApplyButton })
Update-UiHealthDriveLabelsApplyButton

$ui.HealthSupportBundleButton.Add_Click({
    $runIdx = @($ui.PageNames).IndexOf('PageRun')
    if ($runIdx -lt 0) { $runIdx = [Math]::Max(0, $ui.PageNames.Count - 1) }
    Navigate-ToPage -Index $runIdx
    Start-RunExecution -MaintenanceIntent 'support-bundle'
})

$ui.HealthRepairPlanButton.Add_Click({
    $runIdx = @($ui.PageNames).IndexOf('PageRun')
    if ($runIdx -lt 0) { $runIdx = [Math]::Max(0, $ui.PageNames.Count - 1) }
    Navigate-ToPage -Index $runIdx
    Start-RunExecution -MaintenanceIntent 'repair-plan'
})

$ui.HealthRepairMcpButton.Add_Click({
    try {
        $preview = Invoke-BootstrapMcpConfigRepair -DryRun
        if ([int]$preview.totalFixed -eq 0) {
            $ui.StatusLabel.Text = 'Conexões de IA: nada a reparar.'
            return
        }
        $affected = @($preview.targets | Where-Object { [int]$_.fixed -gt 0 } | ForEach-Object { ("{0} ({1})" -f [string]$_.id, [int]$_.fixed) })
        $msg = @(
            ("Corrigir {0} comando(s) de conexão local incompatível:" -f [int]$preview.totalFixed)
            ''
            ("Clientes: {0}" -f (@($affected) -join ', '))
            ''
            'Um backup é criado por arquivo antes de gravar. Continuar?'
        ) -join [Environment]::NewLine
        if (-not (Confirm-UiCriticalAction -Title 'Reparar conexões de IA' -Message $msg)) {
            $ui.StatusLabel.Text = 'Reparo de conexões de IA cancelado.'
            return
        }
        # Roda o reparo via install-cli.bat (processo separado) para produzir result.json/log
        # versionaveis, sem bloquear a thread WPF nem deixar a acao sem artefato.
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $artifacts = New-UiRunArtifactSet -Timestamp $timestamp
        $ui.CurrentLogPath = [string]$artifacts.LogPath
        $ui.CurrentResultPath = [string]$artifacts.ResultPath
        $installCli = Join-Path $PSScriptRoot 'install-cli.bat'
        $repairArgs = @(
            '--repair-mcp',
            '--yes',
            '--result-path', [string]$ui.CurrentResultPath,
            '--log-path', [string]$ui.CurrentLogPath
        )
        Start-Process -FilePath $installCli -ArgumentList (ConvertTo-ArgumentString -Tokens $repairArgs) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
        $ui.StatusLabel.Text = ("Reparo de conexões de IA iniciado. Resultado: {0}" -f [string]$ui.CurrentResultPath)
        Update-RunArtifactButtons
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha no reparo de conexões de IA: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = "Erro no reparo de conexões de IA: $($_.Exception.Message)"
    }
})

function Update-UiDriftScheduleButton {
    try {
        $state = Get-BootstrapDriftCheckTaskState
        $ui.HealthDriftScheduleButton.Content = if ([bool]$state.registered) { 'Remover verificação semanal' } else { 'Agendar verificação semanal' }
    } catch { }
}

$ui.HealthDriftCheckButton.Add_Click({
    try {
        $ui.StatusLabel.Text = 'Verificando mudanças desde a última referência...'
        $drift = Invoke-BootstrapDriftCheck
        if (-not $drift.baselineExisted) {
            $ui.StatusLabel.Text = 'Mudanças: referência inicial criada agora. Rode novamente depois para comparar.'
        } elseif ([int]$drift.regressionCount -eq 0) {
            $ui.StatusLabel.Text = 'Mudanças: nenhuma piora desde a última referência. Tudo estável.'
        } else {
            $list = (@($drift.regressions) | ForEach-Object { "{0} ({1}->{2})" -f $_.id, $_.from, $_.to }) -join ', '
            $ui.StatusLabel.Text = ("Mudanças: {0} piora(s) detectada(s): {1}" -f [int]$drift.regressionCount, $list)
        }
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha na verificação de mudanças: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = "Erro na verificação de mudanças: $($_.Exception.Message)"
    }
})

$ui.HealthDriftScheduleButton.Add_Click({
    try {
        $state = Get-BootstrapDriftCheckTaskState
        if ([bool]$state.registered) {
            $r = Unregister-BootstrapDriftCheckTask
            $ui.StatusLabel.Text = "Verificação semanal removida ($([string]$r.status))."
        } else {
            $r = Register-BootstrapDriftCheckTask -ScriptPath $backendScriptPath
            if ([string]$r.status -eq 'registered') {
                $ui.StatusLabel.Text = 'Verificação semanal agendada: segunda, 09:00.'
            } else {
                $ui.StatusLabel.Text = ("Não foi possível agendar a verificação semanal: {0}" -f [string]$r.reason)
            }
        }
        Update-UiDriftScheduleButton
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao agendar verificação semanal: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = "Erro ao agendar verificação semanal: $($_.Exception.Message)"
    }
})
Update-UiDriftScheduleButton

function Copy-HealthDiagnostic {
    try {
        $text = [string]$ui.HealthDoctorTextBox.Text
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = @(
                [string]$ui.HealthStatusText.Text,
                [string]$ui.HealthWslStatusText.Text,
                [string]$ui.HealthWingetStatusText.Text,
                [string]$ui.HealthRebootStatusText.Text,
                [string]$ui.HealthSecretsStatusText.Text,
                [string]$ui.HealthGithubStatusText.Text,
                [string]$ui.HealthAiUsagebarStatusText.Text,
                [string]$ui.HealthAiMemoryStatusText.Text,
                [string]$ui.HealthAionUiStatusText.Text,
                [string]$ui.HealthDeckStatusText.Text,
                [string]$ui.HealthRollbackStatusText.Text,
                [string]$ui.HealthDriveLabelsStatusText.Text
            ) -join [Environment]::NewLine
        }
        [System.Windows.Clipboard]::SetText($text)
        $ui.StatusLabel.Text = 'Diagnóstico copiado.'
    } catch {
        $ui.StatusLabel.Text = "Erro ao copiar diagnóstico: $($_.Exception.Message)"
    }
}

$ui.HealthCopyDiagnosticButton.Add_Click({ Copy-HealthDiagnostic })

$ui.RollbackChangesButton.Add_Click({
    if (Confirm-UiCriticalAction -Title 'Confirmar reversão' -Message "A reversão desfaz ajustes de registro/sistema criados pelo bootstrap. Apps instalados não serão removidos automaticamente. Log atual: $([string]$ui.CurrentLogPath)") {
        $runIdx = @($ui.PageNames).IndexOf('PageRun')
        if ($runIdx -lt 0) { $runIdx = [Math]::Max(0, $ui.PageNames.Count - 1) }
        Navigate-ToPage -Index $runIdx
        Start-RunExecution -MaintenanceIntent 'rollback'
    }
})

# Filter
$ui.FilterTextBox.Add_TextChanged({ Refresh-SelectionTrees })
$ui.ClearAllSelectionButton.Add_Click({
    $answer = [System.Windows.MessageBox]::Show(
        'Limpar toda a selecao atual? Isso remove perfis, componentes e itens AppTuning selecionados.',
        'Bootstrap UI - Limpar selecao',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Clear-UiAllSelections
})

$ui.RefreshStatusButton.Add_Click({
    try {
        $ui.StatusLabel.Text = 'Atualizando status dos componentes (ao vivo)...'
        $ui['ComponentStatusLive'] = Get-BootstrapComponentStatusMap
        Refresh-SelectionTrees
        Refresh-SelectionSummary
        $total = @($ui.ComponentStatusLive.Keys).Count
        $installed = @($ui.ComponentStatusLive.Values | Where-Object { [string]$_ -ne 'not-installed' }).Count
        $ui.StatusLabel.Text = "Status atualizado: $installed de $total componente(s) detectado(s) como instalado(s)/configurado(s)."
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao atualizar status: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = "Erro ao atualizar status: $($_.Exception.Message)"
    }
})

function Set-UiComponentEnabled {
    param(
        [Parameter(Mandatory=$true)][string]$ComponentName,
        [Parameter(Mandatory=$true)][bool]$Enabled
    )
    $name = @(Normalize-BootstrapNames -Names @($ComponentName))[0]
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $selection = New-BootstrapSelectionObject -SelectedProfiles $ui.State.selectedProfiles -SelectedComponents $ui.State.selectedComponents -ExcludedComponents @() -SelectedHostHealth $ui.State.hostHealth
    $resolution = Resolve-BootstrapComponents -SelectedProfiles $selection.Profiles -SelectedComponents $selection.Components -ExcludedComponents @()
    $isResolved = (@($resolution.ResolvedComponents) -contains $name)
    $isExplicit = (@($ui.State.selectedComponents) -contains $name)
    if ($Enabled) {
        if (@($ui.State.excludedComponents) -contains $name) {
            $ui.State.excludedComponents = @(Remove-UiStringValue -Values $ui.State.excludedComponents -Value $name)
        }
        if (-not $isResolved -and -not $isExplicit) {
            $ui.State.selectedComponents = @(@($ui.State.selectedComponents) + $name)
        }
    } else {
        if ($isResolved -and -not (Test-UiComponentCanExclude -ComponentName $name)) {
            $ui.SelectionErrorLabel.Text = "O componente $name e obrigatorio/dependencia base; remova o perfil ou componente que depende dele."
            return
        }
        if ($isResolved -and -not (@($ui.State.excludedComponents) -contains $name)) {
            $ui.State.excludedComponents = @(@($ui.State.excludedComponents) + $name)
        }
        if ($isExplicit) {
            $ui.State.selectedComponents = @(Remove-UiStringValue -Values $ui.State.selectedComponents -Value $name)
        }
    }
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionTrees
    Refresh-SelectionSummary
}

$ui.OptClaudePluginsCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    Set-UiComponentEnabled -ComponentName 'claude-plugins' -Enabled $true
})
$ui.OptClaudePluginsCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    Set-UiComponentEnabled -ComponentName 'claude-plugins' -Enabled $false
})
$ui.OptOpenWebUICheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    Set-UiComponentEnabled -ComponentName 'openwebui' -Enabled $true
})
$ui.OptOpenWebUICheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    Set-UiComponentEnabled -ComponentName 'openwebui' -Enabled $false
})
$ui.OptClaudeProjectMcpsCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.enableClaudeCodeProjectMcps = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptClaudeProjectMcpsCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.enableClaudeCodeProjectMcps = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$ui.OptSkipManualRequirementsCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.skipManualRequirements = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptSkipManualRequirementsCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.skipManualRequirements = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$ui.OptOfflineModeCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.offlineMode = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptOfflineModeCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.offlineMode = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$ui.OptEnableResumeCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.enableResume = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptEnableResumeCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.enableResume = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$ui.OptIgnoreManualRequirementsCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.ignoreManualRequirements = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptIgnoreManualRequirementsCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.ignoreManualRequirements = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

$ui.OptRequireNoPendingRebootCheckBox.Add_Checked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.requireNoPendingReboot = $true
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})
$ui.OptRequireNoPendingRebootCheckBox.Add_Unchecked({
    if ($ui.SuppressSelectionEvents) { return }
    $ui.State.requireNoPendingReboot = $false
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-SelectionSummary
})

# Host Health
$ui.HostHealthCombo.Add_SelectionChanged({
    if ($ui.HostHealthCombo.SelectedItem) {
        $ui.State.hostHealth = [string]$ui.HostHealthCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-SelectionSummary
        Refresh-HostSetupControls
    }
})

# Steam Deck version
$ui.SteamDeckVersionCombo.Add_SelectionChanged({
    if ($ui.SteamDeckVersionCombo.SelectedItem) {
        $ui.State.steamDeckVersion = [string]$ui.SteamDeckVersionCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

# Browse buttons
$ui.WorkspaceBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description  = $ui.Strings.WorkspaceRoot
    $dialog.SelectedPath = [string]$ui.State.workspaceRoot
    if ($dialog.ShowDialog() -eq 'OK') {
        $ui.WorkspaceRootTextBox.Text = $dialog.SelectedPath
        $ui.State.workspaceRoot       = $dialog.SelectedPath
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

$ui.CloneBrowseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description  = $ui.Strings.CloneBaseDir
    $dialog.SelectedPath = [string]$ui.State.cloneBaseDir
    if ($dialog.ShowDialog() -eq 'OK') {
        $ui.CloneBaseDirTextBox.Text = $dialog.SelectedPath
        $ui.State.cloneBaseDir       = $dialog.SelectedPath
        Save-UiState -State $ui.State -Path $UiStatePath
    }
})

$ui.WorkspaceRootTextBox.Add_LostFocus({
    $ui.State.workspaceRoot = $ui.WorkspaceRootTextBox.Text.Trim()
    Save-UiState -State $ui.State -Path $UiStatePath
})

$ui.CloneBaseDirTextBox.Add_LostFocus({
    $ui.State.cloneBaseDir = $ui.CloneBaseDirTextBox.Text.Trim()
    Save-UiState -State $ui.State -Path $UiStatePath
})

# App Tuning
$ui.AppTuningModeCombo.Add_SelectionChanged({
    if ($ui.AppTuningModeCombo.SelectedItem) {
        $ui.State.appTuningMode = [string]$ui.AppTuningModeCombo.SelectedItem
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-AppTuningControls
        Refresh-SelectionSummary
    }
})

$ui.AppTuningRecommendedButton.Add_Click({
    $ui.State.appTuningMode = 'recommended'
    $ui.State.selectedAppTuningCategories = @()
    $ui.State.selectedAppTuningItems = @()
    $ui.State.excludedAppTuningItems = @()
    Save-UiState -State $ui.State -Path $UiStatePath
    Refresh-AppTuningControls
})

$ui.AppTuningMarkCategoryButton.Add_Click({
    if ($ui.AppTuningCategoryList.SelectedItem -and $ui.AppTuningCategoryList.SelectedItem.Tag) {
        $id = [string]$ui.AppTuningCategoryList.SelectedItem.Tag
        if (-not (@($ui.State.selectedAppTuningCategories) -contains $id)) {
            $ui.State.selectedAppTuningCategories = @(@($ui.State.selectedAppTuningCategories) + $id)
        }
        $ui.State.appTuningMode = 'custom'
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-AppTuningControls
    }
})

$ui.AppTuningClearCategoryButton.Add_Click({
    if ($ui.AppTuningCategoryList.SelectedItem -and $ui.AppTuningCategoryList.SelectedItem.Tag) {
        $id = [string]$ui.AppTuningCategoryList.SelectedItem.Tag
        $ui.State.selectedAppTuningCategories = @(Remove-UiStringValue -Values $ui.State.selectedAppTuningCategories -Value $id)
        $ui.State.appTuningMode = 'custom'
        Save-UiState -State $ui.State -Path $UiStatePath
        Refresh-AppTuningControls
    }
})

$ui.AppTuningAuditButton.Add_Click({
    Capture-AppTuningStateFromControls
    Refresh-AppTuningControls
    Set-AppTuningActionFeedback -Message 'Status local atualizado. Nenhuma configuração foi alterada.' -Level 'info'
})

$ui.AppTuningClearAllButton.Add_Click({
    $answer = [System.Windows.MessageBox]::Show(
        'Limpar toda a selecao atual? Isso remove perfis, componentes e itens AppTuning selecionados.',
        'Bootstrap UI - Limpar selecao',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Clear-UiAllSelections
})

$ui.AppTuningSearchBox.Add_TextChanged({
    Request-AppTuningRefresh
})

$ui.AppTuningStatusFilterCombo.Add_SelectionChanged({
    Request-AppTuningRefresh
})
$ui.AppTuningRiskFilterCombo.Add_SelectionChanged({
    Request-AppTuningRefresh
})

$ui.AppTuningItemsGrid.Add_LoadingRow({
    param($sender, $args)
    try {
        $row = $args.Row
        if ($null -eq $row -or $null -eq $row.Item) { return }
        $item = $row.Item
        $rowData = $null
        if ($item -and $item.PSObject.Properties['Row']) {
            $rowData = $item.Row
        } elseif ($item -is [System.Collections.IDictionary]) {
            $rowData = $item
        } else {
            return
        }
        $description = [string]$rowData['description']
        $appName = [string]$rowData['app']
        $optimization = [string]$rowData['optimization']
        if ([string]::IsNullOrWhiteSpace($description)) {
            $row.ToolTip = "$appName - $optimization"
        } else {
            $row.ToolTip = "$appName - $optimization`n$description"
        }

        $installedRaw = [string]$rowData['installedStateRaw']
        $configuredRaw = [string]$rowData['configuredStateRaw']
        $updatedRaw = [string]$rowData['updatedStateRaw']

        # Regra de cor por status:
        # 1) update -> laranja
        # 2) instalado + configurado -> verde
        # 3) instalado -> azul
        # 4) demais -> padrão
        if ($updatedRaw -in @('check', 'update-available', 'upgrade-available', 'outdated')) {
            $row.Foreground = Get-UiBrush '#F59E0B'
        } elseif ($installedRaw -eq 'installed' -and $configuredRaw -eq 'configured') {
            $row.Foreground = Get-UiBrush '#22C55E'
        } elseif ($installedRaw -eq 'installed') {
            $row.Foreground = Get-UiBrush '#60A5FA'
        } else {
            $row.Foreground = Get-UiBrush '#CBD5E1'
        }
    } catch {
        if ($args -and $args.Row) {
            $args.Row.ToolTip = $null
            $args.Row.Foreground = Get-UiBrush '#CBD5E1'
        }
    }
})

$ui.AppTuningItemsGrid.Add_MouseDoubleClick({
    try {
        if ($null -eq $ui.AppTuningItemsGrid.CurrentCell -or $null -eq $ui.AppTuningItemsGrid.CurrentCell.Column) { return }
        $header = [string]$ui.AppTuningItemsGrid.CurrentCell.Column.Header
        $row = Get-CurrentAppTuningRow
        if ($null -eq $row) { return }

        switch ($header) {
            'Instalado' { Invoke-AppTuningSingleRowAction -Row $row -Action 'install' }
            'Configurado' { Invoke-AppTuningSingleRowAction -Row $row -Action 'configure' }
            'Atualizado' { Invoke-AppTuningSingleRowAction -Row $row -Action 'update' }
            default { }
        }
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha no clique unitário AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel 'a ação unitária da tabela Otimizar Apps' -Exception $_.Exception)
    }
})

$ui.AppTuningInstallButton.Add_Click({
    try {
        $result = Queue-AppTuningInstallOrUpdate -ActionName 'Instalação' -Rows @(Get-CheckedAppTuningRowList)
        if ($result -and -not [string]::IsNullOrWhiteSpace([string]$result.message)) {
            Prompt-AppTuningNavigateToReview -ActionMessage ([string]$result.message)
        }
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao planejar instalação AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel 'a instalação dos apps selecionados' -Exception $_.Exception)
    }
})

$ui.AppTuningConfigureButton.Add_Click({
    try {
        $result = Queue-AppTuningConfigure -Rows @(Get-CheckedAppTuningRowList)
        if ($result -and -not [string]::IsNullOrWhiteSpace([string]$result.message)) {
            Prompt-AppTuningNavigateToReview -ActionMessage ([string]$result.message)
        }
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao planejar configuração AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel 'a configuração/otimização dos apps selecionados' -Exception $_.Exception)
    }
})

$ui.AppTuningUpdateButton.Add_Click({
    try {
        $result = Queue-AppTuningInstallOrUpdate -ActionName 'Atualização' -Rows @(Get-CheckedAppTuningRowList)
        if ($result -and -not [string]::IsNullOrWhiteSpace([string]$result.message)) {
            Prompt-AppTuningNavigateToReview -ActionMessage ([string]$result.message)
        }
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao planejar atualização AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = (Get-UiFriendlyActionError -ActionLabel 'a atualização dos apps selecionados' -Exception $_.Exception)
    }
})

$ui.AppTuningRunNowButton.Add_Click({
    try {
        Capture-AppTuningStateFromControls
        Refresh-SelectionSummary
        Clear-ExecutionScopeOverride
        if (-not (Confirm-AppTuningSecurityImpact -Rows @(Get-ActiveAppTuningRows))) {
            Set-AppTuningActionFeedback -Message 'Execução imediata cancelada: impacto de segurança não confirmado.' -Level 'warning'
            return
        }
        $selectionCount = @($ui.State.selectedComponents).Count
        $appTuningCount = @($ui.State.selectedAppTuningItems).Count
        $scopeMessage = @(
            'Escolha o escopo desta execução:'
            ''
            'Sim = Isolado (somente ajustes de apps selecionados)'
            'Não = Perfil atual (inclui perfil + ajustes de apps)'
            'Cancelar = abortar'
            ''
            ("Componentes selecionados: {0}" -f $selectionCount)
            ("Itens de ajuste selecionados: {0}" -f $appTuningCount)
        ) -join [Environment]::NewLine
        $scopeAnswer = [System.Windows.MessageBox]::Show(
            $scopeMessage,
            'Bootstrap UI - Escopo da execução',
            [System.Windows.MessageBoxButton]::YesNoCancel,
            [System.Windows.MessageBoxImage]::Question
        )

        if ($scopeAnswer -eq [System.Windows.MessageBoxResult]::Cancel) {
            Set-AppTuningActionFeedback -Message 'Execução imediata cancelada pelo usuário.' -Level 'warning'
            return
        }

        if ($scopeAnswer -eq [System.Windows.MessageBoxResult]::Yes) {
            $ui.ExecutionScopeOverride = Get-IsolatedAppTuningExecutionOverride
        } else {
            $ui.ExecutionScopeOverride = Get-ProfileExecutionOverride
        }
        $ui.CurrentExecutionScopeLabel = [string]$ui.ExecutionScopeOverride.scopeLabel
        Write-UiLog -Message ("AppTuningRunNow scopeMode={0}" -f [string]$ui.ExecutionScopeOverride.scopeMode)
        if ([string]$ui.ExecutionScopeOverride.scopeMode -eq 'isolated') {
            $isolatedComponentCount = @($ui.ExecutionScopeOverride.selectedComponents).Count
            $isolatedItemCount = @($ui.ExecutionScopeOverride.selectedAppTuningItems).Count
            if ($isolatedComponentCount -eq 0 -and $isolatedItemCount -eq 0) {
                Clear-ExecutionScopeOverride
                Set-AppTuningActionFeedback -Message 'Execução isolada cancelada: nenhum item AppTuning selecionado para executar.' -Level 'warning'
                [void][System.Windows.MessageBox]::Show('Selecione pelo menos um item AppTuning antes de executar no modo Isolado.', 'Bootstrap UI - Escopo isolado', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return
            }
        }

        $confirmMessage = @(
            'Confirmar inicio imediato?'
            ''
            ("Escopo: {0}" -f [string]$ui.CurrentExecutionScopeLabel)
            ("Componentes no run: {0}" -f @($ui.ExecutionScopeOverride.selectedComponents).Count)
            ("Itens de ajuste nesta execução: {0}" -f @($ui.ExecutionScopeOverride.selectedAppTuningItems).Count)
            ''
            'A execução vai iniciar imediatamente.'
        ) -join [Environment]::NewLine
        $confirmAnswer = [System.Windows.MessageBox]::Show(
            $confirmMessage,
            'Bootstrap UI - Confirmar execução',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirmAnswer -ne [System.Windows.MessageBoxResult]::Yes) {
            Clear-ExecutionScopeOverride
            Set-AppTuningActionFeedback -Message 'Execução imediata cancelada pelo usuário.' -Level 'warning'
            return
        }

        $pageIds = @(Get-UiPageIds)
        $runIndex = [Array]::IndexOf($pageIds, 'run')
        if ($runIndex -ge 0) {
            Navigate-ToPage -Index $runIndex
        } else {
            Navigate-ToPage -Index 9
        }
        Set-AppTuningActionFeedback -Message ("Execução imediata iniciando. Escopo: {0}" -f [string]$ui.CurrentExecutionScopeLabel) -Level 'info'
        Start-RunExecution
    } catch {
        Clear-ExecutionScopeOverride
        Write-UiLog -Level 'ERROR' -Message ("Falha ao iniciar execução imediata do AppTuning: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $friendly = Get-UiFriendlyActionError -ActionLabel 'a execução imediata do AppTuning' -Exception $_.Exception
        Set-AppTuningActionFeedback -Message $friendly -Level 'error'
        [void][System.Windows.MessageBox]::Show($friendly, 'Bootstrap UI - Erro', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$ui.AppTuningOpenFolderButton.Add_Click({
    $root = if (-not [string]::IsNullOrWhiteSpace([string]$ui.State.cloneBaseDir)) { [string]$ui.State.cloneBaseDir } elseif (-not [string]::IsNullOrWhiteSpace([string]$ui.State.workspaceRoot)) { [string]$ui.State.workspaceRoot } else { (Get-Location).Path }
    $path = Join-Path $root '.phasezero'
    if (-not (Test-Path -LiteralPath $path)) { $path = $root }
    Open-ExistingPath -Path $path
})

$ui.AppTuningViewLogButton.Add_Click({
    $path = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentLogPath)) { $ui.CurrentLogPath } else { [string]$ui.State.lastLogPath }
    Open-ExistingPath -Path $path
})

# AI Coding Tools
$ui.AiToolsInstallButton.Add_Click({ Invoke-UiAiToolAction -Action 'install' })
$ui.AiToolsValidateButton.Add_Click({ Invoke-UiAiToolAction -Action 'validate' })
$ui.AiToolsConfigureButton.Add_Click({ Invoke-UiAiToolAction -Action 'configure' })
$ui.AiToolsUninstallButton.Add_Click({ Invoke-UiAiToolAction -Action 'uninstall' })
$ui.AiToolsClearButton.Add_Click({ Clear-UiAiToolSelection })
$ui.AiToolsDocsButton.Add_Click({ Open-SelectedAiToolDocumentation })

# Steam Deck control
$ui.ReloadSettingsButton.Add_Click({ Refresh-SteamDeckControls; $ui.StatusLabel.Text = $ui.Strings.ReloadSettings })
$ui.SaveSettingsButton.Add_Click({ [void](Save-SteamDeckSettingsInteractive) })
$ui.ClassifyMonitorButton.Add_Click({ Classify-PendingExternalDisplay -Choice 'MonitorDev' })
$ui.ClassifyTvButton.Add_Click({ Classify-PendingExternalDisplay -Choice 'TvGame' })

# Review
$ui.RefreshReviewButton.Add_Click({ Refresh-ReviewPage })

# Dual Boot
$ui.RefreshDualBootButton.Add_Click({
    try {
        Refresh-DualBootControls
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao recarregar Windows e Linux: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.StatusLabel.Text = "Erro ao recarregar status Windows/Linux: $($_.Exception.Message)"
    }
})

$ui.BtrfsCheckButton.Add_Click({
    try {
        $r = Get-BootstrapBtrfsReadiness -ScanPartitions
        $fast = if ($r.fastStartupEnabled) { 'LIGADO (desligue!)' } else { 'desligado (ok)' }
        $drv = if ($r.winbtrfsInstalled) { "instalado ($([string]$r.winbtrfsServiceState))" } else { 'ausente' }
        $levelText = switch ([string]$r.accessLevel) {
            'blocked' { 'BLOQUEADO (sem acesso)' }
            'unsafe' { 'INSEGURO (resolva os bloqueios antes de montar)' }
            'read-only-ok' { 'SOMENTE LEITURA ok (escrita NAO habilitada)' }
            'write-opt-in' { 'leitura ok; ESCRITA disponivel apenas opt-in com backup' }
            default { [string]$r.accessLevel }
        }
        $blockers = if (@($r.blockedReasons).Count -gt 0) { (@($r.blockedReasons) -join ', ') } else { 'nenhum' }
        $lines = @(
            ("Nivel de acesso: {0}" -f $levelText),
            ("Bloqueios: {0}" -f $blockers),
            ("Fast Startup: {0}" -f $fast),
            ("WinBtrfs (driver): {0}" -f $drv),
            ("Particoes Linux detectadas: {0}" -f [int]$r.linuxPartitionCount),
            ("Somente leitura: {0} | Escrita (opt-in): {1}" -f $(if ($r.readOnlySupported) { 'sim' } else { 'nao' }), $(if ($r.readWriteSupported) { 'sim' } else { 'nao' })),
            'Este modulo NUNCA formata particoes. Backup antes de escrever.'
        )
        if (@($r.recommendations).Count -gt 0) { $lines += ('Recomendacoes: ' + ((@($r.recommendations)) -join ' | ')) }
        $ui.BtrfsStatusText.Text = ($lines -join [Environment]::NewLine)
    } catch {
        Write-UiLog -Level 'ERROR' -Message ("Falha ao verificar Btrfs: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
        $ui.BtrfsStatusText.Text = "Erro ao verificar Btrfs: $($_.Exception.Message)"
    }
})

$ui.BtrfsInstallButton.Add_Click({
    # Instalacao guiada: abre o release oficial do WinBtrfs. Driver de kernel -> admin + reboot.
    # NAO instala silenciosamente nem formata nada.
    try {
        Start-Process 'https://github.com/maharmstone/btrfs/releases' | Out-Null
        $ui.StatusLabel.Text = 'WinBtrfs: abri o release oficial. Rode como Administrador, reinicie e mantenha Fast Startup OFF. Nunca formate as particoes.'
    } catch {
        $ui.StatusLabel.Text = "Nao foi possivel abrir o release do WinBtrfs: $($_.Exception.Message)"
    }
})

$ui.FixFastStartupButton.Add_Click({
    try {
        $res = Repair-BootstrapFastStartup
        if ($res.Changed) {
            $ui.StatusLabel.Text = "Fast Startup desabilitado com sucesso."
        } else {
            $ui.StatusLabel.Text = "Fast Startup ja estava desabilitado. Nenhuma alteracao necessaria."
        }
        Refresh-DualBootControls
    } catch {
        $ui.StatusLabel.Text = "Erro: $_"
    }
})

$ui.RebootToLinuxButton.Add_Click({
    if (-not $ui.DualBootTargetCombo.SelectedItem) {
        $ui.StatusLabel.Text = 'Selecione um destino de boot (Linux/SteamOS) antes de reiniciar.'
        return
    }
    $guid = [string]$ui.DualBootTargetCombo.SelectedItem.Tag
    $targetText = [string]$ui.DualBootTargetCombo.SelectedItem.Content
    if (-not (Confirm-UiCriticalAction -Title 'Confirmar reboot' -Message "Destino: $targetText`nEfeito: define boot one-time e reinicia o Windows agora.`nCancelamento: feche esta janela." -RequiredToken 'REINICIAR')) {
        $ui.StatusLabel.Text = 'Reinício cancelado.'
        return
    }
    try {
        $res = Invoke-BootstrapRebootToLinux -PreferredEntryGuid $guid -Force
        if ($res.Rebooted) {
            $ui.StatusLabel.Text = "Reiniciando para $targetText em 3 segundos..."
        } else {
            $ui.StatusLabel.Text = "Boot one-time definido para $targetText. Reinicie quando estiver pronto."
        }
    } catch {
        $ui.StatusLabel.Text = "Erro: $_"
    }
})

$ui.BackupWindowsBootButton.Add_Click({
    try {
        $path = Backup-BootstrapWindowsBootManager
        $ui.StatusLabel.Text = "Backup BCD criado: $path"
        Refresh-DualBootControls
    } catch {
        $ui.StatusLabel.Text = "Erro no backup BCD: $_"
    }
})

$ui.ApplyWindowsBootButton.Add_Click({
    try {
        $defaultId = ''
        if ($ui.WindowsBootDefaultCombo.SelectedItem) {
            $defaultId = [string]$ui.WindowsBootDefaultCombo.SelectedItem.Tag
        }
        $timeout = $null
        $timeoutText = $ui.WindowsBootTimeoutTextBox.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($timeoutText)) {
            $parsedTimeout = 0
            if (-not [int]::TryParse($timeoutText, [ref]$parsedTimeout)) {
                throw 'Timeout precisa ser numero inteiro entre 0 e 600.'
            }
            if ($parsedTimeout -lt 0 -or $parsedTimeout -gt 600) {
                throw 'Timeout precisa ficar entre 0 e 600 segundos.'
            }
            $timeout = $parsedTimeout
        }
        if (-not (Confirm-UiCriticalAction -Title 'Confirmar BCD' -Message "Aplicar BCD vai alterar o Windows Boot Manager. Um backup sera criado antes da alteracao. Default: $defaultId Timeout: $timeout")) { return }
        $res = Set-BootstrapWindowsBootManager -DefaultId $defaultId -Timeout $timeout
        $ui.StatusLabel.Text = "BCD atualizado: $(@($res.Actions) -join ', ') | Backup: $($res.Backup)"
        Refresh-DualBootControls
    } catch {
        $ui.StatusLabel.Text = "Erro ao aplicar BCD: $_"
    }
})

$ui.BcdCleanupButton.Add_Click({
    try {
        if (-not (Confirm-UiCriticalAction -Title 'Confirmar BCD cleanup' -Message 'A limpeza de BCD cria backup e remove entradas fantasmas detectadas. Revise o backup no status apos concluir.')) { return }
        $ui.BcdCleanupButton.IsEnabled = $false
        $ui.BcdCleanupStatusText.Text = "Realizando backup e limpando..."
        try {
            $res = Repair-BootstrapPhantomEntries
            if ($res.Success) {
                $ui.StatusLabel.Text = "Removidas $($res.Removed) entradas fantasmas. Backup em: $($res.Backup)"
            }
        } finally {
            # Reabilita sempre (Refresh-DualBootControls reavalia visibilidade/estado conforme phantoms restantes).
            $ui.BcdCleanupButton.IsEnabled = $true
            Refresh-DualBootControls
        }
    } catch {
        $ui.StatusLabel.Text = "Erro na limpeza: $_"
        $ui.BcdCleanupButton.IsEnabled = $true
    }
})

$ui.RestoreBcdButton.Add_Click({
    if (-not $ui.BcdBackupCombo.SelectedItem) {
        $ui.StatusLabel.Text = 'Selecione um backup de BCD para restaurar.'
        return
    }
    $backupPath = [string]$ui.BcdBackupCombo.SelectedItem.Tag
    $backupName = [string]$ui.BcdBackupCombo.SelectedItem.Content
    if (-not (Confirm-UiCriticalAction -Title 'Confirmar restauracao de BCD' -Message ("Restaurar o Windows Boot Manager a partir do backup:`n`n{0}`n`nIsto sobrescreve a configuracao de boot atual (bcdedit /import). Continuar?" -f $backupName) -RequiredToken 'RESTAURAR')) {
        $ui.StatusLabel.Text = 'Restauracao de BCD cancelada.'
        return
    }
    try {
        $res = Restore-BootstrapWindowsBootManager -BackupPath $backupPath
        if ($res.Restored) {
            $ui.StatusLabel.Text = "BCD restaurado a partir de: $backupName"
        }
        Refresh-DualBootControls
    } catch {
        $ui.StatusLabel.Text = "Erro ao restaurar BCD: $_"
    }
})

# Run
$ui.StartRunButton.Add_Click({ Start-RunExecution })

$ui.OpenLogButton.Add_Click({
    $path = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentLogPath)) { $ui.CurrentLogPath } else { [string]$ui.State.lastLogPath }
    Open-ExistingPath -Path $path
})
$ui.OpenResultButton.Add_Click({
    $path = if (-not [string]::IsNullOrWhiteSpace($ui.CurrentResultPath)) { $ui.CurrentResultPath } else { [string]$ui.State.lastResultPath }
    Open-ExistingPath -Path $path
})
$ui.OpenSettingsButton.Add_Click({ Open-ExistingPath -Path ([string]$ui.State.lastSettingsPath) })
$ui.OpenReportsButton.Add_Click({  Open-ExistingPath -Path ([string]$ui.State.lastReportPath) })

# Sidebar nav
for ($i = 0; $i -lt $navButtons.Count; $i++) {
    $navButtons[$i].Tag = [string]$navButtonTargets[$i]
    $navButtons[$i].Add_Click({
        param($sourceControl)
        $targetPageId = [string]$sourceControl.Tag
        $pageIds = @(Get-UiPageIds)
        $idx = [Array]::IndexOf($pageIds, $targetPageId)
        if ($idx -ge 0) { Navigate-ToPage -Index $idx }
    })
}

# Back / Next / Finish
$ui.BackButton.Add_Click({ Navigate-WizardStep -Delta -1 })
$ui.NextButton.Add_Click({ Navigate-WizardStep -Delta 1 })
$ui.FinishButton.Add_Click({
    Save-UiState -State $ui.State -Path $UiStatePath
    $window.Close()
})

#
# Window lifecycle
#

$window.Add_Loaded({
    # Populate language combo
    [void]$ui.LanguageCombo.Items.Clear()
    foreach ($lang in (Get-UiLanguages)) { [void]$ui.LanguageCombo.Items.Add($lang) }
    $ui.LanguageCombo.SelectedItem = [string]$ui.State.language

    # Populate combos
    foreach ($item in @('off','conservador','equilibrado','agressivo')) { [void]$ui.HostHealthCombo.Items.Add($item) }
    foreach ($item in @(Get-BootstrapAppTuningModes)) { [void]$ui.AppTuningModeCombo.Items.Add($item) }
    foreach ($item in @('all','installed','missing','planned','not-configured','update-check')) { [void]$ui.AppTuningStatusFilterCombo.Items.Add($item) }
    $ui.AppTuningStatusFilterCombo.SelectedItem = 'all'
    foreach ($item in @('all','conservative','advanced','aggressive','opt-in')) { [void]$ui.AppTuningRiskFilterCombo.Items.Add($item) }
    $ui.AppTuningRiskFilterCombo.SelectedItem = 'all'
    foreach ($item in @('Auto','LCD','OLED')) { [void]$ui.SteamDeckVersionCombo.Items.Add($item) }
    foreach ($item in @('UNCLASSIFIED_EXTERNAL','DOCKED_TV','DOCKED_MONITOR')) { [void]$ui.GenericModeCombo.Items.Add($item) }

    Refresh-LocalizedText
    Refresh-CustomPresets
    Update-RunArtifactButtons
    $startPageIndex = [Array]::IndexOf(@(Get-UiPageIds), (Get-UiStartPageId))
    if ($startPageIndex -lt 0) { $startPageIndex = 0 }
    Navigate-ToPage -Index $startPageIndex
})

$window.Add_Closing({
    $ui.LogTimer.Stop()
    Save-UiState -State $ui.State -Path $UiStatePath
})

if ($SmokeTestWindow) {
    Save-UiState -State $ui.State -Path $UiStatePath
    [ordered]@{
        pages              = @(Get-UiPageIds)
        startPage          = Get-UiStartPageId
        primaryAction      = 'doctor'
        languages          = @(Get-UiLanguages)
        statePath          = $UiStatePath
        backend            = $backendScriptPath
        windowLoaded       = ($null -ne $window)
        handlersRegistered = $true
        runTimeline        = [ordered]@{
            present       = ($null -ne (Get-Control 'RunTimelineStep1Dot'))
            stages        = @('Preparando','Dry-run','Executando','result.json','Pacote/Logs')
        }
    } | ConvertTo-Json -Depth 8
    return
}

#
# Run the WPF application
#

try {
    if ($null -eq [System.Windows.Application]::Current) {
        $null = New-Object System.Windows.Application
        [System.Windows.Application]::Current.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
    }
    $wpfApp = [System.Windows.Application]::Current
    $wpfApp.MainWindow = $window
    $null = $wpfApp.add_DispatcherUnhandledException({
        param($sender, $e)
        try {
            Write-UiLog -Level 'ERROR' -Message ("DispatcherUnhandledException: {0}" -f $e.Exception.Message)
            Write-UiLog -Level 'ERROR' -Message ($e.Exception | Format-List * -Force | Out-String)
        } catch {
        }
        try {
            if ($null -ne $ui -and $null -ne $ui.StatusLabel) {
                $ui.StatusLabel.Text = 'Erro interno na UI; detalhes no log (DispatcherUnhandledException).'
            }
        } catch {
        }
        try {
            [void][System.Windows.MessageBox]::Show(
                ("Erro interno na interface:`n{0}`n`nA janela continua aberta; veja o log da UI." -f $e.Exception.Message),
                'Bootstrap UI',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        } catch {
        }
        $e.Handled = $true
    })
} catch {
    try {
        Write-UiLog -Level 'WARN' -Message ("Falha ao registar protecao DispatcherUnhandledException: {0}" -f $_.Exception.Message)
    } catch {
    }
}

try {
    $null = [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $e)
        $obj = $e.ExceptionObject
        try {
            Write-UiLog -Level 'ERROR' -Message ("AppDomain.UnhandledException: {0}" -f $obj)
        } catch {
        }
    })
} catch {
}

$null = $window.ShowDialog()
