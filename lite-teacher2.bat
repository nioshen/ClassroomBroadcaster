@echo off
rem ClassroomBroadcaster Lite (browser only, no OBS / MediaMTX needed)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\lite-teacher2.ps1"
