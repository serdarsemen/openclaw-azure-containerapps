$ErrorActionPreference = 'Stop'
$parseTokens = $null
$parseErrors = $null
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'deploy-openclaw-wsl.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Deployment script has parse errors' }

$readyFunction = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-OpenClawReady'
}, $true)
Invoke-Expression $readyFunction.Extent.Text
$modelStatements = @($ast.EndBlock.Statements | Where-Object { $_.Extent.Text -match 'NotePropertyName primary' })
if ($modelStatements.Count -ne 1) { throw 'Expected one primary-model configuration statement' }
$modelScript = [scriptblock]::Create($modelStatements[0].Extent.Text)
$failures = @()

function Test-ReadinessCase {
    param([string] $Output, [int] $ExitCode, [bool] $Expected)
    $ContainerName = 'test-openclaw'
    $script:clockTick = 0
    function Get-Date {
        $script:clockTick++
        [datetime]::new(2026, 1, 1).AddSeconds($script:clockTick)
    }
    function Start-Sleep { param($Seconds) }
    function wsl {
        $global:LASTEXITCODE = $ExitCode
        if (($args -join ' ') -match 'docker exec') { $Output }
    }
    $actual = Wait-OpenClawReady -TimeoutSec 2 -WarningAction SilentlyContinue
    if ($actual -ne $Expected) { throw "Readiness output '$Output', exit ${ExitCode}: expected $Expected, got $actual" }
}

foreach ($case in @(
    @{ Output = 'NOT_READY'; ExitCode = 0; Expected = $false },
    @{ Output = 'READY'; ExitCode = 0; Expected = $true },
    @{ Output = 'READY'; ExitCode = 1; Expected = $false },
    @{ Output = ''; ExitCode = 1; Expected = $false },
    @{ Output = 'ALREADY'; ExitCode = 0; Expected = $false }
)) {
    try { Test-ReadinessCase @case } catch { $failures += $_.Exception.Message }
}

foreach ($primary in @('ollama/custom-model', '', $null)) {
    try {
        $model = [pscustomobject]@{ fallbacks = @('test/fallback') }
        if ($null -ne $primary) { $model | Add-Member -NotePropertyName primary -NotePropertyValue $primary }
        $config = [pscustomobject]@{ agents = [pscustomobject]@{ defaults = [pscustomobject]@{ model = $model } } }
        . $modelScript
        $expected = if ($primary) { $primary } else { 'github-copilot/claude-opus-4.6' }
        if ($config.agents.defaults.model.primary -ne $expected) { throw "Primary model '$primary' was not preserved/defaulted correctly" }
        if ($config.agents.defaults.model.fallbacks[0] -ne 'test/fallback') { throw 'Model fallbacks changed' }
    } catch { $failures += $_.Exception.Message }
}

if ($failures.Count) { throw ($failures -join "`n") }
Write-Host 'Passed 8 WSL deployment regression cases.' -ForegroundColor Green