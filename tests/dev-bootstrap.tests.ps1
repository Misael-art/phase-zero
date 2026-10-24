Describe 'Contributor bootstrap safety' {
    It 'plans without creating environment' {
        $bootstrap = Join-Path $PSScriptRoot '..\tools\dev-bootstrap.ps1'
        $sandbox = Join-Path $TestDrive 'plan-only'
        $old = $env:PZ_DEV_HOME
        try {
            $env:PZ_DEV_HOME = $sandbox
            $output = & $bootstrap -Action Plan -Profile Core | Out-String
            if ($output -notmatch 'Git.Git' -or $output -notmatch 'No PhaseZero service') {
                throw 'Plan omitted expected package/scope details.'
            }
            if (Test-Path -LiteralPath $sandbox) { throw 'Plan created environment.' }
        } finally { $env:PZ_DEV_HOME = $old }
    }
    It 'requires explicit consent for installation' {
        $bootstrap = Join-Path $PSScriptRoot '..\tools\dev-bootstrap.ps1'
        $sandbox = Join-Path $TestDrive 'guard'
        $old = $env:PZ_DEV_HOME
        try {
            $env:PZ_DEV_HOME = $sandbox
            $threw = $false
            try { & $bootstrap -Action Install -Profile Core | Out-Null } catch { $threw = $true }
            if (-not $threw) { throw 'Install accepted missing -Yes.' }
            if (Test-Path -LiteralPath $sandbox) { throw 'Guard created environment.' }
        } finally { $env:PZ_DEV_HOME = $old }
    }
}
