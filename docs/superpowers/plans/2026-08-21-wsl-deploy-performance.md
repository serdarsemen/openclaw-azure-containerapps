# WSL Deployment Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make clean WSL deployments faster and unchanged repeat deployments skip unnecessary work while protecting source changes, secrets, and explicitly requested Ollama dependencies.

**Architecture:** Keep orchestration in `deploy-openclaw-wsl.ps1` and reusable decisions in `wsl-helpers.ps1`. Use an OCI image fingerprint for build freshness, Docker Compose native parallelism for service pulls, an ext4 runtime env file for secrets, and early validation before expensive builds.

**Tech Stack:** PowerShell 7, Pester 3.4-compatible tests, WSL 2, Docker BuildKit, Docker Compose v2.

---

## File Map

- Modify `wsl-helpers.ps1`: add path, Git safety, fingerprint, runtime-env, and pull-selection helpers; update compose generation and CRW healthcheck.
- Modify `deploy-openclaw-wsl.ps1`: require PowerShell 7, add switches, perform early validation, skip fresh builds, write runtime env, and use parallel pulls.
- Modify `update-openclaw-wsl.ps1`: adopt runtime env generation and the token-free compose signature.
- Create `tests/wsl-deploy-performance.Tests.ps1`: focused unit tests for every new decision and generated artifact.
- Modify `tests/wsl-ollama-proxy.Tests.ps1`: update calls to the token-free compose signature.

Commits are intentionally omitted because repository changes must not be committed without explicit user instruction.

### Task 1: Source Path and Worktree Safety

**Files:**
- Modify: `wsl-helpers.ps1`
- Create: `tests/wsl-deploy-performance.Tests.ps1`

- [ ] **Step 1: Write failing path and worktree tests**

```powershell
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "wsl-helpers.ps1")

Describe "Resolve-OpenClawSourcePath" {
    It "resolves a relative source path against the script root" {
        Resolve-OpenClawSourcePath -SourcePath "openclaw-repo" -ScriptRoot "C:\repo" |
            Should Be "C:\repo\openclaw-repo"
    }
}

Describe "Assert-CleanOpenClawWorktree" {
    It "rejects a dirty worktree" {
        Mock Invoke-GitCapture { " M src/file.ts" }
        { Assert-CleanOpenClawWorktree -SourcePath "C:\repo\openclaw-repo" } |
            Should Throw "contains uncommitted changes"
    }
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `Invoke-Pester -Path .\tests\wsl-deploy-performance.Tests.ps1`

Expected: FAIL because `Resolve-OpenClawSourcePath` and `Assert-CleanOpenClawWorktree` do not exist.

- [ ] **Step 3: Implement minimal source helpers**

```powershell
function Resolve-OpenClawSourcePath {
  param([string] $SourcePath, [string] $ScriptRoot)
  if ([IO.Path]::IsPathRooted($SourcePath)) {
    return [IO.Path]::GetFullPath($SourcePath)
  }
  return [IO.Path]::GetFullPath((Join-Path $ScriptRoot $SourcePath))
}

function Invoke-GitCapture {
  param([string] $SourcePath, [string[]] $Arguments)
  $result = & git -C $SourcePath @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Git command failed: $result" }
  return $result
}

function Assert-CleanOpenClawWorktree {
  param([string] $SourcePath)
  $inside = Invoke-GitCapture -SourcePath $SourcePath -Arguments @('rev-parse', '--is-inside-work-tree')
  if ($inside -notcontains 'true') { throw "$SourcePath is not a Git worktree." }
  $status = Invoke-GitCapture -SourcePath $SourcePath -Arguments @('status', '--porcelain')
  if ($status) { throw "OpenClaw source at $SourcePath contains uncommitted changes." }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `Invoke-Pester -Path .\tests\wsl-deploy-performance.Tests.ps1`

Expected: all Task 1 tests pass.

- [ ] **Step 5: Integrate the absolute path and safe update**

In `deploy-openclaw-wsl.ps1`, resolve `$SourcePath` immediately after dot-sourcing helpers. Before fetch/checkout on an existing source directory, call `Assert-CleanOpenClawWorktree`. Replace `git reset --hard origin/main` with `git merge --ff-only origin/main`.

```powershell
$SourcePath = Resolve-OpenClawSourcePath -SourcePath $SourcePath -ScriptRoot $PSScriptRoot
Assert-CleanOpenClawWorktree -SourcePath $SourcePath
git merge --ff-only origin/main
if ($LASTEXITCODE -ne 0) { throw "OpenClaw source cannot be fast-forwarded to origin/main" }
```

- [ ] **Step 6: Parse and rerun tests**

Run the AST parser check and focused Pester file. Expected: parser errors `0`; focused tests pass.

### Task 2: Deterministic Build Freshness

**Files:**
- Modify: `wsl-helpers.ps1`
- Modify: `deploy-openclaw-wsl.ps1`
- Modify: `tests/wsl-deploy-performance.Tests.ps1`

- [ ] **Step 1: Write failing fingerprint tests**

```powershell
Describe "Get-OpenClawBuildFingerprint" {
    It "returns the same digest for identical inputs" {
        $first = Get-OpenClawBuildFingerprint -Inputs @('source', 'abc123', 'tools-hash')
        $second = Get-OpenClawBuildFingerprint -Inputs @('source', 'abc123', 'tools-hash')
        $first | Should Be $second
    }

    It "changes when an input changes" {
        Get-OpenClawBuildFingerprint -Inputs @('source', 'abc123') |
            Should Not Be (Get-OpenClawBuildFingerprint -Inputs @('source', 'def456'))
    }
}

Describe "Test-OpenClawImageFresh" {
    It "returns false when force refresh is requested" {
        Test-OpenClawImageFresh -ImageName 'openclaw-source' -Fingerprint 'abc' -ForceRefresh |
            Should Be $false
    }
}
```

- [ ] **Step 2: Run the test and verify RED**

Expected: FAIL because fingerprint helpers do not exist.

- [ ] **Step 3: Implement fingerprint helpers**

```powershell
function Get-OpenClawBuildFingerprint {
  param([string[]] $Inputs)
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Inputs -join "`n"))
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-OpenClawImageFresh {
  param([string] $ImageName, [string] $Fingerprint, [switch] $ForceRefresh)
  if ($ForceRefresh) { return $false }
  try {
    $label = (Invoke-WslData "docker image inspect ${ImageName}:latest --format '{{ index .Config.Labels \"io.openclaw.build-fingerprint\" }}'").Trim()
    return $label -eq $Fingerprint
  } catch { return $false }
}
```

- [ ] **Step 4: Run tests and verify GREEN**

Expected: focused tests pass.

- [ ] **Step 5: Add `-ForceRefresh` and image label integration**

Compute source revision with `git -C $SourcePath rev-parse HEAD`, hash the selected tools Dockerfile with `Get-FileHash`, and include variant/tag values. Pass the label to the final build:

```powershell
$buildFingerprint = Get-OpenClawBuildFingerprint -Inputs @($variantLabel, $sourceRevision, $toolsHash, $npmTag)
$imageFresh = Test-OpenClawImageFresh -ImageName $ImageName -Fingerprint $buildFingerprint -ForceRefresh:$ForceRefresh
Invoke-WslRetry "DOCKER_BUILDKIT=1 docker build --label io.openclaw.build-fingerprint=$buildFingerprint ..."
```

Wrap both build stages in `if ($imageFresh) { Write-Host ... } else { ... }`. Stop deleting `${ImageName}:base`, allowing BuildKit and the tagged base to accelerate later runs.

- [ ] **Step 6: Run parser and focused tests**

Expected: parser errors `0`; tests pass.

### Task 3: Token-Free Compose Runtime

**Files:**
- Modify: `wsl-helpers.ps1`
- Modify: `deploy-openclaw-wsl.ps1`
- Modify: `update-openclaw-wsl.ps1`
- Modify: `tests/wsl-deploy-performance.Tests.ps1`
- Modify: `tests/wsl-ollama-proxy.Tests.ps1`

- [ ] **Step 1: Write failing runtime-env tests**

```powershell
Describe "New-OpenClawRuntimeEnvContent" {
    It "writes gateway and optional Groq secrets" {
        $content = New-OpenClawRuntimeEnvContent -GatewayToken 'secret-token' -GroqApiKey 'groq-secret'
        $content | Should Match '^OPENCLAW_GATEWAY_TOKEN=secret-token'
        $content | Should Match 'GROQ_API_KEY=groq-secret'
    }
}

Describe "New-OpenClawComposeYaml runtime secrets" {
    It "references the runtime env file without embedding a token" {
        $yaml = New-TestComposeYaml -RuntimeEnvFile '/home/test/.openclaw-data/runtime.env'
        $yaml | Should Match 'env_file:'
        $yaml | Should Match '/home/test/.openclaw-data/runtime.env'
        $yaml | Should Not Match 'secret-token'
    }
}
```

- [ ] **Step 2: Run the test and verify RED**

Expected: FAIL because runtime-env generation/signature is absent.

- [ ] **Step 3: Implement runtime env generation and compose signature**

```powershell
function New-OpenClawRuntimeEnvContent {
  param([string] $GatewayToken, [string] $GroqApiKey = '')
  $lines = @("OPENCLAW_GATEWAY_TOKEN=$GatewayToken")
  if ($GroqApiKey) { $lines += "GROQ_API_KEY=$GroqApiKey" }
  return ($lines -join "`n") + "`n"
}
```

Replace `GatewayToken` and `GroqApiKey` parameters on `New-OpenClawComposeYaml` with mandatory `RuntimeEnvFile`. Add:

```yaml
    env_file:
      - ${RuntimeEnvFile}
```

Remove secret values from `$envVars`.

- [ ] **Step 4: Update deploy and update call sites**

Write `.openclaw-runtime.env` under `$DataDir`, convert it to `$WslDataDir/.openclaw-runtime.env`, and apply `chmod 600` through WSL. Pass only the WSL path to compose generation. Remove the intermediate token print at `deploy-openclaw-wsl.ps1:358`.

- [ ] **Step 5: Run focused and existing compose tests**

Run: `Invoke-Pester -Path .\tests\wsl-deploy-performance.Tests.ps1, .\tests\wsl-ollama-proxy.Tests.ps1`

Expected: all selected tests pass and generated YAML contains no test token.

### Task 4: Required Ollama Failure Policy

**Files:**
- Modify: `deploy-openclaw-wsl.ps1`
- Modify: `update-openclaw-wsl.ps1`
- Modify: `tests/wsl-deploy-performance.Tests.ps1`

- [ ] **Step 1: Write failing policy tests**

```powershell
Describe "Assert-OllamaRequirement" {
    It "throws when requested Ollama is unreachable" {
        { Assert-OllamaRequirement -Requested -Reachable:$false } | Should Throw 'required but unreachable'
    }

    It "allows explicit degraded mode" {
        { Assert-OllamaRequirement -Requested -Reachable:$false -AllowUnavailable } | Should Not Throw
    }
}
```

- [ ] **Step 2: Run and verify RED**

Expected: missing-function failure.

- [ ] **Step 3: Implement and integrate policy**

```powershell
function Assert-OllamaRequirement {
  param([switch] $Requested, [bool] $Reachable, [switch] $AllowUnavailable)
  if ($Requested -and -not $Reachable -and -not $AllowUnavailable) {
    throw 'Ollama was explicitly requested and is required but unreachable.'
  }
}
```

Add `-AllowUnavailableOllama` to deploy/update parameters and call the helper immediately after `Resolve-OllamaHost`, before source fetch/build.

- [ ] **Step 4: Require PowerShell 7**

Add `#requires -Version 7.0` as the first executable line in deploy/update scripts.

- [ ] **Step 5: Run focused tests and parser checks**

Expected: tests pass; parser errors `0`.

### Task 5: Native Parallel Pulls and CRW Health

**Files:**
- Modify: `deploy-openclaw-wsl.ps1`
- Modify: `update-openclaw-wsl.ps1`
- Modify: `wsl-helpers.ps1`
- Modify: `tests/wsl-deploy-performance.Tests.ps1`

- [ ] **Step 1: Write failing compose/pull selection tests**

```powershell
Describe "Get-OpenClawPullServices" {
    It "includes Ollama only for sidecar mode" {
        (Get-OpenClawPullServices -OllamaSidecar) -join ',' | Should Be 'redis,searxng,crw,ollama'
        (Get-OpenClawPullServices) -join ',' | Should Be 'redis,searxng,crw'
    }
}

It "uses a CRW healthcheck available in the image" {
    $yaml = New-TestComposeYaml
    $yaml | Should Match 'cat /proc/1/comm'
    $yaml | Should Not Match 'wget.*localhost:3000'
}
```

- [ ] **Step 2: Run and verify RED**

Expected: pull helper missing and old `wget` assertion fails.

- [ ] **Step 3: Implement pull selection and healthcheck**

```powershell
function Get-OpenClawPullServices {
  param([switch] $OllamaSidecar)
  $services = @('redis', 'searxng', 'crw')
  if ($OllamaSidecar) { $services += 'ollama' }
  return $services
}
```

Use this CRW healthcheck, verified against the current image:

```yaml
    healthcheck:
      test: ["CMD-SHELL", "test \"$(cat /proc/1/comm)\" = crw-server"]
```

- [ ] **Step 4: Replace serial pulls with Compose parallel pulls**

After writing compose YAML, run:

```powershell
$pullServices = Get-OpenClawPullServices -OllamaSidecar:$ollamaEnabled
$serviceArgs = $pullServices -join ' '
Invoke-WslStream "OPENCLAW_DATA_DIR='$WslDataDir' docker compose --parallel 4 -f '$WslComposePath' pull $serviceArgs"
```

On pull failure, verify each required image with `docker image inspect`; continue only when every service has a usable local image. Apply the same pattern in the update script.

- [ ] **Step 5: Run tests and validate generated Compose YAML**

Run Pester, then generate test YAML and pipe it through `wsl docker compose -f - config --quiet`.

Expected: tests pass; Compose validation exits `0`.

### Task 6: End-to-End Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run the complete test suite**

Run: `Invoke-Pester -Path .\tests`

Expected: all tests pass with `Failed: 0`.

- [ ] **Step 2: Parse all touched PowerShell files**

Use `[System.Management.Automation.Language.Parser]::ParseFile` for deploy, update, helpers, and tests.

Expected: zero parser errors.

- [ ] **Step 3: Validate secret absence**

Generate compose with a sentinel token `DO_NOT_EMBED_THIS_TOKEN`, then search the YAML.

Expected: sentinel absent; runtime env file contains it and has WSL mode `600`.

- [ ] **Step 4: Validate runtime health**

Run a deployment using the already-selected `-OllamaWindows` mode. Inspect `docker ps`, the OpenClaw image fingerprint label, CRW health, and the configured Ollama endpoint.

Expected: OpenClaw and CRW healthy; Ollama reachable; image label populated.

- [ ] **Step 5: Measure unchanged repeat behavior**

Run the same deployment again and record elapsed time.

Expected: output states that the image fingerprint matches and both build stages are skipped.

- [ ] **Step 6: Review the final diff**

Run: `git diff --check` and `git diff --stat`.

Expected: no whitespace errors; only planned scripts, tests, and documentation changed.