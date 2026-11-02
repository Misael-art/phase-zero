#Requires -Version 5.1
# Presentation only: the canonical Python owner validates and writes profiles.
function Show-PhaseZeroEconomyWindow {
    param([Parameter(Mandatory = $true)]$Owner, [Parameter(Mandatory = $true)][string]$RepoRoot)
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $python) {
        [System.Windows.MessageBox]::Show('Prepare Python 3.11+ pelo bootstrap.', 'Eficiência') | Out-Null
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    $policy = Get-Content -LiteralPath (Join-Path $RepoRoot 'assets/agent-skills/token-economy.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    $manager = Join-Path $RepoRoot 'linux/ai/token_economy.py'
    $dialog = New-Object System.Windows.Window
    $dialog.Title = 'Memória e eficiência dos agentes'
    $dialog.Owner = $Owner; $dialog.Width = 720; $dialog.Height = 660
    $dialog.MinWidth = 520; $dialog.MinHeight = 400
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Background = $Owner.Background; $dialog.Foreground = $Owner.Foreground
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '20'; $scroll.Content = $panel; $dialog.Content = $scroll
    $state = New-Object System.Windows.Controls.TextBlock
    $state.FontSize = 20; $state.TextWrapping = 'Wrap'; $state.Text = 'Escolha projeto e agente'
    $panel.Children.Add($state) | Out-Null
    $description = New-Object System.Windows.Controls.TextBlock
    $description.Text = 'ai-memory permanece vinculada. Perfil preserva conta, modelo, permissões e testes. Abra nova sessão após aplicar.'
    $description.TextWrapping = 'Wrap'; $description.Margin = '0,12,0,12'
    $panel.Children.Add($description) | Out-Null
    $project = New-Object System.Windows.Controls.TextBox
    $project.Text = $RepoRoot; $project.MinHeight = 32; $project.Margin = '0,4,0,8'
    [System.Windows.Automation.AutomationProperties]::SetName($project, 'Pasta do projeto')
    $panel.Children.Add($project) | Out-Null
    $agent = New-Object System.Windows.Controls.ComboBox
    $agent.MinHeight = 32; $agent.Margin = '0,4,0,8'
    foreach ($property in $policy.agents.PSObject.Properties) { $agent.Items.Add([string]$property.Name) | Out-Null }
    $agent.SelectedIndex = 0
    [System.Windows.Automation.AutomationProperties]::SetName($agent, 'Agente')
    $panel.Children.Add($agent) | Out-Null
    $profileSelector = New-Object System.Windows.Controls.ComboBox
    $profileSelector.Items.Add('Padrão · essencial') | Out-Null
    $profileSelector.Items.Add('Econômico · contexto enxuto') | Out-Null
    $profileSelector.SelectedIndex = 0; $profileSelector.MinHeight = 32
    [System.Windows.Automation.AutomationProperties]::SetName($profileSelector, 'Perfil de eficiência')
    $panel.Children.Add($profileSelector) | Out-Null
    $result = New-Object System.Windows.Controls.TextBlock
    $result.TextWrapping = 'Wrap'; $result.Margin = '0,12,0,12'
    $panel.Children.Add($result) | Out-Null
    $context = @{ Worker = $null; Pending = $null; Buttons = @(); Payload = $null; Action = ''; Project = '' }
    $invoke = {
        param([string]$Action, [string]$Report = '')
        if ($context.Worker) { return }
        $selectedProfile = if ($profileSelector.SelectedIndex -eq 1) { 'economy' } else { 'basic' }
        $arguments = @($Action, '--project', $project.Text, '--agent', [string]$agent.SelectedItem, '--profile', $selectedProfile, '--json')
        if ($Report) { $arguments += @('--path', $Report) }
        foreach ($button in $context.Buttons) { $button.IsEnabled = $false }
        $project.IsEnabled = $false; $agent.IsEnabled = $false; $profileSelector.IsEnabled = $false
        $state.Text = 'Operação em andamento…'; $context.Action = $Action; $context.Project = $project.Text
        $worker = [powershell]::Create()
        $worker.AddScript({ param($Exe, $Manager, $Arguments) & $Exe $Manager @Arguments }).AddArgument($python.Source).AddArgument($manager).AddArgument($arguments) | Out-Null
        $context.Worker = $worker; $context.Pending = $worker.BeginInvoke()
    }.GetNewClosure()
    $row = New-Object System.Windows.Controls.WrapPanel
    $panel.Children.Add($row) | Out-Null
    foreach ($spec in @(
        @('Escolher pasta', 'folder'), @('Atualizar estado', 'status'),
        @('Aplicar perfil', 'apply'), @('Restaurar padrão', 'reset'),
        @('Medir saída local', 'measure'), @('Importar comparação A/B', 'record'),
        @('Revisar componentes', 'review')
    )) {
        $button = New-Object System.Windows.Controls.Button
        $button.Content = $spec[0]; $button.Tag = $spec[1]
        $button.Margin = '0,6,8,6'; $button.MinHeight = 36
        $button.Style = $Owner.FindResource($(if ($spec[1] -eq 'apply') { 'PrimaryBtn' } else { 'GhostBtn' }))
        [System.Windows.Automation.AutomationProperties]::SetName($button, [string]$spec[0])
        $button.Add_Click({
            param($clickedButton)
            $action = [string]$clickedButton.Tag
            if ($action -eq 'folder') {
                $picker = New-Object System.Windows.Forms.FolderBrowserDialog
                try { if ($picker.ShowDialog() -eq 'OK') { $project.Text = $picker.SelectedPath; & $invoke 'status' } }
                finally { $picker.Dispose() }
                return
            }
            if ($action -in @('apply','reset')) {
                $answer = [System.Windows.MessageBox]::Show('Aplicar regras aditivas neste projeto? Regras próprias e memória serão preservadas; sessão atual não é reiniciada.', 'Revisar alteração', 'YesNo', 'Question')
                if ($answer -ne 'Yes') { return }
            }
            if ($action -eq 'record') {
                $picker = New-Object Microsoft.Win32.OpenFileDialog
                $picker.Filter = 'Metadados JSON|*.json'
                if ($picker.ShowDialog()) { & $invoke $action $picker.FileName }
                return
            }
            & $invoke $action
        }.GetNewClosure())
        $context.Buttons += $button; $row.Children.Add($button) | Out-Null
    }
    $details = New-Object System.Windows.Controls.TextBox
    $details.IsReadOnly = $true; $details.TextWrapping = 'Wrap'; $details.Height = 160
    $details.VerticalScrollBarVisibility = 'Auto'; $details.Style = $Owner.FindResource('DarkReadonly')
    $expander = New-Object System.Windows.Controls.Expander
    $expander.Header = 'Diagnóstico e evidências'; $expander.Content = $details
    $panel.Children.Add($expander) | Out-Null
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if (-not $context.Worker -or -not $context.Pending.IsCompleted) { return }
        $payload = $null
        try {
            $text = ($context.Worker.EndInvoke($context.Pending) | Out-String).Trim()
            $payload = $text | ConvertFrom-Json
            $details.Text = $text
            $state.Text = if ($payload.ok) { 'Operação concluída' } else { 'Revisão necessária' }
            $context.Payload = if ($payload.ok -and $payload.PSObject.Properties['agents']) { $payload } else { $null }
            $result.Text = if (-not $payload.ok) { [string]$payload.reason } else { 'Uso em sessão ainda não verificado. Custo API ainda não medido. Headroom permanece experimental.' }
        } catch { $state.Text = 'Estado indisponível'; $context.Payload = $null }
        finally { $context.Worker.Dispose(); $context.Worker = $null; $context.Pending = $null }
        $project.IsEnabled = $true; $agent.IsEnabled = $true; $profileSelector.IsEnabled = $true
        foreach ($button in $context.Buttons) {
            $button.IsEnabled = ($button.Tag -in @('folder','status')) -or ($null -ne $context.Payload)
        }
        if ($context.Payload) {
            $selected = @($context.Payload.agents | Where-Object { $_.id -eq [string]$agent.SelectedItem }) | Select-Object -First 1
            $memoryState = if ($selected.memory.connected) { 'serviço e vínculo presentes' } else { 'vínculo ausente ou não verificado' }
            $result.Text = ('ai-memory: {0}. Perfil: {1}. Regras configuradas: {2}. Uso em sessão e custo API não verificados.' -f $memoryState, $selected.profile, $selected.configured)
            $metric = $context.Payload.measurements.PSObject.Properties[[string]$agent.SelectedItem]
            if ($metric) {
                $result.Text += (' Saída local: {0}% de redução em bytes; tokens estimados, sem prova de fatura.' -f $metric.Value.reductionPercent)
            }
            $comparison = $context.Payload.usage.byAgent.PSObject.Properties[[string]$agent.SelectedItem]
            if ($comparison) {
                $result.Text += (' A/B reportado: {0} -> {1} tokens; aceite {2}/{3}; {4} regressao(oes) de tentativas.' -f $comparison.Value.baselineTokens, $comparison.Value.economyTokens, $comparison.Value.acceptedPairs, $comparison.Value.pairs, $comparison.Value.retryRegressions)
            }
            if ($selected.drift) {
                $result.Text = 'Alteração externa nas regras: revisão necessária antes de aplicar. Conteúdo preservado.'
                foreach ($button in $context.Buttons) {
                    if ($button.Tag -in @('apply','reset','measure','record')) { $button.IsEnabled = $false }
                }
            }
        }
        if ($payload -and $payload.ok -and $context.Action -notin @('status','review')) { & $invoke 'status' }
    }.GetNewClosure())
    $project.Add_TextChanged({
        $context.Payload = $null
        foreach ($button in $context.Buttons) { $button.IsEnabled = $button.Tag -in @('folder','status') }
    }.GetNewClosure())
    $agent.Add_SelectionChanged({ if (-not $context.Worker) { & $invoke 'status' } }.GetNewClosure())
    $dialog.Add_Closed({
        $timer.Stop()
        if ($context.Worker) { $context.Worker.Stop(); $context.Worker.Dispose() }
    }.GetNewClosure())
    $timer.Start(); & $invoke 'status'
    $dialog.ShowDialog() | Out-Null
}
