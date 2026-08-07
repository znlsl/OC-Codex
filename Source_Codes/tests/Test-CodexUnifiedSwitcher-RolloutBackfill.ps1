$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
. $scriptPath -NoUi

$sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqlite) {
    throw "sqlite3 is required for this test"
}

$root = Join-Path $env:TEMP ("codex-rollout-backfill-test-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $root ".codex"
$historyBackupRoot = Join-Path $root "history-sync"
$sessionsDir = Join-Path $codexHome "sessions\2026\06\13"
New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null

$threadId = "thread-rollout-only"
$rolloutPath = Join-Path $sessionsDir "rollout-2026-06-13T15-25-06-$threadId.jsonl"
Set-Content -LiteralPath $rolloutPath -Encoding UTF8 -Value @(
    '{"timestamp":"2026-06-13T07:25:06.040Z","type":"session_meta","payload":{"id":"thread-rollout-only","timestamp":"2026-06-13T07:25:06.040Z","cwd":"C:\\Users\\Angus\\Desktop\\Codex\\O-C","source":"vscode","thread_source":"user","model_provider":"CPA","model":"gpt-5.5","reasoning_effort":"medium"}}'
    '{"timestamp":"2026-06-13T07:26:08.108Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# Files mentioned by the user:\n\n## My request for Codex:\nrestore official history from cpa"}]}}'
)
[System.IO.File]::SetLastWriteTimeUtc($rolloutPath, ([DateTimeOffset]::Parse("2026-06-13T07:26:08Z")).UtcDateTime)

$dbPath = Join-Path $codexHome "state_5.sqlite"
& $sqlite.Source $dbPath @"
CREATE TABLE threads(
  id TEXT PRIMARY KEY,
  rollout_path TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  source TEXT NOT NULL,
  model_provider TEXT NOT NULL,
  cwd TEXT NOT NULL,
  title TEXT NOT NULL,
  sandbox_policy TEXT NOT NULL,
  approval_mode TEXT NOT NULL,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  has_user_event INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  archived_at INTEGER,
  git_sha TEXT,
  git_branch TEXT,
  git_origin_url TEXT,
  cli_version TEXT NOT NULL DEFAULT '',
  first_user_message TEXT NOT NULL DEFAULT '',
  agent_nickname TEXT,
  agent_role TEXT,
  memory_mode TEXT NOT NULL DEFAULT 'enabled',
  model TEXT,
  reasoning_effort TEXT,
  agent_path TEXT,
  created_at_ms INTEGER,
  updated_at_ms INTEGER,
  thread_source TEXT,
  preview TEXT NOT NULL DEFAULT ''
);
"@

try {
    $result = Invoke-HistoryProviderSync `
        -TargetProvider "openai" `
        -CodexHome $codexHome `
        -HistoryBackupRoot $historyBackupRoot

    $count = (& $sqlite.Source $dbPath "SELECT COUNT(*) FROM threads WHERE id='$threadId' AND model_provider='openai' AND cwd='C:\Users\Angus\Desktop\Codex\O-C' AND title='restore official history from cpa';").Trim()
    if ($count -ne "1") {
        throw "Expected rollout-only session to be backfilled into SQLite threads."
    }

    $indexText = Get-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Raw -Encoding UTF8
    if ($indexText -notmatch '"id"\s*:\s*"thread-rollout-only"') {
        throw "Expected rollout-only session to be added to session_index.jsonl."
    }
    if ($result.SqliteRowsBackfilled -ne 1) {
        throw "Expected SqliteRowsBackfilled 1, got $($result.SqliteRowsBackfilled)"
    }

    Write-Host "Codex rollout backfill checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
