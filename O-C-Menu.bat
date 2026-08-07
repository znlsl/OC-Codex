@echo off
chcp 65001 >nul
set "ROOT_DIR=%~dp0"
set "SCRIPT=%ROOT_DIR%Source_Codes\tools\CodexUnifiedSwitcher.ps1"

:menu
cls
echo O-C 备用菜单
echo.
echo 1. 启动图形界面
echo 2. 创建聊天记录备份
echo 3. 恢复聊天记录备份
echo 4. 切换至 OAuth
echo 5. 切换至 CPAMC
echo 6. 打开日志目录
echo 0. 退出
echo.
set /p choice=请选择:

if "%choice%"=="1" goto gui
if "%choice%"=="2" goto backup
if "%choice%"=="3" goto restore
if "%choice%"=="4" goto oauth
if "%choice%"=="5" goto cpamc
if "%choice%"=="6" goto logs
if "%choice%"=="0" exit /b 0
goto menu

:gui
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
pause
goto menu

:backup
set /p codexHome=Codex 数据目录，直接回车使用默认:
set /p backupDir=备份保存目录:
if "%backupDir%"=="" goto menu
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%SCRIPT%' -NoUi; $codex='%codexHome%'; if([string]::IsNullOrWhiteSpace($codex)){ $codex=Join-Path $env:USERPROFILE '.codex' }; $r=New-CodexChatHistoryBackup -CodexHome $codex -BackupDirectory '%backupDir%'; Format-ChatHistoryBackupResult $r"
pause
goto menu

:restore
set /p backupPath=聊天记录备份目录:
set /p restoreHome=恢复到 Codex 数据目录，直接回车使用默认:
if "%backupPath%"=="" goto menu
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%SCRIPT%' -NoUi; $home='%restoreHome%'; if([string]::IsNullOrWhiteSpace($home)){ $home=Join-Path $env:USERPROFILE '.codex' }; $r=Restore-CodexChatHistoryBackup -BackupPath '%backupPath%' -CodexHome $home; Format-ChatHistoryRestoreResult $r"
pause
goto menu

:oauth
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%SCRIPT%' -NoUi; $s=Load-SwitcherSettings; $r=Switch-CodexProfileMode -Target OAuth -CodexHome $s.codexHome -OfficialConfigPath $s.officialConfigPath -CPAMCConfigPath $s.cpamcConfigPath -AppRoot (Get-AppRootFromBackupRoot $s.backupRoot) -HistoryBackupRoot (Get-HistoryBackupRootFromBackupRoot $s.backupRoot); Format-SwitchResult $r"
pause
goto menu

:cpamc
powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%SCRIPT%' -NoUi; $s=Load-SwitcherSettings; $r=Switch-CodexProfileMode -Target CPAMC -CodexHome $s.codexHome -OfficialConfigPath $s.officialConfigPath -CPAMCConfigPath $s.cpamcConfigPath -AppRoot (Get-AppRootFromBackupRoot $s.backupRoot) -HistoryBackupRoot (Get-HistoryBackupRootFromBackupRoot $s.backupRoot); Format-SwitchResult $r"
pause
goto menu

:logs
if not exist "%APPDATA%\C-O\logs" mkdir "%APPDATA%\C-O\logs" >nul 2>nul
start "" "%APPDATA%\C-O\logs"
goto menu
