#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Menu','InstallMemory','InstallApps','InstallCachedApps','CachedAppStatus','GitHub','Status','Dependencies','DependencyStatus','InstallDependencies')][string]$Action = 'Menu',
    [switch]$AllowLargeDownloads, [switch]$UiProbe, [string]$DependencyIds, [string]$RequirementFile,
    [ValidateSet('','x64','x86','arm64')][string]$ApplicationArchitecture = '', [switch]$OnlyRequired,
    [string]$ExpectedTarget, [string]$ExpectedCaller, [string]$ExpectedRequirementHash,
    [string]$OfflineCache, [string]$ApplicationIds
)
$ErrorActionPreference = 'Stop'
$dependencyAction = $Action
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Execute este preparador dentro do Windows.' }
# PS 5.1 clones variable validation attributes into UI closures. The library's
# empty rotation default is not in its ValidateSet; use its valid no-op value.
. (Join-Path $repoRoot 'bootstrap-tools.ps1') -BootstrapUiLibraryMode -RotateSecretsSchedule none
. (Join-Path $PSScriptRoot 'host-instructions.ps1')
. (Join-Path $PSScriptRoot 'windows-dependencies.ps1')
. (Join-Path $PSScriptRoot 'cached-apps.ps1')
if ($OfflineCache) { $OfflineCache = Resolve-PhaseZeroCachedLocalPath $OfflineCache }
$Action = $dependencyAction
$packages = Join-Path $repoRoot 'packages'
$env:PZ_MEMORY_PACKAGES = $packages
$archive = Join-Path $packages 'ai-memory-windows-x86_64.zip'
if (Test-Path -LiteralPath $archive) { $env:AI_MEMORY_RELEASE_ARCHIVE = $archive }

function Update-PhaseZeroHostPath {
    Refresh-SessionPath
    foreach ($directory in @("${env:ProgramFiles(x86)}\GnuPG\bin", "$env:ProgramFiles\GnuPG\bin", "$env:LOCALAPPDATA\Programs\Python\Python314", "$env:LOCALAPPDATA\Programs\Python\Python313", "$env:USERPROFILE\.local\bin")) {
        if ((Test-Path -LiteralPath $directory) -and $env:PATH.Split(';') -notcontains $directory) { $env:PATH = $directory + ';' + $env:PATH }
    }
}
if ($Action -notin @('DependencyStatus','Dependencies','InstallDependencies')) { Update-PhaseZeroHostPath }

if ($Action -notin @('Menu','Dependencies')) {
    try {
        if ($Action -eq 'DependencyStatus') {
            Get-PhaseZeroDependencyReport -RequirementFile $RequirementFile -ApplicationArchitecture $ApplicationArchitecture -OnlyRequired:$OnlyRequired | ConvertTo-Json -Depth 12
        } elseif ($Action -eq 'InstallDependencies') {
            $receipt = Invoke-PhaseZeroDependencySelection -Selected @($DependencyIds -split ',' | Where-Object { $_ }) -RequirementFile $RequirementFile -ApplicationArchitecture $ApplicationArchitecture -AllowLargeDownloads:$AllowLargeDownloads -ExpectedTarget $ExpectedTarget -ExpectedCaller $ExpectedCaller -ExpectedRequirementHash $ExpectedRequirementHash
            $receipt | ConvertTo-Json -Depth 12
            if ($receipt.state -ne 'verified') { exit 2 }
        } elseif ($Action -in @('InstallCachedApps','CachedAppStatus')) {
            if (-not $OfflineCache -or -not $ApplicationIds) { throw 'Informe o cache local e os aplicativos selecionados.' }
            $cacheTarget = Get-PhaseZeroDependencyTarget
            if (($ExpectedTarget -and $cacheTarget.windowsId -cne $ExpectedTarget) -or ($ExpectedCaller -and $cacheTarget.caller -cne $ExpectedCaller)) { throw 'A instalacao Windows ou a conta mudou. Reabra o preparador na conta original.' }
            $requestedApplications = @($ApplicationIds -split ',' | Select-Object -Unique)
            if (@($requestedApplications | Where-Object { $_ -notin @('OpenAI.Codex','Anthropic.ClaudeCode','Anthropic.Claude') }).Count) { throw 'Aplicativo sem adaptador de cache aprovado.' }
            $applicationResults = @(foreach ($applicationId in $requestedApplications) {
                if ($Action -eq 'CachedAppStatus') { Get-PhaseZeroCachedApplicationStatus -CacheDirectory $OfflineCache -Id $applicationId }
                else { Invoke-PhaseZeroCachedApplication -CacheDirectory $OfflineCache -Id $applicationId }
            })
            @{ schemaVersion = 1; action = $Action; results = $applicationResults } | ConvertTo-Json -Depth 12
        } elseif ($Action -eq 'InstallMemory') {
            Set-PhaseZeroHostInstructions | Out-Null
            $winget = Resolve-CommandPath -Name winget
            if (-not $winget) { throw 'Atualize o Instalador de Aplicativos pela Microsoft Store para obter o WinGet.' }
            # Only runtime dependencies; no Node, Rust, WSL or Linux VM.
            foreach ($dependency in @(@{Command='python';Id='Python.Python.3.14'}, @{Command='gpg';Id='GnuPG.GnuPG'}, @{Command='gh';Id='GitHub.cli'})) {
                $command = Get-Command $dependency.Command -ErrorAction SilentlyContinue
                $usable = $false
                if ($command) {
                    & $command.Source --version 2>&1 | Out-Null
                    $usable = $LASTEXITCODE -eq 0
                    if ($usable -and $dependency.Command -eq 'python') {
                        & $command.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)'
                        $usable = $LASTEXITCODE -eq 0
                    }
                }
                if (-not $usable) {
                    Ensure-WingetPackage -WingetPath $winget -Id $dependency.Id -DisplayName $dependency.Id
                    Update-PhaseZeroHostPath
                }
            }
            $result = Invoke-BootstrapAiMemoryPortability -Arguments @('install','--json')
            if (-not $result.ok -or -not $result.serverReachable) { throw 'Servidor de memoria ainda nao respondeu; use Estado e reparar.' }
            # Both clients share this single loopback server, even before app installation.
            $binary = Get-BootstrapAiMemoryExePath -InstallRoot (Get-BootstrapAiInstallRoot -InstallRoot '')
            $wiring = @(Invoke-BootstrapAiMemoryWiring -ExePath $binary -Agents @('codex','claude-code'))
            if (@($wiring | Where-Object { $_.status -eq 'failed' }).Count) { throw 'Integracao MCP/hooks incompleta.' }
            Write-Output 'Memoria local instalada. Importe a recuperacao antes de cadastrar GitHub/projetos e restaurar o historico.'
        } elseif ($Action -eq 'InstallApps') {
            Ensure-PhaseZeroHostCodexRuntime
            if ($AllowLargeDownloads) {
                $winget = Resolve-CommandPath -Name winget
                if (-not $winget) { throw 'WinGet ausente.' }
                Ensure-CodexInstaller -WingetPath $winget
                Ensure-ClaudeCode -WingetPath $winget
            } else {
                # Large payloads remain manual unless the caller explicitly authorizes them.
                $desktopInstaller = Join-Path $packages 'ChatGPTInstaller.exe'
                if (Test-Path -LiteralPath $desktopInstaller) {
                    if ((Get-AuthenticodeSignature -LiteralPath $desktopInstaller).Status -ne 'Valid') { throw 'Assinatura do instalador Microsoft Store invalida; baixe novamente da fonte oficial.' }
                    Start-Process -FilePath $desktopInstaller -Wait
                } else { Start-Process 'https://get.microsoft.com/installer/download/9PLM9XGG6VKS?cid=website_cta_psi' }
                Start-Process 'https://code.claude.com/docs/en/setup#install-on-native-windows'
                Write-Output 'Instale Codex Desktop pela Microsoft Store. Para Claude Code, siga a instalacao nativa oficial. Depois execute Instalar/reparar memoria para conferir os dois clientes.'
            }
        } elseif ($Action -eq 'GitHub') {
            $null = Invoke-BootstrapAiMemoryPortability -Arguments @('github-login','--json')
            Write-Output 'Login conferido. Na janela Memoria, importe a recuperacao antes de conectar o destino privado existente.'
        } elseif ($Action -eq 'Status') {
            Invoke-BootstrapAiMemoryPortability -Arguments @('status','--json') | ConvertTo-Json -Depth 12
        }
    } catch { Write-Warning $_; exit 1 }
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
. (Join-Path $PSScriptRoot 'memory-ui.ps1')
. (Join-Path $PSScriptRoot 'dependencies-ui.ps1')
if ($Action -eq 'Dependencies') {
    Show-PhaseZeroDependenciesWindow -EntryPoint $PSCommandPath -UiProbe:$UiProbe
    return
}
$window = New-Object System.Windows.Window
$window.Title = 'PhaseZero - Codex, Claude e memoria'
$window.Width = 650; $window.Height = 590; $window.MinWidth = 480; $window.MinHeight = 460
$workArea = [Windows.SystemParameters]::WorkArea
$window.Width = [Math]::Min($window.Width, [Math]::Max($window.MinWidth, $workArea.Width - 20))
$window.Height = [Math]::Min($window.Height, [Math]::Max($window.MinHeight, $workArea.Height - 20))
$window.WindowStartupLocation = 'CenterScreen'; $window.Background = '#18202B'; $window.Foreground = '#F0F3F7'
foreach ($key in @('DarkReadonly','DarkInput')) {
    $style = New-Object System.Windows.Style([Windows.Controls.TextBox])
    $style.Setters.Add((New-Object System.Windows.Setter([Windows.Controls.Control]::BackgroundProperty, [Windows.Media.Brushes]::White)))
    $style.Setters.Add((New-Object System.Windows.Setter([Windows.Controls.Control]::ForegroundProperty, [Windows.Media.Brushes]::Black)))
    $window.Resources.Add($key, $style)
}
foreach ($key in @('PrimaryBtn','GhostBtn')) {
    $style = New-Object System.Windows.Style([Windows.Controls.Button])
    $style.Setters.Add((New-Object System.Windows.Setter([Windows.Controls.Control]::BackgroundProperty, [Windows.Media.Brushes]::LightGray)))
    $style.Setters.Add((New-Object System.Windows.Setter([Windows.Controls.Control]::ForegroundProperty, [Windows.Media.Brushes]::Black)))
    $window.Resources.Add($key, $style)
}
$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$panel = New-Object System.Windows.Controls.StackPanel
$panel.Margin = '22'; $scroll.Content = $panel; $window.Content = $scroll
$description = New-Object System.Windows.Controls.TextBlock
$description.Text = "Prepare os aplicativos e a memoria em etapas, uma por vez. Instalar baixa os aplicativos e dependencias. Depois importe sua chave de recuperacao e restaure o backup Linux pela janela Memoria. Entre nas contas dos aplicativos e no GitHub pelo navegador."
if ($OfflineCache) { $description.Text = "Instale os clientes pelos pacotes locais preparados. Abertura e login continuam separados. Depois instale a memoria, importe sua recuperacao e restaure o historico pela janela Memoria. A instalacao online continua disponivel nos botoes existentes." }
$description.TextWrapping = 'Wrap'; $description.FontSize = 17; $description.Margin = '0,0,0,15'
$panel.Children.Add($description) | Out-Null
$operationStatus = New-Object System.Windows.Controls.TextBlock
$operationStatus.TextWrapping = 'Wrap'; $operationStatus.Margin = '0,0,0,12'; $operationStatus.FontSize = 15
$panel.Children.Add($operationStatus) | Out-Null
function Add-PhaseZeroHostButton {
    param([string]$Text, [scriptblock]$Handler)
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text; $button.MinHeight = 48; $button.Margin = '0,0,0,10'; $button.FontSize = 16
    $button.Style = $window.FindResource('PrimaryBtn')
    $button.Add_Click($Handler); $panel.Children.Add($button) | Out-Null
}
$hostScript = $PSCommandPath
$setupLogRoot = Join-Path (Get-BootstrapAiInstallRoot -InstallRoot '') 'logs'
$writeReceipt = ${function:Write-BootstrapJsonFile}
function Invoke-PhaseZeroHostPreparationAction {
    param($SelectedAction)
    # Blocking only this small launcher prevents overlapping installs/syncs.
    $window.Hide()
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $hostScript + '" -Action ' + $SelectedAction
        if ($OfflineCache) { $arguments += ' -OfflineCache "' + $OfflineCache + '"' }
        if ($SelectedAction -eq 'InstallCachedApps') {
            $caller = Get-PhaseZeroDependencyTarget
            $arguments += ' -ApplicationIds OpenAI.Codex,Anthropic.ClaudeCode,Anthropic.Claude -ExpectedTarget ' + $caller.windowsId + ' -ExpectedCaller ' + $caller.caller
        }
        if ($SelectedAction -eq 'InstallApps') { $arguments += ' -AllowLargeDownloads' }
        $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $launch = @{ FilePath = $exe; ArgumentList = $arguments; Wait = $true; PassThru = $true; ErrorAction = 'Stop' }
        if ($SelectedAction -eq 'InstallCachedApps' -and -not (Test-IsAdmin)) { $launch['Verb'] = 'RunAs' }
        $process = Start-Process @launch
        $receipt = Join-Path $setupLogRoot ('prepare-host-' + $SelectedAction + '.json')
        & $writeReceipt -Path $receipt -Value @{ action = $SelectedAction; exitCode = $process.ExitCode; downloadsAuthorized = ($SelectedAction -eq 'InstallApps'); at = (Get-Date).ToString('o') }
        if ($process.ExitCode -ne 0) {
            $operationStatus.Text = 'A etapa falhou. Confira a mensagem da janela e o diagnostico de sessao do Windows. Registro: ' + $receipt
        } else { $operationStatus.Text = 'Etapa encerrada. Confira o estado e teste os aplicativos instalados.' }
    } catch {
        $operationStatus.Text = [string]$_
    } finally { $window.Show() | Out-Null }
}
$run = ${function:Invoke-PhaseZeroHostPreparationAction}
Add-PhaseZeroHostButton '1. Instalar / reparar memoria e dependencias' { & $run 'InstallMemory' }.GetNewClosure()
Add-PhaseZeroHostButton '2. Instalar Codex Desktop e Claude Code' { & $run 'InstallApps' }.GetNewClosure()
if ($OfflineCache) { Add-PhaseZeroHostButton 'Instalar clientes preparados no cache local' { & $run 'InstallCachedApps' }.GetNewClosure() }
Add-PhaseZeroHostButton '3. Entrar no GitHub' { & $run 'GitHub' }.GetNewClosure()
Add-PhaseZeroHostButton '4. Memoria - recuperar, GitHub e sincronizacao' {
    Show-PhaseZeroMemoryWindow -Owner $window -RepoRoot $repoRoot
}.GetNewClosure()
Add-PhaseZeroHostButton 'Dependências de aplicativos e projetos' {
    Show-PhaseZeroDependenciesWindow -Owner $window -EntryPoint $hostScript
}.GetNewClosure()
Add-PhaseZeroHostButton 'Estado da memoria' { & $run 'Status' }.GetNewClosure()
Add-PhaseZeroHostButton 'Guia e destino de recuperacao' {
    Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $repoRoot 'LEIA-ME.txt') + '"')
}.GetNewClosure()
if ($UiProbe) {
    $script:probeRendered = $false
    $window.Add_ContentRendered({ $script:probeRendered = $true })
    $probeTimer = New-Object Windows.Threading.DispatcherTimer
    $probeTimer.Interval = [TimeSpan]::FromSeconds(3)
    $probeTimer.Add_Tick({ $probeTimer.Stop(); $window.Close() }.GetNewClosure())
    $probeTimer.Start()
}
[void]$window.ShowDialog()
if ($UiProbe) {
    if (-not $script:probeRendered) { throw 'Native preparation window was not rendered.' }
    Write-Output 'PASS: native WPF preparation window rendered.'
}
