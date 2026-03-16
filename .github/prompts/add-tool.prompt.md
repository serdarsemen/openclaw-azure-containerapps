---
description: "Add a new CLI tool to the OpenClaw container image"
mode: "agent"
tools: ["read_file", "replace_string_in_file", "run_in_terminal"]
---

# Add a Tool to the OpenClaw Container Image

Guide me through adding a new CLI tool to the OpenClaw container image.

## Gather Information

Ask the user:
1. What tool to install (name, repo URL)
2. Which version to pin (look up the latest stable release)
3. Installation method (Go build, binary download, npm, apt)
4. Which variant (source-build → `Dockerfile.tools`, npm → `Dockerfile.npmtools`, or both)

## Edit the Dockerfile

Open `images/Dockerfile.tools` (or `Dockerfile.npmtools`) and:

1. **Add a header comment** in the tool listing at the top of the file
2. **Add the install block** between the last tool and the `USER node` directive
3. **Pin the version explicitly** — never use `:latest` for tools
4. **Build as root** — the Dockerfile switches to `USER root` at the top and back to `USER node` at the end

### Templates by install method:

**Go build from source:**
```dockerfile
# ── ToolName vX.Y.Z ─────────────────────────────────────────────────────────
RUN git clone --depth 1 --branch vX.Y.Z https://github.com/org/tool.git /tmp/tool \
    && cd /tmp/tool \
    && go build -o /usr/local/bin/tool . \
    && rm -rf /tmp/tool
```

**Binary download:**
```dockerfile
# ── ToolName vX.Y.Z ─────────────────────────────────────────────────────────
RUN curl -fsSL https://github.com/org/tool/releases/download/vX.Y.Z/tool_X.Y.Z_linux_amd64.tar.gz \
    | tar -xz -C /usr/local/bin tool
```

**npm global install:**
```dockerfile
# ── ToolName (latest via npm) ────────────────────────────────────────────────
RUN npm install -g @scope/tool@latest 2>/dev/null && npm cache clean --force
```

## Test the Build

```powershell
$env:PYTHONIOENCODING = "utf-8"
az acr build --registry <acr> --image openclaw:test `
    --build-arg "BASE_IMAGE=<acr>.azurecr.io/openclaw:base" `
    --file "images/Dockerfile.tools" images
```

## Reminders

- The `USER node` directive must remain as the last line
- ACR Tasks uses the classic Docker builder — no BuildKit features
- After verifying, run the update script to deploy the new image
