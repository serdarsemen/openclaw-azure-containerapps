# Runtime Tool Validation Report

**Updated:** 2026-08-31

## Result

The WSL compose generator and both active validators now distinguish supported npm tooling from configured services and external integrations.

Container startup supports one npm-installed tool:

| Tool | Package | Executable | Startup behavior |
|------|---------|------------|------------------|
| Microsoft Learn CLI | `@microsoft/learn-cli` | `mslearn` | Installed only when missing; symlinked for PATH discovery |

## Removed Boot-Time Installs

The startup entrypoint no longer attempts to install or link:

- `@upstash/context7-mcp`
- `mcp-finance`
- `searxng-search`
- `devdocs-mcp`

These attempts did not make a usable server available and delayed every restart. In particular, `mcp-finance` is a placeholder package, while the SearXNG and DevDocs names do not identify npm MCP servers for this deployment.

## Validator Coverage

`validate-mcp-servers.ps1` and `validate-mcp-servers.sh` verify:

1. `@microsoft/learn-cli` is installed in the configured global npm prefix.
2. `mslearn` is executable and its discovery symlink exists.
3. Redis, SearXNG, CRW, and the OpenClaw gateway are reachable when enabled.
4. Expected Docker containers are running.

The validators do not report missing executables for the four unsupported package names and do not recommend installing them.

## External Integrations

MCP tools supplied by GitHub Copilot, VS Code extensions, remote endpoints, or another explicitly configured runtime are outside npm-global validation. Validate those integrations through their owning extension or service rather than manufacturing local executable links.

SearXNG remains an independent backend service in this repository. Its health check is intentionally retained:

```bash
curl http://127.0.0.1:8080/healthz
```

## Verification Commands

```powershell
Invoke-Pester -Path .\tests\wsl-ollama-proxy.Tests.ps1
.\validate-mcp-servers.ps1
```

```bash
bash -n ./validate-mcp-servers.sh
bash validate-mcp-servers.sh
```

The focused Pester regression asserts that generated WSL compose YAML retains the `@microsoft/learn-cli` bootstrap and contains none of the four unsupported package names.