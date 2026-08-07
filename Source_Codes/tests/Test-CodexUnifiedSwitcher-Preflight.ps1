$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
. $scriptPath -NoUi

$sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqlite) {
    throw "sqlite3 is required for this test"
}

$root = Join-Path $env:TEMP ("codex-preflight-test-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $root ".codex"
$appRoot = Join-Path $root "app"
$historyBackupRoot = Join-Path $root "history-sync"
$officialConfig = Join-Path $root "official-config.toml"
$cpamcConfig = Join-Path $root "cpamc-config.toml"

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $codexHome "sessions") -Force | Out-Null

Set-Content -LiteralPath $officialConfig -Encoding UTF8 -Value 'model_provider = "openai"'
Set-Content -LiteralPath $cpamcConfig -Encoding UTF8 -Value @"
model_provider = "CPA"

[model_providers.CPA]
name = "CPA"
api_key = "cpamc-config-key"
"@

Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value (Get-Content -LiteralPath $cpamcConfig -Raw)
Set-Content -LiteralPath (Join-Path $codexHome "auth.json") -Encoding UTF8 -Value '{"auth_mode":"apikey","OPENAI_API_KEY":"cpamc-config-key"}'
Set-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Encoding UTF8 -Value '{"id":"thread-a","thread_name":"A","updated_at":"2026-06-13T00:00:00.0000000Z"}'

$rolloutPath = Join-Path $codexHome "sessions\rollout-a.jsonl"
Set-Content -LiteralPath $rolloutPath -Encoding UTF8 -Value '{"timestamp":"2026-06-13T00:00:00.000Z","type":"session_meta","payload":{"id":"thread-a","cwd":"C:\\Work","source":"cli","model_provider":"CPA"}}'

$dbPath = Join-Path $codexHome "state_5.sqlite"
& $sqlite.Source $dbPath "CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT, archived INTEGER DEFAULT 0); INSERT INTO threads(id, model_provider, archived) VALUES('thread-a', 'CPA', 0);"

$lockStream = [System.IO.File]::Open((Join-Path $codexHome "session_index.jsonl"), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)

try {
    try {
        Switch-CodexProfileMode `
            -Target "OAuth" `
            -CodexHome $codexHome `
            -OfficialConfigPath $officialConfig `
            -CPAMCConfigPath $cpamcConfig `
            -AppRoot $appRoot `
            -HistoryBackupRoot $historyBackupRoot `
            -SkipProcessCheck | Out-Null
        throw "Expected preflight failure when session_index.jsonl is locked."
    } catch {
        if ($_.Exception.Message -notmatch "session_index unavailable") {
            throw "Expected session_index preflight failure, got: $($_.Exception.Message)"
        }
    }

    Write-Host "Codex unified switcher preflight checks passed."
}
finally {
    $lockStream.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
