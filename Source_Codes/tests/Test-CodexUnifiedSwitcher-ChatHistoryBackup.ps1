$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing unified switcher script: $scriptPath"
}

. $scriptPath -NoUi

$requiredFunctions = @(
    "Get-ChatHistoryBackupRootFromBackupRoot",
    "New-CodexChatHistoryBackup",
    "Restore-CodexChatHistoryBackup"
)
foreach ($name in $requiredFunctions) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing required function: $name"
    }
}

$pythonCandidates = @(
    (Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"),
    "C:\Users\Angus\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
)
$pythonExe = $pythonCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $pythonExe) {
    throw "Missing bundled Python runtime for restore-repair test."
}
$env:PYTHONIOENCODING = "utf-8"

$root = Join-Path $env:TEMP ("codex-chat-history-backup-test-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $root ".codex"
$backupRoot = Join-Path $root "backups"
$chosenBackupDirectory = Join-Path $root "chosen-backup-folder"
$chosenRestoreHome = Join-Path $root "chosen-restore-home\.codex"
$rolloutPath = Join-Path $codexHome "sessions\2026\07\03\rollout-a.jsonl"
$archivedPath = Join-Path $codexHome "archived_sessions\rollout-old.jsonl"
$attachmentPath = Join-Path $codexHome "attachments\input.txt"
$memoryPath = Join-Path $codexHome "memories\memory_summary.md"

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $rolloutPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $archivedPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $attachmentPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $memoryPath) -Force | Out-Null

    Set-Content -LiteralPath $rolloutPath -Encoding UTF8 -Value "original session"
    Set-Content -LiteralPath $archivedPath -Encoding UTF8 -Value "archived session"
    Set-Content -LiteralPath $attachmentPath -Encoding UTF8 -Value "attached input"
    Set-Content -LiteralPath $memoryPath -Encoding UTF8 -Value "remembered context"
    Set-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Encoding UTF8 -Value '{"id":"thread-a","thread_name":"Test"}'
    Set-Content -LiteralPath (Join-Path $codexHome "state_5.sqlite") -Encoding UTF8 -Value "state-db"
    Set-Content -LiteralPath (Join-Path $codexHome "state_5.sqlite-wal") -Encoding UTF8 -Value "state-wal"
    Set-Content -LiteralPath (Join-Path $codexHome "logs_2.sqlite") -Encoding UTF8 -Value "logs-db"
    Set-Content -LiteralPath (Join-Path $codexHome "memories_1.sqlite") -Encoding UTF8 -Value "memory-db"
    Set-Content -LiteralPath (Join-Path $codexHome "auth.json") -Encoding UTF8 -Value '{"auth_mode":"chatgpt"}'
    Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value 'model_provider = "openai"'

    $backup = New-CodexChatHistoryBackup -CodexHome $codexHome -BackupRoot $backupRoot -Stamp "20260703-010203"
    if (-not (Test-Path -LiteralPath $backup.BackupDir)) {
        throw "Expected backup directory to exist"
    }
    if ($backup.CopiedItems -lt 8) {
        throw "Expected chat history backup to copy at least 8 entries, got $($backup.CopiedItems)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $backup.BackupDir "manifest.json"))) {
        throw "Expected chat history backup manifest"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $backup.BackupDir "sessions\2026\07\03\rollout-a.jsonl"))) {
        throw "Expected active rollout to be backed up"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $backup.BackupDir "archived_sessions\rollout-old.jsonl"))) {
        throw "Expected archived rollout to be backed up"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $backup.BackupDir "attachments\input.txt"))) {
        throw "Expected attachment to be backed up"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $backup.BackupDir "memories\memory_summary.md"))) {
        throw "Expected memories to be backed up"
    }
    if (Test-Path -LiteralPath (Join-Path $backup.BackupDir "auth.json")) {
        throw "Chat history backup must not copy auth.json"
    }
    if (Test-Path -LiteralPath (Join-Path $backup.BackupDir "config.toml")) {
        throw "Chat history backup must not copy config.toml"
    }

    $chosenBackup = New-CodexChatHistoryBackup -CodexHome $codexHome -BackupDirectory $chosenBackupDirectory -Stamp "20260703-030405"
    if (-not $chosenBackup.BackupDir.StartsWith($chosenBackupDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected user-selected backup directory to be used, got $($chosenBackup.BackupDir)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $chosenBackup.BackupDir "manifest.json"))) {
        throw "Expected selected-path backup manifest"
    }

    Set-Content -LiteralPath $rolloutPath -Encoding UTF8 -Value "changed current session"
    Set-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Encoding UTF8 -Value '{"id":"changed"}'
    Set-Content -LiteralPath (Join-Path $codexHome "auth.json") -Encoding UTF8 -Value '{"auth_mode":"apikey"}'
    Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value 'model_provider = "CPA"'

    $restore = Restore-CodexChatHistoryBackup -BackupPath $backup.BackupDir -CodexHome $codexHome -BackupRoot $backupRoot -Stamp "20260703-020304" -SkipProcessCheck
    if (-not (Test-Path -LiteralPath $restore.SafetyBackupDir)) {
        throw "Expected restore to create a safety backup"
    }
    if ((Get-Content -LiteralPath $rolloutPath -Raw).Trim() -ne "original session") {
        throw "Expected restore to replace current rollout with backup copy"
    }
    if ((Get-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Raw).Trim() -ne '{"id":"thread-a","thread_name":"Test"}') {
        throw "Expected restore to replace session_index.jsonl with backup copy"
    }
    if ((Get-Content -LiteralPath (Join-Path $codexHome "auth.json") -Raw).Trim() -ne '{"auth_mode":"apikey"}') {
        throw "Restore must not overwrite auth.json"
    }
    if ((Get-Content -LiteralPath (Join-Path $codexHome "config.toml") -Raw).Trim() -ne 'model_provider = "CPA"') {
        throw "Restore must not overwrite config.toml"
    }
    if ((Get-Content -LiteralPath (Join-Path $restore.SafetyBackupDir "sessions\2026\07\03\rollout-a.jsonl") -Raw).Trim() -ne "changed current session") {
        throw "Expected safety backup to contain the pre-restore current rollout"
    }

    $restoreToChosenPath = Restore-CodexChatHistoryBackup -BackupPath $backup.BackupDir -CodexHome $chosenRestoreHome -BackupRoot $backupRoot -Stamp "20260703-040506" -SkipProcessCheck
    $chosenRolloutPath = Join-Path $chosenRestoreHome "sessions\2026\07\03\rollout-a.jsonl"
    if ((Get-Content -LiteralPath $chosenRolloutPath -Raw).Trim() -ne "original session") {
        throw "Expected restore to write into user-selected restore path"
    }
    if ($restoreToChosenPath.SafetyBackupDir) {
        throw "Expected no safety backup when restoring into a new selected Codex data directory"
    }

    $invalidBackup = Join-Path $root "invalid-backup"
    New-Item -ItemType Directory -Path $invalidBackup -Force | Out-Null
    $invalidFailed = $false
    try {
        Restore-CodexChatHistoryBackup -BackupPath $invalidBackup -CodexHome $codexHome -BackupRoot $backupRoot -SkipProcessCheck | Out-Null
    } catch {
        $invalidFailed = $true
    }
    if (-not $invalidFailed) {
        throw "Expected restore to reject a folder without manifest.json"
    }

    $richSourceHome = Join-Path $root "rich-source\.codex"
    $richTargetHome = Join-Path $root "rich-target\.codex"
    $richRolloutNested = Join-Path $richSourceHome "sessions\sessions\2026\07\03\rollout-webpro.jsonl"
    $richRolloutTranscript = Join-Path $richSourceHome "sessions\2026\07\03\rollout-ssh.jsonl"
    $richCatalogPath = Join-Path $richSourceHome "sqlite\codex-dev.db"
    New-Item -ItemType Directory -Path (Split-Path -Parent $richRolloutNested) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $richRolloutTranscript) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $richCatalogPath) -Force | Out-Null

    Set-Content -LiteralPath $richRolloutNested -Encoding UTF8 -Value @(
        '{"timestamp":"2026-07-03T01:02:03.000Z","type":"session_meta","payload":{"id":"thread-webpro","cwd":"C:\\Users\\Angus\\Desktop\\opencode\\nx","source":"vscode","model_provider":"CPA"}}'
        '{"timestamp":"2026-07-03T01:02:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"+ Thought: 104ms\nWebPro 项目交接总结\n目标三条"}]}}'
    )
    Set-Content -LiteralPath $richRolloutTranscript -Encoding UTF8 -Value @(
        '{"timestamp":"2026-07-03T01:03:03.000Z","type":"session_meta","payload":{"id":"thread-ssh","cwd":"\\\\?\\C:\\Users\\Angus\\Desktop\\Codex\\SSH","source":"vscode","model_provider":"CPA"}}'
        '{"timestamp":"2026-07-03T01:03:04.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"The following is the Codex agent history whose request action you are assessing.\n>>> TRANSCRIPT START\n[1] user: [$writing-plans](C:\\Users\\Angus\\.codex\\skills\\plan\\SKILL.md) 这是一个SSH工具项目，请你了解学习，方便后面帮我解决问题\n>>> TRANSCRIPT END"}]}}'
    )
    Set-Content -LiteralPath (Join-Path $richSourceHome "session_index.jsonl") -Encoding UTF8 -Value @(
        '{"id":"thread-webpro","thread_name":"+ Thought: 104ms\nWebPro 项目交接总结\n目标三条","updated_at":"2026-07-03T01:02:05.0000000Z"}'
        '{"id":"thread-ssh","thread_name":"The following is the Codex agent history whose request action you are assessing.\n>>> TRANSCRIPT START","updated_at":"2026-07-03T01:03:05.0000000Z"}'
    )
    Set-Content -LiteralPath $richCatalogPath -Encoding UTF8 -Value "broken catalog"

    $seedCode = @'
import os
import sqlite3
from pathlib import Path

home = Path(os.environ["RICH_SOURCE_HOME"])
db = home / "state_5.sqlite"
conn = sqlite3.connect(db)
cur = conn.cursor()
cur.execute("""
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
    git_branch TEXT,
    cli_version TEXT NOT NULL DEFAULT '',
    first_user_message TEXT NOT NULL DEFAULT '',
    memory_mode TEXT NOT NULL DEFAULT 'enabled',
    created_at_ms INTEGER,
    updated_at_ms INTEGER,
    thread_source TEXT,
    preview TEXT NOT NULL DEFAULT ''
)
""")
cur.execute(
    "INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (
        "thread-webpro",
        str(home / "sessions" / "sessions" / "2026" / "07" / "03" / "rollout-webpro.jsonl"),
        1783030923,
        1783030925,
        "vscode",
        "CPA",
        r"\\?\C:\Users\Angus\Desktop\opencode\nx",
        "+ Thought: 104ms\nWebPro 项目交接总结\n目标三条",
        "danger-full-access",
        "never",
        0,
        1,
        0,
        None,
        "",
        "+ Thought: 104ms\nWebPro 项目交接总结\n目标三条",
        "enabled",
        1783030923000,
        1783030925000,
        "user",
        "+ Thought: 104ms\nWebPro 项目交接总结\n目标三条",
    ),
)
cur.execute(
    "INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (
        "thread-ssh",
        str(home / "sessions" / "2026" / "07" / "03" / "rollout-ssh.jsonl"),
        1783030983,
        1783030985,
        "vscode",
        "CPA",
        r"\\?\C:\Users\Angus\Desktop\Codex\SSH",
        "The following is the Codex agent history whose request action you are assessing.\n>>> TRANSCRIPT START",
        "danger-full-access",
        "never",
        0,
        1,
        0,
        None,
        "",
        "The following is the Codex agent history whose request action you are assessing.\n>>> TRANSCRIPT START\n[1] user: [$writing-plans](C:\\Users\\Angus\\.codex\\skills\\plan\\SKILL.md) 这是一个SSH工具项目，请你了解学习，方便后面帮我解决问题",
        "enabled",
        1783030983000,
        1783030985000,
        "user",
        "The following is the Codex agent history whose request action you are assessing.\n>>> TRANSCRIPT START",
    ),
)
conn.commit()
conn.close()
'@
    $seedPath = Join-Path $root "seed-rich-state.py"
    Set-Content -LiteralPath $seedPath -Encoding UTF8 -Value $seedCode
    $env:RICH_SOURCE_HOME = $richSourceHome
    & $pythonExe $seedPath
    if ($LASTEXITCODE -ne 0) {
        throw "Expected rich test SQLite seed to succeed"
    }

    New-Item -ItemType Directory -Path $richTargetHome -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $richTargetHome "config.toml") -Encoding UTF8 -Value 'model_provider = "openai"'
    Set-Content -LiteralPath (Join-Path $richTargetHome "auth.json") -Encoding UTF8 -Value '{"auth_mode":"chatgpt"}'
    Set-Content -LiteralPath (Join-Path $richTargetHome "session_index.jsonl") -Encoding UTF8 -Value '{"id":"stale","thread_name":"stale"}'

    $richBackup = New-CodexChatHistoryBackup -CodexHome $richSourceHome -BackupRoot $backupRoot -Stamp "20260703-050607"
    $richRestore = Restore-CodexChatHistoryBackup -BackupPath $richBackup.BackupDir -CodexHome $richTargetHome -BackupRoot $backupRoot -Stamp "20260703-060708" -SkipProcessCheck
    if (-not $richRestore.RepairRan) {
        throw "Expected restore to run automatic repair for direct visibility"
    }
    if ($richRestore.RepairWarning) {
        throw "Expected restore repair without warnings, got $($richRestore.RepairWarning)"
    }

    $flattenedRollout = Join-Path $richTargetHome "sessions\2026\07\03\rollout-webpro.jsonl"
    if (-not (Test-Path -LiteralPath $flattenedRollout)) {
        throw "Expected restore repair to flatten nested session directories"
    }
    if (Test-Path -LiteralPath (Join-Path $richTargetHome "sessions\sessions")) {
        throw "Expected restore repair to remove nested sessions\\sessions tree"
    }

    $verifyCode = @'
import json
import os
import sqlite3
from pathlib import Path

home = Path(os.environ["RICH_TARGET_HOME"])
state = sqlite3.connect(home / "state_5.sqlite")
cur = state.cursor()
rows = {row[0]: row[1:] for row in cur.execute("SELECT id, model_provider, cwd, rollout_path, title FROM threads ORDER BY id")}
state.close()

catalog = sqlite3.connect(home / "sqlite" / "codex-dev.db")
cur = catalog.cursor()
catalog_rows = {row[0]: row[1] for row in cur.execute("SELECT thread_id, display_title FROM local_thread_catalog WHERE host_id='local' ORDER BY thread_id")}
catalog.close()

index_rows = {}
for raw in (home / "session_index.jsonl").read_text(encoding="utf-8").splitlines():
    if not raw.strip():
        continue
    row = json.loads(raw)
    index_rows[row["id"]] = row["thread_name"]

print(json.dumps({
    "rows": rows,
    "catalog_rows": catalog_rows,
    "index_rows": index_rows,
}, ensure_ascii=False))
'@
    $verifyPath = Join-Path $root "verify-rich-restore.py"
    Set-Content -LiteralPath $verifyPath -Encoding UTF8 -Value $verifyCode
    $env:RICH_TARGET_HOME = $richTargetHome
    $verifyJson = & $pythonExe $verifyPath
    if ($LASTEXITCODE -ne 0) {
        throw "Expected rich restore verification to succeed"
    }
    $verify = $verifyJson | ConvertFrom-Json

    if ($verify.rows.'thread-ssh'[0] -ne 'openai') {
        throw "Expected restore repair to align SQLite provider with current config"
    }
    if ($verify.rows.'thread-webpro'[1] -match '^\\\\\?\\') {
        throw "Expected restore repair to normalize SQLite cwd"
    }
    if ($verify.rows.'thread-webpro'[2] -match '\\sessions\\sessions\\') {
        throw "Expected restore repair to normalize SQLite rollout_path"
    }
    if ($verify.rows.'thread-webpro'[3] -ne 'WebPro 项目交接总结') {
        throw "Expected restore repair to rewrite WebPro title, got $($verify.rows.'thread-webpro'[3])"
    }
    if ($verify.rows.'thread-ssh'[3] -ne '这是一个SSH工具项目，请你了解学习，方便后面帮我解决问题') {
        throw "Expected restore repair to rewrite SSH transcript title, got $($verify.rows.'thread-ssh'[3])"
    }
    if ($verify.index_rows.'thread-webpro' -ne 'WebPro 项目交接总结') {
        throw "Expected session_index to be rebuilt with repaired WebPro title"
    }
    if ($verify.index_rows.'thread-ssh' -ne '这是一个SSH工具项目，请你了解学习，方便后面帮我解决问题') {
        throw "Expected session_index to be rebuilt with repaired SSH title"
    }
    if ($verify.catalog_rows.'thread-webpro' -ne 'WebPro 项目交接总结') {
        throw "Expected local_thread_catalog to be rebuilt for WebPro"
    }
    if ($verify.catalog_rows.'thread-ssh' -ne '这是一个SSH工具项目，请你了解学习，方便后面帮我解决问题') {
        throw "Expected local_thread_catalog to be rebuilt for SSH"
    }

    Write-Host "Codex chat history backup/restore checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
