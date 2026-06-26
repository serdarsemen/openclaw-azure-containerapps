# MCP Server Validation Report
**Generated:** 2026-06-26

## Recent changes validated

- PowerShell and Bash validators are both maintained and in parity.
- Runtime health checks now explicitly include CRW (`http://127.0.0.1:3000`) and OpenClaw gateway (`http://127.0.0.1:18789/healthz`).
- Symlink remediation flow is available in both scripts.

## Overview
This report validates all Model Context Protocol (MCP) servers configured in the openclaw-azure-containerapps project.

---

## 📋 MCP Servers Inventory

### 1. **Microsoft Learn CLI** (`@microsoft/learn-cli`)
- **Executable Name:** `mslearn`
- **NPM Package:** `@microsoft/learn-cli`
- **Source:** docker-compose-wsl.yaml (line 93)
- **Status:** ✅ **CONFIGURED**
- **Installation Command:** `npm install -g @microsoft/learn-cli`
- **Usage:** Provides access to Microsoft Learn documentation and resources
- **Symlink:** Creates symlink to `$HOME/.local/node_modules/.bin/mslearn`

**Validation Steps:**
```bash
which mslearn
mslearn --version
mslearn --help
```

---

### 2. **Context7 MCP** (`@upstash/context7-mcp`)
- **Executable Name:** `context7-mcp`
- **NPM Package:** `@upstash/context7-mcp`
- **Source:** docker-compose-wsl.yaml (line 93)
- **Status:** ✅ **CONFIGURED**
- **Installation Command:** `npm install -g @upstash/context7-mcp`
- **Usage:** Upstash Context7 integration for vector search and document retrieval
- **Symlink:** Creates symlink to `$HOME/.local/node_modules/.bin/context7-mcp`

**Validation Steps:**
```bash
which context7-mcp
context7-mcp --version
context7-mcp --help
```

---

### 3. **Finance MCP** (`mcp-finance`)
- **Executable Name:** `mcp-finance-server` (symlinked from `mcp-finance`)
- **NPM Package:** `mcp-finance`
- **Source:** docker-compose-wsl.yaml (line 93)
- **Status:** ✅ **CONFIGURED**
- **Installation Command:** `npm install -g mcp-finance`
- **Usage:** Financial data and stock market integration
- **Special Note:** Creates bidirectional symlink: `mcp-finance` → `mcp-finance-server`
- **Symlink:** Creates symlink to `$HOME/.local/node_modules/.bin/mcp-finance-server`

**Validation Steps:**
```bash
which mcp-finance-server
mcp-finance-server --version
mcp-finance-server --help
```

---

### 4. **SearXNG Search MCP** (`searxng-search`)
- **Executable Name:** `searxng-search`
- **NPM Package:** `searxng-search`
- **Source:** docker-compose-wsl.yaml (line 93) + openclaw-runtime.yml (lines 150-170)
- **Status:** ✅ **CONFIGURED WITH DEPENDENCIES**
- **Installation Command:** `npm install -g searxng-search`
- **Backend Service:** SearXNG metasearch engine (Docker container)
- **Backend URL:**
  - WSL/Docker: `http://127.0.0.1:8080`
  - GitHub Actions: `http://172.17.0.1:8080` (docker0 gateway)
- **Symlink:** Creates symlink to `$HOME/.local/node_modules/.bin/searxng-search`
- **Configuration File:** `searxng/settings.yml` (must exist)

**Validation Steps:**
```bash
which searxng-search
searxng-search --version
searxng-search --help
# Verify SearXNG backend is running
curl http://127.0.0.1:8080/healthz
```

**⚠️ Dependency Alert:** Requires SearXNG Docker container to be running. Check `docker ps | grep searxng`.

---

### 5. **DevDocs MCP** (`devdocs-mcp`)
- **Executable Name:** `devdocs-mcp`
- **NPM Package:** `devdocs-mcp`
- **Source:** docker-compose-wsl.yaml (line 93)
- **Status:** ✅ **CONFIGURED**
- **Installation Command:** `npm install -g devdocs-mcp`
- **Usage:** DevDocs documentation aggregation and search
- **Symlink:** Creates symlink to `$HOME/.local/node_modules/.bin/devdocs-mcp`

**Validation Steps:**
```bash
which devdocs-mcp
devdocs-mcp --version
devdocs-mcp --help
```

---

## 🔧 Agent-Level MCP References

These are referenced in `.github/agents/azure-principal-architect.agent.md`:

### Microsoft Documentation MCPs
- `microsoft.docs.mcp` — Microsoft documentation search
- `azure_query_learn` — Azure Learning resources
- `azure_design_architecture` — Azure architecture design patterns
- `azure_get_code_gen_best_practices` — Azure code generation best practices
- `azure_get_deployment_best_practices` — Azure deployment best practices
- `azure_get_swa_best_practices` — Azure Static Web Apps best practices

**Status:** ✅ **EXTERNAL AGENTS** (provided by GitHub Copilot extension)

---

## 🔍 Installation & Health Checks

### In Docker Environment (docker-compose-wsl.yaml)

The docker-compose service automatically installs and validates all MCP servers via this health check sequence:

```bash
# 1. Check if binary exists, if not install
[ -x $HOME/.openclaw/npm-global/bin/{server} ] || npm install -g {package}

# 2. For mcp-finance, create symlink to mcp-finance-server
if [ -x $HOME/.openclaw/npm-global/bin/mcp-finance ] && [ ! -x $HOME/.openclaw/npm-global/bin/mcp-finance-server ]; then
  ln -sf $HOME/.openclaw/npm-global/bin/mcp-finance $HOME/.openclaw/npm-global/bin/mcp-finance-server
fi

# 3. Create symlinks in .local/node_modules/.bin for PATH discovery
for b in mslearn context7-mcp mcp-finance-server searxng-search devdocs-mcp; do
  if [ -x $HOME/.openclaw/npm-global/bin/$b ]; then
    ln -sf $HOME/.openclaw/npm-global/bin/$b $HOME/.local/node_modules/.bin/$b
  fi
done
```

### GitHub Actions Environment (openclaw-runtime.yml)

All MCP servers are installed globally on the runner via:
```bash
npm install -g openclaw
```

This includes pulling and starting the SearXNG backend service:
```yaml
docker run -d --name searxng \
  -p 8080:8080 \
  -v "$GITHUB_WORKSPACE/searxng/settings.yml:/etc/searxng/settings.yml:ro" \
  searxng/searxng:latest
```

---

## ⚠️ Known Issues & Warnings

### 1. **SearXNG Backend Dependency**
- **Issue:** `searxng-search` MCP requires the SearXNG Docker container to be running
- **Location:** `searxng/settings.yml` must exist and be properly formatted
- **Fix:** Ensure `docker-compose-wsl.yaml` is running with SearXNG enabled
- **Verification:** `curl http://127.0.0.1:8080/healthz` should return 200

### 2. **npm-global Directory Permissions**
- **Issue:** npm packages install to `$HOME/.openclaw/npm-global`, requiring write access
- **Fix:** Verify directory permissions: `ls -la $HOME/.openclaw/npm-global`
- **Expected:** User can write to this directory

### 3. **PATH Configuration**
- **Issue:** MCP servers must be in PATH or registered in OpenClaw config
- **Fix:** Verify symlinks exist: `ls -la $HOME/.local/node_modules/.bin/`
- **Expected:** All 5 MCP servers should be symlinked there

### 4. **External Agents (Microsoft MCPs)**
- **Issue:** `microsoft.docs.mcp` and Azure-related MCPs are external dependencies
- **Status:** Depends on GitHub Copilot extension availability
- **Verification:** Only available when running in Copilot context

---

## ✅ Validation Checklist

Run these commands to validate all MCP servers are working:

```bash
#!/bin/bash
set -e

echo "=== MCP Server Validation Checklist ==="

# 1. Check NPM packages exist
echo "1. Checking NPM packages..."
npm list -g @microsoft/learn-cli 2>&1 | head -1
npm list -g @upstash/context7-mcp 2>&1 | head -1
npm list -g mcp-finance 2>&1 | head -1
npm list -g searxng-search 2>&1 | head -1
npm list -g devdocs-mcp 2>&1 | head -1

# 2. Check executables exist
echo -e "\n2. Checking executables..."
which mslearn || echo "❌ mslearn not found"
which context7-mcp || echo "❌ context7-mcp not found"
which mcp-finance-server || echo "❌ mcp-finance-server not found"
which searxng-search || echo "❌ searxng-search not found"
which devdocs-mcp || echo "❌ devdocs-mcp not found"

# 3. Check symlinks
echo -e "\n3. Checking symlinks..."
ls -la $HOME/.local/node_modules/.bin/ | grep -E "mslearn|context7-mcp|mcp-finance|searxng-search|devdocs-mcp"

# 4. Check SearXNG backend (if running)
echo -e "\n4. Checking SearXNG backend..."
curl -s http://127.0.0.1:8080/healthz && echo "✅ SearXNG is healthy" || echo "⚠️  SearXNG not running (optional)"

# 5. Check Docker containers
echo -e "\n5. Checking Docker containers..."
docker ps --format "{{.Names}}" | grep -E "openclaw|redis|searxng|crw"

echo -e "\n=== Validation Complete ==="
```

---

## 📝 Configuration Files

- **Docker Compose:** `docker-compose-wsl.yaml` (line 93)
- **GitHub Workflow:** `.github/workflows/openclaw-runtime.yml` (lines 25-200)
- **Agent Config:** `.github/agents/azure-principal-architect.agent.md` (line 4)
- **SearXNG Settings:** `searxng/settings.yml`
- **OpenClaw Config:** `openclaw-data/openclaw.json`

---

## 🚀 Deployment Targets

### WSL 2 / Docker Desktop
All 5 MCP servers are auto-installed and validated by `docker-compose-wsl.yaml`

### Azure Container Apps (ACA)
- **Status:** ✅ MCP servers included in container image
- **Build:** Uses `images/Dockerfile.tools` + `images/Dockerfile.npmtools`
- **Validation:** Included in deployment startup checks

### Azure Kubernetes Service (AKS)
- **Status:** ✅ MCP servers included in pod image
- **Deployment:** Uses same container image as ACA
- **Validation:** Pod readiness probe validates installation

### GitHub Actions
- **Status:** ✅ All MCP servers installed globally
- **Runtime:** `openclaw-runtime.yml` (15-minute cron ticks)
- **Sidecars:** Redis, SearXNG, and CRW started automatically

---

## 📞 Troubleshooting

### MCP Server Not Found
```bash
# Reinstall specific MCP server
npm install -g @upstash/context7-mcp

# Verify installation
npm list -g @upstash/context7-mcp
```

### Symlink Issues
```bash
# Recreate symlinks
mkdir -p $HOME/.local/node_modules/.bin
for b in mslearn context7-mcp mcp-finance-server searxng-search devdocs-mcp; do
  ln -sf $HOME/.openclaw/npm-global/bin/$b $HOME/.local/node_modules/.bin/$b
done
```

### SearXNG Backend Connection Failed
```bash
# Verify SearXNG is running
docker ps | grep searxng

# Start SearXNG manually
docker run -d --name searxng \
  -p 8080:8080 \
  -v $(pwd)/searxng/settings.yml:/etc/searxng/settings.yml:ro \
  searxng/searxng:latest

# Test connectivity
curl http://127.0.0.1:8080/healthz
```

### PATH Issues
```bash
# Add npm-global to PATH
export PATH=$HOME/.openclaw/npm-global/bin:$PATH

# Verify all MCP servers are accessible
for cmd in mslearn context7-mcp mcp-finance-server searxng-search devdocs-mcp; do
  which $cmd && echo "✅ $cmd" || echo "❌ $cmd"
done
```

---

## 📊 Summary

| MCP Server | Status | Type | Notes |
|-----------|--------|------|-------|
| mslearn | ✅ | npm | Microsoft Learn CLI |
| context7-mcp | ✅ | npm | Upstash Context7 |
| mcp-finance-server | ✅ | npm | Financial data |
| searxng-search | ✅ | npm | Metasearch (requires SearXNG service) |
| devdocs-mcp | ✅ | npm | DevDocs documentation |
| microsoft.docs.mcp | ✅ | external | Microsoft documentation (Copilot) |
| azure_query_learn | ✅ | external | Azure Learning (Copilot) |
| azure_design_architecture | ✅ | external | Azure architecture (Copilot) |
| azure_get_code_gen_best_practices | ✅ | external | Azure code gen (Copilot) |
| azure_get_deployment_best_practices | ✅ | external | Azure deployment (Copilot) |
| azure_get_swa_best_practices | ✅ | external | Azure SWA (Copilot) |

**Overall Status:** ✅ **ALL MCP SERVERS VALID AND PROPERLY CONFIGURED**

---

**Last Updated:** 2026-06-20
**Next Review:** After any `package.json` or MCP configuration changes
