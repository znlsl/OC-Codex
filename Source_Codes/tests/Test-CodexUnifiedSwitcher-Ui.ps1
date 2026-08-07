$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
$source = Get-Content -LiteralPath $scriptPath -Raw

$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    throw "CodexUnifiedSwitcher.ps1 has syntax errors: $($errors[0].Message)"
}

function Assert-Contains($needle, $label) {
    if (-not $source.Contains($needle)) {
        throw "Missing expected ${label}: $needle"
    }
}

function Assert-Before($first, $second, $label) {
    $firstIndex = $source.IndexOf($first)
    $secondIndex = $source.IndexOf($second)
    if ($firstIndex -lt 0 -or $secondIndex -lt 0 -or $firstIndex -gt $secondIndex) {
        throw "Expected order for ${label}: $first before $second"
    }
}

Assert-Contains "function Get-DefaultSettingsPath" "app settings path helper"
Assert-Contains "function Get-AppRootFromBackupRoot" "app root from backup root helper"
Assert-Contains "function Get-HistoryBackupRootFromBackupRoot" "history root from backup root helper"
Assert-Contains "function Get-ChatHistoryBackupRootFromBackupRoot" "chat history backup root helper"
Assert-Contains "function New-CodexChatHistoryBackup" "chat history backup helper"
Assert-Contains "function Restore-CodexChatHistoryBackup" "chat history restore helper"
Assert-Contains "function Select-ChatRestoreBackupFolder" "chat restore backup picker"
Assert-Contains "function Write-OCLog" "log writer helper"
Assert-Contains "function Set-UiBusy" "busy state helper"
Assert-Contains "function Refresh-BackupList" "backup list refresh helper"
Assert-Contains "function Update-BackupSummary" "backup summary helper"
Assert-Contains "function Show-ClearMessage" "clear message box helper"
Assert-Contains "function New-NativeSection" "native section helper"
Assert-Contains "function Add-PathRow" "native path row helper"
Assert-Contains "function Add-StatusRow" "status row helper"

Assert-Contains "NativeBackupUiV1" "native backup UI marker"
Assert-Contains "FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle" "normal fixed Windows frame"
Assert-Contains "[System.Drawing.Color]::FromArgb(245, 247, 250)" "light gray window background"
Assert-Contains "[System.Drawing.Color]::FromArgb(16, 94, 72)" "deep green primary button"
Assert-Contains "[System.Drawing.Color]::FromArgb(17, 24, 39)" "clear dark title color"
Assert-Contains "StatusStrip" "bottom status strip"
Assert-Contains "ToolStripStatusLabel" "bottom status text"
Assert-Contains "ListView" "backup list"
Assert-Contains "Details" "details list view mode"
Assert-Contains "System.Drawing.Size(980, 700)" "native tool window size"

Assert-Contains "\u004f\u002d\u0043 \u0043\u006f\u0064\u0065\u0078 \u5de5\u5177\u7bb1" "main title text"
Assert-Contains "\u5907\u4efd\u548c\u6062\u590d\u5f53\u524d\u7528\u6237 .codex \u804a\u5929\u6570\u636e\uff0c\u914d\u7f6e\u5207\u6362\u4fdd\u6301\u7b80\u5355\u3002" "subtitle text"
Assert-Contains "\u004f\u0070\u0065\u006e\u0041\u0049 \u914d\u7f6e" "OpenAI config row label"
Assert-Contains "\u0041\u0050\u0049 \u914d\u7f6e" "API config row label"
Assert-Contains "\u804a\u5929\u8bb0\u5f55\u8def\u5f84" "chat history paths section"
Assert-Contains "\u804a\u5929\u5907\u4efd\u4fdd\u5b58\u5230" "chat backup save path row label"
Assert-Contains "\u6062\u590d\u5907\u4efd\u6570\u636e\u4f4d\u7f6e" "restore backup data path row label"
Assert-Contains "\u9ed8\u8ba4\u8bfb\u53d6\u5e76\u6062\u590d\u5230\u5f53\u524d\u7528\u6237 .codex" "default codex home explanation"
Assert-Contains "\u9009\u62e9" "select button text"
Assert-Contains "\u5f00\u59cb\u5907\u4efd" "start backup button text"
Assert-Contains "\u6062\u590d\u9009\u4e2d\u7684\u5907\u4efd" "restore selected backup button text"
Assert-Contains "\u5237\u65b0\u5217\u8868" "refresh list button text"
Assert-Contains "\u6a21\u62df\u6062\u590d" "simulate restore button text"
Assert-Contains "\u5207\u6362\u81f3 OAuth" "OAuth switch text"
Assert-Contains "\u5207\u6362\u81f3 API" "API switch text"
Assert-Contains "\u5907\u4efd\u5217\u8868" "backup list title"
Assert-Contains "\u5907\u4efd\u6458\u8981" "backup summary title"
Assert-Contains "\u5c31\u7eea" "ready status"
Assert-Contains "\u6b63\u5728\u5907\u4efd" "backup progress status"
Assert-Contains "\u6b63\u5728\u6062\u590d" "restore progress status"
Assert-Contains "\u64cd\u4f5c\u5b8c\u6210" "success message text"
Assert-Contains "\u64cd\u4f5c\u5931\u8d25" "failure message text"

Assert-Contains "Write-OCLog" "operation logging"
Assert-Contains '[System.Windows.Forms.MessageBox]::Show([string]$Message, $title' "old-style direct message box"

Assert-Contains "Invoke-HistoryProviderSync -TargetProvider `$currentProvider" "pre-switch provider sync"
Assert-Contains "Invoke-HistoryProviderSync -TargetProvider `$targetProvider" "post-switch provider sync"
Assert-Contains "New-CodexChatHistoryBackup -CodexHome `$codexHome -BackupRoot `$backupRoot -BackupDirectory `$backupDirectory" "chat backup uses selected save path synchronously"
Assert-Contains "Restore-CodexChatHistoryBackup -BackupPath `$backupPath -CodexHome `$restoreTarget -BackupRoot `$backupRoot" "chat restore uses selected source and target paths synchronously"
Assert-Contains '$codexHome = $Script:DefaultCodexHome' "chat backup defaults to current user codex data"
Assert-Contains '$restoreTarget = $Script:DefaultCodexHome' "chat restore defaults to current user codex data"
Assert-Contains "Format-ChatHistoryBackupResult `$result" "chat backup formats result directly"
Assert-Contains "Show-ClearMessage -Owner `$form -Message (U `"\u804a\u5929\u8bb0\u5f55\u5907\u4efd\u5df2\u5b8c\u6210`")" "chat backup direct completion popup"
Assert-Contains "Show-ClearMessage -Owner `$form -Message (U `"\u804a\u5929\u8bb0\u5f55\u5df2\u6062\u590d`")" "chat restore direct completion popup"
Assert-Contains "Switch-CodexProfileMode -Target OAuth -CodexHome `$codexHome -OfficialConfigPath `$officialConfigPath -CPAMCConfigPath `$cpamcConfigPath -AppRoot `$appRoot -HistoryBackupRoot `$historyRoot" "OAuth switch runs synchronously"
Assert-Contains "Switch-CodexProfileMode -Target CPAMC -CodexHome `$codexHome -OfficialConfigPath `$officialConfigPath -CPAMCConfigPath `$cpamcConfigPath -AppRoot `$appRoot -HistoryBackupRoot `$historyRoot" "CPAMC switch runs synchronously"
Assert-Contains "Format-SwitchResult `$result" "mode switch formats result directly"
Assert-Contains "Show-ClearMessage -Owner `$form -Message (U `"\u5df2\u5207\u6362\u81f3 OAuth`")" "OAuth direct completion popup"
Assert-Contains "Show-ClearMessage -Owner `$form -Message ((U `"\u5df2\u5207\u6362\u81f3`") + `" `$(Get-FriendlyModeName `$result.TargetProvider)`")" "API direct completion popup"

foreach ($forbidden in @(
    'FormBorderStyle = "None"',
    "Enable-GlassBackdrop `$form",
    "Set-RoundedRegion `$form",
    "AcrylicSidebarUiV1",
    "AcrylicBackplateUiV1",
    "New-GlassPanel",
    "New-GlassButton",
    "New-GlassTextBox",
    "New-SidebarButton",
    "RoundedTextBoxControl",
    "function Select-ChatHistoryBackupDestinationFolder",
    "function Select-ChatHistoryRestoreTargetFolder",
    "BeginInvoke",
    "Start-Job",
    "Wait-Job",
    "Receive-Job",
    "Run-UiOperation",
    "Receive-Job -Job `$job -ErrorAction Stop",
    '$codexRow = Add-PathRow',
    '$backupRootRow = Add-PathRow',
    '$restoreTargetRow = Add-PathRow',
    "\u0043\u006f\u0064\u0065\u0078 \u6570\u636e\u76ee\u5f55",
    "\u5207\u6362\u5907\u4efd\u76ee\u5f55",
    "\u6062\u590d\u5230 Codex \u6570\u636e\u76ee\u5f55",
    "\u9009\u62e9\u5907\u4efd\u4fdd\u5b58\u4f4d\u7f6e",
    "[System.Drawing.Color]::FromArgb(12, 24, 18)",
    "[System.Drawing.Color]::FromArgb(22, 34, 27)",
    '$brand = New-GlassLabel -Text "C-O"'
)) {
    if ($source.Contains($forbidden)) {
        throw "Native UI should no longer contain old glass shell marker: $forbidden"
    }
}

Write-Host "Codex unified switcher native UI checks passed."
