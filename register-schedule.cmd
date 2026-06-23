@echo off
title Register Novopay Branch Updater Schedule
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Register-Novopay-BranchUpdater-Schedule.ps1"
echo.
pause
