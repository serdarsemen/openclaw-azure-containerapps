# WSL Deployment Performance Design

## Objective

Reduce clean and repeat deployment time for `deploy-openclaw-wsl.ps1` while making requested dependencies fail predictably and preventing generated secrets from entering tracked files.

## Scope

The change covers the WSL deployment script, its shared WSL helpers, generated runtime configuration, and focused Pester tests. It preserves the existing source and npm variants, command-line defaults, ports, container names, data layout, and Ollama modes.

## Approach

Use a hybrid optimization strategy:

- Keep Docker BuildKit as the build cache.
- Add lightweight deterministic fingerprints to skip builds whose inputs have not changed.
- Run independent image pulls concurrently with isolated output and explicit failure reporting.
- Resolve paths and dependency requirements before expensive build work starts.

This avoids a separate cache database while improving both first-run and repeat performance.

## Command-Line Changes

- Add `-ForceRefresh` to fetch, pull, and rebuild all applicable inputs regardless of fingerprints or local image state.
- Add `-AllowUnavailableOllama` to permit degraded deployment when `-OllamaWindows`, `-OllamaWsl`, or an explicit `-OllamaHost` cannot be reached.
- Require PowerShell 7 because Windows Ollama startup uses `Start-Process -Environment`.

Without `-AllowUnavailableOllama`, an explicitly requested native or external Ollama endpoint is a required dependency and stops deployment when unavailable.

## Source Handling

Resolve `SourcePath` once to an absolute Windows path relative to the script root. Use that same path for Git operations and WSL path conversion.

For the source variant:

1. Clone when the directory does not exist.
2. Verify that an existing directory is an OpenClaw Git worktree.
3. Refuse to update a dirty worktree instead of discarding local changes.
4. Fetch the requested tag or `origin/main`.
5. Move to the requested revision only after the worktree check succeeds.

`-ForceRefresh` bypasses build freshness, but it does not authorize deleting source changes.

## Build Freshness

Calculate a fingerprint from inputs that control the final image:

- OpenClaw source commit or npm package tag.
- Selected tools Dockerfile content.
- Base Dockerfile content for the npm variant.
- Build arguments and variant name.

Store the fingerprint as an OCI image label on the final local image. Before building, inspect the existing image label. Skip both build stages when it matches unless `-ForceRefresh` is supplied.

When a build is required, continue using BuildKit and its layer cache. Do not remove reusable cache layers. The intermediate tagged base image may remain available for subsequent deployments; Docker can reclaim it through normal pruning.

## Concurrent Pulls

Pull Redis, SearXNG, and CRW concurrently. Pull the Ollama image in the same group when the sidecar mode is selected.

Each pull captures its own exit code and output. After all pulls finish, report failures by image. A failed refresh may use an already-present local image; deployment stops only when no usable local image exists.

Do not run source mutation, compose startup, or configuration writes concurrently.

## Runtime Secrets

Do not embed the gateway token in the tracked compose file. Write runtime secrets to an ignored, permission-restricted environment file and reference it through Compose `env_file`.

Stop printing the token during intermediate configuration. Display it only in the existing final summary block.

## Ollama Behavior

The resolver returns the selected endpoint and verified reachability. The deploy script checks that result before starting expensive image builds.

- Sidecar mode remains self-contained and is validated through its Compose healthcheck.
- Windows, WSL-native, and explicit external modes fail before the build when unreachable.
- `-AllowUnavailableOllama` retains the endpoint configuration, emits a warning, and permits the deployment to continue.

## Container Health

Replace CRW's `wget` healthcheck because the current CRW image does not include `wget`. Use an executable already present in the image, confirmed during implementation. If the image exposes no suitable HTTP client or runtime probe, use a process-level healthcheck supported by the image rather than installing tooling at container startup.

## Error Handling

- Validate paths, Git state, PowerShell version, and required Ollama connectivity before builds.
- Preserve `$ErrorActionPreference = "Stop"`.
- Treat parallel pull failures as structured results, not interleaved terminal errors.
- Clean temporary build and secret files in `finally` blocks where applicable.
- Never overwrite user source changes.

## Testing

Add focused Pester coverage for:

- Absolute source-path resolution independent of the caller's working directory.
- Dirty worktree rejection.
- Matching and mismatching build fingerprints.
- `-ForceRefresh` bypass behavior.
- Required Ollama failure and degraded-mode continuation.
- Compose output referencing an environment file without containing the gateway token.
- CRW healthcheck generation without unavailable executables.
- Parallel pull result aggregation and cached-image fallback.

Run the complete existing Pester suite after each behavior slice. Parse both PowerShell files with the PowerShell AST parser and validate generated Compose YAML before completion.

## Success Criteria

- An unchanged repeat deployment skips source image builds.
- Independent image pulls execute concurrently.
- A clean deployment retains readable, image-specific failure output.
- Dirty source changes cannot be destroyed by the script.
- Explicitly requested Ollama modes fail when unavailable unless degraded mode is selected.
- Generated tracked files contain no gateway token.
- CRW no longer becomes unhealthy because its healthcheck executable is absent.
- Existing WSL deployment tests and all new tests pass under PowerShell 7.