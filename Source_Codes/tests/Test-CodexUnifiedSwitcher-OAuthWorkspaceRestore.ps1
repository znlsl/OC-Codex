$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing unified switcher script: $scriptPath"
}

. $scriptPath -NoUi

$sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
if (-not $sqlite) {
    throw "sqlite3 is required for this test"
}

$root = Join-Path $env:TEMP ("codex-oauth-workspace-restore-test-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $root ".codex"
$appRoot = Join-Path $root "app"
$historyBackupRoot = Join-Path $root "history-sync"
$officialConfig = Join-Path $root "official-config.toml"
$cpamcConfig = Join-Path $root "cpamc-config.toml"
$sessionIndexPath = Join-Path $codexHome "session_index.jsonl"
$workspaceRows = @(
    @{ Id = "thread-ssh"; Cwd = "\\?\C:\Users\Angus\Desktop\Codex\SSH"; Expected = "C:\Users\Angus\Desktop\Codex\SSH"; Title = "SSH root" },
    @{ Id = "thread-aether"; Cwd = "\\?\C:\Users\Angus\Desktop\Codex\Aether"; Expected = "C:\Users\Angus\Desktop\Codex\Aether"; Title = "Aether root" },
    @{ Id = "thread-cj"; Cwd = "\\?\C:\Users\Angus\Desktop\Codex\cj"; Expected = "C:\Users\Angus\Desktop\Codex\cj"; Title = "cj root" }
)

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $codexHome "sessions\2026\06\13") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appRoot "profiles\official") -Force | Out-Null

Set-Content -LiteralPath $officialConfig -Encoding UTF8 -Value 'model_provider = "openai"'
Set-Content -LiteralPath $cpamcConfig -Encoding UTF8 -Value @"
model_provider = "CPA"

[model_providers.CPA]
name = "CPA"
api_key = "cpamc-config-key"
"@

Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value (Get-Content -LiteralPath $cpamcConfig -Raw)
Set-Content -LiteralPath (Join-Path $codexHome "auth.json") -Encoding UTF8 -Value '{"auth_mode":"apikey","OPENAI_API_KEY":"cpamc-config-key"}'
Set-Content -LiteralPath (Join-Path $appRoot "profiles\official\auth.json") -Encoding UTF8 -Value '{"auth_mode":"chatgpt"}'
Set-Content -LiteralPath $sessionIndexPath -Encoding UTF8 -Value @(
    '{"id":"thread-ssh","thread_name":"接手工作","updated_at":"2026-06-13T00:00:00.0000000Z"}'
    '{"id":"thread-aether","thread_name":"接手工作","updated_at":"2026-06-13T00:00:00.0000000Z"}'
    '{"id":"thread-cj","thread_name":"了解席位修改脚本原理","updated_at":"2026-06-13T00:00:00.0000000Z"}'
)

foreach ($row in $workspaceRows) {
    $rolloutPath = Join-Path $codexHome ("sessions\2026\06\13\rollout-{0}.jsonl" -f $row.Id)
    $sessionMetaLine = [PSCustomObject]@{
        timestamp = "2026-06-13T09:00:00.000Z"
        type = "session_meta"
        payload = [PSCustomObject]@{
            id = $row.Id
            cwd = $row.Cwd
            source = "vscode"
            model_provider = "CPA"
        }
    } | ConvertTo-Json -Compress -Depth 10

    $responseItemLine = [PSCustomObject]@{
        timestamp = "2026-06-13T09:00:01.000Z"
        type = "response_item"
        payload = [PSCustomObject]@{
            type = "message"
            role = "user"
            content = @(
                [PSCustomObject]@{
                    type = "input_text"
                    text = "restore workspace history"
                }
            )
        }
    } | ConvertTo-Json -Compress -Depth 10

    Set-Content -LiteralPath $rolloutPath -Encoding UTF8 -Value @(
        $sessionMetaLine
        $responseItemLine
    )
}

$dbPath = Join-Path $codexHome "state_5.sqlite"
$sqlLines = @(
    "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, source TEXT NOT NULL, model_provider TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, sandbox_policy TEXT NOT NULL, approval_mode TEXT NOT NULL, tokens_used INTEGER NOT NULL DEFAULT 0, has_user_event INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0, archived_at INTEGER, git_sha TEXT, git_branch TEXT, git_origin_url TEXT, cli_version TEXT NOT NULL DEFAULT '', first_user_message TEXT NOT NULL DEFAULT '', agent_nickname TEXT, agent_role TEXT, memory_mode TEXT NOT NULL DEFAULT 'enabled', model TEXT, reasoning_effort TEXT, agent_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, thread_source TEXT, preview TEXT NOT NULL DEFAULT '');"
)
foreach ($row in $workspaceRows) {
    $safeTitle = $row.Title.Replace("'", "''")
    $safeCwd = $row.Cwd.Replace("'", "''")
    $safeRollout = (Join-Path $codexHome ("sessions\2026\06\13\rollout-{0}.jsonl" -f $row.Id)).Replace('\', '\\').Replace("'", "''")
    $sqlLines += ("INSERT INTO threads(id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode, tokens_used, has_user_event, archived, cli_version, first_user_message, memory_mode, created_at_ms, updated_at_ms, thread_source, preview) VALUES('{0}', '{1}', 1781337600, 1781337600, 'vscode', 'CPA', '{2}', '{3}', 'danger-full-access', 'never', 0, 1, 0, '0.136.0-alpha.2', 'restore workspace history', 'enabled', 1781337600000, 1781337600000, 'user', 'restore workspace history');" -f $row.Id, $safeRollout, $safeCwd, $safeTitle)
}
$seedSqlPath = Join-Path $root "seed.sql"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($seedSqlPath, ($sqlLines -join [Environment]::NewLine), $utf8NoBom)
& $sqlite.Source $dbPath ".read $($seedSqlPath.Replace('\', '/'))"

try {
    $result = Switch-CodexProfileMode `
        -Target "OAuth" `
        -CodexHome $codexHome `
        -OfficialConfigPath $officialConfig `
        -CPAMCConfigPath $cpamcConfig `
        -AppRoot $appRoot `
        -HistoryBackupRoot $historyBackupRoot `
        -SkipProcessCheck

    if ($result.TargetProvider -ne "openai") {
        throw "Expected OAuth target provider openai, got $($result.TargetProvider)"
    }

    foreach ($row in $workspaceRows) {
        $rolloutPath = Join-Path $codexHome ("sessions\2026\06\13\rollout-{0}.jsonl" -f $row.Id)
        $rolloutText = Get-Content -LiteralPath $rolloutPath -Raw -Encoding UTF8
        if ($rolloutText -notmatch '"model_provider"\s*:\s*"openai"') {
            throw "Expected rollout provider openai for $($row.Id)"
        }
        if ($rolloutText -notmatch ([regex]::Escape('"cwd":"' + $row.Expected.Replace('\', '\\') + '"'))) {
            throw "Expected rollout cwd to be normalized for $($row.Id)"
        }

        $dbRow = (& $sqlite.Source $dbPath ("SELECT model_provider || '|' || cwd FROM threads WHERE id='{0}';" -f $row.Id)).Trim()
        if ($dbRow -ne ("openai|{0}" -f $row.Expected)) {
            throw "Expected SQLite row to be normalized for $($row.Id), got '$dbRow'"
        }
    }

    $indexRows = Get-Content -LiteralPath $sessionIndexPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }
    foreach ($row in $workspaceRows) {
        if (-not ($indexRows | Where-Object { $_.id -eq $row.Id })) {
            throw "Expected session_index.jsonl to preserve $($row.Id)"
        }
    }

    Write-Host "Codex unified switcher OAuth workspace restore checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
