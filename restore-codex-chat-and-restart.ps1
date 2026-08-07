$ErrorActionPreference = 'Stop'

$Desktop = [Environment]::GetFolderPath('Desktop')
$BackupDirName = "$([char]0x5907)$([char]0x4efd)"
$Source = Join-Path (Join-Path $Desktop $BackupDirName) 'codex bak\20260708-172606-codex-chat-history'
$Dest = Join-Path $env:USERPROFILE '.codex'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RestoreRoot = Join-Path (Join-Path $Desktop $BackupDirName) "codex-restore-final-$Stamp"
$Log = Join-Path $RestoreRoot 'restore-and-restart.log'
$Python = 'C:\Users\Angus\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$RepairScript = Join-Path $PSScriptRoot 'Repair-Codex-Chat-History.ps1'

New-Item -ItemType Directory -Force -Path $RestoreRoot | Out-Null
"RESTORE_FINAL_START $(Get-Date -Format o)" | Set-Content -LiteralPath $Log -Encoding UTF8
"SOURCE=$Source" | Add-Content -LiteralPath $Log -Encoding UTF8
"DEST=$Dest" | Add-Content -LiteralPath $Log -Encoding UTF8

Start-Sleep -Seconds 8

Get-Process -ErrorAction SilentlyContinue |
  Where-Object {
    ($_.ProcessName -ieq 'Codex') -or
    ($_.ProcessName -ieq 'codex') -or
    ($_.Path -like '*OpenAI.Codex*')
  } |
  ForEach-Object {
    try {
      "STOP_PROCESS id=$($_.Id) name=$($_.ProcessName)" | Add-Content -LiteralPath $Log -Encoding UTF8
      Stop-Process -Id $_.Id -Force -ErrorAction Stop
    } catch {
      "STOP_PROCESS_FAILED id=$($_.Id) error=$($_.Exception.Message)" | Add-Content -LiteralPath $Log -Encoding UTF8
    }
  }

Start-Sleep -Seconds 3

$Items = @(
  'sessions',
  'archived_sessions',
  'attachments',
  'memories',
  'sqlite',
  'session_index.jsonl',
  '.codex-global-state.json',
  'state_5.sqlite',
  'state_5.sqlite-wal',
  'state_5.sqlite-shm',
  'logs_2.sqlite',
  'logs_2.sqlite-wal',
  'logs_2.sqlite-shm',
  'goals_1.sqlite',
  'goals_1.sqlite-wal',
  'goals_1.sqlite-shm',
  'memories_1.sqlite',
  'memories_1.sqlite-wal',
  'memories_1.sqlite-shm'
)

foreach ($Item in $Items) {
  $From = Join-Path $Source $Item
  $To = Join-Path $Dest $Item
  if (Test-Path -LiteralPath $From) {
    Copy-Item -LiteralPath $From -Destination $To -Recurse -Force
    "RESTORED $Item" | Add-Content -LiteralPath $Log -Encoding UTF8
  } else {
    "MISSING_IN_BACKUP $Item" | Add-Content -LiteralPath $Log -Encoding UTF8
  }
}

$Catalog = Join-Path $Dest 'sqlite\codex-dev.db'
if (Test-Path -LiteralPath $RepairScript) {
  & $RepairScript -CodexHome $Dest -LogPath $Log
} elseif ((Test-Path -LiteralPath $Catalog) -and (Test-Path -LiteralPath $Python)) {
  @'
import sqlite3, sys
p = sys.argv[1]
con = sqlite3.connect(p)
cur = con.cursor()
try:
    cur.execute("update local_thread_catalog_sync_state set watermark_updated_at=null, initial_build_complete=0, observation_sequence=0 where host_id='local'")
    cur.execute("update local_thread_catalog_metadata set catalog_revision=catalog_revision+1 where id=1")
    con.commit()
    print("CATALOG_REBUILD_MARKED")
except Exception as e:
    print("CATALOG_REBUILD_MARK_FAILED", repr(e))
finally:
    con.close()
'@ | & $Python - $Catalog | Add-Content -LiteralPath $Log -Encoding UTF8
}

$SessionCount = (Get-ChildItem -LiteralPath (Join-Path $Dest 'sessions') -Recurse -File -Filter '*.jsonl' | Measure-Object).Count
$IndexLines = 0
$Index = Join-Path $Dest 'session_index.jsonl'
if (Test-Path -LiteralPath $Index) {
  $IndexLines = (Get-Content -LiteralPath $Index -Encoding UTF8 | Measure-Object).Count
}
"SESSION_JSONL_COUNT=$SessionCount" | Add-Content -LiteralPath $Log -Encoding UTF8
"SESSION_INDEX_LINES=$IndexLines" | Add-Content -LiteralPath $Log -Encoding UTF8
"RESTORE_FINAL_DONE $(Get-Date -Format o)" | Add-Content -LiteralPath $Log -Encoding UTF8

Start-Sleep -Seconds 2
Start-Process 'explorer.exe' 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
"CODEX_RESTART_REQUESTED $(Get-Date -Format o)" | Add-Content -LiteralPath $Log -Encoding UTF8
