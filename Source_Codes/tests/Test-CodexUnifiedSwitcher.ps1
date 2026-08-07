$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing unified switcher script: $scriptPath"
}

. $scriptPath -NoUi

$requiredFunctions = @(
    "Get-CodexProvider",
    "Save-ModeProfile",
    "Invoke-HistoryProviderSync",
    "Switch-CodexProfileMode"
)
foreach ($name in $requiredFunctions) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing required function: $name"
    }
}

$sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqlite) {
    throw "sqlite3 is required for this test"
}

$root = Join-Path $env:TEMP ("codex-unified-switch-test-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $root ".codex"
$appRoot = Join-Path $root "app"
$historyBackupRoot = Join-Path $root "history-sync"
$officialConfig = Join-Path $root "official-config.toml"
$cpamcConfig = Join-Path $root "cpamc-config.toml"
$expectedChineseTitle = [System.Text.Encoding]::UTF8.GetString([byte[]]@(
    0xe6,0xaf,0x94,0xe8,0xbe,0x83,0xe6,0xa1,0x8c,0xe9,0x9d,0xa2,0xe7,0xab,0xaf,
    0xe4,0xb8,0x8e,0x43,0x50,0x41,0xe6,0x96,0xb9,0xe6,0xa1,0x88
))
$expectedToolTitle = [System.Text.Encoding]::UTF8.GetString([byte[]]@(
    0x4f,0x2d,0x43,0xe5,0xb7,0xa5,0xe5,0x85,0xb7
))
$sqliteUpdatedAtUnix = ([DateTimeOffset]::Parse("2026-06-10T00:00:00Z")).ToUnixTimeSeconds()
$expectedSqliteUpdatedAt = ([DateTimeOffset]::FromUnixTimeSeconds($sqliteUpdatedAtUnix)).UtcDateTime.ToString("o")
$gbkEncoding = [System.Text.Encoding]::GetEncoding(936)
$mojibakeToolTitle = $gbkEncoding.GetString([System.Text.Encoding]::UTF8.GetBytes($expectedToolTitle))

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $codexHome "sessions") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appRoot "profiles\cpamc") -Force | Out-Null

Set-Content -LiteralPath $officialConfig -Encoding UTF8 -Value @"
model_provider = "openai"
"@
Set-Content -LiteralPath $cpamcConfig -Encoding UTF8 -Value @"
model_provider = "CPA"

[model_providers.CPA]
name = "CPA"
api_key = "cpamc-config-key"
"@
Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value (Get-Content -LiteralPath $officialConfig -Raw)
Set-Content -LiteralPath (Join-Path $codexHome "auth.json") -Encoding UTF8 -Value '{"auth_mode":"chatgpt"}'
Set-Content -LiteralPath (Join-Path $appRoot "profiles\cpamc\auth.json") -Encoding UTF8 -Value '{"auth_mode":"apikey","OPENAI_API_KEY":"stale-profile-key"}'
Copy-Item -LiteralPath $cpamcConfig -Destination (Join-Path $appRoot "profiles\cpamc\config.toml") -Force

$rolloutPath = Join-Path $codexHome "sessions\rollout-a.jsonl"
$firstLine = '{"timestamp":"2026-06-08T00:00:00.000Z","type":"session_meta","payload":{"id":"thread-a","cwd":"C:\\Work","source":"cli","model_provider":"openai"}}'
Set-Content -LiteralPath $rolloutPath -Encoding UTF8 -Value ($firstLine + "`n" + '{"type":"event_msg","payload":{"type":"user_message","message":"hello"}}')
[System.IO.File]::SetLastWriteTimeUtc($rolloutPath, ([DateTimeOffset]::Parse("2026-06-01T00:00:00Z")).UtcDateTime)
$questionRolloutPath = Join-Path $codexHome "sessions\rollout-question.jsonl"
$questionFirstLine = '{"timestamp":"2026-06-08T00:00:00.000Z","type":"session_meta","payload":{"id":"thread-question","cwd":"C:\\QuestionProject","source":"cli","model_provider":"openai"}}'
Set-Content -LiteralPath $questionRolloutPath -Encoding UTF8 -Value $questionFirstLine
$orphanRolloutPath = Join-Path $codexHome "sessions\rollout-orphan.jsonl"
$orphanFirstLine = '{"timestamp":"2026-06-08T00:00:00.000Z","type":"session_meta","payload":{"id":"thread-rollout-only","cwd":"C:\\OrphanProject","source":"cli","model_provider":"openai"}}'
Set-Content -LiteralPath $orphanRolloutPath -Encoding UTF8 -Value $orphanFirstLine
Set-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Encoding UTF8 -Value @(
    '{"id":"thread-a","thread_name":"Project Alias","updated_at":"2026-06-06T00:00:00.0000000Z"}'
    '{"id":"thread-a","thread_name":"' + ('bad title ' * 30) + '","updated_at":"2026-06-07T00:00:00.0000000Z"}'
    '{"id":"thread-question","thread_name":"???????","updated_at":"2026-06-07T00:00:00.0000000Z"}'
    '{"id":"thread-mojibake","thread_name":"' + $mojibakeToolTitle + '","updated_at":"2026-06-07T00:00:00.0000000Z"}'
    '{"id":"other-thread","thread_name":"Other","updated_at":"2026-06-07T00:00:00.0000000Z"}'
)

$dbPath = Join-Path $codexHome "state_5.sqlite"
$dbSeedPath = Join-Path $root "seed-state.sql"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($dbSeedPath, @"
CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT, title TEXT, updated_at INTEGER, cwd TEXT, archived INTEGER DEFAULT 0);
INSERT INTO threads(id, model_provider, title, updated_at, cwd, archived) VALUES('thread-a', 'openai', '$expectedChineseTitle', $sqliteUpdatedAtUnix, 'C:\Work', 0);
INSERT INTO threads(id, model_provider, title, updated_at, cwd, archived) VALUES('thread-question', 'openai', '???????', $sqliteUpdatedAtUnix, 'C:\QuestionProject', 0);
INSERT INTO threads(id, model_provider, title, updated_at, cwd, archived) VALUES('thread-mojibake', 'openai', '$expectedToolTitle', $sqliteUpdatedAtUnix, 'C:\ToolProject', 0);
"@, $utf8NoBom)
& $sqlite.Source $dbPath ".read $($dbSeedPath.Replace('\', '/'))"

try {
    $cpamcResult = Switch-CodexProfileMode `
        -Target "CPAMC" `
        -CodexHome $codexHome `
        -OfficialConfigPath $officialConfig `
        -CPAMCConfigPath $cpamcConfig `
        -AppRoot $appRoot `
        -HistoryBackupRoot $historyBackupRoot `
        -SkipProcessCheck

    if ($cpamcResult.TargetProvider -ne "CPA") {
        throw "Expected CPAMC target provider CPA, got $($cpamcResult.TargetProvider)"
    }
    if (-not $cpamcResult.PostSync.BackupDir.StartsWith($historyBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected CPAMC history backup under temp history root, got $($cpamcResult.PostSync.BackupDir)"
    }
    if ((Get-CodexProvider -CodexHome $codexHome) -ne "CPA") {
        throw "Expected config provider CPA after CPAMC switch"
    }
    $cpamcAuth = Get-Content -LiteralPath (Join-Path $codexHome "auth.json") -Raw | ConvertFrom-Json
    if ($cpamcAuth.auth_mode -ne "apikey") {
        throw "Expected CPAMC apikey auth after CPAMC switch"
    }
    if ($cpamcAuth.OPENAI_API_KEY -ne "cpamc-config-key") {
        throw "Expected CPAMC auth key to be regenerated from config.toml"
    }
    if ((Get-Content -LiteralPath $rolloutPath -Raw) -notmatch '"model_provider"\s*:\s*"CPA"') {
        throw "Expected rollout provider CPA after CPAMC switch"
    }
    if ((Get-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Raw) -notmatch '"id"\s*:\s*"thread-a"') {
        throw "Expected session_index.jsonl to include switched rollout after CPAMC switch"
    }
    $indexRows = Get-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }
    $threadAIndexes = @($indexRows | Where-Object { $_.id -eq "thread-a" })
    if ($threadAIndexes.Count -ne 2) {
        throw "Expected session_index.jsonl to preserve duplicate project mappings for thread-a, got $($threadAIndexes.Count)"
    }
    if ($threadAIndexes[0].thread_name -ne "Project Alias") {
        throw "Expected session_index.jsonl to preserve good project alias, got $($threadAIndexes[0].thread_name)"
    }
    if ($threadAIndexes[1].thread_name -ne $expectedChineseTitle) {
        throw "Expected session_index.jsonl to repair only bad thread-a title from SQLite, got $($threadAIndexes[1].thread_name)"
    }
    if ($threadAIndexes[0].updated_at -ne $expectedSqliteUpdatedAt) {
        throw "Expected stale good thread-a index timestamp to refresh from SQLite, got $($threadAIndexes[0].updated_at)"
    }
    if ($threadAIndexes[1].updated_at -ne $expectedSqliteUpdatedAt) {
        throw "Expected stale repaired thread-a index timestamp to refresh from SQLite, got $($threadAIndexes[1].updated_at)"
    }
    $questionIndex = $indexRows | Where-Object { $_.id -eq "thread-question" } | Select-Object -First 1
    if ($questionIndex.thread_name -ne "QuestionProject") {
        throw "Expected session_index.jsonl to repair question-mark title from rollout cwd, got $($questionIndex.thread_name)"
    }
    $mojibakeIndex = $indexRows | Where-Object { $_.id -eq "thread-mojibake" } | Select-Object -First 1
    if ($mojibakeIndex.thread_name -ne $expectedToolTitle) {
        throw "Expected session_index.jsonl to repair mojibake title, got $($mojibakeIndex.thread_name)"
    }
    if (-not ($indexRows | Where-Object { $_.id -eq "thread-rollout-only" })) {
        throw "Expected session_index.jsonl to add rollout-only sessions after SQLite backfill"
    }
    $rolloutOnlyProvider = (& $sqlite.Source $dbPath "SELECT model_provider FROM threads WHERE id='thread-rollout-only';").Trim()
    if ($rolloutOnlyProvider -ne "CPA") {
        throw "Expected rollout-only SQLite backfill provider CPA after CPAMC switch, got $rolloutOnlyProvider"
    }
    $dbProvider = (& $sqlite.Source $dbPath "SELECT model_provider FROM threads WHERE id='thread-a';").Trim()
    if ($dbProvider -ne "CPA") {
        throw "Expected SQLite provider CPA after CPAMC switch, got $dbProvider"
    }

    $oauthResult = Switch-CodexProfileMode `
        -Target "OAuth" `
        -CodexHome $codexHome `
        -OfficialConfigPath $officialConfig `
        -CPAMCConfigPath $cpamcConfig `
        -AppRoot $appRoot `
        -HistoryBackupRoot $historyBackupRoot `
        -SkipProcessCheck

    if ($oauthResult.TargetProvider -ne "openai") {
        throw "Expected OAuth target provider openai, got $($oauthResult.TargetProvider)"
    }
    if (-not $oauthResult.PostSync.BackupDir.StartsWith($historyBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected OAuth history backup under temp history root, got $($oauthResult.PostSync.BackupDir)"
    }
    if ((Get-CodexProvider -CodexHome $codexHome) -ne "openai") {
        throw "Expected config provider openai after OAuth switch"
    }
    if ((Get-Content -LiteralPath (Join-Path $codexHome "auth.json") -Raw) -notmatch '"auth_mode"\s*:\s*"chatgpt"') {
        throw "Expected restored OpenAI auth after OAuth switch"
    }
    if ((Get-ChildItem -LiteralPath $codexHome -Filter "auth.json.api-before-oauth-*" -ErrorAction SilentlyContinue).Count -lt 1) {
        throw "Expected API auth to be moved aside before OAuth"
    }
    if ((Get-Content -LiteralPath $rolloutPath -Raw) -notmatch '"model_provider"\s*:\s*"openai"') {
        throw "Expected rollout provider openai after OAuth switch"
    }
    if ((Get-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Raw) -notmatch '"id"\s*:\s*"thread-a"') {
        throw "Expected session_index.jsonl to preserve switched rollout after OAuth switch"
    }
    $dbProvider = (& $sqlite.Source $dbPath "SELECT model_provider FROM threads WHERE id='thread-a';").Trim()
    if ($dbProvider -ne "openai") {
        throw "Expected SQLite provider openai after OAuth switch, got $dbProvider"
    }

    Write-Host "Codex unified switcher checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
