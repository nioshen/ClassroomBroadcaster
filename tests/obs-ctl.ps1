# 測試用：關閉／重新開啟資料夾內的 OBS（recover.mjs 呼叫）
#   obs-ctl.ps1 kill   強制結束 OBS（模擬當機或直接關機）
#   obs-ctl.ps1 start  用 start.ps1 相同的方式重新開啟 OBS 並開始直播
param([ValidateSet('kill', 'start')][string]$Action)
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'scripts\common.ps1')
. (Join-Path $Root 'scripts\obs.ps1')
if ($Action -eq 'kill') {
    Get-Process obs64 -ErrorAction SilentlyContinue | Stop-Process -Force
    exit 0
}
$S = Get-Settings
$obs = Get-ObsPath $S
Ensure-ObsConfig $obs 'http://127.0.0.1:8889/teacher1/whip'
Start-Obs $S $obs
