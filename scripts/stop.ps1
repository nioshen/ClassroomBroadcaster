# ClassroomBroadcaster 關閉：MediaMTX、播放頁伺服器（以及可選的 OBS）
param([switch]$Quiet, [switch]$KeepOBS)

$ErrorActionPreference = 'SilentlyContinue'
$Base = Split-Path $PSScriptRoot -Parent
$S = Import-PowerShellDataFile (Join-Path $Base 'settings.psd1')
$MtxExe = Join-Path $Base 'mediamtx.exe'
$PidFile = Join-Path $Base 'run\pids.json'

function Say($msg) { if (-not $Quiet) { Write-Host $msg } }

# 0. 先關掉主教師機的狀態視窗（start.ps1），否則它會把下面關掉的 MediaMTX／播放頁伺服器自動重新啟動
#    （start.ps1 自己呼叫 stop.ps1 時是同一個行程，用 $PID 排除）
$StartPs1 = Join-Path $Base 'scripts\start.ps1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($StartPs1, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                   $_.CommandLine -notlike '*publisher*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 1. 依紀錄的 PID 關閉
if (Test-Path $PidFile) {
    $ids = Get-Content $PidFile -Raw | ConvertFrom-Json
    foreach ($id in @($ids.mediamtx, $ids.web)) { if ($id) { Stop-Process -Id $id -Force } }
    Remove-Item $PidFile -Force
}

# 2. 保險：關掉本資料夾的 mediamtx.exe 與 serve.ps1
Get-Process mediamtx | Where-Object { $_.Path -ieq $MtxExe } | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*serve.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 3. 視設定關閉 OBS（正常關閉，讓 OBS 自己停止直播）
if (-not $KeepOBS -and $S.StopOBSOnExit) {
    Get-Process obs64 | ForEach-Object { [void]$_.CloseMainWindow() }
}

Say '教室直播系統已關閉。'
