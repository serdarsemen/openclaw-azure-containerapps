$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'wsl-helpers.ps1')

Describe 'Windows Ollama runtime startup' {
    BeforeEach {
        $script:apiReady = $false
        $script:process = [pscustomobject]@{ Id = 1234; HasExited = $false; ExitCode = 1 }
        $script:launch = $null
        $script:requests = @()
        Mock Get-Service { $null }
        Mock Start-Service {}
        Mock Stop-OllamaWindowsServer {}
        Mock Invoke-RestMethod {
            $script:requests += @{ Uri = $Uri; NoProxy = $NoProxy }
            if (-not $script:apiReady) { throw 'not listening' }
            [pscustomobject]@{ version = '0.33.3' }
        }
        Mock Get-NetTCPConnection { [pscustomobject]@{ LocalAddress = '0.0.0.0'; OwningProcess = 1234 } }
        Mock Start-Process {
            $script:launch = @{ FilePath = $FilePath; PassThru = $PassThru; ErrorAction = $ErrorAction; Stdout = $RedirectStandardOutput; Stderr = $RedirectStandardError }
            $script:apiReady = $true
            return $script:process
        }
        Mock Start-Sleep {}
        Mock Write-Host {}
        $parameters = @{
            ExecutablePath = 'C:\Tools\Ollama\ollama.exe'
            ExpectedVersion = '0.33.3'
            LogDirectory = $TestDrive
            TimeoutSeconds = 1
        }
    }

    It 'launches the resolved executable with captured output and verifies its API version directly' {
        Start-OllamaWindowsRuntime @parameters | Should Be $true
        $script:launch.FilePath | Should Be $parameters.ExecutablePath
        $script:launch.PassThru | Should Be $true
        (Get-Command Start-OllamaWindowsRuntime).ScriptBlock.ToString() | Should Match '-PassThru -ErrorAction Stop'
        $script:launch.Stderr | Should Match '\.stderr\.log$'
        $script:launch.Stdout | Should Match '\.stdout\.log$'
        $script:requests[-1].Uri | Should Be 'http://127.0.0.1:11434/api/version'
        $script:requests[-1].NoProxy | Should Be $true
    }

    It 'reuses an already healthy server without launching another process' {
        $script:apiReady = $true
        Start-OllamaWindowsRuntime @parameters | Should Be $true
        Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
    }

    It 'reports launch failures immediately instead of waiting for readiness' {
        Mock Start-Process { throw 'executable could not be started' }
        $failure = ''
        try { Start-OllamaWindowsRuntime @parameters } catch { $failure = $_.Exception.Message }
        $failure | Should Match 'executable could not be started'
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }

    It 'reports an early server exit and the diagnostic path without waiting' {
        Mock Start-Process {
            Set-Content -LiteralPath $RedirectStandardError -Value 'Error: listen tcp 0.0.0.0:11434: bind: Only one usage of each socket address is normally permitted.'
            [pscustomobject]@{ HasExited = $true; ExitCode = 1; Id = 1234 }
        }
        $failure = ''
        try { Start-OllamaWindowsRuntime @parameters } catch { $failure = $_.Exception.Message }
        $failure | Should Match 'exited.*1'
        $failure | Should Match '\.stderr\.log'
        $failure | Should Match 'port 11434'
        $failure | Should Match 'mirrored'
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }

    It 'does not accept a stale server or loopback-only listener' {
        $script:apiReady = $true
        Mock Invoke-RestMethod { [pscustomobject]@{ version = '0.32.14' } }
        Mock Get-NetTCPConnection { [pscustomobject]@{ LocalAddress = '127.0.0.1' } }
        Mock Start-Process { [pscustomobject]@{ HasExited = $true; ExitCode = 1; Id = 1234 } }
        $failure = ''
        try { Start-OllamaWindowsRuntime @parameters } catch { $failure = $_.Exception.Message }
        ($failure.Length -gt 0) | Should Be $true
    }
}