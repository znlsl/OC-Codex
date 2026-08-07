$ErrorActionPreference = 'Stop'

$codexHome = Join-Path $env:USERPROFILE '.codex'
$stateDb = Join-Path $codexHome 'state_5.sqlite'
$indexFile = Join-Path $codexHome 'session_index.jsonl'
$catalogDb = Join-Path $codexHome 'sqlite\codex-dev.db'
$pythonExe = 'C:\Users\Angus\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'

foreach ($path in @($stateDb, $indexFile, $catalogDb, $pythonExe)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing required path: $path"
    }
}

$backupDir = Join-Path $codexHome ("title-fix-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupDir | Out-Null
Copy-Item -LiteralPath $stateDb -Destination (Join-Path $backupDir 'state_5.sqlite') -Force
Copy-Item -LiteralPath $indexFile -Destination (Join-Path $backupDir 'session_index.jsonl') -Force
Copy-Item -LiteralPath $catalogDb -Destination (Join-Path $backupDir 'codex-dev.db') -Force

$pyPath = Join-Path $env:TEMP 'codex-fix-titles.py'
$py = @'
import json
import os
import sqlite3
from pathlib import Path

title_map = {
    "019f36be-9a96-71c0-836a-d390abc28f1d": "\u4fee\u590d\u5fae\u4fe1\u63d2\u4ef6\u9632\u64a4\u56de",
    "019f36bc-cb12-7191-8e9d-7c5686ee46f7": "WebPro \u9879\u76ee\u4ea4\u63a5\u603b\u7ed3",
    "019f358c-22be-7a73-a026-6c6b341aba0c": "\u9006\u5411 LSPilot \u83b7\u53d6 MCP",
    "019f3030-3db3-7ab1-ae60-b1568798140d": "\u8bfb\u53d6\u9006\u5411\u9879\u76ee",
    "019ea5a8-6168-7923-be89-49346bff6858": "\u4f18\u5316 TiB \u5355\u4f4d\u548c\u8fb9\u680f\u5e03\u5c40",
    "019ea2ea-9924-7ab0-873b-bc976e27bb19": "\u4e86\u89e3 SSH \u5de5\u5177\u9879\u76ee",
    "019ea727-fa5d-7392-8854-d7881a0d1d27": "\u4fee\u590d\u547d\u4ee4\u8bb0\u5f55",
    "019ea5b0-2308-70c3-9015-0cae7c5013c7": "TiB \u5e03\u5c40\u4f18\u5316\u5ba1\u6279\u8bb0\u5f55",
    "019ea2f2-a7aa-7852-8a9b-3eedc1ea5c29": "SSH \u9879\u76ee\u521d\u59cb\u5ba1\u67e5\u8bb0\u5f55",
}

state_db = Path(os.environ["CODEX_STATE_DB"])
catalog_db = Path(os.environ["CODEX_CATALOG_DB"])
index_file = Path(os.environ["CODEX_INDEX_FILE"])

def update_db(db_path, statements):
    conn = sqlite3.connect(str(db_path))
    try:
        cur = conn.cursor()
        for thread_id, new_title in title_map.items():
            for sql in statements:
                cur.execute(sql, (new_title, thread_id))
        conn.commit()
    finally:
        conn.close()

update_db(state_db, ["UPDATE threads SET title=? WHERE id=?"])

catalog_statements = []
conn = sqlite3.connect(str(catalog_db))
try:
    cur = conn.cursor()
    tables = {row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "local_thread_catalog" in tables:
        cols = {row[1] for row in cur.execute("PRAGMA table_info(local_thread_catalog)")}
        if "display_title" in cols:
            catalog_statements.append("UPDATE local_thread_catalog SET display_title=? WHERE thread_id=?")
        if "title" in cols:
            catalog_statements.append("UPDATE local_thread_catalog SET title=? WHERE thread_id=?")
finally:
    conn.close()

if catalog_statements:
    update_db(catalog_db, catalog_statements)

lines = []
with index_file.open("r", encoding="utf-8") as f:
    for raw in f:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        obj = json.loads(raw)
        if obj.get("id") in title_map:
            obj["thread_name"] = title_map[obj["id"]]
        lines.append(json.dumps(obj, ensure_ascii=False))

with index_file.open("w", encoding="utf-8", newline="\n") as f:
    for line in lines:
        f.write(line + "\n")

print("Updated titles:", len(title_map))
print("Backup:", os.environ["CODEX_BACKUP_DIR"])
'@

Set-Content -LiteralPath $pyPath -Value $py -Encoding UTF8

$env:CODEX_STATE_DB = $stateDb
$env:CODEX_CATALOG_DB = $catalogDb
$env:CODEX_INDEX_FILE = $indexFile
$env:CODEX_BACKUP_DIR = $backupDir

& $pythonExe $pyPath
