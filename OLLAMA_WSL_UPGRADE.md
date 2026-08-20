# Upgrade Ollama in WSL

Use `upgrade-ollama-wsl.ps1` from Windows PowerShell to install the latest Ollama release inside the default WSL distribution.

The WSL deploy and update scripts also perform this check automatically when `-OllamaWsl` is selected. They upgrade Ollama only when the installed semantic version is older than the latest GitHub release. Pass `-UpgradeOllama` to force a reinstall.

## Prerequisites

- WSL 2 is installed and available through `wsl.exe`.
- The WSL distribution has `bash`, `curl`, and network access to `https://ollama.com`.
- Your WSL user can authorize `sudo` if the official installer requests it.

## Upgrade

Open PowerShell in the repository root and run:

```powershell
.\upgrade-ollama-wsl.ps1
```

The script:

1. Confirms that `wsl.exe` is available.
2. Reports the currently installed Ollama version when present.
3. Runs the official installer command in WSL:

   ```powershell
   wsl -- bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'
   ```

4. Stops with an error if the installer fails.
5. Reports the installed version after the upgrade.

The installer updates the Ollama binaries. It does not remove downloaded models. The wrapper does not restart Ollama or pull models.

## Restart for this repository

After upgrading, restart Ollama with the network binding and connectivity checks expected by the WSL deployment:

```powershell
.\start-ollama-qwen.ps1
```

This startup script binds Ollama to `0.0.0.0:11434`, checks access from Docker, and ensures the `qwen3.5` model is available.

## Verify manually

Check the installed version:

```powershell
wsl -- bash -lc 'ollama --version'
```

After Ollama is running, check its API:

```powershell
Invoke-RestMethod http://localhost:11434/api/version
```

List the models stored in WSL:

```powershell
wsl -- bash -lc 'ollama list'
```

## Troubleshooting

### The installer asks for a password

Enter the password for your Linux user. Windows credentials are not used for the WSL `sudo` prompt.

If the PowerShell invocation cannot handle the prompt, open a WSL terminal and run the installer directly:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### Ollama reports a client/server version mismatch

The old server process is still running. Restart it with:

```powershell
.\start-ollama-qwen.ps1
```

### Docker cannot reach Ollama

Ollama may be listening only on `127.0.0.1`. Use `start-ollama-qwen.ps1` to restart it with `OLLAMA_HOST=0.0.0.0:11434` and run the repository's Docker connectivity check.
