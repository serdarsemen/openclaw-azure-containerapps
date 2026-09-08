# WSL Source Builds

The source variant of [deploy-openclaw-wsl.ps1](../deploy-openclaw-wsl.ps1) prepares
sources on the WSL Linux filesystem and retains build contexts between runs.
These options do not change the npm variant or the update script's build flow.

## Source and Cache

- Without `-SourcePath`, the checkout is `$HOME/.cache/openclaw-build/source` in
  the default WSL distribution, under the default WSL user.
- `-BuildCacheDir /absolute/linux/path` relocates both the context cache and the
  default checkout. Prefer the Linux filesystem rather than `/mnt/c`.
- `-SourcePath` accepts an absolute Linux path or a Windows path (relative Windows
  paths resolve against the current PowerShell directory). Existing Windows
  checkouts remain usable, but cloning and fetching there still incur cross-filesystem costs.
- Builds use fetched `origin/main`, or the upstream release tag named by `-Tag`.
  Local edits and the checkout's current branch are left untouched and are not
  included in the build. The cached checkout's working files are not updated on
  each fetch; the logged commit identifies the actual build input.
- Contexts are keyed by the fetched commit and the preparation script's hash.
  An unchanged pair skips archive creation, extraction, and Dockerfile patching.
  Preparation is serialized per cache root and publishes a context only when complete.

The first run needs a clone and a fresh context. Old contexts remain on disk;
there is no automatic pruning. When no build or preparation is running, unused
entries under `<cache>/contexts` can be removed manually. Do not edit prepared
contexts: their keys assume immutable contents. Removing one makes the next run
prepare it again. Docker's layer and BuildKit caches are separate from this cache.
Recreating a context previously added filesystem work; it did not inherently
invalidate Docker layers, because modification times alone do not invalidate COPY cache.

## Progress and Memory

Both source base-image and tools-image builds stream `--progress=plain` output,
including cache-hit information. Fetch, archive, extraction, and patch operations
report timings. PowerShell also reports preparation, base-build, and tools-build
elapsed time; build timings include retries and are reported on failure.

```powershell
.\deploy-openclaw-wsl.ps1 -BuildNodeHeapMB 4096 -BuildTsdownHeapMB 2048
.\deploy-openclaw-wsl.ps1 -SourcePath C:\src\openclaw -BuildCacheDir /home/me/openclaw-build
```

`-BuildNodeHeapMB` defaults to 8192 MiB and supplies
`OPENCLAW_DOCKER_BUILD_NODE_OPTIONS=--max-old-space-size=<value>`.
`-BuildTsdownHeapMB` defaults to 0, meaning no override; a positive value supplies
`OPENCLAW_DOCKER_BUILD_TSDOWN_MAX_OLD_SPACE_MB`. These require an upstream Dockerfile
that supports those build arguments; older tags may ignore them.

The script displays WSL logical CPUs, RAM, and swap, and warns if the larger heap
leaves less than 2 GiB of currently available RAM. This is a heuristic, not a
guarantee against out-of-memory failures: heaps are not total process memory,
and concurrent build processes need additional headroom. Compose runtime memory
and CPU settings do not govern these builds. WSL allocation is never changed
automatically and WSL is never restarted by this build optimization.

The tools-layer design is unchanged. A changed base image can still rebuild its
large dependency installation. No full-image speedup benchmark is implied by the
context-reuse and mocked deployment tests.