@echo off
chcp 65001 >nul
set "ROOT_DIR=%~dp0"
set "SCRIPT=%ROOT_DIR%Source_Codes\tools\CodexUnifiedSwitcher.ps1"
set "LOG_DIR=%APPDATA%\C-O\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>nul
set "LOG_FILE=%LOG_DIR%\debug-launch.log"

echo O-C 调试启动
echo 日志文件: %LOG_FILE%
echo.
echo [%date% %time%] Debug launch started.>>"%LOG_FILE%"

if not exist "%SCRIPT%" (
  echo 找不到主脚本: %SCRIPT%
  echo [%date% %time%] Missing script: %SCRIPT%>>"%LOG_FILE%"
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -NoExit -Command "try { Start-Transcript -Path '%LOG_FILE%' -Append | Out-Null; & '%SCRIPT%'; } catch { Write-Host $_.Exception.Message -ForegroundColor Red; Add-Content -LiteralPath '%LOG_FILE%' -Value $_.Exception.ToString(); } finally { try { Stop-Transcript | Out-Null } catch {} }"
