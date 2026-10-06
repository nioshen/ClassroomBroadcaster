@echo off
rem ClassroomBroadcaster - build the full offline package (run once on a PC with internet)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build.ps1"
