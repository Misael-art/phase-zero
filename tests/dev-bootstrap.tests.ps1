Describe 'Contributor bootstrap safety' {
    $script = Join-Path $PSScriptRoot '..\tools\dev-bootstrap.ps1'
    It 'plans without creating environment' {
        $sandbox = Join-Path $TestDrive 'plan-only'
        $old = $env:PZ_DEV_HOME
        try {
            $env:PZ_DEV_HOME = $sandbox
            $output = & $script -Action Plan -Profile Core | Out-String
            $output | Should Match 'Git.Git'
            $output | Should Match 'No PhaseZero service'
            (Test-Path -LiteralPath $sandbox) | Should Be $false
        } finally { $env:PZ_DEV_HOME = $old }
    }
    It 'requires explicit consent for installation' {
        $sandbox = Join-Path $TestDrive 'guard'
        $old = $env:PZ_DEV_HOME
        try {
            $env:PZ_DEV_HOME = $sandbox
            { & $script -Action Install -Profile Core } | Should Throw
            (Test-Path -LiteralPath $sandbox) | Should Be $false
        } finally { $env:PZ_DEV_HOME = $old }
    }
}
