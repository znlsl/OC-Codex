$ErrorActionPreference = 'Stop'

$CheckOnly = $args -contains '--check'
$Desktop = [Environment]::GetFolderPath('Desktop')
$BackupDirName = "$([char]0x5907)$([char]0x4efd)"
$Source = Join-Path (Join-Path $Desktop $BackupDirName) 'codex bak\20260708-172606-codex-chat-history'
$Dest = Join-Path $env:USERPROFILE '.codex'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$SafetyRoot = Join-Path (Join-Path $Desktop $BackupDirName) "codex-manual-restore-safety-$Stamp"
$Log = Join-Path $SafetyRoot 'manual-restore.log'
$Python = 'C:\Users\Angus\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$RepairScript = Join-Path $PSScriptRoot 'Repair-Codex-Chat-History.ps1'

function Write-Log {
  param([string]$Message)
  $Line = "$(Get-Date -Format o) $Message"
  $Line | Tee-Object -FilePath $Log -Append
}

function Copy-ItemSafe {
  param(
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To
  )

  if (Test-Path -LiteralPath $To) {
    Remove-Item -LiteralPath $To -Recurse -Force
  }

  if ((Get-Item -LiteralPath $From).PSIsContainer) {
    robocopy $From $To /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Host
    if ($LASTEXITCODE -gt 7) {
      throw "robocopy failed with exit code $LASTEXITCODE for $From"
    }
  } else {
    $Parent = Split-Path -Parent $To
    if ($Parent) {
      New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    }
    Copy-Item -LiteralPath $From -Destination $To -Force
  }
}

New-Item -ItemType Directory -Force -Path $SafetyRoot | Out-Null
Write-Log "Manual Codex chat restore started."
Write-Log "Source: $Source"
Write-Log "Destination: $Dest"
Write-Log "Safety backup: $SafetyRoot"

if (!(Test-Path -LiteralPath $Source)) {
  throw "Backup source not found: $Source"
}

if ($CheckOnly) {
  Write-Host "CHECK_OK"
  Write-Host "Source: $Source"
  Write-Host "Destination: $Dest"
  Write-Host "Python exists: $(Test-Path -LiteralPath $Python)"
  Write-Host "Backup manifest exists: $(Test-Path -LiteralPath (Join-Path $Source 'manifest.json'))"
  Write-Host "Backup sessions exist: $(Test-Path -LiteralPath (Join-Path $Source 'sessions'))"
  exit 0
}

Write-Host ""
Write-Host "This will close Codex, restore chat history, then start Codex again."
Write-Host "Close any important unsent Codex input now."
Write-Host ""
Read-Host "Press Enter to continue"

Write-Log "Stopping Codex processes."
Get-Process -ErrorAction SilentlyContinue |
  Where-Object {
    ($_.ProcessName -ieq 'Codex') -or
    ($_.ProcessName -ieq 'codex') -or
    ($_.ProcessName -ieq 'node_repl') -or
    ($_.Path -like '*OpenAI.Codex*') -or
    ($_.Path -like '*\.codex*')
  } |
  ForEach-Object {
    try {
      Write-Log "Stopping process id=$($_.Id) name=$($_.ProcessName)"
      Stop-Process -Id $_.Id -Force -ErrorAction Stop
    } catch {
      Write-Log "Failed to stop process id=$($_.Id): $($_.Exception.Message)"
    }
  }

Start-Sleep -Seconds 4

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

Write-Log "Creating safety backup of current Codex data."
foreach ($Item in $Items) {
  $Current = Join-Path $Dest $Item
  if (Test-Path -LiteralPath $Current) {
    $Backup = Join-Path $SafetyRoot $Item
    Write-Log "Safety backup: $Item"
    Copy-ItemSafe -From $Current -To $Backup
  }
}

Write-Log "Restoring backup files."
foreach ($Item in $Items) {
  $From = Join-Path $Source $Item
  $To = Join-Path $Dest $Item
  if (Test-Path -LiteralPath $From) {
    Write-Log "Restore: $Item"
    Copy-ItemSafe -From $From -To $To
  } else {
    Write-Log "Missing in backup: $Item"
  }
}

$Catalog = Join-Path $Dest 'sqlite\codex-dev.db'
if (Test-Path -LiteralPath $RepairScript) {
  Write-Log "Running Codex chat repair."
  & $RepairScript -CodexHome $Dest -LogPath $Log
} elseif ((Test-Path -LiteralPath $Catalog) -and (Test-Path -LiteralPath $Python)) {
  Write-Log "Repair script missing; only marking catalog for rebuild."
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
'@ | & $Python - $Catalog | Tee-Object -FilePath $Log -Append
}

$State = Join-Path $Dest 'state_5.sqlite'
if ((Test-Path -LiteralPath $State) -and (Test-Path -LiteralPath $Python)) {
  Write-Log "Verifying restored thread database."
  @'
import sqlite3, sys
p = sys.argv[1]
con = sqlite3.connect(p)
cur = con.cursor()
print("THREAD_COUNT=" + str(cur.execute("select count(*) from threads").fetchone()[0]))
for row in cur.execute("select id, title, updated_at from threads order by updated_at desc limit 8"):
    print("THREAD", row[0], row[2], row[1])
con.close()
'@ | & $Python - $State | Tee-Object -FilePath $Log -Append
}

$SessionDir = Join-Path $Dest 'sessions'
$SessionCount = 0
if (Test-Path -LiteralPath $SessionDir) {
  $SessionCount = (Get-ChildItem -LiteralPath $SessionDir -Recurse -File -Filter '*.jsonl' | Measure-Object).Count
}
$Index = Join-Path $Dest 'session_index.jsonl'
$IndexLines = 0
if (Test-Path -LiteralPath $Index) {
  $IndexLines = (Get-Content -LiteralPath $Index -Encoding UTF8 | Measure-Object).Count
}

Write-Log "SESSION_JSONL_COUNT=$SessionCount"
Write-Log "SESSION_INDEX_LINES=$IndexLines"
Write-Log "Restore finished."

Write-Host ""
Write-Host "Restore finished."
Write-Host "Session jsonl files: $SessionCount"
Write-Host "Session index lines: $IndexLines"
Write-Host "Log: $Log"
Write-Host ""
Write-Host "Starting Codex..."
Start-Process 'explorer.exe' 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
Write-Host ""
Write-Host "If the project sidebar still says no conversations, the data is restored but this Codex build is not showing restored local catalog entries."
Write-Host "Use the log above to verify THREAD_COUNT and restored titles."
Write-Host ""
Read-Host "Press Enter to close this window"
