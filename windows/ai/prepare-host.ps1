#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Menu','InstallMemory','InstallApps','GitHub','Status')][string]$Action = 'Menu', [switch]$AllowLargeDownloads)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Execute este preparador dentro do Windows.' }
. (Join-Path $repoRoot 'bootstrap-tools.ps1') -BootstrapUiLibraryMode
. (Join-Path $PSScriptRoot 'host-instructions.ps1')
$packages = Join-Path $repoRoot 'packages'
$env:PZ_MEMORY_PACKAGES = $packages
$archive = Join-Path $packages 'ai-memory-windows-x86_64.zip'
if (Test-Path -LiteralPath $archive) { $env:AI_MEMORY_RELEASE_ARCHIVE = $archive }

function Update-PhaseZeroHostPath {
    Refresh-SessionPath
    foreach ($directory in @("${env:ProgramFiles(x86)}\GnuPG\bin", "$env:ProgramFiles\GnuPG\bin", "$env:LOCALAPPDATA\Programs\Python\Python313", "$env:USERPROFILE\.local\bin")) {
        if ((Test-Path -LiteralPath $directory) -and $env:PATH.Split(';') -notcontains $directory) { $env:PATH = $directory + ';' + $env:PATH }
    }
}
Update-PhaseZeroHostPath

if ($Action -ne 'Menu') {
    try {
        if ($Action -eq 'InstallMemory') {
            Set-PhaseZeroHostInstructions | Out-Null
            $winget = Resolve-CommandPath -Name winget
            if (-not $winget) { throw 'Atualize o Instalador de Aplicativos pela Microsoft Store para obter o WinGet.' }
            # Only runtime dependencies; no Node, Rust, WSL or Linux VM.
            foreach ($dependency in @(@{Command='python';Id='Python.Python.3.13'}, @{Command='gpg';Id='GnuPG.GnuPG'}, @{Command='gh';Id='GitHub.cli'})) {
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
            if ($AllowLargeDownloads) {
                $winget = Resolve-CommandPath -Name winget
                if (-not $winget) { throw 'WinGet ausente.' }
                Ensure-CodexInstaller -WingetPath $winget
                Ensure-ClaudeCode -WingetPath $winget
            } else {
                # Large payloads remain manual unless the caller explicitly authorizes them.
                Start-Process 'https://get.microsoft.com/installer/download/9PLM9XGG6VKS?cid=website_cta_psi'
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
$window = New-Object System.Windows.Window
$window.Title = 'PhaseZero - Codex, Claude e memoria'
$window.Width = 650; $window.Height = 590; $window.MinWidth = 480; $window.MinHeight = 460
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
$description.Text = "Prepare os aplicativos e a memoria em etapas, uma por vez. Depois importe sua chave de recuperacao e restaure o backup Linux pela janela Memoria. Entre nas contas dos aplicativos e no GitHub pelo navegador."
$description.TextWrapping = 'Wrap'; $description.FontSize = 17; $description.Margin = '0,0,0,15'
$panel.Children.Add($description) | Out-Null
function Add-PhaseZeroHostButton {
    param([string]$Text, [scriptblock]$Handler)
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text; $button.MinHeight = 48; $button.Margin = '0,0,0,10'; $button.FontSize = 16
    $button.Style = $window.FindResource('PrimaryBtn')
    $button.Add_Click($Handler); $panel.Children.Add($button) | Out-Null
}
$hostScript = $PSCommandPath
$run = {
    param($SelectedAction)
    # Blocking only this small launcher prevents overlapping installs/syncs.
    $window.Hide()
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $hostScript + '" -Action ' + $SelectedAction
        Start-Process powershell.exe -ArgumentList $arguments -Wait
    } finally { $window.Show() | Out-Null }
}.GetNewClosure()
Add-PhaseZeroHostButton '1. Instalar / reparar memoria e dependencias' { & $run 'InstallMemory' }.GetNewClosure()
Add-PhaseZeroHostButton '2. Abrir instaladores oficiais de Codex e Claude' { & $run 'InstallApps' }.GetNewClosure()
Add-PhaseZeroHostButton '3. Entrar no GitHub' { & $run 'GitHub' }.GetNewClosure()
Add-PhaseZeroHostButton '4. Memoria - recuperar, GitHub e sincronizacao' {
    Show-PhaseZeroMemoryWindow -Owner $window -RepoRoot $repoRoot
}.GetNewClosure()
Add-PhaseZeroHostButton 'Estado da memoria' { & $run 'Status' }.GetNewClosure()
Add-PhaseZeroHostButton 'Guia e destino de recuperacao' {
    Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $repoRoot 'LEIA-ME.txt') + '"')
}.GetNewClosure()
[void]$window.ShowDialog()
