#Requires -Version 5.1
# WPF view only. All operations delegate to the same cross-platform CLI owner.
function Show-PhaseZeroMemoryWindow {
    param([Parameter(Mandatory = $true)]$Owner, [Parameter(Mandatory = $true)][string]$RepoRoot)
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $python) {
        [System.Windows.MessageBox]::Show('Prepare Python 3.11+ pelo bootstrap de desenvolvimento antes de usar portabilidade.', 'Memória') | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Window
    $dialog.Title = 'Memória dos agentes'
    $dialog.Owner = $Owner
    $dialog.Width = 720; $dialog.Height = 640
    $dialog.MinWidth = 520; $dialog.MinHeight = 400
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Background = $Owner.Background
    $dialog.Foreground = $Owner.Foreground
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '20'
    $scroll.Content = $panel; $dialog.Content = $scroll
    $context = @{ Worker = $null; Pending = $null; Buttons = @(); Result = $null; Curation = $null; Review = $null }
    $manager = Join-Path $RepoRoot 'linux/ai/memory_manager.py'

    $state = New-Object System.Windows.Controls.TextBlock
    $state.Text = 'Verificando memória…'; $state.TextWrapping = 'Wrap'
    $state.FontSize = 20; $state.Margin = '0,0,0,10'
    $panel.Children.Add($state) | Out-Null
    $caption = New-Object System.Windows.Controls.TextBlock
    $caption.Text = 'Conhecimento por projeto entre hosts. Backups completos privados por equipamento.'
    $caption.TextWrapping = 'Wrap'; $caption.Margin = '0,0,0,12'
    $panel.Children.Add($caption) | Out-Null
    $result = New-Object System.Windows.Controls.TextBox
    $result.IsReadOnly = $true; $result.TextWrapping = 'Wrap'; $result.Height = 130
    $result.VerticalScrollBarVisibility = 'Auto'
    $result.Style = $Owner.FindResource('DarkReadonly')
    $panel.Children.Add($result) | Out-Null

    $invoke = {
        param([string[]]$Command, [Security.SecureString]$Password = $null)
        if ($context.Worker) { return }
        foreach ($button in $context.Buttons) { $button.IsEnabled = $false }
        $state.Text = 'Operação em andamento…'
        $worker = [powershell]::Create()
        $worker.AddScript({
            param($PythonExe, $ManagerPath, $Arguments, [Security.SecureString]$Secret)
            $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            if ($Secret) {
                $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
                try {
                    # Native stdin is the only plaintext boundary; never argv/logs.
                    $plainInput = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
                    $plainInput | & $PythonExe $ManagerPath @Arguments
                } finally {
                    $plainInput = $null
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
                    $Secret.Dispose()
                }
            } else { & $PythonExe $ManagerPath @Arguments }
        }).AddArgument($python.Source).AddArgument($manager).AddArgument($Command).AddArgument($Password) | Out-Null
        $context.Worker = $worker
        $context.Pending = $worker.BeginInvoke()
    }.GetNewClosure()

    $row = $null
    $addRow = {
        $newRow = New-Object System.Windows.Controls.WrapPanel
        $newRow.Margin = '0,8,0,8'
        $panel.Children.Add($newRow) | Out-Null
        return $newRow
    }.GetNewClosure()
    $addButton = {
        param($Row, [string]$Title, [scriptblock]$Handler, [bool]$Primary = $false)
        $button = New-Object System.Windows.Controls.Button
        $button.Content = $Title; $button.Margin = '0,0,8,8'; $button.MinHeight = 36
        $button.Style = $Owner.FindResource($(if ($Primary) { 'PrimaryBtn' } else { 'GhostBtn' }))
        [System.Windows.Automation.AutomationProperties]::SetName($button, $Title)
        $button.Add_Click($Handler)
        $context.Buttons += $button
        $Row.Children.Add($button) | Out-Null
    }.GetNewClosure()
    $addField = {
        param([string]$Label, [string]$Default = '')
        $labelControl = New-Object System.Windows.Controls.TextBlock
        $labelControl.Text = $Label; $labelControl.Margin = '0,8,0,4'
        $panel.Children.Add($labelControl) | Out-Null
        $inputControl = New-Object System.Windows.Controls.TextBox
        $inputControl.Text = $Default; $inputControl.Style = $Owner.FindResource('DarkInput'); $inputControl.MinHeight = 32
        [System.Windows.Automation.AutomationProperties]::SetName($inputControl, $Label)
        $panel.Children.Add($inputControl) | Out-Null
        return $inputControl
    }.GetNewClosure()
    $row = & $addRow
    & $addButton $row 'Instalar / atualizar' { & $invoke @('install','--json') }.GetNewClosure() $true
    & $addButton $row 'Reparar' { & $invoke @('repair','--json') }.GetNewClosure()
    & $addButton $row 'Sincronizar agora' { & $invoke @('sync','--json') }.GetNewClosure() $true
    & $addButton $row 'Atualizar estado' { & $invoke @('status','--json') }.GetNewClosure()

    $curationTitle = New-Object System.Windows.Controls.TextBlock
    $curationTitle.Text = 'Curadoria do memorial'
    $curationTitle.FontSize = 18; $curationTitle.Margin = '0,8,0,4'
    $panel.Children.Add($curationTitle) | Out-Null
    $curationResult = New-Object System.Windows.Controls.TextBox
    $curationResult.Text = 'Selecione um memorial.md para gerar uma proposta de revisão.'
    $curationResult.IsReadOnly = $true; $curationResult.TextWrapping = 'Wrap'
    $curationResult.MaxHeight = 220; $curationResult.VerticalScrollBarVisibility = 'Auto'
    $curationResult.Style = $Owner.FindResource('DarkReadonly')
    [System.Windows.Automation.AutomationProperties]::SetName($curationResult, 'Estado, evidências e comparação da curadoria')
    $panel.Children.Add($curationResult) | Out-Null
    $row = & $addRow
    & $addButton $row 'Curar memorial' {
        $picker = New-Object Microsoft.Win32.OpenFileDialog
        $picker.Title = 'Selecionar memorial'
        $picker.Filter = 'Memorial (memorial.md)|memorial.md'
        $picker.InitialDirectory = Join-Path $RepoRoot 'assets/agent-skills'
        if ($picker.ShowDialog($dialog)) {
            $context.Review = $null
            & $invoke @('curate-plan','--path',$picker.FileName)
        }
    }.GetNewClosure()
    & $addButton $row 'Revisar proposta' {
        $context.Review = $null
        & $invoke @('curate-review','--id',$context.Curation.id)
    }.GetNewClosure()
    $reviewButton = $context.Buttons[-1]
    $reviewButton.IsEnabled = $false
    & $addButton $row 'Aplicar ao memorial local' {
        $review = $context.Review
        $approval = [System.Windows.MessageBox]::Show($dialog, "Atualizar este memorial local com as mudanças revisadas?`n`n$($review.path)", 'Aplicar curadoria', 'OKCancel', 'Question', 'Cancel')
        if ($approval -eq 'OK') {
            & $invoke @('curate-apply','--id',$review.id,'--confirm','APPLY-CURATION','--expected-sha256',$review.sha256)
        }
    }.GetNewClosure()
    $applyButton = $context.Buttons[-1]
    $applyButton.IsEnabled = $false

    $row = & $addRow
    & $addButton $row 'Ligar automação' { & $invoke @('automatic','--enabled','yes') }.GetNewClosure()
    & $addButton $row 'Pausar automação' { & $invoke @('automatic','--enabled','no') }.GetNewClosure()
    & $addButton $row 'Backup completo' { & $invoke @('backup','--json') }.GetNewClosure()

    $project = & $addField 'Projeto no ai-memory'
    $workspace = & $addField 'Workspace' 'default'
    $checkout = & $addField 'Pasta do projeto'
    $sharedIdentity = & $addField 'ID compartilhado de outro host (opcional; para projetos sem remoto Git)'
    $row = & $addRow
    & $addButton $row 'Compartilhar conhecimento deste projeto' {
        $command = @('scope-add','--project',$project.Text,'--workspace',$workspace.Text,'--repo-path',$checkout.Text)
        if ($sharedIdentity.Text) { $command += @('--identity',$sharedIdentity.Text) }
        & $invoke $command
    }.GetNewClosure()
    & $addButton $row 'Preparar projeto novo neste host' {
        $command = @('scope-add','--project',$project.Text,'--workspace',$workspace.Text,'--repo-path',$checkout.Text,'--create-project')
        if ($sharedIdentity.Text) { $command += @('--identity',$sharedIdentity.Text) }
        & $invoke $command
    }.GetNewClosure()
    $device = & $addField 'Dispositivo montado (ex.: F:\)'
    $row = & $addRow
    & $addButton $row 'Cadastrar dispositivo' { & $invoke @('device-add','--path',$device.Text) }.GetNewClosure()
    $repository = & $addField 'GitHub privado: usuario/repositorio'
    $row = & $addRow
    & $addButton $row 'Conectar destino privado' { & $invoke @('github','--repository',$repository.Text) }.GetNewClosure()
    & $addButton $row 'Entrar no GitHub' { & $invoke @('github-login') }.GetNewClosure()
    & $addButton $row 'Backups no GitHub' { & $invoke @('github-open-backups') }.GetNewClosure()
    & $addButton $row 'Criar repositório privado' {
        if ([System.Windows.MessageBox]::Show('Criar repositório dedicado privado no GitHub autenticado?', 'Memória', 'YesNo') -eq 'Yes') {
            & $invoke @('github','--repository',$repository.Text,'--create')
        }
    }.GetNewClosure()
    $file = & $addField 'Arquivo de backup ou chave de recuperação (.gpg)'
    $row = & $addRow
    & $addButton $row 'Selecionar arquivo .gpg' {
        $picker = New-Object Microsoft.Win32.OpenFileDialog
        $picker.Filter = 'OpenPGP (*.gpg)|*.gpg'
        if ($picker.ShowDialog($dialog)) { $file.Text = $picker.FileName }
    }.GetNewClosure()
    $passwordLabel = New-Object System.Windows.Controls.TextBlock
    $passwordLabel.Text = 'Senha para exportar/importar chave (mínimo 12 caracteres; nunca enviada no comando)'
    $passwordLabel.TextWrapping = 'Wrap'; $passwordLabel.Margin = '0,8,0,4'
    $panel.Children.Add($passwordLabel) | Out-Null
    $password = New-Object System.Windows.Controls.PasswordBox
    $password.MinHeight = 32
    [System.Windows.Automation.AutomationProperties]::SetName($password, 'Senha da chave de recuperação')
    $panel.Children.Add($password) | Out-Null
    $row = & $addRow
    & $addButton $row 'Guardar chave de recuperação' {
        if (-not $file.Text) {
            $picker = New-Object Microsoft.Win32.SaveFileDialog
            $picker.FileName = 'phasezero-memory-recovery.gpg'; $picker.Filter = 'OpenPGP (*.gpg)|*.gpg'
            if (-not $picker.ShowDialog($dialog)) { return }
            $file.Text = $picker.FileName
        }
        $value = $password.SecurePassword.Copy(); $password.Clear()
        & $invoke @('key-export','--path',$file.Text,'--passphrase-stdin') $value
    }.GetNewClosure()
    & $addButton $row 'Importar chave neste host' {
        $value = $password.SecurePassword.Copy(); $password.Clear()
        & $invoke @('key-import','--path',$file.Text,'--passphrase-stdin') $value
    }.GetNewClosure()
    & $addButton $row 'Verificar backup' { & $invoke @('verify','--path',$file.Text) }.GetNewClosure()
    & $addButton $row 'Revisar restauração' { & $invoke @('restore-plan','--path',$file.Text) }.GetNewClosure()
    & $addButton $row 'Restaurar backup revisado' {
        if (-not $context.Result -or $context.Result.state -ne 'restore-planned' -or
            $context.Result.bundlePath -ne [IO.Path]::GetFullPath($file.Text)) {
            $state.Text = 'Use Revisar restauração para este arquivo antes de aplicar.'
            return
        }
        if ([System.Windows.MessageBox]::Show('Restaurar backup selecionado com pré-backup e parada do servidor?', 'Memória', 'YesNo', 'Warning') -eq 'Yes') {
            & $invoke @('restore','--path',$file.Text,'--confirm','RESTORE','--expected-sha256',$context.Result.sha256)
        }
    }.GetNewClosure()
    $conflict = & $addField 'ID do conflito recebido (listado no estado)'
    $row = & $addRow
    & $addButton $row 'Manter versão local' { & $invoke @('resolve','--id',$conflict.Text,'--prefer','server') }.GetNewClosure()
    & $addButton $row 'Usar versão recebida' { & $invoke @('resolve','--id',$conflict.Text,'--prefer','repo') }.GetNewClosure()
    $interval = & $addField 'Intervalo do conhecimento em minutos (5 a 1440)' '15'
    $hours = & $addField 'Intervalo de backup completo em horas (1 a 168)' '24'
    $keep = & $addField 'Snapshots preservados por host (2 a 30)' '7'
    $row = & $addRow
    & $addButton $row 'Salvar frequência e retenção' { & $invoke @('settings','--interval',$interval.Text,'--backup-hours',$hours.Text,'--keep',$keep.Text) }.GetNewClosure()
    $diagnostics = New-Object System.Windows.Controls.Expander
    $diagnostics.Header = 'Diagnóstico avançado'
    $technical = New-Object System.Windows.Controls.TextBox
    $technical.IsReadOnly = $true; $technical.TextWrapping = 'Wrap'; $technical.MaxHeight = 220
    $technical.VerticalScrollBarVisibility = 'Auto'; $technical.Style = $Owner.FindResource('DarkReadonly')
    $diagnostics.Content = $technical; $panel.Children.Add($diagnostics) | Out-Null

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if (-not $context.Worker -or -not $context.Pending.IsCompleted) { return }
        $nextCuration = $null
        try {
            $output = $context.Worker.EndInvoke($context.Pending)
            $data = ($output -join "`n") | ConvertFrom-Json
            $context.Result = $data
            $state.Text = if ($data.ok) { 'Operação concluída' } else { 'Memória requer atenção' }
            $technical.Text = $data | ConvertTo-Json -Depth 8
            if ($data.state -eq 'curation-planned') {
                $curationResult.Text = $data.summary
                $approval = [System.Windows.MessageBox]::Show($dialog, "$($data.summary)`n`n$($data.path)`n`n$($data.nextAction)", 'Gerar proposta de curadoria', 'OKCancel', 'Question', 'Cancel')
                if ($approval -eq 'OK') {
                    $curationResult.Text = 'Verificando cota e gerando proposta…'
                    $nextCuration = @('curate','--path',$data.path,'--expected-sha256',$data.sha256,'--confirm','CURATE')
                } else { $curationResult.Text = 'Curadoria cancelada antes do envio.' }
            } elseif ($data.state -eq 'curation-ready') {
                $context.Curation = $data
                $curationResult.Text = "$($data.summary) $($data.provider) · $($data.model)"
            } elseif ($data.state -eq 'curation-reviewed') {
                $context.Review = $data
                $findings = $data.achados | ForEach-Object { "$($_.tipo) · $($_.motivo)`nEvidência`n$($_.evidencia)" }
                $curationResult.Text = "$($data.path)`n$($data.provider) · $($data.model)`n`n" + ($findings -join "`n`n") + "`n`n" + $data.diff
                $curationResult.ScrollToHome()
                $curationResult.Focus() | Out-Null
            } elseif ($data.state -eq 'curation-applied') {
                $context.Curation = $null; $context.Review = $null
                $curationResult.Text = $data.summary
            } elseif ($data.reason -like 'curation-*' -or $data.reason -eq 'source-changed-before-replace') {
                $context.Review = $null
                $curationResult.Text = $data.message
            }
            if ($data.PSObject.Properties.Name -contains 'installed') {
                $context.Curation = $data.curation
                if ($data.curation.id) {
                    $statusText = if ($data.curation.applied) { 'Alterações aplicadas ao memorial local.' }
                    elseif ($data.curation.findings) { "$($data.curation.findings) achado(s) para revisar." }
                    else { 'A revisão não identificou achados com evidência.' }
                    $curationResult.Text = "$statusText $($data.curation.provider) · $($data.curation.model)"
                }
                $state.Text = if ($data.installed -and $data.serverReachable) { 'Memória ativa' } elseif ($data.installed) { 'Memória precisa de reparo' } else { 'Memória não instalada' }
                $lines = @('Automação: ' + $(if ($data.automatic) { 'ligada' } else { 'pausada' }))
                $lines += 'Projetos compartilhados: ' + (($data.scopes | ForEach-Object project) -join ', ')
                if ($data.sync.PSObject.Properties.Name -contains 'targets') {
                    foreach ($target in $data.sync.targets) {
                        $lines += 'Destino: ' + $target.state
                        if ($target.lastBackup) { $lines += 'Backup verificado: ' + $target.lastBackup.verifiedAt }
                    }
                }
                $lines += $(if ($data.recoveryExported) { 'Chave de recuperação exportada.' } else { 'Guarde chave de recuperação fora deste equipamento.' })
                $result.Text = $lines -join "`n"
            } elseif ($data.PSObject.Properties.Name -contains 'message') { $result.Text = $data.message }
            elseif ($data.PSObject.Properties.Name -contains 'manifest') {
                $result.Text = 'Origem: ' + $data.manifest.sourceHost.name + "`nData: " + $data.manifest.createdAt + "`nArquivos verificados: " + $data.manifest.items.Count + "`nConfiguração local preservada."
            } else { $result.Text = $(if ($data.ok) { 'Operação concluída. Atualize estado para conferir destinos e backups.' } else { 'Operação interrompida. Confira diagnóstico avançado.' }) }
        } catch { $state.Text = 'Operação falhou. Confira dependências e cofre do sistema.' }
        finally {
            $context.Worker.Dispose(); $context.Worker = $null; $context.Pending = $null
            foreach ($button in $context.Buttons) { $button.IsEnabled = $true }
            $reviewButton.IsEnabled = [bool]($context.Curation.findings -and -not $context.Curation.applied)
            $applyButton.IsEnabled = [bool]$context.Review
        }
        if ($nextCuration) { & $invoke $nextCuration }
    }.GetNewClosure())
    $dialog.Add_Closing({ param($ClosingWindow, $ClosingArguments) if ($context.Worker) { $ClosingArguments.Cancel = $true; $ClosingWindow.Title = 'Memória · operação em andamento'; $state.Text = 'Aguarde conclusão da operação para fechar.' } }.GetNewClosure())
    $timer.Start()
    & $invoke @('status','--json')
    try { $dialog.ShowDialog() | Out-Null } finally { $timer.Stop(); $password.Clear() }
}
