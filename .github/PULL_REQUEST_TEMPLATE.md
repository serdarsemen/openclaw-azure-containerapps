## What does this PR do?

<!-- Brief description of the change -->

## Checklist

### General
- [ ] Tested locally (ran the relevant script or verified the change)
- [ ] No secrets or tokens in code or output

### Bicep changes (`bicep/`)
- [ ] All parameters have `@description()` decorators
- [ ] Globally unique names use `uniqueString(resourceGroup().id)`
- [ ] Changes applied to both `main.bicep` and `mainnpm.bicep` where applicable
- [ ] `.bicepparam` files updated for new parameters
- [ ] `az bicep build` succeeds without errors

### PowerShell changes (`*.ps1`)
- [ ] `$ErrorActionPreference = "Stop"` is set
- [ ] `$LASTEXITCODE` checked after every `az` CLI call
- [ ] Secrets use Container App secrets with `secretRef`, not plain env vars
- [ ] New env vars added to **both** deploy and update script YAML templates
- [ ] YAML heredocs escape `$` as `` `$ `` for container runtime variables

### Dockerfile changes (`images/`)
- [ ] Tool versions pinned explicitly (no `:latest` for tools)
- [ ] Header comment updated with new tool listing
- [ ] `USER node` remains as the last directive
- [ ] No `--mount=type=cache` directives (ACR Tasks uses classic builder)
- [ ] Total container resources stay within 4 vCPU / 8 GiB

### Documentation
- [ ] README updated if user-facing behavior changed
