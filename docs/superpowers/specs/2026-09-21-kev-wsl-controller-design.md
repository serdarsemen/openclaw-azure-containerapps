# Kev WSL Controller Design

## Goal

Provide a reusable PowerShell controller that deploy scripts can call to keep
`jaredpalmer/kev-9b` installed, current, running in WSL, and reachable at
`http://127.0.0.1:8009`.

## Interface

Create `control-kev-wsl.ps1` with an `-Action` parameter supporting `Status`,
`Start`, `Stop`, `Restart`, and `Ensure`. `Ensure` is the deploy-script entry
point:

```powershell
& "$PSScriptRoot/control-kev-wsl.ps1" -Action Ensure
if ($LASTEXITCODE -ne 0) { throw "Kev WSL readiness failed" }
```

The script defaults to model `jaredpalmer/kev-9b`, port `8009`, TypeSafe model
ID `kev-latest`, and Jev-compatible alias `jev-latest`. Paths and port remain
parameters so tests and non-default WSL installations can override them.

## Lifecycle

`Status` queries `/v1/models`, verifies the model ID and alias, performs a
minimal Noul request against `/v1/systemone`, and reports the running model,
base model, device, inference duration, and local cached Hugging Face revision.
When exactly one matching Kev server already owns the configured port, the
controller adopts its parent launcher PID into the state file.

`Start` launches Kev from its source checkout through `uv run --extra serve
python -m kev.serve`. It writes a PID file and log under
`~/.local/state/kev/`, waits for `/v1/models`, and fails unless both required
identifiers are advertised.

`Stop` terminates only the PID recorded or adopted by the controller after
confirming its command is a matching Kev server on the configured port. A stale
or unrelated PID file is removed without killing the process.

`Restart` performs `Stop` followed by `Start`.

`Ensure` checks upstream on every invocation. It compares the local Kev Git
revision with its tracked upstream branch and the cached model revision with
the Hugging Face model API. If code, dependencies, or model weights are stale,
it stops the service, fast-forwards the clean checkout, runs `uv sync --extra
serve`, refreshes the model snapshot, and starts the service. If everything is
current and healthy, it leaves the process untouched. If current but stopped,
it starts it.

## Safety And Failure Handling

- Refuse automatic source updates when the Kev checkout has uncommitted changes
  or cannot be fast-forwarded.
- Download and dependency failures leave the existing checkout and cached model
  intact where their underlying tools support transactional updates.
- Do not stop a healthy process until upstream checks establish that an update
  is required.
- Use bounded HTTP readiness retries and emit actionable errors with the log
  path.
- Return exit code `0` only when the requested action succeeds. Deploy scripts
  can treat any other exit code as a blocking readiness failure.
- Never print environment variables, tokens, or Hugging Face credentials.

## Integration

The controller is independently callable and does not require deploy scripts to
dot-source internal functions. WSL deploy and update scripts may invoke `Ensure`
at the point where other local model backends are resolved. Initial delivery
adds the controller and its tests; wiring individual deploy variants can then
use the same stable command without duplicating lifecycle logic.

## Validation

Pester tests mock WSL commands and HTTP responses to cover healthy, stopped,
process adoption, stale-code, stale-model, dirty-checkout, failed-update,
stale-PID, inference failure, and readiness timeout paths. A live smoke check
runs `Status` against the existing service, confirms that `/v1/models`
advertises `kev-latest`, `jev-latest`, `jaredpalmer/kev-9b`, and
`Qwen/Qwen3.5-9B-Base`, and verifies a Noul response from `/v1/systemone`.
