param(
    [switch]$WaitForExit,
    [switch]$SkipWait,
    [switch]$DryRun,
    [int]$TimeoutMinutes = 120
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$switcherScript = Join-Path $PSScriptRoot "CodexUnifiedSwitcher.ps1"
. $switcherScript -NoUi

$settings = Load-SwitcherSettings
$appRoot = Get-AppRootFromBackupRoot $settings.backupRoot
$historyBackupRoot = Get-HistoryBackupRootFromBackupRoot $settings.backupRoot
$logRoot = Join-Path $repoRoot "local-repair-backups\forced-official-sync"
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

$statusPath = Join-Path $logRoot "latest-status.json"
$logPath = Join-Path $logRoot "latest-log.txt"

function Write-StatusFile($State, $Details) {
    $payload = [ordered]@{
        state = $State
        updated_at = (Get-Date).ToString("o")
        details = $Details
    }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

function Write-LogLine($Text) {
    $line = "[{0}] {1}" -f (Get-Date).ToString("o"), $Text
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Wait-CodexExit([int]$Minutes) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        $processes = Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -in @("Codex", "codex") }
        if (-not $processes) {
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for Codex to exit."
}

function Get-RunningCodexProcessList {
    return @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -in @("Codex", "codex") })
}

function Assert-CodexClosed {
    $processes = Get-RunningCodexProcessList
    if ($processes.Count -eq 0) {
        return
    }

    $ids = ($processes | Select-Object -ExpandProperty Id) -join ", "
    throw "Codex is still running. Close Codex completely first, then run this script again. Running process ids: $ids"
}

try {
    "" | Set-Content -LiteralPath $logPath -Encoding UTF8
    Write-LogLine "Helper started."
    Write-Host "Helper started."
    Write-StatusFile -State "checking_codex_closed" -Details @{
        codexHome = $settings.codexHome
        officialConfigPath = $settings.officialConfigPath
        cpamcConfigPath = $settings.cpamcConfigPath
    }

    if ($WaitForExit -and -not $SkipWait) {
        Write-StatusFile -State "waiting_for_codex_exit" -Details @{
            codexHome = $settings.codexHome
            officialConfigPath = $settings.officialConfigPath
            cpamcConfigPath = $settings.cpamcConfigPath
        }
        Write-LogLine "Waiting for all Codex processes to exit."
        Write-Host "Waiting for Codex to close..."
        Wait-CodexExit -Minutes $TimeoutMinutes
    } else {
        Write-LogLine "Manual mode: verifying Codex is already closed."
        Write-Host "Checking that Codex is closed..."
        Assert-CodexClosed
    }

    Write-LogLine "Codex is closed. Starting OAuth switch and history sync."
    Write-Host "Codex closed. Starting official-mode sync..."
    Write-StatusFile -State "running_sync" -Details @{
        codexHome = $settings.codexHome
        target = "OAuth"
    }

    if ($DryRun) {
        Write-LogLine "Dry run requested. Exiting before switch."
        Write-StatusFile -State "dry_run_complete" -Details @{
            codexHome = $settings.codexHome
        }
        exit 0
    }

    $result = Switch-CodexProfileMode `
        -Target "OAuth" `
        -CodexHome $settings.codexHome `
        -OfficialConfigPath $settings.officialConfigPath `
        -CPAMCConfigPath $settings.cpamcConfigPath `
        -AppRoot $appRoot `
        -HistoryBackupRoot $historyBackupRoot `
        -SkipProcessCheck

    Write-LogLine ("Switch completed. TargetProvider={0} ChangedRollouts={1} SqliteRowsUpdated={2}" -f $result.TargetProvider, $result.PostSync.ChangedRollouts, $result.PostSync.SqliteRowsUpdated)
    Write-Host "Sync completed."
    Write-StatusFile -State "completed" -Details @{
        targetProvider = $result.TargetProvider
        previousProvider = $result.PreviousProvider
        postSync = $result.PostSync
        authBackup = $result.AuthBackup
        movedAuth = $result.MovedAuth
    }
} catch {
    Write-LogLine ("Helper failed: {0}" -f $_.Exception.Message)
    Write-Host ("Sync failed: {0}" -f $_.Exception.Message)
    Write-StatusFile -State "failed" -Details @{
        message = $_.Exception.Message
    }
    exit 1
}
