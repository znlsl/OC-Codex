$ErrorActionPreference = "Stop"

$CodexHome = "C:\Users\Angus\.codex"
$PreCockpitBackup = "C:\Users\Angus\Desktop\backup\codex-chat-backup-20260612-225107"
$SafetyRoot = "D:\codex-back\c-o-safety-backups"
$SwitcherScript = "C:\Users\Angus\Desktop\Codex\O-C\Source_Codes\tools\CodexUnifiedSwitcher.ps1"

function Wait-CodexExit {
    $deadline = (Get-Date).AddMinutes(20)
    while (Get-Date -lt $deadline) {
        $processes = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -in @("Codex", "codex") }
        if (-not $processes) {
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for Codex to exit."
}

Wait-CodexExit

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $SafetyRoot "post-exit-pre-cockpit-restore-$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

foreach ($name in @("session_index.jsonl", ".codex-global-state.json")) {
    $current = Join-Path $CodexHome $name
    if (Test-Path -LiteralPath $current) {
        Copy-Item -LiteralPath $current -Destination (Join-Path $backupDir "$name.before") -Force
    }

    $source = Join-Path $PreCockpitBackup $name
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $current -Force
    }
}

. $SwitcherScript -NoUi
$result = Sync-SessionIndex -CodexHome $CodexHome

$summary = [PSCustomObject]@{
    RestoredAt = (Get-Date).ToString("o")
    BackupDir = $backupDir
    SessionIndexAdded = $result.AddedRows
    SessionIndexRepaired = $result.RepairedRows
    SessionIndexTotal = $result.TotalRows
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backupDir "restore-result.json") -Encoding UTF8
