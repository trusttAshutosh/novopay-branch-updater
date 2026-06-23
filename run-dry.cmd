@echo off
title Novopay Branch Updater (Dry Run)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Update-Novopay-Branches.ps1" -DryRun %*
echo.
pause
