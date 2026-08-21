$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Get-OllamaWindowsSetupLines" {
    It "shows the commands required to expose Ollama to WSL" {
        @(Get-OllamaWindowsSetupLines) | Should Be @(
            '  taskkill /IM ollama.exe /F',
            '  setx OLLAMA_HOST "0.0.0.0:11434"',
            '  ollama serve'
        )
    }
}

Describe "Get-OllamaSummaryLines" {
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