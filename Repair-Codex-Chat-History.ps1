param(
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$TargetProvider = '',
  [string]$LogPath = $null
)

$ErrorActionPreference = 'Stop'

function Write-Step {
  param([string]$Message)

  if ([string]::IsNullOrWhiteSpace($LogPath)) {
    Write-Host $Message
    return
  }

  $line = "$(Get-Date -Format o) $Message"
  $line | Tee-Object -FilePath $LogPath -Append
}

function Get-RepairPythonPath {
  $candidates = @(
    (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'),
    'C:\Users\Angus\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
  )

  $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
  if ($pythonCommand -and -not [string]::IsNullOrWhiteSpace($pythonCommand.Source)) {
    $candidates += $pythonCommand.Source
  }

  foreach ($candidate in $candidates | Select-Object -Unique) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  throw 'Python runtime not found for Codex chat repair.'
}

function Merge-DirectoryContents {
  param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$DestinationDir
  )

  $copiedFiles = 0
  if (-not (Test-Path -LiteralPath $SourceDir)) {
    return $copiedFiles
  }

  New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $SourceDir -Force) {
    $target = Join-Path $DestinationDir $item.Name
    if ($item.PSIsContainer) {
      $copiedFiles += Merge-DirectoryContents -SourceDir $item.FullName -DestinationDir $target
      continue
    }

    $parent = Split-Path -Parent $target
    if ($parent) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Copy-Item -LiteralPath $item.FullName -Destination $target -Force
    $copiedFiles++
  }

  return $copiedFiles
}

function Repair-NestedHistoryEntry {
  param(
    [Parameter(Mandatory = $true)][string]$CodexHomePath,
    [Parameter(Mandatory = $true)][string]$EntryName
  )

  $root = Join-Path $CodexHomePath $EntryName
  $copiedFiles = 0
  $removedTrees = 0

  if (-not (Test-Path -LiteralPath $root)) {
    return [PSCustomObject]@{
      EntryName = $EntryName
      CopiedFiles = 0
      RemovedTrees = 0
    }
  }

  while ($true) {
    $nested = Join-Path $root $EntryName
    if (-not (Test-Path -LiteralPath $nested)) {
      break
    }

    $copiedFiles += Merge-DirectoryContents -SourceDir $nested -DestinationDir $root
    Remove-Item -LiteralPath $nested -Recurse -Force
    $removedTrees++
  }

  return [PSCustomObject]@{
    EntryName = $EntryName
    CopiedFiles = $copiedFiles
    RemovedTrees = $removedTrees
  }
}

Write-Step "CHAT_REPAIR_START CodexHome=$CodexHome TargetProvider=$TargetProvider"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$switcherPath = Join-Path $repoRoot 'Source_Codes\tools\CodexUnifiedSwitcher.ps1'
if (Test-Path -LiteralPath $switcherPath) {
  . $switcherPath -NoUi
}

$treeRepairs = @(
  Repair-NestedHistoryEntry -CodexHomePath $CodexHome -EntryName 'sessions'
  Repair-NestedHistoryEntry -CodexHomePath $CodexHome -EntryName 'archived_sessions'
)

foreach ($repair in $treeRepairs) {
  Write-Step "TREE_REPAIR entry=$($repair.EntryName) copied_files=$($repair.CopiedFiles) removed_nested_trees=$($repair.RemovedTrees)"
}

$rewrittenRollouts = 0
$rolloutRewriteFailures = 0
if ((Get-Command Get-RolloutProviderChanges -ErrorAction SilentlyContinue) -and
    (Get-Command Rewrite-FirstLine -ErrorAction SilentlyContinue)) {
  foreach ($change in @(Get-RolloutProviderChanges -CodexHome $CodexHome -TargetProvider $TargetProvider)) {
    try {
      Rewrite-FirstLine -Path $change.Path -Record $change.Record -NextFirstLine $change.UpdatedFirstLine
      $rewrittenRollouts++
    } catch {
      $rolloutRewriteFailures++
      Write-Step "ROLLOUT_REWRITE_FAILED path=$($change.Path) error=$($_.Exception.Message)"
    }
  }
}
Write-Step "ROLLOUT_REWRITE rewritten=$rewrittenRollouts failed=$rolloutRewriteFailures"

$env:PYTHONIOENCODING = 'utf-8'
$python = Get-RepairPythonPath
@'
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sqlite3
import sys
from pathlib import Path

codex_home = Path(sys.argv[1])
requested_provider = (sys.argv[2] or "").strip()

state_db = codex_home / "state_5.sqlite"
catalog_db = codex_home / "sqlite" / "codex-dev.db"
index_path = codex_home / "session_index.jsonl"


def normalize_windows_path(value: str | None) -> str | None:
    if not value:
        return value

    normalized = value
    if normalized.startswith("\\\\?\\"):
        normalized = normalized[4:]

    for entry in ("sessions", "archived_sessions"):
        needle = f"\\{entry}\\{entry}\\"
        while needle in normalized:
            normalized = normalized.replace(needle, f"\\{entry}\\")

    return normalized


def detect_target_provider(explicit: str) -> str | None:
    if explicit and explicit.lower() not in {"auto", "missing", "preserve"}:
        return explicit

    config_path = codex_home / "config.toml"
    if not config_path.exists():
        return None

    try:
        for raw in config_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("["):
                break
            match = re.match(r'^model_provider\s*=\s*"([^"]+)"\s*$', line)
            if match:
                return match.group(1)
    except Exception:
        return None

    return None


def iso_from_seconds(value: object) -> str:
    try:
        seconds = float(value)
    except Exception:
        seconds = 0.0
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def to_unix_seconds(value: object, fallback: float) -> int:
    if value not in (None, ""):
        text = str(value).strip()
        if text:
            try:
                return int(dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp())
            except Exception:
                pass
    return int(fallback)


def to_unix_milliseconds(value: object, fallback: float) -> int:
    if value not in (None, ""):
        text = str(value).strip()
        if text:
            try:
                return int(dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp() * 1000)
            except Exception:
                pass
    return int(fallback * 1000)


def get_path_leaf(value: str | None, fallback: str) -> str:
    if value:
        normalized = normalize_windows_path(value).rstrip("\\/")
        if normalized:
            parts = re.split(r"[\\/]+", normalized)
            if parts:
                leaf = parts[-1].strip()
                if leaf:
                    return leaf
    return fallback


def get_mojibake_marker_count(text: str) -> int:
    return len(re.findall(r"\u20ac|\ufffd|[\uE000-\uF8FF]", text))


def repair_mojibake(text: str | None) -> str | None:
    if not text:
        return text

    has_strong_marker = ("\ufffd" in text) or ("\u20ac" in text) or bool(re.search(r"[\uE000-\uF8FF]", text))
    if not has_strong_marker and get_mojibake_marker_count(text) < 2:
        return text

    try:
        candidate = text.encode("gbk").decode("utf-8")
    except Exception:
        return text

    if not candidate.strip():
        return text
    if "\ufffd" in candidate or re.search(r"[\uE000-\uF8FF]", candidate):
        return text
    if re.search(r"[\x00-\x08\x0B\x0C\x0E-\x1F]", candidate):
        return text
    return candidate


def title_needs_repair(text: str | None) -> bool:
    value = (text or "").strip()
    if not value:
        return True
    if len(value) > 120:
        return True
    if "\n" in value or "\r" in value:
        return True
    if re.fullmatch(r"\?{3,}", value):
        return True
    if re.match(r"^[\"']?(?:\\\\\?\\)?[A-Za-z]:\\", value):
        return True
    if value.startswith("The following is the Codex agent history"):
        return True
    if ">>> TRANSCRIPT START" in value:
        return True
    if value.startswith("+ Thought:"):
        return True
    if "<image" in value.lower():
        return True
    return False


def strip_skill_links(text: str) -> str:
    return re.sub(r'^(?:\[\$[^\]]+\]\([^)]+\)\s*)+', "", text).strip()


def strip_path_prefix(text: str) -> str:
    value = text
    quoted_patterns = [
        r'^\s*"(?:(?:\\\\\?\\)?[A-Za-z]:\\[^"\n]+)"\s*(?:,|:|\uFF0C|\uFF1A)?\s*',
        r"^\s*'(?:(?:\\\\\?\\)?[A-Za-z]:\\[^'\n]+)'\s*(?:,|:|\uFF0C|\uFF1A)?\s*",
    ]
    bare_patterns = [
        r'^\s*(?:\\\\\?\\)?[A-Za-z]:\\\S+\s*(?:,|:|\uFF0C|\uFF1A)?\s*',
    ]
    for pattern in quoted_patterns + bare_patterns:
        value = re.sub(pattern, "", value)
    return value.strip()


def trim_title_length(text: str, max_len: int = 48) -> str:
    value = text.strip()
    if len(value) <= max_len:
        return value

    short = value[:max_len]
    match = re.search(r"[。！？!?；;，,:：]", short[8:])
    if match:
        cut = 8 + match.start()
        if cut > 8:
            return short[:cut].strip()
    return short.rstrip() + "..."


def trim_title_length_safe(text: str, max_len: int = 48) -> str:
    value = text.strip()
    if len(value) <= max_len:
        return value

    short = value[:max_len]
    match = re.search(r"[.!?,;:\u3002\uFF01\uFF1F\uFF0C\uFF1B\uFF1A]", short[8:])
    if match:
        cut = 8 + match.start()
        if cut > 8:
            return short[:cut].strip()
    return short.rstrip() + "..."


def clean_title_text(text: str | None) -> str | None:
    if not text:
        return None

    value = repair_mojibake(str(text)) or ""
    value = value.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not value:
        return None

    if ">>> TRANSCRIPT START" in value:
        blocks = re.findall(r"\[\d+\]\s+user:\s*(.*?)(?=\n\[\d+\]\s+\w+:|\n>>> TRANSCRIPT END|\Z)", value, flags=re.S)
        for block in blocks:
            candidate = clean_title_text(block)
            if candidate and not title_needs_repair(candidate):
                return candidate
        return None

    marker = "## My request for Codex:"
    marker_index = value.lower().find(marker.lower())
    if marker_index >= 0:
        value = value[marker_index + len(marker):].strip()

    value = re.sub(r"<image[\s\S]*$", "", value, flags=re.I).strip()
    if not value:
        return None

    chosen_line = None
    for raw_line in value.split("\n"):
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("+ Thought:"):
            continue
        if line.startswith("The following is the Codex agent history"):
            continue
        if line.startswith(">>> TRANSCRIPT"):
            continue
        if line.startswith("# Files mentioned by the user"):
            continue
        if line.startswith("## "):
            continue
        if line.lower().startswith("<image"):
            continue

        line = strip_skill_links(line)
        line = strip_path_prefix(line)
        line = line.strip(" \"'`，,:：;；-")
        line = re.sub(r"\s+", " ", line).strip()
        if not line:
            continue
        chosen_line = line
        break

    if not chosen_line:
        return None

    return trim_title_length_safe(chosen_line)


def choose_best_title(current: str | None, candidate: str | None) -> str | None:
    if not candidate:
        return current
    if not current:
        return candidate

    current_bad = title_needs_repair(current)
    candidate_bad = title_needs_repair(candidate)
    if current_bad and not candidate_bad:
        return candidate
    if not current_bad and candidate_bad:
        return current
    if current_bad and candidate_bad:
        return candidate if len(candidate) < len(current) else current
    return current


def choose_display_title(
    existing_title: str | None,
    session_index_title: str | None,
    rollout_title: str | None,
    cwd: str | None,
    thread_id: str,
) -> str:
    candidates = [
        clean_title_text(session_index_title),
        clean_title_text(existing_title),
        clean_title_text(rollout_title),
    ]

    for candidate in candidates:
        if candidate and not title_needs_repair(candidate):
            return candidate

    for candidate in candidates:
        if candidate:
            return candidate

    return get_path_leaf(cwd, thread_id)


def extract_first_user_text(path: Path) -> str | None:
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as handle:
            for raw in handle:
                line = raw.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except Exception:
                    continue

                payload = record.get("payload") or {}
                text_parts: list[str] = []

                if record.get("type") == "response_item" and payload.get("role") == "user":
                    for item in payload.get("content") or []:
                        if item.get("type") == "input_text" and item.get("text"):
                            text_parts.append(str(item.get("text")))
                elif record.get("type") == "event_msg" and payload.get("type") == "user_message":
                    message = payload.get("message")
                    if isinstance(message, str):
                        text_parts.append(message)

                if not text_parts:
                    continue

                cleaned = clean_title_text("\n".join(text_parts).strip())
                if cleaned:
                    return cleaned
    except Exception:
        return None

    return None


def load_rollout_entries() -> dict[str, dict[str, object]]:
    entries: dict[str, dict[str, object]] = {}
    for dir_name in ("sessions", "archived_sessions"):
        root = codex_home / dir_name
        if not root.exists():
            continue

        for rollout in root.rglob("rollout-*.jsonl"):
            try:
                with rollout.open("r", encoding="utf-8", errors="ignore") as handle:
                    first_line = handle.readline().strip()
                first_record = json.loads(first_line) if first_line else None
            except Exception:
                continue

            if not isinstance(first_record, dict):
                continue
            if first_record.get("type") != "session_meta":
                continue
            payload = first_record.get("payload") or {}
            thread_id = str(payload.get("id") or "").strip()
            if not thread_id:
                continue

            first_user_text = extract_first_user_text(rollout)
            cwd = normalize_windows_path(str(payload.get("cwd") or "")) or ""
            fallback_title = get_path_leaf(cwd, thread_id)
            title = choose_display_title(None, None, first_user_text, cwd, thread_id)
            timestamp_text = str(payload.get("timestamp") or first_record.get("timestamp") or "").strip()
            if timestamp_text:
                try:
                    created_dt = dt.datetime.fromisoformat(timestamp_text.replace("Z", "+00:00"))
                except Exception:
                    created_dt = dt.datetime.fromtimestamp(rollout.stat().st_mtime, dt.timezone.utc)
            else:
                created_dt = dt.datetime.fromtimestamp(rollout.stat().st_mtime, dt.timezone.utc)

            updated_dt = dt.datetime.fromtimestamp(rollout.stat().st_mtime, dt.timezone.utc)

            candidate = {
                "id": thread_id,
                "cwd": cwd,
                "rollout_path": normalize_windows_path(str(rollout)),
                "source": str(payload.get("source") or "vscode"),
                "model_provider": str(payload.get("model_provider") or ""),
                "title": title or fallback_title,
                "first_user_message": first_user_text or "",
                "preview": first_user_text or "",
                "created_at": int(created_dt.timestamp()),
                "updated_at": int(updated_dt.timestamp()),
                "created_at_ms": int(created_dt.timestamp() * 1000),
                "updated_at_ms": int(updated_dt.timestamp() * 1000),
                "cli_version": str(payload.get("cli_version") or ""),
                "thread_source": payload.get("thread_source"),
                "git_branch": payload.get("git_branch"),
                "updated_at_iso": updated_dt.isoformat(timespec="microseconds").replace("+00:00", "Z"),
            }

            current = entries.get(thread_id)
            if not current or current["updated_at"] < candidate["updated_at"]:
                entries[thread_id] = candidate

    return entries


def load_existing_session_index():
    rows: list[dict[str, object]] = []
    preferred_titles: dict[str, str] = {}
    if not index_path.exists():
        return rows, preferred_titles

    with index_path.open("r", encoding="utf-8", errors="ignore") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            thread_id = str(row.get("id") or "").strip()
            if not thread_id:
                continue
            rows.append(row)
            cleaned = clean_title_text(str(row.get("thread_name") or ""))
            if cleaned:
                preferred_titles[thread_id] = choose_best_title(preferred_titles.get(thread_id), cleaned) or cleaned

    return rows, preferred_titles


def ensure_catalog_schema(connection: sqlite3.Connection) -> None:
    cur = connection.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS local_thread_catalog(
            host_id TEXT NOT NULL,
            thread_id TEXT NOT NULL,
            display_title TEXT,
            source_created_at REAL,
            source_updated_at REAL,
            cwd TEXT,
            source_kind TEXT,
            source_detail TEXT,
            model_provider TEXT,
            git_branch TEXT,
            observation_sequence INTEGER,
            missing_candidate INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(host_id, thread_id)
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS local_thread_catalog_hosts(
            host_id TEXT PRIMARY KEY,
            host_kind TEXT
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS local_thread_catalog_metadata(
            id INTEGER PRIMARY KEY,
            catalog_revision INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS local_thread_catalog_sync_state(
            host_id TEXT PRIMARY KEY,
            watermark_updated_at REAL,
            initial_build_complete INTEGER NOT NULL DEFAULT 0,
            observation_sequence INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    connection.commit()


def open_catalog_connection(path: Path) -> sqlite3.Connection:
    try:
        connection = sqlite3.connect(path)
        ensure_catalog_schema(connection)
        return connection
    except Exception:
        try:
            connection.close()
        except Exception:
            pass
        if path.exists():
            path.unlink()
        connection = sqlite3.connect(path)
        ensure_catalog_schema(connection)
        return connection


target_provider = detect_target_provider(requested_provider)
rollout_entries = load_rollout_entries()
existing_index_rows, preferred_index_titles = load_existing_session_index()

if not state_db.exists():
    index_lines = []
    for thread_id, rollout in sorted(rollout_entries.items(), key=lambda item: (-int(item[1]["updated_at"]), item[0])):
        title = choose_display_title(None, preferred_index_titles.get(thread_id), str(rollout.get("title") or ""), str(rollout.get("cwd") or ""), thread_id)
        index_lines.append(
            json.dumps(
                {
                    "id": thread_id,
                    "thread_name": title,
                    "updated_at": str(rollout["updated_at_iso"]),
                },
                ensure_ascii=False,
            )
        )
    index_path.write_text("\n".join(index_lines) + ("\n" if index_lines else ""), encoding="utf-8")
    print(f"STATE_DB_MISSING {state_db}")
    print(f"SESSION_INDEX_REWRITTEN rows={len(index_lines)}")
    raise SystemExit(0)

try:
    state = sqlite3.connect(state_db)
except Exception as exc:
    print(f"STATE_DB_OPEN_FAILED {state_db} error={exc!r}")
    raise SystemExit(0)

state.row_factory = sqlite3.Row
cur = state.cursor()

try:
    cur.execute("PRAGMA table_info(threads)")
except Exception as exc:
    print(f"THREAD_SCHEMA_READ_FAILED error={exc!r}")
    state.close()
    raise SystemExit(0)

thread_columns = {row["name"] for row in cur.fetchall()}
if "id" not in thread_columns:
    print("THREAD_SCHEMA_INVALID missing=id")
    state.close()
    raise SystemExit(0)

existing_ids = {str(row["id"]) for row in cur.execute("SELECT id FROM threads")}
backfilled_rows = 0

for thread_id, rollout in rollout_entries.items():
    if thread_id in existing_ids:
        continue

    values_by_column = {
        "id": thread_id,
        "rollout_path": str(rollout.get("rollout_path") or ""),
        "created_at": int(rollout.get("created_at") or 0),
        "updated_at": int(rollout.get("updated_at") or 0),
        "source": str(rollout.get("source") or "vscode"),
        "model_provider": target_provider or str(rollout.get("model_provider") or "openai"),
        "cwd": str(rollout.get("cwd") or ""),
        "title": choose_display_title(None, preferred_index_titles.get(thread_id), str(rollout.get("title") or ""), str(rollout.get("cwd") or ""), thread_id),
        "sandbox_policy": "danger-full-access",
        "approval_mode": "never",
        "tokens_used": 0,
        "has_user_event": 1 if str(rollout.get("first_user_message") or "").strip() else 0,
        "archived": 0,
        "cli_version": str(rollout.get("cli_version") or ""),
        "first_user_message": str(rollout.get("first_user_message") or ""),
        "memory_mode": "enabled",
        "created_at_ms": int(rollout.get("created_at_ms") or 0),
        "updated_at_ms": int(rollout.get("updated_at_ms") or 0),
        "thread_source": rollout.get("thread_source"),
        "preview": str(rollout.get("preview") or ""),
        "git_branch": rollout.get("git_branch"),
    }

    insert_columns = [name for name in values_by_column if name in thread_columns]
    placeholders = ", ".join(["?"] * len(insert_columns))
    sql = "INSERT OR IGNORE INTO threads ({}) VALUES ({})".format(", ".join(insert_columns), placeholders)
    cur.execute(sql, tuple(values_by_column[name] for name in insert_columns))
    if cur.rowcount:
        backfilled_rows += 1
        existing_ids.add(thread_id)

state.commit()

select_columns = [
    "id",
    "title" if "title" in thread_columns else "'' as title",
    "created_at" if "created_at" in thread_columns else "0 as created_at",
    "updated_at" if "updated_at" in thread_columns else "0 as updated_at",
    "source" if "source" in thread_columns else "'vscode' as source",
    "cwd" if "cwd" in thread_columns else "'' as cwd",
    "rollout_path" if "rollout_path" in thread_columns else "'' as rollout_path",
    "git_branch" if "git_branch" in thread_columns else "NULL as git_branch",
    "archived" if "archived" in thread_columns else "0 as archived",
    "model_provider" if "model_provider" in thread_columns else "'' as model_provider",
    "first_user_message" if "first_user_message" in thread_columns else "'' as first_user_message",
]

cur.execute(f"SELECT {', '.join(select_columns)} FROM threads ORDER BY updated_at DESC, id DESC")
rows = cur.fetchall()

updated_threads = 0
catalog_rows = []
state_rows_by_id: dict[str, dict[str, object]] = {}

for row in rows:
    thread_id = str(row["id"])
    rollout = rollout_entries.get(thread_id, {})

    old_title = str(row["title"] or "")
    old_first_user = str(row["first_user_message"] or "")
    old_cwd = str(row["cwd"] or "")
    old_rollout_path = str(row["rollout_path"] or "")
    old_provider = str(row["model_provider"] or "")

    new_cwd = normalize_windows_path(old_cwd) or ""
    new_rollout_path = normalize_windows_path(old_rollout_path) or ""
    chosen_title = choose_display_title(
        old_title,
        preferred_index_titles.get(thread_id),
        str(rollout.get("title") or old_first_user or ""),
        new_cwd,
        thread_id,
    )
    new_provider = target_provider or old_provider or str(rollout.get("model_provider") or "")

    assignments: list[str] = []
    values: list[object] = []

    if "model_provider" in thread_columns and new_provider and old_provider != new_provider:
        assignments.append("model_provider = ?")
        values.append(new_provider)
    if "cwd" in thread_columns and old_cwd != new_cwd:
        assignments.append("cwd = ?")
        values.append(new_cwd)
    if "rollout_path" in thread_columns and old_rollout_path != new_rollout_path:
        assignments.append("rollout_path = ?")
        values.append(new_rollout_path)
    if "title" in thread_columns and chosen_title and (title_needs_repair(old_title) or not old_title.strip()):
        if old_title != chosen_title:
            assignments.append("title = ?")
            values.append(chosen_title)

    if assignments:
        values.append(thread_id)
        cur.execute(f"UPDATE threads SET {', '.join(assignments)} WHERE id = ?", tuple(values))
        if cur.rowcount:
            updated_threads += 1

    created_at = float(row["created_at"] or 0)
    updated_at = float(row["updated_at"] or 0)
    source_kind = str(row["source"] or "vscode")
    git_branch = row["git_branch"]
    archived = int(row["archived"] or 0)

    state_rows_by_id[thread_id] = {
        "id": thread_id,
        "title": chosen_title or thread_id,
        "created_at": created_at,
        "updated_at": updated_at,
        "cwd": new_cwd,
        "source": source_kind,
        "provider": new_provider or old_provider or str(rollout.get("model_provider") or ""),
        "git_branch": git_branch,
        "archived": archived,
        "updated_at_iso": iso_from_seconds(updated_at),
    }

    if archived == 0:
        catalog_rows.append(
            (
                "local",
                thread_id,
                chosen_title or thread_id,
                created_at,
                updated_at,
                new_cwd,
                source_kind,
                None,
                new_provider or old_provider or str(rollout.get("model_provider") or ""),
                git_branch,
            )
        )

state.commit()
state.close()

index_lines = []
seen_ids: set[str] = set()

for existing in existing_index_rows:
    thread_id = str(existing.get("id") or "").strip()
    if not thread_id:
        continue

    row = state_rows_by_id.get(thread_id, {})
    rollout = rollout_entries.get(thread_id, {})
    title = choose_display_title(
        str(existing.get("thread_name") or ""),
        preferred_index_titles.get(thread_id),
        str(rollout.get("title") or row.get("title") or ""),
        str(row.get("cwd") or rollout.get("cwd") or ""),
        thread_id,
    )

    updated_at_candidates = [
        str(existing.get("updated_at") or "").strip(),
        str(row.get("updated_at_iso") or "").strip(),
        str(rollout.get("updated_at_iso") or "").strip(),
    ]
    best_updated_at = None
    best_dt = None
    for candidate in updated_at_candidates:
        if not candidate:
            continue
        try:
            parsed = dt.datetime.fromisoformat(candidate.replace("Z", "+00:00"))
        except Exception:
            if not best_updated_at:
                best_updated_at = candidate
            continue
        if best_dt is None or parsed > best_dt:
            best_dt = parsed
            best_updated_at = parsed.isoformat(timespec="microseconds").replace("+00:00", "Z")

    if not best_updated_at:
        best_updated_at = iso_from_seconds(row.get("updated_at") or rollout.get("updated_at") or 0)

    index_lines.append(
        json.dumps(
            {
                "id": thread_id,
                "thread_name": title,
                "updated_at": best_updated_at,
            },
            ensure_ascii=False,
        )
    )
    seen_ids.add(thread_id)

for thread_id, row in sorted(state_rows_by_id.items(), key=lambda item: (-float(item[1]["updated_at"]), item[0])):
    if thread_id in seen_ids:
        continue
    if int(row.get("archived") or 0) != 0:
        continue
    index_lines.append(
        json.dumps(
            {
                "id": thread_id,
                "thread_name": str(row.get("title") or thread_id),
                "updated_at": str(row.get("updated_at_iso") or iso_from_seconds(row.get("updated_at") or 0)),
            },
            ensure_ascii=False,
        )
    )
    seen_ids.add(thread_id)

index_path.write_text("\n".join(index_lines) + ("\n" if index_lines else ""), encoding="utf-8")

catalog_db.parent.mkdir(parents=True, exist_ok=True)
catalog = open_catalog_connection(catalog_db)
cur = catalog.cursor()
cur.execute("DELETE FROM local_thread_catalog WHERE host_id = ?", ("local",))

observation_sequence = int(dt.datetime.now(dt.timezone.utc).timestamp())
cur.executemany(
    """
    INSERT OR REPLACE INTO local_thread_catalog(
        host_id,
        thread_id,
        display_title,
        source_created_at,
        source_updated_at,
        cwd,
        source_kind,
        source_detail,
        model_provider,
        git_branch,
        observation_sequence,
        missing_candidate
    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
    """,
    [
        (
            host_id,
            thread_id,
            title,
            created_at,
            updated_at,
            cwd,
            source_kind,
            source_detail,
            provider,
            git_branch,
            observation_sequence,
        )
        for host_id, thread_id, title, created_at, updated_at, cwd, source_kind, source_detail, provider, git_branch in catalog_rows
    ],
)

cur.execute(
    "INSERT OR REPLACE INTO local_thread_catalog_hosts(host_id, host_kind) VALUES(?, ?)",
    ("local", "local"),
)

cur.execute("SELECT COUNT(*) FROM local_thread_catalog_metadata WHERE id = 1")
if cur.fetchone()[0]:
    cur.execute(
        "UPDATE local_thread_catalog_metadata SET catalog_revision = catalog_revision + 1 WHERE id = 1"
    )
else:
    cur.execute(
        "INSERT INTO local_thread_catalog_metadata(id, catalog_revision) VALUES(1, 1)"
    )

watermark = max((row[4] for row in catalog_rows), default=None)
cur.execute("SELECT COUNT(*) FROM local_thread_catalog_sync_state WHERE host_id = 'local'")
if cur.fetchone()[0]:
    cur.execute(
        """
        UPDATE local_thread_catalog_sync_state
        SET watermark_updated_at = ?, initial_build_complete = 1, observation_sequence = ?
        WHERE host_id = 'local'
        """,
        (watermark, observation_sequence),
    )
else:
    cur.execute(
        """
        INSERT INTO local_thread_catalog_sync_state(
            host_id,
            watermark_updated_at,
            initial_build_complete,
            observation_sequence
        ) VALUES('local', ?, 1, ?)
        """,
        (watermark, observation_sequence),
    )

catalog.commit()
catalog.close()
print(f"CATALOG_REBUILT rows={len(catalog_rows)} observation_sequence={observation_sequence}")

print(f"TARGET_PROVIDER {target_provider or '(preserved)'}")
print(f"SQLITE_BACKFILLED {backfilled_rows}")
print(f"THREADS_UPDATED {updated_threads}")
print(f"SESSION_INDEX_REWRITTEN rows={len(index_lines)}")
'@ | & $python - $CodexHome $TargetProvider 2>&1 | ForEach-Object {
  Write-Step ([string]$_)
}

Write-Step 'CHAT_REPAIR_DONE'
