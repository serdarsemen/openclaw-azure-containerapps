# Windows Ollama Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Print both the user-facing Windows Ollama URL and the internal WSL relay route in deploy and update summaries.

**Architecture:** Centralize Ollama summary rendering in `wsl-helpers.ps1`, which is already shared by both scripts. Return formatted lines so tests can assert output without invoking a full deployment, while callers retain control of terminal colors.

**Tech Stack:** PowerShell 7, Pester 3, Docker Compose validation

---

### Task 1: Shared Ollama Summary Formatter

**Files:**
- Create: `tests/wsl-ollama-summary.Tests.ps1`
- Modify: `wsl-helpers.ps1`

- [ ] **Step 1: Write failing formatter tests**

Cover Windows relay, Docker sidecar, WSL-native, external, and disabled modes. Require Windows mode to return:

```text
Ollama:          http://localhost:11434 (Windows host)
Container route: http://host.docker.internal:11435 (WSL relay)
```

- [ ] **Step 2: Verify the test fails**

Run: `Invoke-Pester .\tests\wsl-ollama-summary.Tests.ps1`

Expected: failure because `Get-OllamaSummaryLines` does not exist.

- [ ] **Step 3: Implement the formatter**

Add `Get-OllamaSummaryLines` with explicit parameters for sidecar state, resolved host, and Windows/WSL mode. Preserve existing text for all non-Windows modes.

- [ ] **Step 4: Verify the formatter tests pass**

Run: `Invoke-Pester .\tests\wsl-ollama-summary.Tests.ps1`

Expected: all formatter cases pass.

### Task 2: Use Formatter in Deploy and Update Summaries

**Files:**
- Modify: `deploy-openclaw-wsl.ps1`
- Modify: `update-openclaw-wsl.ps1`

- [ ] **Step 1: Replace duplicated summary branches**

Call `Get-OllamaSummaryLines` from each script and print every returned line with the existing white terminal color.

- [ ] **Step 2: Run focused tests and diagnostics**

Run: `Invoke-Pester .\tests\wsl-ollama-summary.Tests.ps1, .\tests\wsl-ollama-proxy.Tests.ps1`

Expected: all tests pass with zero failures.

- [ ] **Step 3: Validate script syntax**

Run PowerShell parser checks for `wsl-helpers.ps1`, `deploy-openclaw-wsl.ps1`, and `update-openclaw-wsl.ps1`.

Expected: zero parser errors.

- [ ] **Step 4: Validate rendered Windows summary**

Invoke the formatter with `-OllamaWindows -OllamaHost http://host.docker.internal:11435` and assert both approved lines are present.