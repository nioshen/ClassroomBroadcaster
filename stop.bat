@echo off
rem ClassroomBroadcaster - stop all services (auto elevates to Administrator)
cd /d "%~dp0"
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\stop.ps1"
timeout /t 3 >nul
