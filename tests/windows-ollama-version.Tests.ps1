$repoRoot = Split-Path $PSScriptRoot -Parent

function ollama { $global:LASTEXITCODE = 0; $script:versionOutput }
function winget { $script:wingetCalls++; $global:LASTEXITCODE = 1 }
. (Join-Path $repoRoot 'wsl-helpers.ps1')

function Invoke-WindowsOllamaVersionSetupForTest {
    param([switch] $Upgrade)
    $definition = (Get-Command Start-OllamaWindows).ScriptBlock.Ast
    $body = $definition.Find({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] }, $true).Body
    $statements = @()
    foreach ($statement in $body.Statements) {
        if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -eq '$env:OLLAMA_HOST') { break }
        $statements += $statement.Extent.Text
    }
    & ([scriptblock]::Create($statements -join "`n"))
}

Describe 'Windows Ollama version detection' {
    BeforeEach {
        $script:wingetCalls = 0
        $script:versionOutput = @('ollama version is 0.32.14', 'Warning: client version is 0.33.3')
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Tools\ollama.exe' } } -ParameterFilter { $Name -eq 'ollama' }
        Mock Write-Host {}
    }

    It 'distinguishes an outdated server from an already updated client' {
        $versions = Get-OllamaWindowsVersionInfo
        $versions.ClientVersion | Should Be '0.33.3'
        $versions.ServerVersion | Should Be '0.32.14'
    }

    It 'uses the common version when the client and server match' {
        $script:versionOutput = 'ollama version is 0.33.3'
        $versions = Get-OllamaWindowsVersionInfo
        $versions.ClientVersion | Should Be '0.33.3'
        $versions.ServerVersion | Should Be '0.33.3'
    }

    It 'detects the client version when no server is running' {
        $script:versionOutput = @('Warning: could not connect to a running Ollama instance', 'Warning: client version is 0.33.3')
        $versions = Get-OllamaWindowsVersionInfo
        $versions.ClientVersion | Should Be '0.33.3'
        $versions.ServerVersion | Should Be ''
    }

    It 'does not invoke winget when only the running server is outdated' {
        Update-OllamaWindows -LatestVersion '0.33.3' | Should Be $true
        $script:wingetCalls | Should Be 0
    }
}

Describe 'Outdated Windows Ollama server recovery' {
    BeforeEach {
        $script:versions = [pscustomobject]@{ ClientVersion = '0.33.3'; ServerVersion = '0.32.14' }
        Mock Get-OllamaWindowsVersionInfo { $script:versions }
        Mock Get-LatestOllamaVersion { '0.33.3' }
        Mock Get-Command { [pscustomobject]@{ Source = 'C:\Tools\ollama.exe' } } -ParameterFilter { $Name -eq 'ollama' }
        Mock Write-Host {}
        Mock Update-OllamaWindows { $true }
        Mock Stop-OllamaWindowsServer {}
    }

    It 'restarts an outdated server without trying to upgrade the current client' {
        Invoke-WindowsOllamaVersionSetupForTest
        Assert-MockCalled Update-OllamaWindows -Times 0 -Exactly -Scope It
        Assert-MockCalled Stop-OllamaWindowsServer -Times 1 -Exactly -Scope It -ParameterFilter { $ExecutablePath -eq 'C:\Tools\ollama.exe' }
    }

    It 'leaves a matching client and server running' {
        $script:versions.ServerVersion = '0.33.3'
        Invoke-WindowsOllamaVersionSetupForTest
        Assert-MockCalled Stop-OllamaWindowsServer -Times 0 -Exactly -Scope It
    }

    It 'still stops on a genuine required installation failure' {
        $script:versions.ClientVersion = '0.32.14'
        Mock Update-OllamaWindows { $false }
        $failure = ''
        try { Invoke-WindowsOllamaVersionSetupForTest } catch { $failure = $_.Exception.Message }
        $failure | Should Match 'Required Ollama upgrade failed'
        Assert-MockCalled Stop-OllamaWindowsServer -Times 0 -Exactly -Scope It
    }
}

Describe 'Stopping only the matching Ollama server' {
    BeforeEach {
        Mock Get-NetTCPConnection { [pscustomobject]@{ OwningProcess = 1234 } }
        Mock Get-Process { [pscustomobject]@{ Id = 1234; Path = 'C:\Tools\ollama.exe' } }
        Mock Get-Service { $null }
        Mock Stop-Process {}
        Mock Stop-Service {}
    }

    It 'stops the matching listener executable' {
        Stop-OllamaWindowsServer -ExecutablePath 'C:\Tools\ollama.exe'
        Assert-MockCalled Stop-Process -Times 1 -Exactly -Scope It -ParameterFilter { $Id -eq 1234 }
    }

    It 'refuses to stop a different executable using that port' {
        Mock Get-Process { [pscustomobject]@{ Id = 1234; Path = 'C:\Other\server.exe' } }
        $failure = ''
        try { Stop-OllamaWindowsServer -ExecutablePath 'C:\Tools\ollama.exe' } catch { $failure = $_.Exception.Message }
        $failure | Should Match 'different executable'
        Assert-MockCalled Stop-Process -Times 0 -Exactly -Scope It
    }

    It 'stops the service when the matching server is service-managed' {
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Stop-OllamaWindowsServer -ExecutablePath 'C:\Tools\ollama.exe'
        Assert-MockCalled Stop-Service -Times 1 -Exactly -Scope It
        Assert-MockCalled Stop-Process -Times 0 -Exactly -Scope It
    }
}