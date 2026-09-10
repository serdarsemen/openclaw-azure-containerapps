$repoRoot = Split-Path $PSScriptRoot -Parent

function wsl {
    & wsl.exe @args
}

. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Invoke-Wsl service recovery" {
    BeforeEach {
        $script:bashAttempts = 0

        Mock wsl {
            if ($args[0] -eq '--shutdown') {
                $global:LASTEXITCODE = 0
                return
            }

            $script:bashAttempts++
            if ($script:bashAttempts -eq 1) {
                $global:LASTEXITCODE = -1
                return 'Wsl/Service/0x8007274c'
            }

            $global:LASTEXITCODE = 0
            return 'removed'
        }
        Mock Start-Sleep {}
        Mock Write-Host {}
    }

    It "restarts WSL before retrying a service-level socket failure" {
        Invoke-Wsl "docker rmi openclaw-source:base 2>/dev/null || true" | Should Be 'removed'

        Assert-MockCalled wsl 1 -ParameterFilter { $args[0] -eq '--shutdown' }
        $script:bashAttempts | Should Be 2
    }
}

Describe "Invoke-WslRetry build output" {
    BeforeEach {
        $script:bashAttempts = 0
        $script:displayedLines = New-Object 'System.Collections.Generic.List[string]'
        $script:displayedBeforeExit = $false
        Mock Start-Sleep {}
        Mock Write-Host {
            param($Object)
            $script:displayedLines.Add([string]$Object)
        }
        Mock wsl {
            $script:bashAttempts++
            Write-Output '#1 compiling'
            $script:displayedBeforeExit = $script:displayedLines.Contains('#1 compiling')
            Write-Output '#1 DONE 1.0s'
            $global:LASTEXITCODE = 0
        }
    }

    It "displays output before command exit without replaying it on success" {
        $result = @(Invoke-WslRetry 'build fixture' -StreamOutput)

        $script:displayedBeforeExit | Should Be $true
        $script:displayedLines.Count | Should Be 2
        $result.Count | Should Be 0
        $script:bashAttempts | Should Be 1
    }

    It "preserves buffered output for callers that do not request streaming" {
        $result = @(Invoke-WslRetry 'build fixture')

        $script:displayedBeforeExit | Should Be $false
        $script:displayedLines.Count | Should Be 0
        ($result -join '|') | Should Be '#1 compiling|#1 DONE 1.0s'
    }

    It "retains transient diagnostics and retries before succeeding" {
        Mock wsl {
            $script:bashAttempts++
            if ($script:bashAttempts -eq 1) {
                Write-Output 'fetch failed: connection reset by peer'
                $global:LASTEXITCODE = 1
            } else {
                Write-Output '#1 DONE 1.0s'
                $global:LASTEXITCODE = 0
            }
        }

        Invoke-WslRetry 'build fixture' -StreamOutput

        $script:bashAttempts | Should Be 2
        $script:displayedLines.Contains('fetch failed: connection reset by peer') | Should Be $true
        $script:displayedLines.Contains('#1 DONE 1.0s') | Should Be $true
        Assert-MockCalled Start-Sleep 1 -Exactly -Scope It -ParameterFilter { $Seconds -eq 5 }
    }

    It "includes captured output and exit code in non-transient failures" {
        Mock wsl {
            $script:bashAttempts++
            Write-Output 'compiler failed: invalid source'
            $global:LASTEXITCODE = 17
        }

        $failure = $null
        try { Invoke-WslRetry 'build fixture' -StreamOutput } catch { $failure = $_.Exception.Message }

        $failure | Should Match 'exit 17'
        $failure | Should Match 'compiler failed: invalid source'
        $script:displayedLines.Contains('compiler failed: invalid source') | Should Be $true
        $script:bashAttempts | Should Be 1
        Assert-MockCalled Start-Sleep 0 -Exactly -Scope It
    }

    It "reports the final attempt diagnostics after exhausting retries" {
        Mock wsl {
            $script:bashAttempts++
            Write-Output "fetch failed on attempt $script:bashAttempts"
            $global:LASTEXITCODE = 23
        }

        $failure = $null
        try { Invoke-WslRetry 'build fixture' -StreamOutput } catch { $failure = $_.Exception.Message }

        $failure | Should Match 'exit 23'
        $failure | Should Match 'fetch failed on attempt 3'
        $script:bashAttempts | Should Be 3
        Assert-MockCalled Start-Sleep 1 -Exactly -Scope It -ParameterFilter { $Seconds -eq 5 }
        Assert-MockCalled Start-Sleep 1 -Exactly -Scope It -ParameterFilter { $Seconds -eq 10 }
    }

    It "enables streamed plain progress on every deploy and update build" {
        foreach ($scriptName in @('deploy-openclaw-wsl.ps1', 'update-openclaw-wsl.ps1')) {
            $buildCalls = @(Get-Content (Join-Path $repoRoot $scriptName) |
                Where-Object { $_ -match '^\s*Invoke-WslRetry .*docker build ' })
            $buildCalls.Count | Should Be 4
            foreach ($buildCall in $buildCalls) {
                $buildCall | Should Match '--progress=plain'
                $buildCall | Should Match '-StreamOutput'
            }
        }
    }
}
