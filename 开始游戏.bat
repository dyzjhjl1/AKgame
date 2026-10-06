@echo off
chcp 65001 >nul
title Adventure King - Offline
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1"

if errorlevel 1 (
    echo.
    echo [!] First attempt failed - retrying with an alternative method...
    echo.
    powershell -NoProfile -Command "iex (Get-Content -Raw '%~dp0serve.ps1')"
)

echo.
echo Server stopped. Press any key to close.
pause >nul
