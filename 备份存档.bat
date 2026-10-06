@echo off
chcp 65001 >nul
title 冒险王 - 备份存档
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup_save.ps1"

echo.
echo Press any key to close this window.
pause >nul
