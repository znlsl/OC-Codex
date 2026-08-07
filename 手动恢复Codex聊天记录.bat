@echo off
chcp 65001 >nul
setlocal
title Manual Restore Codex Chat
cd /d "%~dp0"

echo.
echo Manual Restore Codex Chat History
echo.
echo This script will close Codex and restore chat history from:
echo Desktop\backup-folder\codex bak\20260708-172606-codex-chat-history
echo.
echo Current .codex data will be backed up first.
echo A black window will stay open so you can read errors.
echo.
pause

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manual-Restore-Codex-Chat.ps1"

echo.
echo Script finished.
pause
