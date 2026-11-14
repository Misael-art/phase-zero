function Show-PhaseZeroDependenciesWindow {
    param($Owner, [string]$EntryPoint, [switch]$UiProbe)

    [xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dependências de aplicativos e projetos" Width="790" Height="530" MinWidth="470" MinHeight="400"
        WindowStartupLocation="CenterOwner" Background="#18202B" Foreground="#F0F3F7">
  <DockPanel Margin="18" LastChildFill="True">
    <StackPanel DockPanel.Dock="Top">
      <TextBlock x:Name="Target" TextWrapping="Wrap" Margin="0,0,0,6" />
      <WrapPanel Margin="0,0,0,8">
        <Button x:Name="Check" Content="_Verificar" MinHeight="34" Padding="12,0" Margin="0,0,8,4"/>
        <Button x:Name="Project" Content="_Abrir requisitos…" MinHeight="34" Padding="12,0" Margin="0,0,8,4"/>
        <ComboBox x:Name="Architecture" AutomationProperties.Name="Arquitetura do aplicativo ou projeto" Width="115" MinHeight="34" Margin="0,0,8,4"/>
        <Button x:Name="Clear" Content="_Limpar" MinHeight="34" Padding="12,0" Margin="0,0,8,4"/>
      </WrapPanel>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
      <TextBlock x:Name="Details" TextWrapping="Wrap" MaxHeight="80" Margin="0,0,0,6"/>
      <TextBlock x:Name="Outcome" AutomationProperties.Name="Resultado da instalação" TextWrapping="Wrap" Margin="0,0,0,6"/>
      <WrapPanel>
        <Button x:Name="Install" Content="_Instalar / reparar seleção" MinHeight="36" Padding="12,0" Margin="0,0,8,4"/>
        <Button x:Name="Official" Content="_Fonte oficial" MinHeight="36" Padding="12,0" Margin="0,0,8,4"/>
        <Button x:Name="Logs" Content="_Abrir log" MinHeight="36" Padding="12,0" Margin="0,0,8,4"/>
        <CheckBox x:Name="Large" Content="Autorizar downloads acima de 70 MB" Foreground="#F0F3F7" VerticalAlignment="Center" Margin="0,0,0,4"/>
      </WrapPanel>
    </StackPanel>
    <ListBox x:Name="Dependencies" SelectionMode="Extended" ScrollViewer.HorizontalScrollBarVisibility="Disabled"
             AutomationProperties.Name="Dependências verificadas, seleção múltipla">
      <ListBox.ItemTemplate>
        <DataTemplate><TextBlock Text="{Binding text}" TextWrapping="Wrap" Padding="5,4"/></DataTemplate>
      </ListBox.ItemTemplate>
    </ListBox>
  </DockPanel>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $layout
    $dialog = [Windows.Markup.XamlReader]::Load($reader)
    if ($Owner) { $dialog.Owner = $Owner } else { $dialog.WindowStartupLocation = 'CenterScreen' }
    $controls = @{}
    foreach ($name in 'Target','Check','Project','Architecture','Clear','Dependencies','Details','Outcome','Install','Official','Logs','Large') {
        $controls[$name] = $dialog.FindName($name)
    }
    $controls.Architecture.ItemsSource = @('Windows', 'x64', 'x86', 'arm64')
    $controls.Architecture.SelectedIndex = 0
    $context = @{ entryPoint = $EntryPoint; requirementFile = ''; report = $null; process = $null; rendered = $false; probeError = ''; restoring = $false }
    $updateSelection = {
        $rows = @($controls.Dependencies.SelectedItems)
        $controls.Details.Text = if ($rows.Count -eq 1) { $rows[0].detail } elseif ($rows.Count) { "$($rows.Count) itens selecionados." } else { 'Selecione os itens que deseja instalar ou reparar.' }
        $controls.Official.IsEnabled = ($rows.Count -eq 1 -and [bool]$rows[0].officialUrl)
        $controls.Install.IsEnabled = ($null -eq $context.process -and $rows.Count -gt 0 -and
            @($rows | Where-Object { -not $_.packageId -or $_.status -in @('unknown', 'not-applicable', 'satisfied') }).Count -eq 0)
    }.GetNewClosure()
    $refresh = {
        param([switch]$Restore)
        try {
            $arch = if ($controls.Architecture.SelectedItem -ne 'Windows') { [string]$controls.Architecture.SelectedItem } else { '' }
            $report = Get-PhaseZeroDependencyReport -RequirementFile $context.requirementFile -ApplicationArchitecture $arch
            if ($Restore -and $report.previousRun -and $report.previousRun['requirementFile'] -and
                (Test-Path -LiteralPath $report.previousRun['requirementFile'] -PathType Leaf)) {
                $context.requirementFile = [string]$report.previousRun['requirementFile']
                $arch = [string]$report.previousRun['applicationArchitecture']
                $context.restoring = $true
                try { if ($arch) { $controls.Architecture.SelectedItem = $arch } }
                finally { $context.restoring = $false }
                $report = Get-PhaseZeroDependencyReport -RequirementFile $context.requirementFile -ApplicationArchitecture $arch
            }
            $context.report = $report
            $previous = $report.previousRun
            $target = $report.target
            $controls.Target.Text = if ($target) {
                "Windows $($target.build) $($target.architecture) · $($target.systemDrive) $($target.volumeLabel) · $([Math]::Round($target.freeBytes / 1GB, 1)) GiB livres"
            } else { 'Identidade do Windows indisponível. ' + $report.targetError }
            if ($target -and -not $target.winget) { $controls.Target.Text += ' · WinGet indisponível' }
            if ($target -and $target.pendingRestart.Count) { $controls.Target.Text += ' · Reinício pendente' }
            if ($context.requirementFile) { $controls.Target.Text += "`n" + $context.requirementFile }
            $labels = @{ satisfied = 'Verificado'; missing = 'Ausente'; partial = 'Parcial'; insufficient = 'Versão insuficiente'; unknown = 'Desconhecido'; 'not-applicable' = 'Incompatível' }
            $controls.Dependencies.ItemsSource = @(foreach ($item in ($report.items | Sort-Object @{Expression='required';Descending=$true})) {
                $version = if ($item.version) { ' ' + $item.version } else { '' }
                $required = if ($item.required) { 'Projeto · ' } else { '' }
                $last = if ($previous -and $previous['results'] -and $previous['results'][$item.id]) { $previous['results'][$item.id] } else { $null }
                $detail = $item.detail
                if ($last -and $last['detail']) { $detail += "`nÚltima execução: " + $last['detail'] }
                [pscustomobject]@{ id = $item.id; text = "$required$($item.label) · $($labels[$item.status])$version"; detail = $detail
                    officialUrl = $item.officialUrl; packageId = $item.packageId; status = $item.status; required = $item.required }
            })
            if ($Restore -and $previous -and $previous['state'] -ne 'verified') {
                foreach ($row in $controls.Dependencies.ItemsSource) {
                    if ($row.id -in $previous['selected'] -and $row.packageId -and $row.status -in @('missing','partial','insufficient')) {
                        [void]$controls.Dependencies.SelectedItems.Add($row)
                    }
                }
            }
            $store = if ($report.store.status -eq 'unknown') { 'Store: consulta inconclusiva' } else { "Store: $($report.store.packages.Count) frameworks na conta atual" }
            if ($report.store.packages.Count) {
                $controls.Target.ToolTip = ($report.store.packages | ForEach-Object { "$($_.name) $($_.version) $($_.architecture) ($($_.health))" }) -join "`n"
            } else { $controls.Target.ToolTip = $report.store.detail }
            $outcome = $store
            if ($previous) {
                $lastState = @{ verified = 'Verificada'; pending = 'Com pendências'; running = 'Em andamento ou interrompida'; 'restart-required' = 'Reinício solicitado' }[$previous['state']]
                $outcome += " · Última fila: $lastState"
                if ($target -and $previous['hostId'] -and $previous['hostId'] -ne $target.hostId) { $outcome += ' · Computador mudou desde a última fila' }
            }
            if ($report.receiptError) { $outcome += ' · Registro anterior ilegível' }
            $controls.Outcome.Text = $outcome
            $controls.Logs.IsEnabled = ($previous -and $previous['log'] -and (Test-Path -LiteralPath $previous['log'] -PathType Leaf))
            & $updateSelection
        } catch {
            $controls.Outcome.Text = $_.Exception.Message
            $controls.Dependencies.ItemsSource = @()
            $controls.Install.IsEnabled = $false
            if ($UiProbe) { $context.probeError = $_.Exception.Message }
        }
    }.GetNewClosure()
    $controls.Dependencies.Add_SelectionChanged($updateSelection)
    $controls.Check.Add_Click({ & $refresh }.GetNewClosure())
    $controls.Architecture.Add_SelectionChanged({ if ($context.requirementFile -and -not $context.restoring) { & $refresh } }.GetNewClosure())
    $controls.Clear.Add_Click({ $context.requirementFile = ''; & $refresh }.GetNewClosure())
    $controls.Project.Add_Click({
        $picker = New-Object Microsoft.Win32.OpenFileDialog
        $picker.Filter = 'Requisitos de aplicativos e projetos (*.json;*.vcxproj)|*.json;*.vcxproj'
        if ($picker.ShowDialog($dialog)) { $context.requirementFile = $picker.FileName; & $refresh }
    }.GetNewClosure())
    $controls.Official.Add_Click({
        $row = $controls.Dependencies.SelectedItem
        if ($row -and $row.officialUrl) { Start-Process $row.officialUrl }
    }.GetNewClosure())
    $controls.Logs.Add_Click({
        if ($context.report.previousRun) { Start-Process notepad.exe -ArgumentList ('"' + $context.report.previousRun['log'] + '"') }
    }.GetNewClosure())
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(1)
    $timer.Add_Tick({
        if (-not $context.process.HasExited) { return }
        $timer.Stop()
        $exit = 1
        try { $exit = $context.process.ExitCode } catch { $controls.Outcome.Text = $_.Exception.Message }
        $context.process.Dispose()
        $context.process = $null
        foreach ($name in 'Check','Project','Architecture','Clear') { $controls[$name].IsEnabled = $true }
        & $refresh
        if ($exit -ne 0) { $controls.Outcome.Text += " · Instalação pendente (saída $exit). Selecione o item para ver o motivo." }
    }.GetNewClosure())
    $controls.Install.Add_Click({
        try {
            $ids = @($controls.Dependencies.SelectedItems | ForEach-Object { $_.id })
            $context.process = Start-PhaseZeroDependencyWorker -EntryPoint $context.entryPoint -Selected $ids -Report $context.report -AllowLargeDownloads:($controls.Large.IsChecked -eq $true)
            foreach ($name in 'Check','Project','Architecture','Clear','Install') { $controls[$name].IsEnabled = $false }
            $controls.Outcome.Text = 'Instalação em andamento. O registro permite conferir o resultado ao reabrir.'
            $timer.Start()
        } catch { $controls.Outcome.Text = $_.Exception.Message }
    }.GetNewClosure())
    $dialog.Add_Closed({
        $timer.Stop()
        if ($context.process) { $context.process.Dispose() }
    }.GetNewClosure())
    $dialog.Add_ContentRendered({
        & $refresh -Restore
        if ($UiProbe) {
            $context.rendered = ($controls.Dependencies.Items.Count -gt 0)
            if ($context.rendered) {
                $controls.Dependencies.SelectedIndex = 0
                $context.rendered = ($controls.Details.Text.Length -gt 0)
            }
            $dialog.Close()
        }
    }.GetNewClosure())
    [void]$dialog.ShowDialog()
    if ($UiProbe -and -not $context.rendered) { throw ('Dependency window did not render an inventory: ' + $context.probeError) }
}
