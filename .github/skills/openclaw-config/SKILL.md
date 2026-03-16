# OpenClaw Gateway Configuration

Guide configuring, securing, and managing the OpenClaw gateway running on Azure Container Apps.

## When to Use

- User asks about OpenClaw gateway settings
- User wants to change models, add channels, or configure providers
- User asks about security hardening or device pairing
- User asks about environment variables or startup commands

## Gateway Startup Command

The container starts with this command chain:

```bash
chmod -R 755 /app/extensions &&
mkdir -p /home/node/.openclaw/workspace/memory &&
export NODE_COMPILE_CACHE=$HOME/.openclaw/compile-cache &&
mkdir -p $HOME/.openclaw/compile-cache &&
export OPENCLAW_NO_RESPAWN=1 &&
node openclaw.mjs config set gateway.controlUi.allowInsecureAuth true &&
node openclaw.mjs config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true &&
exec node openclaw.mjs gateway --allow-unconfigured --bind lan --port 18789
```

Key flags:
- `--allow-unconfigured` — starts without requiring provider auth upfront
- `--bind lan` — binds to all interfaces (required for Container Apps ingress)
- `--port 18789` — matches the Container App target port and probe configuration
- `OPENCLAW_NO_RESPAWN=1` — prevents the gateway from forking (Container Apps manages lifecycle)

## Environment Variables

| Variable | Value | Source |
|----------|-------|--------|
| `OPENCLAW_GATEWAY_TOKEN` | 256-bit hex token | Container App secret (`gateway-token`) |
| `OLLAMA_HOST` | `http://localhost:11434` | Hardcoded — Ollama sidecar runs in same pod |
| `NODE_ENV` | `production` | Hardcoded |
| `HOME` | `/home/node` (source) or `/home/openclaw` (npm) | Hardcoded |
| `TERM` | `xterm-256color` | Hardcoded |
| `OPENCLAW_BUNDLED_PLUGINS_DIR` | `/app/extensions` | Hardcoded |

### Adding a New Environment Variable

Add it to **both** the deploy and update scripts' YAML templates. The update script rebuilds the full YAML spec, so any variable missing from it will be dropped.

## LLM Provider: GitHub Copilot

Default model: `github-copilot/claude-opus-4.6`

Authentication via device flow (one-time):
```bash
az containerapp exec --name ca-openclaw --resource-group rg-openclaw
node openclaw.mjs models auth login-github-copilot
# Follow the browser device flow, then: exit
```

Switch models:
```bash
node openclaw.mjs models set copilot-proxy/gpt-5.2
node openclaw.mjs models list  # see all available
```

## Ollama Sidecar (Local Models)

The Ollama container runs alongside OpenClaw in the same pod:
- Accessible at `http://localhost:11434`
- Models stored on NFS at `/home/ollama/.ollama/models`
- Resources: 1.0 vCPU / 2 GiB (limited by Consumption tier)

Pull a model inside the container:
```bash
az containerapp exec --name ca-openclaw --resource-group rg-openclaw --container ollama
ollama pull phi3:mini
```

## NFS Persistent Storage

Mount path: `/home/node/.openclaw` (source variant) or `/home/openclaw/.openclaw` (npm variant)

Persisted data:
- `config.json` — gateway configuration
- `workspace/` — conversation state and files
- `workspace/memory/` — memory store
- `compile-cache/` — Node.js compile cache
- `gopath/` — Go packages installed at runtime

Note: NFS root defaults to 777 permissions. `chmod -R 700` fails on NFS mounts — use 755 instead.

## Security Hardening

### Device Pairing (Recommended for Production)

```bash
# Disable insecure auth
az containerapp exec --name ca-openclaw --resource-group rg-openclaw \
  --command "node openclaw.mjs config set gateway.controlUi.allowInsecureAuth false"

# Restart the revision
$rev = az containerapp show --name ca-openclaw --resource-group rg-openclaw \
  --query "properties.latestRevisionName" -o tsv
az containerapp revision restart --revision $rev --resource-group rg-openclaw
```

Then pair via the Control UI with: `node openclaw.mjs devices approve --latest --url ws://127.0.0.1:18789 --token <TOKEN>`

### Security Audit

```bash
az containerapp exec --name ca-openclaw --resource-group rg-openclaw \
  --command "node openclaw.mjs security audit"
```

## Probes

| Probe | Type | Target | Config |
|-------|------|--------|--------|
| OpenClaw startup | TCP | port 18789 | initialDelay: 5s, period: 10s, failures: 30 |
| OpenClaw liveness | TCP | port 18789 | period: 30s |
| Ollama liveness | HTTP GET `/` | port 11434 | period: 30s |
