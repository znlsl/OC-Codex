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

$root = Join-Path $env:TEMP ("codex-cockpit-auth-test-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $root ".codex"
$appRoot = Join-Path $root "app"
$historyBackupRoot = Join-Path $root "history-sync"
$officialConfig = Join-Path $root "official-config.toml"
$cpamcConfig = Join-Path $root "cpamc-config.toml"

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $codexHome "sessions") -Force | Out-Null

Set-Content -LiteralPath $officialConfig -Encoding UTF8 -Value 'model = "gpt-5.5"'
Set-Content -LiteralPath $cpamcConfig -Encoding UTF8 -Value @"
model_provider = "CPA"

[model_providers.CPA]
name = "CPA"
api_key = "cpamc-config-key"
"@

Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value (Get-Content -LiteralPath $cpamcConfig -Raw)
Set-Content -LiteralPath (Join-Path $codexHome "auth.json") -Encoding UTF8 -Value '{"auth_mode":"apikey","OPENAI_API_KEY":"cpamc-config-key"}'
Set-Content -LiteralPath (Join-Path $codexHome ".cockpit_codex_auth.json") -Encoding UTF8 -Value '{"writer":"cockpit","account_id":"codex_local_access_runtime"}'
Set-Content -LiteralPath (Join-Path $codexHome "sessions\rollout-a.jsonl") -Encoding UTF8 -Value '{"timestamp":"2026-06-08T00:00:00.000Z","type":"session_meta","payload":{"id":"thread-a","cwd":"C:\\Work","source":"cli","model_provider":"CPA"}}'

$dbPath = Join-Path $codexHome "state_5.sqlite"
& $sqlite.Source $dbPath "CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT, archived INTEGER DEFAULT 0); INSERT INTO threads(id, model_provider, archived) VALUES('thread-a', 'CPA', 0);"

New-Item -ItemType Directory -Path (Join-Path $appRoot "profiles\official") -Force | Out-Null
Set-Content -LiteralPath (Join-Path $appRoot "profiles\official\auth.json") -Encoding UTF8 -Value '{"auth_mode":"chatgpt"}'

try {
    $oauthResult = Switch-CodexProfileMode `
        -Target "OAuth" `
        -CodexHome $codexHome `
        -OfficialConfigPath $officialConfig `
        -CPAMCConfigPath $cpamcConfig `
        -AppRoot $appRoot `
        -HistoryBackupRoot $historyBackupRoot `
        -SkipProcessCheck

    $disabledCockpit = @(Get-ChildItem -LiteralPath $codexHome -Filter ".cockpit_codex_auth.json.disabled-before-oauth-*" -ErrorAction SilentlyContinue)
    if ($disabledCockpit.Count -ne 1) {
        throw "Expected cockpit auth file to be moved aside before OAuth switch."
    }
    if (Test-Path -LiteralPath (Join-Path $codexHome ".cockpit_codex_auth.json")) {
        throw "Expected live cockpit auth file to be absent after OAuth switch."
    }

    $cpamcResult = Switch-CodexProfileMode `
        -Target "CPAMC" `
        -CodexHome $codexHome `
        -OfficialConfigPath $officialConfig `
        -CPAMCConfigPath $cpamcConfig `
        -AppRoot $appRoot `
        -HistoryBackupRoot $historyBackupRoot `
        -SkipProcessCheck

    if (-not (Test-Path -LiteralPath (Join-Path $codexHome ".cockpit_codex_auth.json"))) {
        throw "Expected cockpit auth file to be restored before CPAMC switch."
    }

    Write-Host "Codex unified switcher cockpit auth checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
