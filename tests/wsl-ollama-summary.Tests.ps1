$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Get-OllamaWindowsSetupLines" {
    It "shows the commands required to expose Ollama to WSL" {
        @(Get-OllamaWindowsSetupLines) | Should Be @(
            '  Manual recovery only if automatic startup fails; close the existing Ollama tray/server first:',
            '  taskkill /IM ollama.exe /F',
            '  $env:OLLAMA_HOST = "0.0.0.0:11434"',
            '  setx OLLAMA_HOST "0.0.0.0:11434"',
            '  ollama serve'
        )
    }
}

Describe "Get-OllamaWindowsUpgradeLines" {
    It "shows how to upgrade Ollama on Windows and restart with the required host binding" {
        @(Get-OllamaWindowsUpgradeLines) | Should Be @(
            '  Optional Windows upgrade (winget may report no applicable upgrade):',
            '  winget upgrade --id Ollama.Ollama -e',
            '  ollama --version',
            '  Close the existing Ollama tray/server before restarting:',
            '  taskkill /IM ollama.exe /F',
            '  $env:OLLAMA_HOST = "0.0.0.0:11434"',
            '  setx OLLAMA_HOST "0.0.0.0:11434"',
            '  ollama serve'
        )
    }
}

Describe "Get-OllamaSummaryLines" {
    It "labels a direct Windows endpoint without calling it a relay" {
        $lines = @(Get-OllamaSummaryLines -OllamaWindows -OllamaHost 'http://192.168.1.190:11434')
        $lines[-1] | Should Be '  Container route: http://192.168.1.190:11434 (direct Windows endpoint)'
    }

    It "labels the Docker Desktop host route without calling it a WSL relay" {
        $lines = @(Get-OllamaSummaryLines -OllamaWindows -OllamaHost 'http://host.docker.internal:11434')
        $lines[-1] | Should Be '  Container route: http://host.docker.internal:11434 (Docker host endpoint)'
    }

    It "shows the Windows endpoint and internal WSL relay" {
        $lines = @(Get-OllamaSummaryLines `
            -OllamaWindows `
            -OllamaHost "http://host.docker.internal:11435")

        $lines | Should Be @(
            "  Ollama:          http://localhost:11434 (Windows host)",
            "  Container route: http://host.docker.internal:11435 (WSL relay)"
        )
    }

    It "preserves the Docker sidecar summary" {
        @(Get-OllamaSummaryLines -OllamaSidecar) | Should Be @(
            "  Ollama:     http://localhost:11434 (Docker sidecar)"
        )
    }

    It "preserves the WSL-native summary" {
        @(Get-OllamaSummaryLines `
            -OllamaWsl `
            -OllamaHost "http://host.docker.internal:11434") | Should Be @(
            "  Ollama:     http://host.docker.internal:11434 (WSL native)"
        )
    }

    It "preserves the external summary" {
        @(Get-OllamaSummaryLines `
            -OllamaHost "http://ollama.example:11434") | Should Be @(
            "  Ollama:     http://ollama.example:11434 (external)"
        )
    }

    It "preserves the disabled summary" {
        @(Get-OllamaSummaryLines) | Should Be @(
            "  Ollama:     disabled"
        )
    }
}