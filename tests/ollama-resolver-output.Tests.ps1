$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'wsl-helpers.ps1')

Describe 'Accurate Ollama resolver output' {
    BeforeEach {
        $script:messages = @()
        $script:probeUrls = @()
        $script:desktop = $false
        $script:startupSucceeded = $true
        $script:reachableUrl = 'http://127.0.0.1:11434'
        Mock Write-Host { $script:messages += ($Object -join ' ') }
        Mock Write-Warning { $script:messages += $Message }
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '192.168.1.190' } }
        Mock Get-NetIPConfiguration { @() }
        Mock Invoke-WslData {
            if ($Command -match 'docker info') {
                if ($script:desktop) { 'Docker Desktop' } else { 'Debian' }
            } elseif ($Command -match 'ip route') { '192.168.1.1' }
            elseif ($Command -match 'nameserver') { 'nameserver 1.1.1.1' }
        }
        Mock Start-OllamaWindows { $script:startupSucceeded }
        Mock Start-OllamaWsl { $true }
        Mock Wait-OllamaEndpointFromWsl {
            $script:probeUrls += $Url
            return $Url -eq $script:reachableUrl
        }
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200 } }
    }

    It 'reports the verified upstream separately from the pending container relay' {
        $result = Resolve-OllamaHost -OllamaWindows
        $output = $script:messages -join "`n"
        $result.OllamaHost | Should Be 'http://host.docker.internal:11435'
        $result.Reachable | Should Be $true
        $result.ProbeUrl | Should Be 'http://127.0.0.1:11434'
        $result.ContainerRouteVerified | Should Be $false
        $output | Should Match 'Unverified address candidates'
        $output | Should Match 'Selected container relay.*pending Compose startup'
        $output | Should Match 'WSL host.*http://127.0.0.1:11434'
        $output | Should Match 'Container-route connectivity has not been verified'
        $output | Should Not Match 'taskkill|setx|winget upgrade|keeping fallback endpoint|enabling container relay|Ollama connectivity verified'
    }

    It 'does not label a direct Windows route as a relay' {
        $script:reachableUrl = 'http://192.168.1.190:11434'
        $result = Resolve-OllamaHost -OllamaWindows
        $result.ProbeUrl | Should Be $script:reachableUrl
        $result.OllamaHost | Should Be $script:reachableUrl
        $result.RelayRequired | Should Be $false
        ($script:messages -join "`n") | Should Not Match 'Selected container relay'
    }

    It 'retains the Docker Desktop route and describes its Windows-side verification' {
        $script:desktop = $true
        $result = Resolve-OllamaHost -OllamaWindows
        $result.OllamaHost | Should Be 'http://host.docker.internal:11434'
        $result.VerificationScope | Should Be 'Windows host'
        $result.ContainerRouteVerified | Should Be $false
        $script:probeUrls.Count | Should Be 0
    }

    It 'tests an explicitly supplied endpoint rather than silently substituting localhost' {
        $script:reachableUrl = 'http://host.docker.internal:11500'
        $result = Resolve-OllamaHost -OllamaHost $script:reachableUrl
        $result.ProbeUrl | Should Be $script:reachableUrl
        ($script:probeUrls -join ',') | Should Be $script:reachableUrl
        Assert-MockCalled Start-OllamaWindows -Times 0 -Exactly -Scope It
    }

    It 'does not say autostart was attempted for an unavailable external endpoint' {
        $result = Resolve-OllamaHost -OllamaHost 'http://external.example:11434'
        $result.Reachable | Should Be $false
        ($script:messages -join "`n") | Should Match 'No local startup was requested'
        ($script:messages -join "`n") | Should Not Match 'Auto-start was attempted'
    }

    It 'reports a failed Windows startup instead of silently ignoring its result' {
        $script:startupSucceeded = $false
        $script:reachableUrl = ''
        $result = Resolve-OllamaHost -OllamaWindows
        $result.Reachable | Should Be $false
        ($script:messages -join "`n") | Should Match 'Windows Ollama startup did not report success'
    }
}

Describe 'Windows upgrade messaging' {
    It 'does not promise a forced reinstall that winget upgrade does not perform' {
        (Get-Command Start-OllamaWindows).ScriptBlock.ToString() | Should Not Match 'forces a reinstall'
    }
}