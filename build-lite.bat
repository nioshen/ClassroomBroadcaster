@echo off
rem ClassroomBroadcaster - package the Lite version only (no internet needed)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build.ps1" -LiteOnly
