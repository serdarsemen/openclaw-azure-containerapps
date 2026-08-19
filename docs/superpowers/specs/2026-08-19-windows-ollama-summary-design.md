# Windows Ollama Summary Design

## Goal

Make WSL deployment and update summaries distinguish the Windows Ollama URL from the internal container relay URL.

## Output

For `-OllamaWindows`, both scripts print:

```text
  Ollama:          http://localhost:11434 (Windows host)
  Container route: http://host.docker.internal:11435 (WSL relay)
```

Docker sidecar, WSL-native, external, and disabled Ollama summaries retain their existing behavior.

## Implementation

Add a shared formatter in `wsl-helpers.ps1` and call it from `deploy-openclaw-wsl.ps1` and `update-openclaw-wsl.ps1`. A focused Pester test covers all summary modes and prevents the two scripts from drifting.