$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
. $scriptPath -NoUi

$root = Join-Path $env:TEMP ("codex-sync-failure-test-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $root ".codex"
$historyBackupRoot = Join-Path $root "history-sync"
$sessionsDir = Join-Path $codexHome "sessions"
New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null

$rolloutPath = Join-Path $sessionsDir "rollout-a.jsonl"
Set-Content -LiteralPath $rolloutPath -Encoding UTF8 -Value '{"timestamp":"2026-06-13T00:00:00.000Z","type":"session_meta","payload":{"id":"thread-a","cwd":"C:\\Work","source":"cli","model_provider":"openai"}}'

$dbPath = Join-Path $codexHome "state_5.sqlite"
Set-Content -LiteralPath $dbPath -Encoding UTF8 -Value "not a sqlite database"

try {
    $result = Invoke-HistoryProviderSync `
        -TargetProvider "CPA" `
        -CodexHome $codexHome `
        -HistoryBackupRoot $historyBackupRoot

    if (-not $result.Warning -or $result.Warning -notmatch "SQLite") {
        throw "Expected SQLite failure warning, got '$($result.Warning)'"
    }
    if ($result.TargetProvider -ne "CPA") {
        throw "Expected result to preserve target provider CPA"
    }
    if ((Get-Content -LiteralPath $rolloutPath -Raw) -notmatch '"model_provider"\s*:\s*"CPA"') {
        throw "Expected rollout provider sync to continue despite SQLite failure"
    }

    Write-Host "Codex sync failure tolerance checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
