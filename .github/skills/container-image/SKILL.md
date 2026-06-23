# Container Image Build & Management

Guide building, layering, and managing OpenClaw container images via Azure Container Registry.

## When to Use

- User asks to add tools to the container image
- User asks about the Docker build process
- User wants to modify Dockerfiles
- User asks about ACR build issues or image tagging

## Build Architecture

```
┌─────────────────────────┐     ┌──────────────────────────────┐
│ openclaw-repo/Dockerfile │────▶│ openclaw:base                │
│ (patched for ACR Tasks)  │     │ Node.js + OpenClaw from src  │
└─────────────────────────┘     └──────────────┬───────────────┘
                                               │
┌─────────────────────────┐     ┌──────────────▼───────────────┐
│ images/Dockerfile.tools  │────▶│ openclaw:latest              │
│ (extends base)           │     │ + Go 1.24.1                  │
└─────────────────────────┘     │ + GitHub CLI 2.72.0          │
                                │ + Gemini CLI (npm)           │
                                │ + GoG CLI (from source)      │
                                └──────────────────────────────┘
```

npm variant uses `images/Dockerfile.npmtools` instead, which adds Bun, Playwright/Chromium, QMD.

## ACR Tasks Compatibility

ACR Tasks uses the **classic Docker builder**, not BuildKit. The deploy scripts automatically patch the OpenClaw Dockerfile:

```powershell
# Strip --mount=type=cache directives (not supported)
(Get-Content "$SourcePath/Dockerfile" -Raw) `
    -replace '--mount=type=cache,\S+\s*', '' `
    -replace '(?m)^\s+\\\r?\n', '' |
    Set-Content $AcrDockerfile -Encoding utf8
```

**Never skip this patching step** — the build will fail with `--mount` errors.

## Adding a New Tool

1. Edit `images/Dockerfile.tools` (or `Dockerfile.npmtools` for the npm variant)
2. **Pin the version explicitly** — never use `latest` tags for tools
3. Add a comment in the header listing the new tool
4. Build as `root`, switch back to `USER node` at the end
5. Test the build: `az acr build --registry <acr> --image openclaw:test --build-arg BASE_IMAGE=<acr>.azurecr.io/openclaw:base --file images/Dockerfile.tools images`

## Python ML Stack Installation Order (CRITICAL)

The Dockerfiles include PyTorch, scipy, statsmodels, scikit-learn, matplotlib, mplfinance, huggingface_hub, langgraph, pytest-timeout, and 20+ scientific packages. **Installation order must be strictly maintained** to prevent numpy version conflicts:

1. **scipy==1.14.1** and **statsmodels==0.14.6** install FIRST (they have strict numpy version requirements)
2. Keep pinned package versions synchronized in both Dockerfiles (for example: **scikit-learn==1.9.0**, **matplotlib==3.11.0**, **mplfinance==0.12.10b0**, **pytest-timeout==2.4.0**)
3. **PyTorch installs LAST** (it adapts to the existing numpy environment)

**Why this matters:**
- Wrong order (PyTorch before scipy/statsmodels) causes numpy version downgrade and breaks `numpy.testing`
- PyTorch's bundled numpy then becomes incompatible with scipy/statsmodels
- This also breaks torch library imports with "cannot load libaries" errors

**Cleanup patterns:**
- Use conservative cleanup: `-maxdepth 2 -type d -name "tests"`
- **Never** use aggressive patterns like `-name "test*" -prune` — they remove torch .so library files
- Always verify torch after cleanup: `python3 -c "import torch; import torch.utils.data"`

Both `images/Dockerfile.tools` and `images/Dockerfile.npmtools` must be kept in sync for consistency.

### Example: Adding a New Go Tool

```dockerfile
# ── New Tool v1.2.3 ──────────────────────────────────────────────────────────
RUN git clone --depth 1 --branch v1.2.3 https://github.com/org/tool.git /tmp/tool \
    && cd /tmp/tool \
    && go build -o /usr/local/bin/tool . \
    && rm -rf /tmp/tool
```

### Example: Adding an npm Tool

```dockerfile
# ── New Tool (latest via npm) ────────────────────────────────────────────────
RUN npm install -g @scope/tool@latest 2>/dev/null && npm cache clean --force
```

## Build Commands

```powershell
# Set encoding to avoid Windows Azure CLI Unicode crashes
$env:PYTHONIOENCODING = "utf-8"

# Step 1: Base image
az acr build --registry $AcrName --image openclaw:base --file $AcrDockerfile $SourcePath

# Step 2: Tools layer
az acr build --registry $AcrName --image openclaw:latest `
    --build-arg "BASE_IMAGE=$AcrServer/openclaw:base" `
    --file "images/Dockerfile.tools" images
```

## Image Tags

| Tag | Purpose |
|-----|---------|
| `openclaw:base` | Base OpenClaw from source Dockerfile |
| `openclaw:latest` | Production image with tools layer |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `--mount` syntax error during build | Dockerfile not patched — ensure `--mount=type=cache` directives are stripped |
| Unicode/encoding crash on Windows | Set `$env:PYTHONIOENCODING = "utf-8"` before `az acr build` |
| Build timeout | ACR Basic tier has limited build minutes — consider upgrading to Standard |
| `BASE_IMAGE` not found | Base image must be built first (`openclaw:base`) before the tools layer |
| Large context upload | Use `.dockerignore` to exclude unnecessary files from the build context |
