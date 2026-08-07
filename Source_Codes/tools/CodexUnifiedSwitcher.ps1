param(
    [switch]$NoUi
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function U($text) {
    return [System.Text.RegularExpressions.Regex]::Unescape($text)
}

function Get-DefaultSettingsPath {
    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = Join-Path $env:USERPROFILE "AppData\Roaming"
    }
    return (Join-Path (Join-Path $appData "C-O") "settings.json")
}

function Get-AppRootFromBackupRoot($BackupRoot) {
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = $Script:DefaultBackupRoot
    }
    return (Join-Path $BackupRoot "codex-switch")
}

function Get-HistoryBackupRootFromBackupRoot($BackupRoot) {
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = $Script:DefaultBackupRoot
    }
    return (Join-Path $BackupRoot "history-sync")
}

function Get-ChatHistoryBackupRootFromBackupRoot($BackupRoot) {
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = $Script:DefaultBackupRoot
    }
    return (Join-Path $BackupRoot "chat-history")
}

$Script:DefaultCodexHome = Join-Path $env:USERPROFILE ".codex"
$Script:DefaultBackupRoot = "D:\codex-back"
$Script:DefaultAppRoot = Join-Path $Script:DefaultBackupRoot "codex-switch"
$Script:DefaultHistoryBackupRoot = Join-Path $Script:DefaultBackupRoot "history-sync"
$Script:DefaultChatHistoryBackupRoot = Join-Path $Script:DefaultBackupRoot "chat-history"
$Script:DefaultSettingsPath = Get-DefaultSettingsPath
$Script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Script:Title = U "\u004f\u002d\u0043 \u0043\u006f\u0064\u0065\u0078 \u5de5\u5177\u7bb1"
$Script:UiVersion = "NativeBackupUiV1"

function Get-DefaultOfficialConfigPath {
    return "D:\" + [char]0x4f18 + [char]0x5316 + "\Team" + [char]0x6e90 + [char]0x6587 + [char]0x4ef6 + "\config.toml"
}

function Get-DefaultCPAMCConfigPath {
    return "D:\" + [char]0x4f18 + [char]0x5316 + "\" + [char]0x914d + [char]0x7f6e + [char]0x6587 + [char]0x4ef6 + "\NewAPI\newapi-config.toml"
}

function Ensure-SwitcherDirs($AppRoot = $Script:DefaultAppRoot) {
    foreach ($path in @(
        $AppRoot,
        (Join-Path $AppRoot "profiles"),
        (Join-Path $AppRoot "profiles\official"),
        (Join-Path $AppRoot "profiles\cpamc"),
        (Join-Path $AppRoot "backups")
    )) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Load-SwitcherSettings($SettingsPath = $Script:DefaultSettingsPath) {
    $settings = [ordered]@{
        officialConfigPath = Get-DefaultOfficialConfigPath
        cpamcConfigPath = Get-DefaultCPAMCConfigPath
        codexHome = $Script:DefaultCodexHome
        backupRoot = $Script:DefaultBackupRoot
        chatBackupDirectory = $Script:DefaultChatHistoryBackupRoot
        chatRestoreBackupPath = ""
        chatRestoreTargetPath = $Script:DefaultCodexHome
    }

    $sourcePath = $SettingsPath
    $legacyPath = Join-Path $Script:DefaultAppRoot "unified-settings.json"
    if (-not (Test-Path -LiteralPath $sourcePath) -and (Test-Path -LiteralPath $legacyPath)) {
        $sourcePath = $legacyPath
    }

    if (Test-Path -LiteralPath $sourcePath) {
        try {
            $loaded = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
            foreach ($name in @("officialConfigPath", "cpamcConfigPath", "codexHome", "backupRoot", "chatBackupDirectory", "chatRestoreBackupPath", "chatRestoreTargetPath")) {
                if ($loaded.$name) {
                    $settings[$name] = [string]$loaded.$name
                }
            }
        } catch {}
    }

    if ([string]::IsNullOrWhiteSpace($settings["chatBackupDirectory"])) {
        $settings["chatBackupDirectory"] = Get-ChatHistoryBackupRootFromBackupRoot $settings["backupRoot"]
    }
    if ([string]::IsNullOrWhiteSpace($settings["chatRestoreTargetPath"])) {
        $settings["chatRestoreTargetPath"] = $settings["codexHome"]
    }

    return [PSCustomObject]$settings
}

function Save-SwitcherSettings($Settings, $SettingsPath = $Script:DefaultSettingsPath) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $SettingsPath) -Force | Out-Null
    $Settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
}

function Get-CodexProvider($CodexHome = $Script:DefaultCodexHome) {
    $configPath = Join-Path $CodexHome "config.toml"
    return Get-CodexProviderFromConfigPath $configPath
}

function Get-CodexProviderFromConfigPath($ConfigPath) {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { return "missing" }
    $configPath = $ConfigPath
    if (-not (Test-Path -LiteralPath $configPath)) { return "missing" }

    foreach ($line in Get-Content -LiteralPath $configPath -ErrorAction Stop) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed.StartsWith("[")) {
            break
        }
        $match = [regex]::Match($trimmed, '^model_provider\s*=\s*"([^"]+)"\s*$')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }

    return "openai"
}

function Get-CodexAuthMode($CodexHome = $Script:DefaultCodexHome) {
    $authPath = Join-Path $CodexHome "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) { return "missing" }
    try {
        $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
        if ($auth.auth_mode) { return [string]$auth.auth_mode }
    } catch {}
    return "unknown"
}

function Backup-ActiveAuthConfig(
    $CodexHome = $Script:DefaultCodexHome,
    $AppRoot = $Script:DefaultAppRoot
) {
    Ensure-SwitcherDirs $AppRoot
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = Join-Path (Join-Path $AppRoot "backups") "auth-config-$stamp"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null

    foreach ($name in @("auth.json", "config.toml")) {
        $path = Join-Path $CodexHome $name
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $backup $name) -Force
        }
    }

    return $backup
}

function Save-ModeProfile(
    [ValidateSet("official", "cpamc")] $ProfileName,
    $CodexHome = $Script:DefaultCodexHome,
    $AppRoot = $Script:DefaultAppRoot
) {
    Ensure-SwitcherDirs $AppRoot
    $profilePath = Join-Path (Join-Path $AppRoot "profiles") $ProfileName
    New-Item -ItemType Directory -Path $profilePath -Force | Out-Null

    foreach ($name in @("auth.json", "config.toml")) {
        $source = Join-Path $CodexHome $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $profilePath $name) -Force
        }
    }

    return $profilePath
}

function Save-CurrentModeProfile(
    $CodexHome = $Script:DefaultCodexHome,
    $AppRoot = $Script:DefaultAppRoot
) {
    $provider = Get-CodexProvider $CodexHome
    if ($provider -eq "openai" -or $provider -eq "missing") {
        return Save-ModeProfile -ProfileName "official" -CodexHome $CodexHome -AppRoot $AppRoot
    }
    if ($provider -eq "CPA" -or $provider -eq "CPAMC") {
        return Save-ModeProfile -ProfileName "cpamc" -CodexHome $CodexHome -AppRoot $AppRoot
    }
    if ($provider -ne "openai" -and $provider -ne "missing") {
        return Save-ModeProfile -ProfileName "cpamc" -CodexHome $CodexHome -AppRoot $AppRoot
    }
    return $null
}

function Close-CodexIfRunning {
    $processes = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -ieq "codex" -or
            $_.ProcessName -ieq "Codex" -or
            $_.ProcessName -ieq "Codex (Beta)"
        }

    if (-not $processes) { return }

    $message = U "\u68c0\u6d4b\u5230 Codex \u6b63\u5728\u8fd0\u884c\u3002\u5207\u6362\u524d\u9700\u8981\u5148\u5173\u95ed\uff0c\u662f\u5426\u73b0\u5728\u5173\u95ed\uff1f"
    $result = [System.Windows.Forms.MessageBox]::Show($message, $Script:Title, "YesNo", "Question")
    if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
        throw (U "\u5df2\u53d6\u6d88\uff1aCodex \u4ecd\u5728\u8fd0\u884c\u3002")
    }

    $processes | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Test-ExclusiveWriteAccess($Path, [switch]$AllowCreate) {
    try {
        $parent = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            return [PSCustomObject]@{
                Ok = $false
                Reason = "Parent directory missing: $parent"
            }
        }

        $mode = [System.IO.FileMode]::Open
        if ($AllowCreate) {
            $mode = [System.IO.FileMode]::OpenOrCreate
        } elseif (-not (Test-Path -LiteralPath $Path)) {
            return [PSCustomObject]@{
                Ok = $false
                Reason = "File missing: $Path"
            }
        }

        $stream = [System.IO.File]::Open($Path, $mode, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            return [PSCustomObject]@{
                Ok = $true
                Reason = $null
            }
        } finally {
            $stream.Dispose()
        }
    } catch {
        return [PSCustomObject]@{
            Ok = $false
            Reason = Get-SyncExceptionSummary $_.Exception
        }
    }
}

function Test-SqliteWriteAccess($CodexHome) {
    $dbPath = Join-Path $CodexHome "state_5.sqlite"
    if (-not (Test-Path -LiteralPath $dbPath)) {
        return [PSCustomObject]@{
            Ok = $false
            Reason = "Missing SQLite state file: $dbPath"
        }
    }

    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite) {
        return [PSCustomObject]@{
            Ok = $false
            Reason = "sqlite3.exe not found"
        }
    }

    try {
        $output = & $sqlite.Source $dbPath "PRAGMA busy_timeout=1000; BEGIN IMMEDIATE; ROLLBACK;" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Out-String).Trim())
        }
        return [PSCustomObject]@{
            Ok = $true
            Reason = $null
        }
    } catch {
        return [PSCustomObject]@{
            Ok = $false
            Reason = Get-SyncExceptionSummary $_.Exception
        }
    }
}

function Assert-HistorySyncWritable($CodexHome, $TargetProvider) {
    $issues = New-Object System.Collections.Generic.List[string]

    $rolloutChanges = @(Get-RolloutProviderChanges -CodexHome $CodexHome -TargetProvider $TargetProvider)
    foreach ($change in $rolloutChanges | Select-Object -First 5) {
        $rolloutAccess = Test-ExclusiveWriteAccess -Path $change.Path
        if (-not $rolloutAccess.Ok) {
            $issues.Add("rollout locked: $($change.Path) ($($rolloutAccess.Reason))") | Out-Null
            break
        }
    }

    $sessionIndexPath = Join-Path $CodexHome "session_index.jsonl"
    $sessionIndexAccess = Test-ExclusiveWriteAccess -Path $sessionIndexPath -AllowCreate
    if (-not $sessionIndexAccess.Ok) {
        $issues.Add("session_index unavailable: $($sessionIndexAccess.Reason)") | Out-Null
    }

    $sqliteAccess = Test-SqliteWriteAccess -CodexHome $CodexHome
    if (-not $sqliteAccess.Ok) {
        $issues.Add("SQLite unavailable: $($sqliteAccess.Reason)") | Out-Null
    }

    if ($issues.Count -gt 0) {
        throw ((U "\u5207\u6362\u524d\u68c0\u67e5\u5931\u8d25\uff1a") + " " + ($issues.ToArray() -join "; "))
    }
}

function Read-FirstLineRecord($Path) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $memory = New-Object System.IO.MemoryStream
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        } finally {
            $memory.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    $lfIndex = [Array]::IndexOf($bytes, [byte]10)
    if ($lfIndex -lt 0) {
        $lineLength = $bytes.Length
        $separator = ""
        $restOffset = $bytes.Length
    } else {
        $lineLength = $lfIndex
        $separator = "`n"
        if ($lineLength -gt 0 -and $bytes[$lineLength - 1] -eq [byte]13) {
            $lineLength -= 1
            $separator = "`r`n"
        }
        $restOffset = $lfIndex + 1
    }

    $firstLine = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $lineLength).TrimStart([char]0xFEFF)
    return [PSCustomObject]@{
        Bytes = $bytes
        FirstLine = $firstLine
        Separator = $separator
        RestOffset = $restOffset
    }
}

function Rewrite-FirstLine($Path, $Record, $NextFirstLine) {
    $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($Path)
    $head = [System.Text.Encoding]::UTF8.GetBytes($NextFirstLine + $Record.Separator)
    if ($Record.RestOffset -lt $Record.Bytes.Length) {
        $restLength = $Record.Bytes.Length - $Record.RestOffset
        $rest = New-Object byte[] $restLength
        [Array]::Copy($Record.Bytes, $Record.RestOffset, $rest, 0, $restLength)
        $next = New-Object byte[] ($head.Length + $rest.Length)
        [Array]::Copy($head, 0, $next, 0, $head.Length)
        [Array]::Copy($rest, 0, $next, $head.Length, $rest.Length)
    } else {
        $next = $head
    }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $stream.SetLength(0)
        $stream.Write($next, 0, $next.Length)
    } finally {
        $stream.Dispose()
    }
    [System.IO.File]::SetLastWriteTimeUtc($Path, $lastWrite)
}

function Get-RelativeBackupPath($BasePath, $ChildPath) {
    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $childFull = [System.IO.Path]::GetFullPath($ChildPath)
    if ($childFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $childFull.Substring($baseFull.Length)
    }
    return ($childFull -replace '[:\\\/]+', '_')
}

function Get-RolloutProviderChanges($CodexHome, $TargetProvider) {
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($dirName in @("sessions", "archived_sessions")) {
        $root = Join-Path $CodexHome $dirName
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter "rollout-*.jsonl" -ErrorAction SilentlyContinue) {
            $record = Read-FirstLineRecord $file.FullName
            if ([string]::IsNullOrWhiteSpace($record.FirstLine)) { continue }
            try {
                $json = $record.FirstLine | ConvertFrom-Json
            } catch {
                continue
            }
            if ($json.type -ne "session_meta" -or -not $json.payload) { continue }

            $currentProvider = [string]$json.payload.model_provider
            if ([string]::IsNullOrWhiteSpace($currentProvider)) {
                $currentProvider = "(missing)"
            }
            $currentCwd = [string]$json.payload.cwd
            $normalizedCwd = Normalize-CodexCwd $currentCwd
            $providerNeedsUpdate = ($currentProvider -ne $TargetProvider)
            $cwdNeedsUpdate = ($currentCwd -ne $normalizedCwd)
            if (-not $providerNeedsUpdate -and -not $cwdNeedsUpdate) { continue }

            if ($providerNeedsUpdate) {
                $payloadProperties = @($json.payload.PSObject.Properties.Name)
                if ($payloadProperties -contains "model_provider") {
                    $json.payload.model_provider = $TargetProvider
                } else {
                    Add-Member -InputObject $json.payload -NotePropertyName "model_provider" -NotePropertyValue $TargetProvider -Force
                }
            }

            if ($cwdNeedsUpdate) {
                $payloadProperties = @($json.payload.PSObject.Properties.Name)
                if ($payloadProperties -contains "cwd") {
                    $json.payload.cwd = $normalizedCwd
                } else {
                    Add-Member -InputObject $json.payload -NotePropertyName "cwd" -NotePropertyValue $normalizedCwd -Force
                }
            }

            $changes.Add([PSCustomObject]@{
                Path = $file.FullName
                Directory = $dirName
                OriginalProvider = $currentProvider
                UpdatedFirstLine = ($json | ConvertTo-Json -Compress -Depth 100)
                Record = $record
            }) | Out-Null
        }
    }
    return $changes.ToArray()
}

function Normalize-CodexCwd($Cwd) {
    $value = [string]$Cwd
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $value
    }
    return ($value -replace '^\\\\\?\\', '')
}

function Get-FriendlyThreadNameFromCwd($Cwd, $FallbackId) {
    $name = ""
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        $clean = Normalize-CodexCwd $Cwd
        $clean = $clean.TrimEnd('\', '/')
        if (-not [string]::IsNullOrWhiteSpace($clean)) {
            $name = Split-Path -Leaf $clean
        }
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $FallbackId
    }
    return $name
}

function Get-RolloutSessionIndexEntries($CodexHome) {
    $entries = @{}
    foreach ($dirName in @("sessions", "archived_sessions")) {
        $root = Join-Path $CodexHome $dirName
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter "rollout-*.jsonl" -ErrorAction SilentlyContinue) {
            $record = Read-FirstLineRecord $file.FullName
            if ([string]::IsNullOrWhiteSpace($record.FirstLine)) { continue }
            try {
                $json = $record.FirstLine | ConvertFrom-Json
            } catch {
                continue
            }
            if ($json.type -ne "session_meta" -or -not $json.payload -or [string]::IsNullOrWhiteSpace([string]$json.payload.id)) {
                continue
            }

            $id = [string]$json.payload.id
            $threadName = Get-FriendlyThreadNameFromCwd -Cwd ([string]$json.payload.cwd) -FallbackId $id
            if (-not $entries.ContainsKey($id) -or ([datetime]$entries[$id].UpdatedAtForSort) -lt $file.LastWriteTimeUtc) {
                $entries[$id] = [PSCustomObject]@{
                    id = $id
                    thread_name = $threadName
                    updated_at = $file.LastWriteTimeUtc.ToString("o")
                    UpdatedAtForSort = $file.LastWriteTimeUtc
                }
            }
        }
    }
    return $entries
}

function Test-SessionIndexThreadNameNeedsRepair($ThreadName) {
    $name = [string]$ThreadName
    if ([string]::IsNullOrWhiteSpace($name)) { return $true }
    if ($name.Length -gt 120) { return $true }
    if ($name -match "[\r\n]") { return $true }
    if ($name -match '^\?{3,}$') { return $true }
    return $false
}

function Get-MojibakeMarkerCount($Text) {
    $value = [string]$Text
    if ([string]::IsNullOrWhiteSpace($value)) { return 0 }
    return [regex]::Matches($value, '姣|旇|緝|妗|潰|绔|笌|鏂|宸|叿|鍥|瀹|鑱|璇|浠|鎺|墜|甯|闂|€|�|[\uE000-\uF8FF]').Count
}

function Repair-SessionIndexThreadName($ThreadName) {
    $name = [string]$ThreadName
    if ([string]::IsNullOrWhiteSpace($name)) { return $name }

    $hasStrongMarker = ($name -match '[\uE000-\uF8FF]') -or $name.Contains([string][char]0xFFFD) -or $name.Contains("€")
    if (-not $hasStrongMarker -and (Get-MojibakeMarkerCount $name) -lt 2) {
        return $name
    }

    try {
        $gbk = [System.Text.Encoding]::GetEncoding(936)
        $candidate = [System.Text.Encoding]::UTF8.GetString($gbk.GetBytes($name))
    } catch {
        return $name
    }

    if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -eq $name) { return $name }
    if ($candidate.Contains([string][char]0xFFFD) -or $candidate -match '[\uE000-\uF8FF]') { return $name }
    if ($candidate -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { return $name }
    return $candidate
}

function Select-NewestSessionIndexTimestamp($Existing, $Sqlite, $Rollout) {
    $bestText = $null
    $bestDate = $null
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    foreach ($candidate in @($Existing, $Sqlite, $Rollout)) {
        $text = [string]$candidate
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        try {
            $parsed = [DateTimeOffset]::Parse($text, $culture, $styles)
            if (-not $bestDate -or $parsed -gt $bestDate) {
                $bestDate = $parsed
                $bestText = $text
            }
        } catch {
            if (-not $bestText) {
                $bestText = $text
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($bestText)) {
        return (Get-Date).ToUniversalTime().ToString("o")
    }
    return $bestText
}

function Convert-UnixSecondsToIso($Value) {
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '^\d+$') {
        return $null
    }

    try {
        return ([DateTimeOffset]::FromUnixTimeSeconds([int64]$text)).UtcDateTime.ToString("o")
    } catch {
        return $null
    }
}

function Convert-DateToUnixSeconds($Value, $Fallback) {
    $text = [string]$Value
    try {
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return [DateTimeOffset]::Parse($text).ToUnixTimeSeconds()
        }
    } catch {}
    return ([DateTimeOffset]$Fallback).ToUnixTimeSeconds()
}

function Convert-DateToUnixMilliseconds($Value, $Fallback) {
    $text = [string]$Value
    try {
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return [DateTimeOffset]::Parse($text).ToUnixTimeMilliseconds()
        }
    } catch {}
    return ([DateTimeOffset]$Fallback).ToUnixTimeMilliseconds()
}

function ConvertTo-SqlLiteral($Value) {
    if ($null -eq $Value) { return "NULL" }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Get-FirstUserTextFromRollout($Path) {
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $json = $line | ConvertFrom-Json
        } catch {
            continue
        }
        if ($json.type -ne "response_item" -or -not $json.payload -or $json.payload.role -ne "user") {
            continue
        }

        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($json.payload.content)) {
            if ($item.type -eq "input_text" -and -not [string]::IsNullOrWhiteSpace([string]$item.text)) {
                $parts.Add([string]$item.text) | Out-Null
            }
        }
        $text = (($parts.ToArray() -join "`n").Trim())
        if ([string]::IsNullOrWhiteSpace($text) -or $text -match '<environment_context>') {
            continue
        }

        $requestMarker = "## My request for Codex:"
        $markerIndex = $text.IndexOf($requestMarker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -ge 0) {
            $text = $text.Substring($markerIndex + $requestMarker.Length).Trim()
        }
        $text = ($text -replace '<image[\s\S]*$', '').Trim()
        if ($text.Length -gt 400) {
            $text = $text.Substring(0, 400).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
    }
    return $null
}

function Get-RolloutThreadBackfillEntries($CodexHome) {
    $entries = @{}
    foreach ($dirName in @("sessions", "archived_sessions")) {
        $root = Join-Path $CodexHome $dirName
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter "rollout-*.jsonl" -ErrorAction SilentlyContinue) {
            $record = Read-FirstLineRecord $file.FullName
            if ([string]::IsNullOrWhiteSpace($record.FirstLine)) { continue }
            try {
                $json = $record.FirstLine | ConvertFrom-Json
            } catch {
                continue
            }
            if ($json.type -ne "session_meta" -or -not $json.payload -or [string]::IsNullOrWhiteSpace([string]$json.payload.id)) {
                continue
            }

            $id = [string]$json.payload.id
            $firstUserText = Get-FirstUserTextFromRollout -Path $file.FullName
            $fallbackTitle = Get-FriendlyThreadNameFromCwd -Cwd ([string]$json.payload.cwd) -FallbackId $id
            $title = $(if (-not [string]::IsNullOrWhiteSpace($firstUserText)) { $firstUserText } else { $fallbackTitle })
            $timestamp = $(if (-not [string]::IsNullOrWhiteSpace([string]$json.payload.timestamp)) { [string]$json.payload.timestamp } else { [string]$json.timestamp })
            $fallbackTime = [DateTimeOffset]$file.LastWriteTimeUtc

            if (-not $entries.ContainsKey($id) -or ([datetime]$entries[$id].UpdatedAtForSort) -lt $file.LastWriteTimeUtc) {
                $entries[$id] = [PSCustomObject]@{
                    Id = $id
                    RolloutPath = $file.FullName
                    CreatedAt = Convert-DateToUnixSeconds -Value $timestamp -Fallback $fallbackTime
                    UpdatedAt = Convert-DateToUnixSeconds -Value $file.LastWriteTimeUtc.ToString("o") -Fallback $fallbackTime
                    CreatedAtMs = Convert-DateToUnixMilliseconds -Value $timestamp -Fallback $fallbackTime
                    UpdatedAtMs = Convert-DateToUnixMilliseconds -Value $file.LastWriteTimeUtc.ToString("o") -Fallback $fallbackTime
                    Source = $(if ($json.payload.source) { [string]$json.payload.source } else { "vscode" })
                    ModelProvider = $(if ($json.payload.model_provider) { [string]$json.payload.model_provider } else { "missing" })
                    Cwd = Normalize-CodexCwd ([string]$json.payload.cwd)
                    Title = $title
                    FirstUserMessage = $(if ($firstUserText) { $firstUserText } else { "" })
                    Preview = $(if ($firstUserText) { $firstUserText } else { "" })
                    CliVersion = $(if ($json.payload.cli_version) { [string]$json.payload.cli_version } else { "" })
                    Model = $(if ($json.payload.model) { [string]$json.payload.model } else { $null })
                    ReasoningEffort = $(if ($json.payload.reasoning_effort) { [string]$json.payload.reasoning_effort } else { $null })
                    ThreadSource = $(if ($json.payload.thread_source) { [string]$json.payload.thread_source } else { $null })
                    UpdatedAtForSort = $file.LastWriteTimeUtc
                }
            }
        }
    }
    return $entries
}

function Invoke-SqliteRolloutBackfill($CodexHome) {
    $dbPath = Join-Path $CodexHome "state_5.sqlite"
    if (-not (Test-Path -LiteralPath $dbPath)) {
        return [PSCustomObject]@{ InsertedRows = 0; Present = $false; Warning = $null }
    }

    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite) {
        return [PSCustomObject]@{
            InsertedRows = 0
            Present = $true
            Warning = "sqlite3.exe not found; rollout-only sessions were not backfilled."
        }
    }

    $schemaOutput = & $sqlite.Source $dbPath "PRAGMA table_info(threads);" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ InsertedRows = 0; Present = $true; Warning = "Could not read SQLite thread schema." }
    }

    $columns = @{}
    foreach ($row in $schemaOutput) {
        $parts = ([string]$row).Split("|")
        if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
            $columns[[string]$parts[1]] = $true
        }
    }
    if (-not $columns.ContainsKey("id")) {
        return [PSCustomObject]@{ InsertedRows = 0; Present = $true; Warning = "SQLite threads table has no id column." }
    }

    $entries = Get-RolloutThreadBackfillEntries -CodexHome $CodexHome
    if ($entries.Count -eq 0) {
        return [PSCustomObject]@{ InsertedRows = 0; Present = $true; Warning = $null }
    }

    $statements = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $entries.Values) {
        $insertColumns = New-Object System.Collections.Generic.List[string]
        $insertValues = New-Object System.Collections.Generic.List[string]

        $valuesByColumn = @{
            id = ConvertTo-SqlLiteral $entry.Id
            rollout_path = ConvertTo-SqlLiteral $entry.RolloutPath
            created_at = [string]$entry.CreatedAt
            updated_at = [string]$entry.UpdatedAt
            source = ConvertTo-SqlLiteral $entry.Source
            model_provider = ConvertTo-SqlLiteral $entry.ModelProvider
            cwd = ConvertTo-SqlLiteral $entry.Cwd
            title = ConvertTo-SqlLiteral $entry.Title
            sandbox_policy = ConvertTo-SqlLiteral "danger-full-access"
            approval_mode = ConvertTo-SqlLiteral "never"
            tokens_used = "0"
            has_user_event = $(if ([string]::IsNullOrWhiteSpace([string]$entry.FirstUserMessage)) { "0" } else { "1" })
            archived = "0"
            cli_version = ConvertTo-SqlLiteral $entry.CliVersion
            first_user_message = ConvertTo-SqlLiteral $entry.FirstUserMessage
            memory_mode = ConvertTo-SqlLiteral "enabled"
            model = ConvertTo-SqlLiteral $entry.Model
            reasoning_effort = ConvertTo-SqlLiteral $entry.ReasoningEffort
            created_at_ms = [string]$entry.CreatedAtMs
            updated_at_ms = [string]$entry.UpdatedAtMs
            thread_source = ConvertTo-SqlLiteral $entry.ThreadSource
            preview = ConvertTo-SqlLiteral $entry.Preview
        }

        foreach ($name in $valuesByColumn.Keys) {
            if ($columns.ContainsKey($name)) {
                $insertColumns.Add($name) | Out-Null
                $insertValues.Add([string]$valuesByColumn[$name]) | Out-Null
            }
        }
        $statements.Add("INSERT OR IGNORE INTO threads (" + ($insertColumns.ToArray() -join ", ") + ") VALUES (" + ($insertValues.ToArray() -join ", ") + ");") | Out-Null
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-rollout-backfill-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $queryFile = Join-Path $tempDir "rollout-backfill.sql"
    try {
        $sql = "PRAGMA busy_timeout=5000;`nBEGIN IMMEDIATE;`n" + ($statements.ToArray() -join "`n") + "`nSELECT total_changes();`nCOMMIT;`n"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($queryFile, $sql, $utf8NoBom)

        $readScriptPath = $queryFile.Replace('\', '/')
        $output = & $sqlite.Source $dbPath ".read $readScriptPath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Out-String).Trim())
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $inserted = 0
    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match '^\d+$') {
            $inserted = [int]$text
        }
    }
    return [PSCustomObject]@{ InsertedRows = $inserted; Present = $true; Warning = $null }
}

function Get-SqliteThreadIndexMetadata($CodexHome) {
    $metadata = @{}
    $dbPath = Join-Path $CodexHome "state_5.sqlite"
    if (-not (Test-Path -LiteralPath $dbPath)) { return $metadata }

    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite) { return $metadata }

    $readDbPath = $dbPath
    $tempDir = $null
    try {
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-state-read-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $readDbPath = Join-Path $tempDir "state_5.sqlite"
        Copy-Item -LiteralPath $dbPath -Destination $readDbPath -Force
        foreach ($suffix in @("-wal", "-shm")) {
            $sidecar = "$dbPath$suffix"
            if (Test-Path -LiteralPath $sidecar) {
                Copy-Item -LiteralPath $sidecar -Destination "$readDbPath$suffix" -Force
            }
        }
    } catch {
        $readDbPath = $dbPath
    }

    $columns = @{}
    $schemaOutput = & $sqlite.Source $readDbPath "PRAGMA table_info(threads);" 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        return $metadata
    }
    foreach ($row in $schemaOutput) {
        $parts = ([string]$row).Split("|")
        if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
            $columns[[string]$parts[1]] = $true
        }
    }

    $delimiter = "|~codex-index~|"
    $titleExpr = "''"
    if ($columns.ContainsKey("title")) { $titleExpr = "COALESCE(title, '')" }
    $updatedAtExpr = "''"
    if ($columns.ContainsKey("updated_at")) { $updatedAtExpr = "COALESCE(CAST(updated_at AS TEXT), '')" }
    $cwdExpr = "''"
    if ($columns.ContainsKey("cwd")) { $cwdExpr = "COALESCE(cwd, '')" }

    $sql = @"
SELECT id || '$delimiter' || $titleExpr || '$delimiter' || $updatedAtExpr || '$delimiter' || $cwdExpr
FROM threads
WHERE COALESCE(id, '') <> '';
"@

    $dataFile = Join-Path $tempDir "thread-index-metadata.txt"
    $queryFile = Join-Path $tempDir "thread-index-query.sql"
    $queryScript = ".output $($dataFile.Replace('\', '/'))`n$sql`n.output stdout`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($queryFile, $queryScript, $utf8NoBom)

    $readScriptPath = $queryFile.Replace('\', '/')
    & $sqlite.Source $readDbPath ".read $readScriptPath" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dataFile)) {
        if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        return $metadata
    }

    foreach ($line in [System.IO.File]::ReadLines($dataFile, [System.Text.Encoding]::UTF8)) {
        $parts = ([string]$line).Split([string[]]@($delimiter), [System.StringSplitOptions]::None)
        if ($parts.Count -lt 4 -or [string]::IsNullOrWhiteSpace($parts[0])) { continue }

        $title = [string]$parts[1]
        $updatedAt = Convert-UnixSecondsToIso $parts[2]
        $cwd = [string]$parts[3]

        $metadata[[string]$parts[0]] = [PSCustomObject]@{
            Title = $title
            UpdatedAt = $updatedAt
            Cwd = Normalize-CodexCwd $cwd
        }
    }

    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    return $metadata
}

function Sync-SessionIndex($CodexHome) {
    $indexPath = Join-Path $CodexHome "session_index.jsonl"
    $existingRows = New-Object System.Collections.Generic.List[object]
    $existingIds = @{}

    if (Test-Path -LiteralPath $indexPath) {
        foreach ($line in Get-Content -LiteralPath $indexPath -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $json = $line | ConvertFrom-Json
                $id = [string]$json.id
                if ($id) {
                    $existingRows.Add($json) | Out-Null
                    $existingIds[$id] = $true
                }
            } catch {
                continue
            }
        }
    }

    $rolloutEntries = Get-RolloutSessionIndexEntries -CodexHome $CodexHome
    $sqliteEntries = Get-SqliteThreadIndexMetadata -CodexHome $CodexHome
    $newLines = New-Object System.Collections.Generic.List[string]
    $added = 0
    $repaired = 0

    foreach ($existing in $existingRows) {
        $id = [string]$existing.id
        $rollout = $null
        if ($rolloutEntries.ContainsKey($id)) { $rollout = $rolloutEntries[$id] }

        $sqliteMeta = $null
        if ($sqliteEntries.ContainsKey($id)) { $sqliteMeta = $sqliteEntries[$id] }

        $threadName = $null
        if ($existing.thread_name) { $threadName = [string]$existing.thread_name }
        $threadName = Repair-SessionIndexThreadName $threadName

        $sqliteTitle = $null
        if ($sqliteMeta -and -not [string]::IsNullOrWhiteSpace([string]$sqliteMeta.Title)) {
            $sqliteTitle = Repair-SessionIndexThreadName ([string]$sqliteMeta.Title)
        }

        if ((Test-SessionIndexThreadNameNeedsRepair $threadName) -and $sqliteTitle -and -not (Test-SessionIndexThreadNameNeedsRepair $sqliteTitle)) {
            $threadName = $sqliteTitle
        } elseif ((Test-SessionIndexThreadNameNeedsRepair $threadName) -and $rollout) {
            $threadName = Repair-SessionIndexThreadName ([string]$rollout.thread_name)
        } elseif (Test-SessionIndexThreadNameNeedsRepair $threadName) {
            $threadName = $id
        }

        $updatedAt = Select-NewestSessionIndexTimestamp `
            -Existing ([string]$existing.updated_at) `
            -Sqlite ($(if ($sqliteMeta) { [string]$sqliteMeta.UpdatedAt } else { $null })) `
            -Rollout ($(if ($rollout) { [string]$rollout.updated_at } else { $null }))

        $entry = [PSCustomObject]@{
            id = $id
            thread_name = $threadName
            updated_at = $updatedAt
        }
        $line = $entry | ConvertTo-Json -Compress -Depth 10
        $newLines.Add($line) | Out-Null

        $oldLine = ([PSCustomObject]@{
            id = [string]$existing.id
            thread_name = [string]$existing.thread_name
            updated_at = [string]$existing.updated_at
        } | ConvertTo-Json -Compress -Depth 10)
        if ($oldLine -ne $line) { $repaired++ }
    }

    foreach ($id in $sqliteEntries.Keys) {
        if ($existingIds.ContainsKey($id)) { continue }
        $sqliteMeta = $sqliteEntries[$id]
        $rollout = $null
        if ($rolloutEntries.ContainsKey($id)) { $rollout = $rolloutEntries[$id] }
        $threadName = Repair-SessionIndexThreadName ([string]$sqliteMeta.Title)
        if ((Test-SessionIndexThreadNameNeedsRepair $threadName) -and $rollout) {
            $threadName = Repair-SessionIndexThreadName ([string]$rollout.thread_name)
        }
        if (Test-SessionIndexThreadNameNeedsRepair $threadName) {
            $threadName = $id
        }
        $updatedAt = Select-NewestSessionIndexTimestamp `
            -Existing $null `
            -Sqlite ([string]$sqliteMeta.UpdatedAt) `
            -Rollout ($(if ($rollout) { [string]$rollout.updated_at } else { $null }))

        $entry = [PSCustomObject]@{
            id = $id
            thread_name = $threadName
            updated_at = $updatedAt
        }
        $newLines.Add(($entry | ConvertTo-Json -Compress -Depth 10)) | Out-Null
        $added++
    }

    if ($added -gt 0 -or $repaired -gt 0 -or -not (Test-Path -LiteralPath $indexPath)) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($indexPath, (($newLines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine), $utf8NoBom)
    }

    return [PSCustomObject]@{
        AddedRows = $added
        RepairedRows = $repaired
        TotalRows = $newLines.Count
        Present = Test-Path -LiteralPath $indexPath
    }
}

function Backup-HistorySyncState(
    $CodexHome,
    $TargetProvider,
    $Changes,
    $HistoryBackupRoot = $Script:DefaultHistoryBackupRoot
) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupRoot = Join-Path $HistoryBackupRoot "$stamp-$TargetProvider"
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

    foreach ($name in @("config.toml", "state_5.sqlite", ".codex-global-state.json", "session_index.jsonl")) {
        $path = Join-Path $CodexHome $name
        if (Test-Path -LiteralPath $path) {
            $target = Join-Path $backupRoot $name
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $path -Destination $target -Force
        }
    }

    foreach ($change in $Changes) {
        $relative = Get-RelativeBackupPath -BasePath $CodexHome -ChildPath $change.Path
        $target = Join-Path (Join-Path $backupRoot "rollouts") $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $change.Path -Destination $target -Force
    }

    return $backupRoot
}

function Invoke-CodexChatHistoryRestoreRepair(
    $CodexHome,
    $TargetProvider = ""
) {
    $repairScript = Join-Path $Script:RepoRoot "Repair-Codex-Chat-History.ps1"
    if (-not (Test-Path -LiteralPath $repairScript)) {
        return [PSCustomObject]@{
            Ran = $false
            Warning = "Repair script not found: $repairScript"
        }
    }

    try {
        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $repairScript,
            "-CodexHome", $CodexHome
        )
        if (-not [string]::IsNullOrWhiteSpace([string]$TargetProvider)) {
            $args += @("-TargetProvider", [string]$TargetProvider)
        }

        $output = & powershell.exe @args 2>&1
        $exitCode = $LASTEXITCODE
        return [PSCustomObject]@{
            Ran = $true
            ExitCode = $exitCode
            Output = @($output | ForEach-Object { [string]$_ })
            Warning = $(if ($exitCode -ne 0) { "Repair script exited with code $exitCode." } else { $null })
        }
    } catch {
        return [PSCustomObject]@{
            Ran = $false
            Warning = "Restore repair failed: $(Get-SyncExceptionSummary $_.Exception)"
        }
    }
}

function Get-CodexChatHistoryBackupItemNames {
    return @(
        "sessions",
        "archived_sessions",
        "attachments",
        "memories",
        "sqlite",
        "session_index.jsonl",
        ".codex-global-state.json",
        "state_5.sqlite",
        "state_5.sqlite-wal",
        "state_5.sqlite-shm",
        "logs_2.sqlite",
        "logs_2.sqlite-wal",
        "logs_2.sqlite-shm",
        "goals_1.sqlite",
        "goals_1.sqlite-wal",
        "goals_1.sqlite-shm",
        "memories_1.sqlite",
        "memories_1.sqlite-wal",
        "memories_1.sqlite-shm"
    )
}

function Resolve-SafeChildPath($BasePath, $RelativeName) {
    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        throw "Base path is required."
    }
    if ([string]::IsNullOrWhiteSpace($RelativeName)) {
        throw "Relative path is required."
    }
    if ([System.IO.Path]::IsPathRooted($RelativeName)) {
        throw "Refusing rooted backup entry: $RelativeName"
    }

    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]@('\', '/'))
    $targetFull = [System.IO.Path]::GetFullPath((Join-Path $baseFull $RelativeName))
    $prefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $targetFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing backup entry outside base path: $RelativeName"
    }
    return $targetFull
}

function Test-PathInsideDirectory($ParentPath, $ChildPath) {
    if ([string]::IsNullOrWhiteSpace($ParentPath) -or [string]::IsNullOrWhiteSpace($ChildPath)) {
        return $false
    }
    $parentFull = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([char[]]@('\', '/'))
    $childFull = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd([char[]]@('\', '/'))
    $prefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar
    return $childFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-CodexChatHistoryBackupEntryName($Name) {
    $allowed = @{}
    foreach ($entryName in Get-CodexChatHistoryBackupItemNames) {
        $allowed[$entryName] = $true
    }

    if (-not $allowed.ContainsKey([string]$Name)) {
        throw "Unsupported chat history backup entry: $Name"
    }
}

function Get-CodexChatHistoryBackupManifest($BackupPath) {
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        throw (U "\u8bf7\u9009\u62e9\u5907\u4efd\u76ee\u5f55")
    }

    $manifestPath = Join-Path $BackupPath "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw (U "\u8be5\u76ee\u5f55\u4e0d\u662f O-C \u804a\u5929\u8bb0\u5f55\u5907\u4efd\uff1a\u7f3a\u5c11 manifest.json")
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
        throw (U "\u5907\u4efd manifest.json \u65e0\u6cd5\u8bfb\u53d6")
    }

    if ($manifest.kind -ne "oc.codex.chatHistoryBackup" -or [int]$manifest.version -ne 1) {
        throw (U "\u5907\u4efd\u7c7b\u578b\u4e0d\u5339\u914d\uff0c\u65e0\u6cd5\u6062\u590d")
    }

    foreach ($entry in @($manifest.entries)) {
        Assert-CodexChatHistoryBackupEntryName ([string]$entry.name)
        $source = Resolve-SafeChildPath -BasePath $BackupPath -RelativeName ([string]$entry.name)
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Backup entry missing: $($entry.name)"
        }
    }

    return $manifest
}

function New-CodexChatHistoryBackup(
    $CodexHome = $Script:DefaultCodexHome,
    $BackupRoot = $Script:DefaultBackupRoot,
    $BackupDirectory = $null,
    $Stamp = $null,
    $Label = "codex-chat-history"
) {
    if ([string]::IsNullOrWhiteSpace($CodexHome) -or -not (Test-Path -LiteralPath $CodexHome)) {
        throw ((U "\u627e\u4e0d\u5230 Codex \u6570\u636e\u76ee\u5f55\uff1a") + "`n$CodexHome")
    }
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = $Script:DefaultBackupRoot
    }
    if ([string]::IsNullOrWhiteSpace($Stamp)) {
        $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    }
    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = "codex-chat-history"
    }

    $chatBackupRoot = $BackupDirectory
    if ([string]::IsNullOrWhiteSpace($chatBackupRoot)) {
        $chatBackupRoot = Get-ChatHistoryBackupRootFromBackupRoot $BackupRoot
    }
    New-Item -ItemType Directory -Path $chatBackupRoot -Force | Out-Null

    $backupDir = Join-Path $chatBackupRoot "$Stamp-$Label"
    if (Test-Path -LiteralPath $backupDir) {
        throw "Backup directory already exists: $backupDir"
    }
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($name in Get-CodexChatHistoryBackupItemNames) {
        $source = Resolve-SafeChildPath -BasePath $CodexHome -RelativeName $name
        if (-not (Test-Path -LiteralPath $source)) {
            continue
        }

        $target = Resolve-SafeChildPath -BasePath $backupDir -RelativeName $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force

        $sourceItem = Get-Item -LiteralPath $source -Force
        $entries.Add([PSCustomObject]@{
            name = $name
            type = $(if ($sourceItem.PSIsContainer) { "directory" } else { "file" })
        }) | Out-Null
    }

    $manifest = [ordered]@{
        kind = "oc.codex.chatHistoryBackup"
        version = 1
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        source_codex_home = $CodexHome
        entries = @($entries.ToArray())
    }
    $manifestPath = Join-Path $backupDir "manifest.json"
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    return [PSCustomObject]@{
        BackupDir = $backupDir
        ManifestPath = $manifestPath
        CopiedItems = $entries.Count
    }
}

function Restore-CodexChatHistoryBackup(
    $BackupPath,
    $CodexHome = $Script:DefaultCodexHome,
    $BackupRoot = $Script:DefaultBackupRoot,
    $Stamp = $null,
    [switch]$SkipProcessCheck
) {
    if (-not $SkipProcessCheck) {
        Close-CodexIfRunning
    }
    if ([string]::IsNullOrWhiteSpace($CodexHome)) {
        $CodexHome = $Script:DefaultCodexHome
    }
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = $Script:DefaultBackupRoot
    }
    if ([string]::IsNullOrWhiteSpace($Stamp)) {
        $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    }

    $manifest = Get-CodexChatHistoryBackupManifest -BackupPath $BackupPath
    if (Test-PathInsideDirectory -ParentPath $CodexHome -ChildPath $BackupPath) {
        throw (U "\u4e0d\u80fd\u4ece Codex \u6570\u636e\u76ee\u5f55\u5185\u90e8\u6062\u590d\u5907\u4efd")
    }

    $safetyBackupDir = $null
    if (Test-Path -LiteralPath $CodexHome) {
        $safety = New-CodexChatHistoryBackup -CodexHome $CodexHome -BackupRoot $BackupRoot -Stamp $Stamp -Label "before-chat-restore"
        $safetyBackupDir = $safety.BackupDir
    } else {
        New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    }

    $restored = 0
    foreach ($entry in @($manifest.entries)) {
        $name = [string]$entry.name
        Assert-CodexChatHistoryBackupEntryName $name

        $source = Resolve-SafeChildPath -BasePath $BackupPath -RelativeName $name
        $target = Resolve-SafeChildPath -BasePath $CodexHome -RelativeName $name
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Backup entry missing: $name"
        }

        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
        $restored++
    }

    $targetProvider = Get-CodexProvider $CodexHome
    if ($targetProvider -eq "missing") {
        $targetProvider = ""
    }
    $repairResult = Invoke-CodexChatHistoryRestoreRepair -CodexHome $CodexHome -TargetProvider $targetProvider

    return [PSCustomObject]@{
        BackupDir = $BackupPath
        SafetyBackupDir = $safetyBackupDir
        RestoredItems = $restored
        RepairRan = [bool]$repairResult.Ran
        RepairWarning = $repairResult.Warning
        RepairOutput = @($repairResult.Output)
    }
}

function Invoke-SqliteProviderSync($CodexHome, $TargetProvider) {
    $dbPath = Join-Path $CodexHome "state_5.sqlite"
    if (-not (Test-Path -LiteralPath $dbPath)) {
        return [PSCustomObject]@{ UpdatedRows = 0; Present = $false; Warning = $null }
    }

    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite) {
        return [PSCustomObject]@{
            UpdatedRows = 0
            Present = $true
            Warning = "sqlite3.exe not found; SQLite provider metadata was not updated."
        }
    }

    $schemaOutput = & $sqlite.Source $dbPath "PRAGMA table_info(threads);" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{
            UpdatedRows = 0
            Present = $true
            Warning = "Could not read SQLite thread schema."
        }
    }

    $columns = @{}
    foreach ($row in $schemaOutput) {
        $parts = ([string]$row).Split("|")
        if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
            $columns[[string]$parts[1]] = $true
        }
    }

    $safeProvider = $TargetProvider.Replace("'", "''")
    $verbatimPrefix = "\\?\"
    $safeVerbatimPrefix = $verbatimPrefix.Replace("'", "''")

    $setClauses = New-Object System.Collections.Generic.List[string]
    $whereClauses = New-Object System.Collections.Generic.List[string]

    if ($columns.ContainsKey("model_provider")) {
        $setClauses.Add(@"
model_provider = CASE
    WHEN COALESCE(model_provider, '') <> '$safeProvider' THEN '$safeProvider'
    ELSE model_provider
  END
"@.Trim()) | Out-Null
        $whereClauses.Add("COALESCE(model_provider, '') <> '$safeProvider'") | Out-Null
    }

    if ($columns.ContainsKey("cwd")) {
        $setClauses.Add(@"
cwd = CASE
    WHEN substr(COALESCE(cwd, ''), 1, 4) = '$safeVerbatimPrefix' THEN substr(cwd, 5)
    ELSE cwd
  END
"@.Trim()) | Out-Null
        $whereClauses.Add("substr(COALESCE(cwd, ''), 1, 4) = '$safeVerbatimPrefix'") | Out-Null
    }

    if ($setClauses.Count -eq 0) {
        return [PSCustomObject]@{
            UpdatedRows = 0
            Present = $true
            Warning = "SQLite threads table has no model_provider or cwd columns."
        }
    }

    $sql = @"
PRAGMA busy_timeout=5000;
BEGIN IMMEDIATE;
UPDATE threads
SET
  $($setClauses.ToArray() -join ",`n  ")
WHERE
  $($whereClauses.ToArray() -join "`n  OR ");
SELECT changes();
COMMIT;
"@
    $output = & $sqlite.Source $dbPath $sql 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }

    $updated = 0
    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match '^\d+$') {
            $updated = [int]$text
        }
    }

    return [PSCustomObject]@{ UpdatedRows = $updated; Present = $true; Warning = $null }
}

function Get-SyncExceptionSummary($Exception) {
    $message = [string]$Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        return "unknown error"
    }

    $line = (($message -split "(`r`n|`n|`r)") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($line)) {
        return "unknown error"
    }
    return $line.Trim()
}

function Invoke-HistoryProviderSync(
    $TargetProvider,
    $CodexHome = $Script:DefaultCodexHome,
    $HistoryBackupRoot = $Script:DefaultHistoryBackupRoot
) {
    if ([string]::IsNullOrWhiteSpace($TargetProvider) -or $TargetProvider -eq "missing") {
        return [PSCustomObject]@{
            TargetProvider = $TargetProvider
            BackupDir = $null
            ChangedRollouts = 0
            SqliteRowsUpdated = 0
            Warning = "Skipped sync because target provider is missing."
        }
    }

    $changes = @(Get-RolloutProviderChanges -CodexHome $CodexHome -TargetProvider $TargetProvider)
    $backupDir = Backup-HistorySyncState -CodexHome $CodexHome -TargetProvider $TargetProvider -Changes $changes -HistoryBackupRoot $HistoryBackupRoot
    $failedRollouts = New-Object System.Collections.Generic.List[object]
    foreach ($change in $changes) {
        try {
            Rewrite-FirstLine -Path $change.Path -Record $change.Record -NextFirstLine $change.UpdatedFirstLine
        } catch {
            $failedRollouts.Add([PSCustomObject]@{
                Path = $change.Path
                Error = $_.Exception.Message
            }) | Out-Null
        }
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    if ($failedRollouts.Count -gt 0) {
        $warnings.Add("Failed to rewrite $($failedRollouts.Count) locked rollout file(s). Close Codex and run sync again.") | Out-Null
    }

    $backfillResult = [PSCustomObject]@{ InsertedRows = 0; Present = $false; Warning = $null }
    try {
        $backfillResult = Invoke-SqliteRolloutBackfill -CodexHome $CodexHome
        if ($backfillResult.Warning) { $warnings.Add([string]$backfillResult.Warning) | Out-Null }
    } catch {
        $warnings.Add("SQLite rollout backfill failed: $(Get-SyncExceptionSummary $_.Exception)") | Out-Null
    }

    $sqliteResult = [PSCustomObject]@{ UpdatedRows = 0; Present = $false; Warning = $null }
    try {
        $sqliteResult = Invoke-SqliteProviderSync -CodexHome $CodexHome -TargetProvider $TargetProvider
        if ($sqliteResult.Warning) { $warnings.Add([string]$sqliteResult.Warning) | Out-Null }
    } catch {
        $warnings.Add("SQLite provider sync failed: $(Get-SyncExceptionSummary $_.Exception)") | Out-Null
    }

    $sessionIndexResult = [PSCustomObject]@{ AddedRows = 0; RepairedRows = 0; TotalRows = 0; Present = $false }
    try {
        $sessionIndexResult = Sync-SessionIndex -CodexHome $CodexHome
    } catch {
        $warnings.Add("Session index sync failed: $(Get-SyncExceptionSummary $_.Exception)") | Out-Null
    }

    return [PSCustomObject]@{
        TargetProvider = $TargetProvider
        BackupDir = $backupDir
        ChangedRollouts = ($changes.Count - $failedRollouts.Count)
        FailedRollouts = $failedRollouts.Count
        FailedRolloutPaths = @($failedRollouts | ForEach-Object { $_.Path })
        SqliteRowsBackfilled = $backfillResult.InsertedRows
        SqliteRowsUpdated = $sqliteResult.UpdatedRows
        SessionIndexAdded = $sessionIndexResult.AddedRows
        SessionIndexRepaired = $sessionIndexResult.RepairedRows
        Warning = ($(if ($warnings.Count -gt 0) { $warnings.ToArray() -join " " } else { $null }))
    }
}

function Copy-ConfigToCodex($SourcePath, $CodexHome) {
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw ((U "\u627e\u4e0d\u5230\u914d\u7f6e\u6587\u4ef6\uff1a") + "`n$SourcePath")
    }
    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination (Join-Path $CodexHome "config.toml") -Force
}

function Get-CodexApiKeyFromConfig($ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    foreach ($line in Get-Content -LiteralPath $ConfigPath -Encoding UTF8 -ErrorAction Stop) {
        $match = [regex]::Match($line, '^\s*api_key\s*=\s*"([^"]+)"\s*$')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
    }
    return $null
}

function Write-ApiAuthFromConfig($ConfigPath, $CodexHome, $ProfilePath = $null) {
    $apiKey = Get-CodexApiKeyFromConfig -ConfigPath $ConfigPath
    if ([string]::IsNullOrWhiteSpace($apiKey)) { return $null }

    $auth = [ordered]@{
        OPENAI_API_KEY = $apiKey
        auth_mode = "apikey"
    }
    $json = $auth | ConvertTo-Json -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $authPath = Join-Path $CodexHome "auth.json"
    [System.IO.File]::WriteAllText($authPath, $json, $utf8NoBom)

    if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
        New-Item -ItemType Directory -Path $ProfilePath -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $ProfilePath "auth.json"), $json, $utf8NoBom)
    }

    return $authPath
}

function Move-ApiAuthForOAuth($CodexHome, $CurrentProvider, $AuthMode) {
    $authPath = Join-Path $CodexHome "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) { return $null }

    $shouldMove = ($CurrentProvider -ne "openai") -or ($AuthMode -match "api|key")
    if (-not $shouldMove) { return $null }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $target = Join-Path $CodexHome "auth.json.api-before-oauth-$stamp"
    Move-Item -LiteralPath $authPath -Destination $target -Force
    return $target
}

function Move-OAuthAuthForCPAMC($CodexHome, $CurrentProvider, $AuthMode) {
    $authPath = Join-Path $CodexHome "auth.json"
    if (-not (Test-Path -LiteralPath $authPath)) { return $null }

    $shouldMove = ($CurrentProvider -eq "openai") -or ($AuthMode -match "chatgpt|oauth")
    if (-not $shouldMove) { return $null }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $target = Join-Path $CodexHome "auth.json.oauth-before-cpamc-$stamp"
    Move-Item -LiteralPath $authPath -Destination $target -Force
    return $target
}

function Move-CockpitAuthForOAuth($CodexHome) {
    $cockpitAuthPath = Join-Path $CodexHome ".cockpit_codex_auth.json"
    if (-not (Test-Path -LiteralPath $cockpitAuthPath)) { return $null }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $target = Join-Path $CodexHome ".cockpit_codex_auth.json.disabled-before-oauth-$stamp"
    Move-Item -LiteralPath $cockpitAuthPath -Destination $target -Force
    return $target
}

function Restore-CockpitAuthForCPAMC($CodexHome) {
    $cockpitAuthPath = Join-Path $CodexHome ".cockpit_codex_auth.json"
    if (Test-Path -LiteralPath $cockpitAuthPath) {
        return $cockpitAuthPath
    }

    $backup = Get-ChildItem -LiteralPath $CodexHome -Filter ".cockpit_codex_auth.json.disabled-before-oauth-*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $backup) { return $null }

    Move-Item -LiteralPath $backup.FullName -Destination $cockpitAuthPath -Force
    return $cockpitAuthPath
}

function Switch-CodexProfileMode(
    [ValidateSet("OAuth", "CPAMC")] $Target,
    $CodexHome = $Script:DefaultCodexHome,
    $OfficialConfigPath = (Get-DefaultOfficialConfigPath),
    $CPAMCConfigPath = (Get-DefaultCPAMCConfigPath),
    $AppRoot = $Script:DefaultAppRoot,
    $HistoryBackupRoot = $Script:DefaultHistoryBackupRoot,
    [switch]$SkipProcessCheck
) {
    Ensure-SwitcherDirs $AppRoot
    if (-not $SkipProcessCheck) {
        Close-CodexIfRunning
    }

    $currentProvider = Get-CodexProvider $CodexHome
    $authMode = Get-CodexAuthMode $CodexHome
    $targetProvider = if ($Target -eq "CPAMC") {
        Get-CodexProviderFromConfigPath $CPAMCConfigPath
    } else {
        "openai"
    }
    if ($Target -eq "CPAMC" -and ([string]::IsNullOrWhiteSpace($targetProvider) -or $targetProvider -eq "missing")) {
        throw ((U "\u65e0\u6cd5\u8bc6\u522b API \u914d\u7f6e\u7684 model_provider\uff1a") + "`n$CPAMCConfigPath")
    }
    Assert-HistorySyncWritable -CodexHome $CodexHome -TargetProvider $currentProvider
    Assert-HistorySyncWritable -CodexHome $CodexHome -TargetProvider $targetProvider
    $preSync = Invoke-HistoryProviderSync -TargetProvider $currentProvider -CodexHome $CodexHome -HistoryBackupRoot $HistoryBackupRoot
    $savedProfile = Save-CurrentModeProfile -CodexHome $CodexHome -AppRoot $AppRoot
    $authBackup = Backup-ActiveAuthConfig -CodexHome $CodexHome -AppRoot $AppRoot
    $movedAuth = $null

    if ($Target -eq "CPAMC") {
        $cpamcProfile = Join-Path $AppRoot "profiles\cpamc"
        Restore-CockpitAuthForCPAMC -CodexHome $CodexHome | Out-Null
        Copy-ConfigToCodex -SourcePath $CPAMCConfigPath -CodexHome $CodexHome
        $movedAuth = Move-OAuthAuthForCPAMC -CodexHome $CodexHome -CurrentProvider $currentProvider -AuthMode $authMode
        Write-ApiAuthFromConfig -ConfigPath $CPAMCConfigPath -CodexHome $CodexHome -ProfilePath $cpamcProfile | Out-Null
    } else {
        Move-CockpitAuthForOAuth -CodexHome $CodexHome | Out-Null
        $movedAuth = Move-ApiAuthForOAuth -CodexHome $CodexHome -CurrentProvider $currentProvider -AuthMode $authMode
        Copy-ConfigToCodex -SourcePath $OfficialConfigPath -CodexHome $CodexHome
        $officialAuth = Join-Path $AppRoot "profiles\official\auth.json"
        if (Test-Path -LiteralPath $officialAuth) {
            Copy-Item -LiteralPath $officialAuth -Destination (Join-Path $CodexHome "auth.json") -Force
        }
    }

    $postSync = Invoke-HistoryProviderSync -TargetProvider $targetProvider -CodexHome $CodexHome -HistoryBackupRoot $HistoryBackupRoot
    return [PSCustomObject]@{
        Target = $Target
        PreviousProvider = $currentProvider
        TargetProvider = $targetProvider
        PreSync = $preSync
        PostSync = $postSync
        SavedProfile = $savedProfile
        AuthBackup = $authBackup
        MovedAuth = $movedAuth
    }
}

function Format-SwitchResult($Result) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((U "\u5df2\u5207\u6362\u81f3") + " $(Get-FriendlyModeName $Result.TargetProvider)")
    $lines.Add((U "\u5386\u53f2\u8bb0\u5f55\u5df2\u540c\u6b65\uff1a") + " provider=$($Result.TargetProvider)")
    $lines.Add("")
    $lines.Add((U "\u5207\u6362\u524d\u68c0\u67e5\uff1a") + " rollout=$($Result.PreSync.ChangedRollouts), sqlite=$($Result.PreSync.SqliteRowsUpdated)")
    $lines.Add((U "\u5207\u6362\u540e\u540c\u6b65\uff1a") + " rollout=$($Result.PostSync.ChangedRollouts), sqlite=$($Result.PostSync.SqliteRowsUpdated)")
    $lines.Add((U "\u5b89\u5168\u5907\u4efd\uff1a") + " $($Result.AuthBackup)")
    $lines.Add((U "\u8bb0\u5f55\u5907\u4efd\uff1a") + " $($Result.PostSync.BackupDir)")
    if ($Result.MovedAuth) {
        $lines.Add((U "\u5df2\u79fb\u8d70 API auth\uff1a") + " $($Result.MovedAuth)")
    }
    if ($Result.PostSync.Warning) {
        $lines.Add("")
        $lines.Add("Warning: $($Result.PostSync.Warning)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Format-ChatHistoryBackupResult($Result) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((U "\u804a\u5929\u8bb0\u5f55\u5907\u4efd\u5df2\u5b8c\u6210"))
    $lines.Add((U "\u5907\u4efd\u9879\uff1a") + " $($Result.CopiedItems)")
    $lines.Add((U "\u4f4d\u7f6e\uff1a") + " $($Result.BackupDir)")
    return ($lines -join [Environment]::NewLine)
}

function Format-ChatHistoryRestoreResult($Result) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((U "\u804a\u5929\u8bb0\u5f55\u5df2\u6062\u590d"))
    $lines.Add((U "\u6062\u590d\u9879\uff1a") + " $($Result.RestoredItems)")
    if ($Result.SafetyBackupDir) {
        $lines.Add((U "\u6062\u590d\u524d\u5907\u4efd\uff1a") + " $($Result.SafetyBackupDir)")
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-FriendlyModeName($Provider) {
    if ($Provider -eq "openai" -or $Provider -eq "OAuth") {
        return "OAuth"
    }
    if ($Provider -eq "CPA" -or $Provider -eq "CPAMC") {
        return "API (CPA)"
    }
    if ([string]::IsNullOrWhiteSpace($Provider) -or $Provider -eq "missing") {
        return (U "\u672a\u8bc6\u522b")
    }
    return [string]$Provider
}

function Get-FriendlyAuthName($AuthMode) {
    if ($AuthMode -eq "chatgpt" -or $AuthMode -eq "oauth") {
        return "OAuth"
    }
    if ($AuthMode -eq "apikey") {
        return "API"
    }
    if ([string]::IsNullOrWhiteSpace($AuthMode) -or $AuthMode -eq "missing") {
        return (U "\u672a\u767b\u5f55")
    }
    return [string]$AuthMode
}

function Test-ToolReadiness($Settings, $AppRoot = $Script:DefaultAppRoot) {
    if ($Settings -and $Settings.backupRoot) {
        $AppRoot = Get-AppRootFromBackupRoot $Settings.backupRoot
    }
    $cpamcAuth = Join-Path $AppRoot "profiles\cpamc\auth.json"
    $officialAuth = Join-Path $AppRoot "profiles\official\auth.json"
    return [PSCustomObject]@{
        OfficialConfigExists = Test-Path -LiteralPath $Settings.officialConfigPath
        CPAMCConfigExists = Test-Path -LiteralPath $Settings.cpamcConfigPath
        OfficialAuthSaved = Test-Path -LiteralPath $officialAuth
        CPAMCAuthSaved = Test-Path -LiteralPath $cpamcAuth
        Sqlite3Exists = [bool](Get-Command sqlite3 -ErrorAction SilentlyContinue)
    }
}

function Get-OCLogPath {
    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if ([string]::IsNullOrWhiteSpace($appData)) {
        $appData = Join-Path $env:USERPROFILE "AppData\Roaming"
    }
    $logDir = Join-Path (Join-Path $appData "C-O") "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    return (Join-Path $logDir ("oc-{0}.log" -f (Get-Date -Format "yyyyMMdd")))
}

function Write-OCLog($Message, $Exception = $null) {
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), [string]$Message
        Add-Content -LiteralPath (Get-OCLogPath) -Value $line -Encoding UTF8
        if ($Exception) {
            Add-Content -LiteralPath (Get-OCLogPath) -Value ([string]$Exception) -Encoding UTF8
        }
    } catch {}
}

function Show-ClearMessage($Owner, $Message, [switch]$Error) {
    $title = $(if ($Error) { U "\u64cd\u4f5c\u5931\u8d25" } else { U "\u64cd\u4f5c\u5b8c\u6210" })
    $icon = $(if ($Error) { [System.Windows.Forms.MessageBoxIcon]::Error } else { [System.Windows.Forms.MessageBoxIcon]::Information })
    [System.Windows.Forms.MessageBox]::Show([string]$Message, $title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null
}

function New-NativeSection($Parent, $Text, $Location, $Size) {
    $group = New-Object System.Windows.Forms.GroupBox
    $group.Text = $Text
    $group.Location = $Location
    $group.Size = $Size
    $group.BackColor = [System.Drawing.Color]::White
    $group.ForeColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $group.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
    $Parent.Controls.Add($group)
    return $group
}

function New-NativeButton($Text, $Location, $Size, [switch]$Primary) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = $Location
    $button.Size = $Size
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::System
    $button.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $button.UseVisualStyleBackColor = $true
    if ($Primary) {
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.BackColor = [System.Drawing.Color]::FromArgb(16, 94, 72)
        $button.ForeColor = [System.Drawing.Color]::White
        $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(16, 94, 72)
        $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(20, 120, 92)
        $button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(12, 72, 56)
    }
    return $button
}

function Add-PathRow($Parent, $LabelText, $Text, $Y, $Kind) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $LabelText
    $label.Location = New-Object System.Drawing.Point(18, $Y)
    $label.Size = New-Object System.Drawing.Size(132, 24)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $label.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $Parent.Controls.Add($label)

    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point(154, ($Y + 1))
    $box.Size = New-Object System.Drawing.Size(610, 24)
    $box.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $Parent.Controls.Add($box)

    $button = New-NativeButton -Text (U "\u9009\u62e9") -Location (New-Object System.Drawing.Point(776, ($Y - 1))) -Size (New-Object System.Drawing.Size(86, 28))
    $button.Tag = $Kind
    $Parent.Controls.Add($button)

    return [PSCustomObject]@{
        Label = $label
        TextBox = $box
        Button = $button
        Kind = $Kind
    }
}

function Add-StatusRow($Parent, $LabelText, $Y) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $LabelText
    $label.Location = New-Object System.Drawing.Point(18, $Y)
    $label.Size = New-Object System.Drawing.Size(104, 22)
    $label.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $Parent.Controls.Add($label)

    $value = New-Object System.Windows.Forms.Label
    $value.Text = "-"
    $value.Location = New-Object System.Drawing.Point(128, $Y)
    $value.Size = New-Object System.Drawing.Size(150, 22)
    $value.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
    $value.ForeColor = [System.Drawing.Color]::FromArgb(16, 94, 72)
    $Parent.Controls.Add($value)
    return $value
}

function Set-UiBusy($Controls, $StatusLabel, $Busy, $Text) {
    foreach ($control in @($Controls)) {
        if ($control) { $control.Enabled = -not $Busy }
    }
    if ($StatusLabel) {
        $StatusLabel.Text = [string]$Text
    }
}

function Show-UnifiedForm {
    Write-OCLog "Starting O-C UI"
    $settings = Load-SwitcherSettings
    Ensure-SwitcherDirs (Get-AppRootFromBackupRoot $settings.backupRoot)
    $scriptPath = $PSCommandPath

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Script:Title
    $form.Size = New-Object System.Drawing.Size(980, 700)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = U "\u004f\u002d\u0043 \u0043\u006f\u0064\u0065\u0078 \u5de5\u5177\u7bb1"
    $title.Location = New-Object System.Drawing.Point(24, 18)
    $title.Size = New-Object System.Drawing.Size(520, 34)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
    $title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 18, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($title)

    $subTitle = New-Object System.Windows.Forms.Label
    $subTitle.Text = U "\u5907\u4efd\u548c\u6062\u590d\u5f53\u524d\u7528\u6237 .codex \u804a\u5929\u6570\u636e\uff0c\u914d\u7f6e\u5207\u6362\u4fdd\u6301\u7b80\u5355\u3002"
    $subTitle.Location = New-Object System.Drawing.Point(26, 54)
    $subTitle.Size = New-Object System.Drawing.Size(760, 24)
    $subTitle.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
    $subTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)
    $form.Controls.Add($subTitle)

    $pathsSection = New-NativeSection -Parent $form -Text (U "\u914d\u7f6e\u6587\u4ef6") -Location (New-Object System.Drawing.Point(24, 90)) -Size (New-Object System.Drawing.Size(930, 106))
    $openaiRow = Add-PathRow -Parent $pathsSection -LabelText (U "\u004f\u0070\u0065\u006e\u0041\u0049 \u914d\u7f6e") -Text $settings.officialConfigPath -Y 30 -Kind "file"
    $cpamcRow = Add-PathRow -Parent $pathsSection -LabelText (U "\u0041\u0050\u0049 \u914d\u7f6e") -Text $settings.cpamcConfigPath -Y 66 -Kind "file"

    $chatPathsSection = New-NativeSection -Parent $form -Text (U "\u804a\u5929\u8bb0\u5f55\u8def\u5f84") -Location (New-Object System.Drawing.Point(24, 210)) -Size (New-Object System.Drawing.Size(930, 128))
    $chatBackupSaveRow = Add-PathRow -Parent $chatPathsSection -LabelText (U "\u804a\u5929\u5907\u4efd\u4fdd\u5b58\u5230") -Text $settings.chatBackupDirectory -Y 30 -Kind "folder"
    $restoreBackupPathRow = Add-PathRow -Parent $chatPathsSection -LabelText (U "\u6062\u590d\u5907\u4efd\u6570\u636e\u4f4d\u7f6e") -Text $settings.chatRestoreBackupPath -Y 66 -Kind "folder"
    $defaultCodexNote = New-Object System.Windows.Forms.Label
    $defaultCodexNote.Text = (U "\u9ed8\u8ba4\u8bfb\u53d6\u5e76\u6062\u590d\u5230\u5f53\u524d\u7528\u6237 .codex") + "  " + $Script:DefaultCodexHome
    $defaultCodexNote.Location = New-Object System.Drawing.Point(154, 100)
    $defaultCodexNote.Size = New-Object System.Drawing.Size(740, 20)
    $defaultCodexNote.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
    $chatPathsSection.Controls.Add($defaultCodexNote)

    $backupSection = New-NativeSection -Parent $form -Text (U "\u804a\u5929\u8bb0\u5f55\u5907\u4efd") -Location (New-Object System.Drawing.Point(24, 352)) -Size (New-Object System.Drawing.Size(610, 280))
    $listTitle = New-Object System.Windows.Forms.Label
    $listTitle.Text = U "\u5907\u4efd\u5217\u8868"
    $listTitle.Location = New-Object System.Drawing.Point(18, 28)
    $listTitle.Size = New-Object System.Drawing.Size(160, 22)
    $listTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
    $backupSection.Controls.Add($listTitle)

    $backupList = New-Object System.Windows.Forms.ListView
    $backupList.Location = New-Object System.Drawing.Point(18, 56)
    $backupList.Size = New-Object System.Drawing.Size(568, 134)
    $backupList.View = [System.Windows.Forms.View]::Details
    $backupList.FullRowSelect = $true
    $backupList.MultiSelect = $false
    $backupList.GridLines = $true
    [void]$backupList.Columns.Add((U "\u5907\u4efd\u540d\u79f0"), 285)
    [void]$backupList.Columns.Add((U "\u65f6\u95f4"), 150)
    [void]$backupList.Columns.Add((U "\u9879\u76ee"), 70)
    $backupSection.Controls.Add($backupList)

    $backupButton = New-NativeButton -Text (U "\u5f00\u59cb\u5907\u4efd") -Location (New-Object System.Drawing.Point(18, 206)) -Size (New-Object System.Drawing.Size(116, 36)) -Primary
    $restoreButton = New-NativeButton -Text (U "\u6062\u590d\u9009\u4e2d\u7684\u5907\u4efd") -Location (New-Object System.Drawing.Point(144, 206)) -Size (New-Object System.Drawing.Size(148, 36)) -Primary
    $refreshButton = New-NativeButton -Text (U "\u5237\u65b0\u5217\u8868") -Location (New-Object System.Drawing.Point(302, 206)) -Size (New-Object System.Drawing.Size(104, 36))
    $simulateButton = New-NativeButton -Text (U "\u6a21\u62df\u6062\u590d") -Location (New-Object System.Drawing.Point(416, 206)) -Size (New-Object System.Drawing.Size(104, 36))
    $backupSection.Controls.AddRange(@($backupButton, $restoreButton, $refreshButton, $simulateButton))

    $summarySection = New-NativeSection -Parent $form -Text (U "\u5907\u4efd\u6458\u8981") -Location (New-Object System.Drawing.Point(650, 352)) -Size (New-Object System.Drawing.Size(304, 280))
    $summaryBox = New-Object System.Windows.Forms.TextBox
    $summaryBox.Location = New-Object System.Drawing.Point(18, 30)
    $summaryBox.Size = New-Object System.Drawing.Size(268, 96)
    $summaryBox.Multiline = $true
    $summaryBox.ReadOnly = $true
    $summaryBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $summaryBox.BackColor = [System.Drawing.Color]::White
    $summaryBox.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $summarySection.Controls.Add($summaryBox)

    $modeValue = Add-StatusRow -Parent $summarySection -LabelText (U "\u5f53\u524d\u6a21\u5f0f") -Y 132
    $authValue = Add-StatusRow -Parent $summarySection -LabelText (U "\u767b\u5f55\u65b9\u5f0f") -Y 160
    $configValue = Add-StatusRow -Parent $summarySection -LabelText (U "\u914d\u7f6e\u72b6\u6001") -Y 188

    $oauthButton = New-NativeButton -Text (U "\u5207\u6362\u81f3 OAuth") -Location (New-Object System.Drawing.Point(18, 222)) -Size (New-Object System.Drawing.Size(124, 36)) -Primary
    $cpamcButton = New-NativeButton -Text (U "\u5207\u6362\u81f3 API") -Location (New-Object System.Drawing.Point(154, 222)) -Size (New-Object System.Drawing.Size(132, 36))
    $summarySection.Controls.AddRange(@($oauthButton, $cpamcButton))

    $saveSettingsButton = New-NativeButton -Text (U "\u4fdd\u5b58\u8bbe\u7f6e") -Location (New-Object System.Drawing.Point(810, 42)) -Size (New-Object System.Drawing.Size(120, 34)) -Primary
    $form.Controls.Add($saveSettingsButton)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = U "\u5c31\u7eea"
    [void]$statusStrip.Items.Add($statusLabel)
    $form.Controls.Add($statusStrip)

    $operationButtons = @($backupButton, $restoreButton, $refreshButton, $simulateButton, $oauthButton, $cpamcButton, $saveSettingsButton, $openaiRow.Button, $cpamcRow.Button, $chatBackupSaveRow.Button, $restoreBackupPathRow.Button)

    function Save-UiSettings {
        $settings.officialConfigPath = $openaiRow.TextBox.Text.Trim()
        $settings.cpamcConfigPath = $cpamcRow.TextBox.Text.Trim()
        $settings.codexHome = $Script:DefaultCodexHome
        if ([string]::IsNullOrWhiteSpace($settings.backupRoot)) { $settings.backupRoot = $Script:DefaultBackupRoot }
        $settings.chatBackupDirectory = $chatBackupSaveRow.TextBox.Text.Trim()
        $settings.chatRestoreBackupPath = $restoreBackupPathRow.TextBox.Text.Trim()
        $settings.chatRestoreTargetPath = $Script:DefaultCodexHome
        if ([string]::IsNullOrWhiteSpace($settings.chatBackupDirectory)) { $settings.chatBackupDirectory = Get-ChatHistoryBackupRootFromBackupRoot $settings.backupRoot }
        $chatBackupSaveRow.TextBox.Text = $settings.chatBackupDirectory
        Save-SwitcherSettings $settings
        Ensure-SwitcherDirs (Get-AppRootFromBackupRoot $settings.backupRoot)
    }

    function Refresh-UiStatus {
        $readiness = Test-ToolReadiness -Settings $settings
        $provider = Get-CodexProvider $settings.codexHome
        $authMode = Get-CodexAuthMode $settings.codexHome
        $modeValue.Text = Get-FriendlyModeName $provider
        $authValue.Text = Get-FriendlyAuthName $authMode
        $configValue.Text = $(if ($readiness.OfficialConfigExists -and $readiness.CPAMCConfigExists) { U "\u6b63\u5e38" } else { U "\u9700\u68c0\u67e5" })
    }

    function Refresh-BackupList {
        $backupList.Items.Clear()
        $root = $chatBackupSaveRow.TextBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($root)) {
            $root = Get-ChatHistoryBackupRootFromBackupRoot $settings.backupRoot
            $chatBackupSaveRow.TextBox.Text = $root
        }
        if (-not (Test-Path -LiteralPath $root)) {
            $summaryBox.Text = (U "\u5c1a\u672a\u627e\u5230\u5907\u4efd\u76ee\u5f55\uff1a") + [Environment]::NewLine + $root
            return
        }
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) {
            $manifestPath = Join-Path $dir.FullName "manifest.json"
            if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $item = New-Object System.Windows.Forms.ListViewItem($dir.Name)
                [void]$item.SubItems.Add($dir.LastWriteTime.ToString("yyyy-MM-dd HH:mm"))
                [void]$item.SubItems.Add(([string]@($manifest.entries).Count))
                $item.Tag = $dir.FullName
                [void]$backupList.Items.Add($item)
            } catch {
                Write-OCLog "Invalid backup manifest: $manifestPath" $_.Exception
            }
        }
        if ($backupList.Items.Count -eq 0) {
            $summaryBox.Text = U "\u6682\u65e0\u53ef\u7528\u5907\u4efd\u3002"
        }
    }

    function Update-BackupSummaryFromPath($Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $summaryBox.Text = U "\u8bf7\u9009\u62e9\u8981\u6062\u590d\u7684\u5907\u4efd\u76ee\u5f55\u3002"
            return
        }
        try {
            $manifest = Get-CodexChatHistoryBackupManifest -BackupPath $Path
            $summaryBox.Text = @(
                (U "\u5907\u4efd\u76ee\u5f55\uff1a")
                $Path
                ""
                ((U "\u521b\u5efa\u65f6\u95f4\uff1a") + " $($manifest.created_at)")
                ((U "\u6765\u6e90\u76ee\u5f55\uff1a") + " $($manifest.source_codex_home)")
                ((U "\u5305\u542b\u9879\u76ee\uff1a") + " $(@($manifest.entries).Count)")
            ) -join [Environment]::NewLine
        } catch {
            $summaryBox.Text = $_.Exception.Message
        }
    }

    function Update-BackupSummary {
        if ($backupList.SelectedItems.Count -eq 0) {
            $summaryBox.Text = U "\u8bf7\u5728\u5de6\u4fa7\u9009\u62e9\u4e00\u4e2a\u5907\u4efd\uff0c\u6216\u5728\u201c\u6062\u590d\u5907\u4efd\u6570\u636e\u4f4d\u7f6e\u201d\u4e2d\u9009\u62e9\u3002"
            return
        }
        $path = [string]$backupList.SelectedItems[0].Tag
        $restoreBackupPathRow.TextBox.Text = $path
        Update-BackupSummaryFromPath $path
    }

    function Select-PathForRow($row) {
        if ($row.Kind -eq "file") {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title = $row.Label.Text
            $dialog.Filter = "config.toml|config.toml|TOML files (*.toml)|*.toml|All files (*.*)|*.*"
            $dialog.FileName = "config.toml"
            if (-not [string]::IsNullOrWhiteSpace($row.TextBox.Text)) {
                $folder = Split-Path -Parent $row.TextBox.Text
                if (Test-Path -LiteralPath $folder) { $dialog.InitialDirectory = $folder }
            }
            try {
                if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $row.TextBox.Text = $dialog.FileName }
            } finally { $dialog.Dispose() }
        } else {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = $row.Label.Text
            $dialog.ShowNewFolderButton = $true
            if (-not [string]::IsNullOrWhiteSpace($row.TextBox.Text) -and (Test-Path -LiteralPath $row.TextBox.Text)) { $dialog.SelectedPath = $row.TextBox.Text }
            try {
                if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $row.TextBox.Text = $dialog.SelectedPath }
            } finally { $dialog.Dispose() }
        }
        Save-UiSettings
        Refresh-UiStatus
        Refresh-BackupList
    }

    function Get-SelectedBackupPath {
        $typedPath = $restoreBackupPathRow.TextBox.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($typedPath)) {
            try {
                [void](Get-CodexChatHistoryBackupManifest -BackupPath $typedPath)
                return $typedPath
            } catch {
                Show-ClearMessage -Owner $form -Message ((U "\u6062\u590d\u5907\u4efd\u76ee\u5f55\u65e0\u6548\uff1a") + [Environment]::NewLine + $_.Exception.Message) -Error
                return $null
            }
        }
        if ($backupList.SelectedItems.Count -eq 0) {
            Show-ClearMessage -Owner $form -Message (U "\u8bf7\u5148\u9009\u62e9\u201c\u6062\u590d\u5907\u4efd\u6570\u636e\u4f4d\u7f6e\u201d\uff0c\u6216\u5728\u5907\u4efd\u5217\u8868\u4e2d\u9009\u62e9\u4e00\u4e2a\u5907\u4efd\u3002") -Error
            return $null
        }
        return [string]$backupList.SelectedItems[0].Tag
    }

    function Select-ChatRestoreBackupFolder {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = U "\u9009\u62e9\u8981\u6062\u590d\u7684\u804a\u5929\u5907\u4efd\u76ee\u5f55"
        $dialog.ShowNewFolderButton = $false
        $seed = $restoreBackupPathRow.TextBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($seed)) { $seed = $chatBackupSaveRow.TextBox.Text.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($seed) -and (Test-Path -LiteralPath $seed)) { $dialog.SelectedPath = $seed }
        try {
            if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $restoreBackupPathRow.TextBox.Text = $dialog.SelectedPath
                Save-UiSettings
                Update-BackupSummaryFromPath $dialog.SelectedPath
                return $dialog.SelectedPath
            }
        } finally {
            $dialog.Dispose()
        }
        return $null
    }

    $openaiRow.Button.Add_Click({ Select-PathForRow $openaiRow })
    $cpamcRow.Button.Add_Click({ Select-PathForRow $cpamcRow })
    $chatBackupSaveRow.Button.Add_Click({ Select-PathForRow $chatBackupSaveRow })
    $restoreBackupPathRow.Button.Add_Click({ Select-ChatRestoreBackupFolder })
    $backupList.Add_SelectedIndexChanged({ Update-BackupSummary })

    $saveSettingsButton.Add_Click({
        try {
            Save-UiSettings
            Refresh-UiStatus
            Refresh-BackupList
            Show-ClearMessage -Owner $form -Message (U "\u8bbe\u7f6e\u5df2\u4fdd\u5b58")
        } catch {
            Write-OCLog (U "\u4fdd\u5b58\u8bbe\u7f6e\u5931\u8d25") $_.Exception
            Show-ClearMessage -Owner $form -Message $_.Exception.Message -Error
        }
    })

    $refreshButton.Add_Click({ Refresh-BackupList; $statusLabel.Text = U "\u5c31\u7eea" })

    $simulateButton.Add_Click({
        $selected = Get-SelectedBackupPath
        if (-not $selected) { return }
        try {
            $manifest = Get-CodexChatHistoryBackupManifest -BackupPath $selected
            Show-ClearMessage -Owner $form -Message ((U "\u6a21\u62df\u6062\u590d\u901a\u8fc7\uff0c\u5c06\u6062\u590d\u9879\u76ee\uff1a") + " $(@($manifest.entries).Count)")
        } catch {
            Write-OCLog (U "\u6a21\u62df\u6062\u590d\u5931\u8d25") $_.Exception
            Show-ClearMessage -Owner $form -Message $_.Exception.Message -Error
        }
    })

    $backupButton.Add_Click({
        try {
            Save-UiSettings
            $backupDirectory = $settings.chatBackupDirectory
            if ([string]::IsNullOrWhiteSpace($backupDirectory)) {
                Show-ClearMessage -Owner $form -Message (U "\u8bf7\u5148\u5728\u201c\u804a\u5929\u5907\u4efd\u4fdd\u5b58\u5230\u201d\u4e2d\u9009\u62e9\u4fdd\u5b58\u76ee\u5f55\u3002") -Error
                return
            }
            Set-UiBusy -Controls $operationButtons -StatusLabel $statusLabel -Busy $true -Text (U "\u6b63\u5728\u5907\u4efd\u2026")
            $form.UseWaitCursor = $true
            [System.Windows.Forms.Application]::DoEvents()
            Write-OCLog (U "\u6b63\u5728\u5907\u4efd\u2026")
            $codexHome = $Script:DefaultCodexHome
            $backupRoot = $settings.backupRoot
            $result = New-CodexChatHistoryBackup -CodexHome $codexHome -BackupRoot $backupRoot -BackupDirectory $backupDirectory
            $summaryBox.Text = Format-ChatHistoryBackupResult $result
            Refresh-BackupList
            Write-OCLog (U "\u804a\u5929\u8bb0\u5f55\u5907\u4efd\u5df2\u5b8c\u6210")
            Show-ClearMessage -Owner $form -Message (U "\u804a\u5929\u8bb0\u5f55\u5907\u4efd\u5df2\u5b8c\u6210")
        } catch {
            Write-OCLog (U "\u804a\u5929\u8bb0\u5f55\u5907\u4efd\u5931\u8d25") $_.Exception
            Show-ClearMessage -Owner $form -Message $_.Exception.Message -Error
        } finally {
            $form.UseWaitCursor = $false
            Set-UiBusy -Controls $operationButtons -StatusLabel $statusLabel -Busy $false -Text (U "\u5c31\u7eea")
        }
    })

    $restoreButton.Add_Click({
        try {
            Save-UiSettings
            $backupPath = Get-SelectedBackupPath
            if (-not $backupPath) { return }
            $restoreTarget = $Script:DefaultCodexHome
            if ([string]::IsNullOrWhiteSpace($restoreTarget)) { return }
            $confirm = [System.Windows.Forms.MessageBox]::Show($form, ((U "\u6062\u590d\u4f1a\u66ff\u6362\u5f53\u524d\u7528\u6237 .codex \u91cc\u7684\u672c\u5730\u804a\u5929\u8bb0\u5f55\uff0c\u5e76\u5148\u521b\u5efa\u6062\u590d\u524d\u5907\u4efd\u3002\u7ee7\u7eed\uff1f") + [Environment]::NewLine + [Environment]::NewLine + $restoreTarget), $Script:Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            Set-UiBusy -Controls $operationButtons -StatusLabel $statusLabel -Busy $true -Text (U "\u6b63\u5728\u6062\u590d\u2026")
            $form.UseWaitCursor = $true
            [System.Windows.Forms.Application]::DoEvents()
            Write-OCLog (U "\u6b63\u5728\u6062\u590d\u2026")
            $backupRoot = $settings.backupRoot
            $result = Restore-CodexChatHistoryBackup -BackupPath $backupPath -CodexHome $restoreTarget -BackupRoot $backupRoot
            $summaryBox.Text = Format-ChatHistoryRestoreResult $result
            Write-OCLog (U "\u804a\u5929\u8bb0\u5f55\u5df2\u6062\u590d")
            Show-ClearMessage -Owner $form -Message (U "\u804a\u5929\u8bb0\u5f55\u5df2\u6062\u590d")
        } catch {
            Write-OCLog (U "\u804a\u5929\u8bb0\u5f55\u6062\u590d\u5931\u8d25") $_.Exception
            Show-ClearMessage -Owner $form -Message $_.Exception.Message -Error
        } finally {
            $form.UseWaitCursor = $false
            Set-UiBusy -Controls $operationButtons -StatusLabel $statusLabel -Busy $false -Text (U "\u5c31\u7eea")
        }
    })

    $oauthButton.Add_Click({
        try {
            Save-UiSettings
            Set-UiBusy -Controls $operationButtons -StatusLabel $statusLabel -Busy $true -Text (U "\u6b63\u5728\u5207\u6362\u81f3 OAuth\u2026")
            $form.UseWaitCursor = $true
            [System.Windows.Forms.Application]::DoEvents()
            Write-OCLog (U "\u6b63\u5728\u5207\u6362\u81f3 OAuth\u2026")
            $codexHome = $Script:DefaultCodexHome
            $officialConfigPath = $settings.officialConfigPath
            $cpamcConfigPath = $settings.cpamcConfigPath
            $appRoot = Get-AppRootFromBackupRoot $settings.backupRoot
            $historyRoot = Get-HistoryBackupRootFromBackupRoot $settings.backupRoot
            $result = Switch-CodexProfileMode -Target OAuth -CodexHome $codexHome -OfficialConfigPath $officialConfigPath -CPAMCConfigPath $cpamcConfigPath -AppRoot $appRoot -HistoryBackupRoot $historyRoot
            Refresh-UiStatus
            $summaryBox.Text = Format-SwitchResult $result
            Write-OCLog (U "\u5df2\u5207\u6362\u81f3 OAuth")
            Show-ClearMessage -Owner $form -Message (U "\u5df2\u5207\u6362\u81f3 OAuth")
        } catch {
            Write-OCLog (U "\u5207\u6362\u81f3 OAuth \u5931\u8d25") $_.Exception
            Show-ClearMessage -Owner $form -Message $_.Exception.Message -Error
        } finally {
            $form.UseWaitCursor = $false
            Set-UiBusy -Controls $operationButtons -StatusLabel $statusLabel -Busy $false -Text (U "\u5c31\u7eea")
        }
    })

    $cpamcButton.Add_Click({
        try {
            Save-UiSettings
            Set-UiBusy -Controls $operationButtons -StatusLabel $statusLabel -Busy $true -Text (U "\u6b63\u5728\u5207\u6362\u81f3 API\u2026")
            $form.UseWaitCursor = $true
            [System.Windows.Forms.Application]::DoEvents()
            Write-OCLog (U "\u6b63\u5728\u5207\u6362\u81f3 API\u2026")
            $codexHome = $Script:DefaultCodexHome
            $officialConfigPath = $settings.officialConfigPath
            $cpamcConfigPath = $settings.cpamcConfigPath
            $appRoot = Get-AppRootFromBackupRoot $settings.backupRoot
            $historyRoot = Get-HistoryBackupRootFromBackupRoot $settings.backupRoot
            $result = Switch-CodexProfileMode -Target CPAMC -CodexHome $codexHome -OfficialConfigPath $officialConfigPath -CPAMCConfigPath $cpamcConfigPath -AppRoot $appRoot -HistoryBackupRoot $historyRoot
            Refresh-UiStatus
            $summaryBox.Text = Format-SwitchResult $result
            Write-OCLog ((U "\u5df2\u5207\u6362\u81f3") + " $(Get-FriendlyModeName $result.TargetProvider)")
            Show-ClearMessage -Owner $form -Message ((U "\u5df2\u5207\u6362\u81f3") + " $(Get-FriendlyModeName $result.TargetProvider)")
        } catch {
            Write-OCLog (U "\u5207\u6362\u81f3 API \u5931\u8d25") $_.Exception
            Show-ClearMessage -Owner $form -Message $_.Exception.Message -Error
        } finally {
            $form.UseWaitCursor = $false
            Set-UiBusy -Controls $operationButtons -StatusLabel $statusLabel -Busy $false -Text (U "\u5c31\u7eea")
        }
    })

    Refresh-UiStatus
    Refresh-BackupList
    [void]$form.ShowDialog()
}

if (-not $NoUi) {
    try {
        Show-UnifiedForm
    } catch {
        Write-OCLog "UI startup failed" $_.Exception
        throw
    }
}
