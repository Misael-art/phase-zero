$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap-tools.ps1'

Describe 'Antigravity workspace setup' {
    It 'applies only Antigravity wiring and preserves user edits on rerun' {
        . $bootstrap -BootstrapUiLibraryMode -RotateSecretsSchedule none
        $project = Join-Path $TestDrive 'workspace with spaces'
        $profile = Join-Path $TestDrive 'user profile'
        $null = New-Item -ItemType Directory -Path $project
        $null = New-Item -ItemType Directory -Path (Join-Path $profile '.gemini')
        $rulesPath = Join-Path $profile '.gemini\AGENTS.md'
        Set-Content -LiteralPath $rulesPath -Value 'User rule'
        Mock Get-BootstrapUserProfileRoot { Join-Path $TestDrive 'user profile' }
        Mock Get-BootstrapAiMemoryExePath { 'C:\Managed tools\ai-memory.exe' }
        Mock Invoke-BootstrapAiMemoryWiring {
            @{ status = 'applied'; command = 'install-mcp' }
            @{ status = 'applied'; command = 'install-hooks' }
        }

        $plan = Invoke-BootstrapAiToolAction -ToolName 'antigravity-workflows' -Action 'configure' -InstallRoot $TestDrive -ProjectRoot $project -DryRun
        $plan.status | Should Be 'planned'
        (Test-BootstrapAntigravityWorkflows -ProjectRoot $project) | Should Be $false
        (Get-Content -LiteralPath $rulesPath) | Should Be 'User rule'
        Assert-MockCalled Invoke-BootstrapAiMemoryWiring -Times 0 -Exactly -Scope It

        $result = Invoke-BootstrapAiToolAction -ToolName 'antigravity-workflows' -Action 'configure' -InstallRoot $TestDrive -ProjectRoot $project -Yes
        $result.status | Should Be 'configured'
        (Get-Content -LiteralPath $result.skillPath -Raw) | Should Match 'memory_query'
        Set-Content -LiteralPath $result.skillPath -Value 'User customization'

        $null = Invoke-BootstrapAiToolAction -ToolName 'antigravity-workflows' -Action 'configure' -InstallRoot $TestDrive -ProjectRoot $project -Yes
        (Get-Content -LiteralPath $result.skillPath) | Should Be 'User customization'
        $rules = Get-Content -LiteralPath $rulesPath -Raw
        $rules | Should Match 'User rule'
        ([regex]::Matches($rules, 'BEGIN HOST RESOURCE CHECK').Count) | Should Be 1
        Assert-MockCalled Invoke-BootstrapAiMemoryWiring -Times 2 -Exactly -Scope It -ParameterFilter {
            @($Agents).Count -eq 1 -and $Agents[0] -eq 'antigravity-cli'
        }
    }
}
