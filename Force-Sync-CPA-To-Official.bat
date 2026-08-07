@echo off
setlocal

set "SCRIPT=%~dp0Source_Codes\tools\ForceSyncCPAHistoryToOfficialAfterExit.ps1"

if not exist "%SCRIPT%" (
  echo Cannot find helper script:
  echo %SCRIPT%
  pause
  exit /b 1
)

echo This script will sync CPA history into official mode.
echo Please close Codex completely before continuing.
echo It will NOT wait in the background and will NOT run while Codex is open.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "ERR=%ERRORLEVEL%"
echo.
if not "%ERR%"=="0" (
  echo Sync failed. Check:
  echo %~dp0local-repair-backups\forced-official-sync\latest-status.json
  echo %~dp0local-repair-backups\forced-official-sync\latest-log.txt
  pause
  exit /b %ERR%
)

echo Sync finished. You can reopen Codex now.
pause
