# Kev WSL Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable PowerShell controller that automatically updates, starts, and validates Kev-9B in WSL whenever a Kev-enabled deploy or update runs.

**Architecture:** Put lifecycle and update functions in `kev-wsl-helpers.ps1` so Pester can test each boundary independently. Keep `control-kev-wsl.ps1` as the stable command-line dispatcher, and add an opt-in `-KevWsl` switch to the two WSL deployment scripts; once enabled, each run invokes the controller's automatic `Ensure` action.

**Tech Stack:** PowerShell 7, WSL 2, Bash, Git, uv, Hugging Face Hub, TypeSafe `/v1/models` and `/v1/systemone` APIs, Pester 3-compatible tests.

---

## File Structure

- Create `kev-wsl-helpers.ps1`: WSL command boundary, process discovery, update comparison, lifecycle operations, and API checks.
- Create `control-kev-wsl.ps1`: validated parameters, helper import, action dispatch, and process exit code.
- Create `tests/kev-wsl-controller.Tests.ps1`: behavior tests using mocked WSL and HTTP boundaries.
- Create `tests/kev-wsl-deploy-integration.Tests.ps1`: static integration contract for both deploy scripts.
- Modify `deploy-openclaw-wsl.ps1`: add `-KevWsl` and call `Ensure` after WSL/DNS preflight.
- Modify `update-openclaw-wsl.ps1`: add `-KevWsl` and call `Ensure` after WSL/DNS preflight.
- Modify `README.md`: document controller actions and deploy usage.

### Task 1: Controller API And Health Checks

**Files:**
- Create: `tests/kev-wsl-controller.Tests.ps1`
- Create: `kev-wsl-helpers.ps1`

- [ ] **Step 1: Write failing tests for model discovery and inference**

Dot-source `kev-wsl-helpers.ps1`, mock `Invoke-RestMethod`, and assert that
`Test-KevApi -BaseUrl http://127.0.0.1:8009` rejects missing aliases and accepts
this model plus a Noul answer:

```powershell
$models = [pscustomobject]@{ models = @([pscustomobject]@{
    id = 'kev-latest'; aliases = @('jev-latest'); run = 'jaredpalmer/kev-9b'
    base = 'Qwen/Qwen3.5-9B-Base'; device = 'cpu'
}) }
$inference = [pscustomobject]@{
    model = 'kev-latest'
    answers = [pscustomobject]@{ healthy = [pscustomobject]@{ type = 'noul'; noul = 0.99 } }
}
```

Verify the POST body contains model `kev-latest`, state `Kev health check`, and
a `healthy` Noul question. Verify the returned object includes `Healthy`,
`InferenceMilliseconds`, `Run`, `Base`, and `Device`.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```powershell
Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1
```

Expected: FAIL because `kev-wsl-helpers.ps1` or `Test-KevApi` does not exist.

- [ ] **Step 3: Implement the API boundary**

Add `Test-KevApi` with these defaults and behavior:

```powershell
function Test-KevApi {
    param(
        [string] $BaseUrl = 'http://127.0.0.1:8009',
        [string] $ModelId = 'kev-latest',
        [string] $Alias = 'jev-latest',
        [int] $TimeoutSeconds = 120
    )
    # GET $BaseUrl/v1/models, find $ModelId, require $Alias, then time a POST
    # to /v1/systemone. Return a structured status object; throw on mismatch.
}
```

Use `Invoke-RestMethod` and `ConvertTo-Json -Depth 8`. The inference payload is:

```powershell
@{
    state = 'Kev health check'
    model = $ModelId
    questions = @{
        healthy = @{
            type = 'noul'
            instructions = 'Does the state indicate a Kev health check?'
        }
    }
}
```

Require `answers.healthy.type -eq 'noul'` and a numeric `noul` in `[0,1]`.

- [ ] **Step 4: Run the focused tests**

Run `Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1`.

Expected: API tests PASS.

### Task 2: Process Lifecycle And Adoption

**Files:**
- Modify: `tests/kev-wsl-controller.Tests.ps1`
- Modify: `kev-wsl-helpers.ps1`

- [ ] **Step 1: Add failing process tests**

Mock a single WSL process matching `kev.serve`, `jaredpalmer/kev-9b`, and port
`8009`. Assert `Get-KevWslProcess` returns its launcher PID, `Save-KevWslPid`
adopts it, and `Stop-KevWsl` only issues `kill` after re-reading and validating
the command line. Add cases for no process, multiple matches, stale PID, and an
unrelated PID.

- [ ] **Step 2: Run the tests and confirm lifecycle failures**

Run `Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1`.

Expected: FAIL for missing lifecycle functions.

- [ ] **Step 3: Implement safe lifecycle functions**

Add these public functions:

```powershell
Get-KevWslProcess -ModelRepo $ModelRepo -Port $Port
Save-KevWslPid -Pid $Pid -StateDir $StateDir
Start-KevWsl -SourceDir $SourceDir -ModelRepo $ModelRepo -Port $Port -StateDir $StateDir
Stop-KevWsl -ModelRepo $ModelRepo -Port $Port -StateDir $StateDir
Wait-KevApi -BaseUrl $BaseUrl -Attempts 60 -DelaySeconds 2
```

Use `~/.local/state/kev/kev-8009.pid` and `kev-8009.log`. Launch with:

```bash
cd "$source_dir"
mkdir -p "$state_dir"
nohup env KEV_DTYPE=bf16 "$HOME/.local/bin/uv" run --extra serve \
  python -m kev.serve --run "$model_repo" --port "$port" \
  >>"$log_path" 2>&1 </dev/null &
echo $! >"$pid_path"
```

Never use a broad `pkill`. Before `kill`, read `/proc/<pid>/cmdline` and require
the configured module, model, and port. If the API is already healthy, discover
exactly one matching process and adopt it without restarting.

- [ ] **Step 4: Run lifecycle tests**

Run `Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1`.

Expected: API and lifecycle tests PASS.

### Task 3: Automatic Code And Model Updates

**Files:**
- Modify: `tests/kev-wsl-controller.Tests.ps1`
- Modify: `kev-wsl-helpers.ps1`

- [ ] **Step 1: Add failing update-state tests**

Cover these exact states:

| Local code | Upstream code | Local model | Upstream model | Result |
| --- | --- | --- | --- | --- |
| A | A | M | M | no update |
| A | B | M | M | code update |
| A | A | M | N | model update |
| A | B | M | N | both updates |

Also assert a dirty checkout throws before service shutdown and that upstream
lookup failure blocks `Ensure` rather than claiming the installation is current.

- [ ] **Step 2: Run the tests and confirm update failures**

Run `Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1`.

Expected: FAIL for missing update functions.

- [ ] **Step 3: Implement revision discovery and update**

Add:

```powershell
Get-KevUpdateState -SourceDir $SourceDir -ModelRepo $ModelRepo
Update-KevWsl -UpdateState $state -SourceDir $SourceDir -ModelRepo $ModelRepo
Ensure-KevWsl -SourceDir $SourceDir -ModelRepo $ModelRepo -Port $Port -StateDir $StateDir
```

`Get-KevUpdateState` must:

1. Run `git fetch --quiet origin`.
2. Read `git rev-parse HEAD`, `git rev-parse '@{u}'`, and `git status --porcelain`.
3. Read the cached model ref from
   `~/.cache/huggingface/hub/models--jaredpalmer--kev-9b/refs/main`.
4. Query `https://huggingface.co/api/models/jaredpalmer/kev-9b` and read `sha`.
5. Return booleans `CodeUpdateAvailable` and `ModelUpdateAvailable` plus all four revisions.

`Update-KevWsl` must stop only after update state is known, refuse a dirty tree,
run `git pull --ff-only`, then `uv sync --extra serve`. Refresh the model with:

```bash
uv run --extra serve python -c \
  "from huggingface_hub import snapshot_download; snapshot_download(repo_id='jaredpalmer/kev-9b')"
```

`Ensure-KevWsl` always checks upstream. It leaves a healthy current process
running, starts a current stopped service, and performs update then start when
either revision differs.

- [ ] **Step 4: Run controller tests**

Run `Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1`.

Expected: all controller tests PASS.

### Task 4: Executable Controller

**Files:**
- Create: `control-kev-wsl.ps1`
- Modify: `tests/kev-wsl-controller.Tests.ps1`

- [ ] **Step 1: Add failing dispatch tests**

Assert the script defines validated actions `Status`, `Start`, `Stop`, `Restart`,
and `Ensure`, uses `$ErrorActionPreference = 'Stop'`, imports
`kev-wsl-helpers.ps1`, and exits nonzero when an action throws.

- [ ] **Step 2: Run tests and confirm dispatcher failure**

Run `Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1`.

Expected: FAIL because `control-kev-wsl.ps1` does not exist.

- [ ] **Step 3: Implement the thin dispatcher**

Use these parameters:

```powershell
param(
    [ValidateSet('Status', 'Start', 'Stop', 'Restart', 'Ensure')]
    [string] $Action = 'Status',
    [string] $SourceDir = '$HOME/kev',
    [string] $ModelRepo = 'jaredpalmer/kev-9b',
    [int] $Port = 8009,
    [string] $StateDir = '$HOME/.local/state/kev'
)
```

Dispatch one action, print Cyan progress/Green success/Gray details, and let
errors terminate with a nonzero process exit. `Status` prints model, base,
device, revisions, endpoint, aliases, and measured inference time.

- [ ] **Step 4: Run controller tests**

Run `Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1`.

Expected: all tests PASS.

### Task 5: WSL Deploy Integration

**Files:**
- Create: `tests/kev-wsl-deploy-integration.Tests.ps1`
- Modify: `deploy-openclaw-wsl.ps1`
- Modify: `update-openclaw-wsl.ps1`

- [ ] **Step 1: Write failing integration tests**

For both scripts, assert the source includes `[switch] $KevWsl` and invokes:

```powershell
& "$PSScriptRoot/control-kev-wsl.ps1" -Action Ensure
if ($LASTEXITCODE -ne 0) { throw "Kev WSL readiness failed" }
```

inside `if ($KevWsl)`. Assert the call occurs after WSL/DNS preflight and before
the OpenClaw image build/update.

- [ ] **Step 2: Run integration tests and confirm failure**

Run `Invoke-Pester .\tests\kev-wsl-deploy-integration.Tests.ps1`.

Expected: FAIL because neither deploy script exposes Kev yet.

- [ ] **Step 3: Add opt-in automatic Ensure calls**

Add `-KevWsl` to each parameter block and usage header. After DNS repair, invoke
the controller when selected. The controller itself checks for and applies
updates on every call; users who do not select Kev retain current behavior.

- [ ] **Step 4: Run focused integration tests**

Run `Invoke-Pester .\tests\kev-wsl-deploy-integration.Tests.ps1`.

Expected: all integration tests PASS.

### Task 6: Documentation And Live Verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document commands and deployment behavior**

Add examples for:

```powershell
.\control-kev-wsl.ps1 -Action Status
.\control-kev-wsl.ps1 -Action Ensure
.\control-kev-wsl.ps1 -Action Restart
.\deploy-openclaw-wsl.ps1 -KevWsl
.\update-openclaw-wsl.ps1 -KevWsl
```

State that `Ensure` checks both the Kev Git revision and Hugging Face model SHA,
automatically updates stale components, preserves a healthy current process,
and validates a real TypeSafe Noul inference.

- [ ] **Step 2: Run the complete focused Pester suite**

Run:

```powershell
Invoke-Pester .\tests\kev-wsl-controller.Tests.ps1, .\tests\kev-wsl-deploy-integration.Tests.ps1
```

Expected: all tests PASS.

- [ ] **Step 3: Run the live automatic update**

Run:

```powershell
.\control-kev-wsl.ps1 -Action Ensure
```

Expected on the current machine: detect stale code (`8cb2987` behind
`5e94a28`), stop the adopted process, fast-forward and sync, leave the already
current model snapshot at `2629c06a`, restart on port `8009`, and pass inference.

- [ ] **Step 4: Run final status and syntax validation**

Run:

```powershell
.\control-kev-wsl.ps1 -Action Status
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\control-kev-wsl.ps1), [ref]$null, [ref]$errors
) | Out-Null
if ($errors) { $errors | ForEach-Object { Write-Error $_ } }
```

Expected: status reports `kev-latest`, alias `jev-latest`, base
`Qwen/Qwen3.5-9B-Base`, device `cpu`, a successful inference duration, matching
local/upstream revisions, and no parser errors.
