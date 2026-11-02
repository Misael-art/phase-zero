Describe 'Memory portability integration contracts' {
    BeforeEach {
        $script:MemoryRepo = Split-Path -Parent $PSScriptRoot
        . (Join-Path $script:MemoryRepo 'bootstrap-tools.ps1') -BootstrapUiLibraryMode
    }

    It 'uses one verified pin for Windows and Linux metadata' {
        $pins = Get-Content (Join-Path $script:MemoryRepo 'packaging/ai-memory/pins.json') -Raw | ConvertFrom-Json
        $catalog = Get-BootstrapAiToolCatalog
        if ($catalog['ai-memory'].ReleaseTag -ne ('v' + $pins.version)) { throw 'Version pin differs' }
        if ($catalog['ai-memory'].ReleaseAssets.windows.Sha256 -ne $pins.assets.'windows-x86_64'.sha256) { throw 'Asset pin differs' }
    }

    It 'never mirrors raw databases or enrolls arbitrary drive letters' {
        $text = (Get-Command Sync-BootstrapAiMemoryWithSdCard).ScriptBlock.ToString()
        if ($text -match 'robocopy|/MIR|F:|DriveType') { throw 'Unsafe mirroring returned' }
        if ($text -notmatch 'Invoke-BootstrapAiMemoryPortability') { throw 'Canonical owner missing' }
        if ((Sync-BootstrapAiMemoryWithSdCard -DryRun).synced) { throw 'Dry run claimed sync' }
    }

    It 'routes native UI and CLI to the same memory owner' {
        $ui = Get-Content (Join-Path $script:MemoryRepo 'windows/ai/memory-ui.ps1') -Raw
        $cli = Get-Content (Join-Path $script:MemoryRepo 'windows/pz.ps1') -Raw
        if ($ui -notmatch 'memory_manager.py') { throw 'Missing contract: memory_manager.py' }
        if ($cli -notmatch 'memory_manager.py') { throw 'Missing contract: memory_manager.py' }
        if ($ui -notmatch 'BeginInvoke') { throw 'Missing contract: BeginInvoke' }
        if ($ui -notmatch 'PasswordBox') { throw 'Missing contract: PasswordBox' }
        if ($ui -notmatch 'expected-sha256') { throw 'Missing contract: expected-sha256' }
    }
}
