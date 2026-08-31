# Quick Start: Runtime Tool Validation

Last updated: 2026-08-31

## TL;DR

The container startup installs only the supported Microsoft Learn CLI when it is missing. It does not attempt to install placeholder packages or packages that are not MCP servers.

Run the validator for your environment:

```powershell
.\validate-mcp-servers.ps1
```

```bash
bash validate-mcp-servers.sh
```

## Supported npm Tooling

| Tool                | Package                | Executable |
| ------------------- | ---------------------- | ---------- |
| Microsoft Learn CLI | `@microsoft/learn-cli` | `mslearn`  |

WSL container startup uses the persistent npm prefix at `$HOME/.openclaw/npm-global`. If `mslearn` is absent, startup installs it and creates a PATH-discovery symlink:

```bash
npm install -g @microsoft/learn-cli
ln -sf "$HOME/.openclaw/npm-global/bin/mslearn" "$HOME/.local/node_modules/.bin/mslearn"
```

## Unsupported Package Names

Do not install or validate these names as runtime MCP servers:

- `mcp-finance`: The npm package is a placeholder and does not provide the expected server executable.
- `searxng-search`: SearXNG is a backend service, not an npm MCP server under this name.
- `devdocs-mcp`: DevDocs is not an npm MCP server under this name.
- `@upstash/context7-mcp` / `context7-mcp`: Not provisioned by this repository's container startup. Use an explicitly supported external integration instead.

Stale references to these names in persisted OpenClaw data do not make the npm packages installable. Remove or replace those configuration entries with supported integrations.

## Runtime Services

The validators also check the services used by this deployment:

```bash
curl http://127.0.0.1:8080/healthz
curl http://127.0.0.1:3000
curl http://127.0.0.1:18789/healthz
```

Redis listens on port `6379`; use `redis-cli ping` for a protocol-level check. SearXNG remains a valid standalone metasearch backend even though `searxng-search` is not an npm MCP server.

## Troubleshooting

If `mslearn` is missing:

```bash
npm config set prefix "$HOME/.openclaw/npm-global"
npm install -g @microsoft/learn-cli
export PATH="$HOME/.openclaw/npm-global/bin:$PATH"
```

To repair its discovery symlink:

```powershell
.\validate-mcp-servers.ps1 -FixSymlinks
```

```bash
bash validate-mcp-servers.sh --fix-symlinks
```

To inspect container startup and service health:

```bash
docker logs openclaw
docker ps --format "table {{.Names}}\t{{.Status}}"
mslearn --version
```

Do not add package installation back to the entrypoint for unsupported servers. A new npm-based tool must first be verified to publish the expected executable; prefer installing pinned tools in the image build when practical.
