@echo off
title Novopay Branch Updater
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Update-Novopay-Branches.ps1"
if errorlevel 1 (
    echo.
    echo Script exited with an error.
    pause
)
