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

Describe "New-OpenClawComposeYaml CRW healthcheck" {
    It "checks HTTP health using Bash builtins available in the CRW image" {
        $parameters = @{
            ContainerName = "openclaw-test"
            ImageName = "openclaw-source"
            HomeDir = "/home/node"
            WslDataDir = "/home/test/.openclaw-data"
            GatewayPort = 18789
            BridgePort = 18790
            GatewayToken = "test-token"
        }

        foreach ($yaml in @(
            (New-OpenClawComposeYaml @parameters),
            (New-OpenClawComposeYaml @parameters -Npm)
        )) {
            $yaml | Should Match 'exec 3<>/dev/tcp/127\.0\.0\.1/3000'
            $yaml | Should Match 'GET /health HTTP/1\.1'
            $yaml | Should Match 'read -r -t 3 response'
            $yaml | Should Match '\$\$response'
            $yaml | Should Match 'HTTP/1\.\[01\]" 200 "'
            $yaml | Should Not Match 'wget.*localhost:3000'
        }
    }
}