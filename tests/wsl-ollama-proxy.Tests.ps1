$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "New-OpenClawComposeYaml Windows Ollama proxy" {
    It "adds a host-network relay for the Windows Ollama endpoint" {
        $yaml = New-OpenClawComposeYaml `
            -ContainerName "openclaw-test" `
            -ImageName "openclaw-source" `
            -HomeDir "/home/node" `
            -WslDataDir "/home/test/.openclaw-data" `
            -GatewayPort 18789 `
            -BridgePort 18790 `
            -GatewayToken "test-token" `
            -OllamaHost "http://host.docker.internal:11435"

        $yaml | Should Match '(?m)^  ollama-windows-proxy:\r?$'
        $yaml | Should Match '(?m)^    network_mode: host\r?$'
        $yaml | Should Match 'OLLAMA_HOST=http://host\.docker\.internal:11435'
        $yaml | Should Match '(?ms)^  openclaw:.*?^    depends_on:.*?^      ollama-windows-proxy:\r?$.*?^        condition: service_healthy\r?$'
    }
}

Describe "New-OpenClawComposeYaml MCP startup" {
    It "does not install known-uninstallable MCP packages at boot" {
        $parameters = @{
            ContainerName = "openclaw-test"
            ImageName = "openclaw-source"
            HomeDir = "/home/node"
            WslDataDir = "/home/test/.openclaw-data"
            GatewayPort = 18789
            BridgePort = 18790
            GatewayToken = "test-token"
        }

        $sourceYaml = New-OpenClawComposeYaml @parameters
        $npmYaml = New-OpenClawComposeYaml @parameters -Npm

        $sourceYaml | Should Match 'npm install -g @microsoft/learn-cli'
        $sourceYaml | Should Not Match '@upstash/context7-mcp|mcp-finance|searxng-search|devdocs-mcp'
        $npmYaml | Should Match 'npm install -g @microsoft/learn-cli'
        $npmYaml | Should Not Match '@upstash/context7-mcp|mcp-finance|searxng-search|devdocs-mcp'
    }
}

Describe "New-OpenClawComposeYaml OpenClaw resources" {
    It "allocates six CPUs, twelve GiB, and a six GiB Node heap" {
        $yaml = New-OpenClawComposeYaml `
            -ContainerName "openclaw-test" `
            -ImageName "openclaw-source" `
            -HomeDir "/home/node" `
            -WslDataDir "/home/test/.openclaw-data" `
            -GatewayPort 18789 `
            -BridgePort 18790 `
            -GatewayToken "test-token"

        $openclawService = ($yaml -split '(?m)^  searxng:\r?$')[0]
        $openclawService | Should Match 'NODE_OPTIONS=--max-old-space-size=6144'
        $openclawService | Should Match "(?m)^          cpus: '6'\r?$"
        $openclawService | Should Match '(?m)^          memory: 12G\r?$'
    }
}