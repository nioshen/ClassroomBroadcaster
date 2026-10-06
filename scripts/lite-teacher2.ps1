# ClassroomBroadcaster 簡易版：第二教師機（用瀏覽器把畫面推到主教師機的 teacher2 頻道）
# 不需系統管理員權限、不需安裝任何軟體
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
Set-Location $Base
$Host.UI.RawUI.WindowTitle = 'ClassroomBroadcaster 教室直播（簡易版．教師 2）'
$S = Get-Settings
$Port = [int]$S.HttpPort
Unblock-All

$main = Get-MainServerIP $S $Port
$origin = "http://${main}:$Port"
$edge = Get-EdgePath
if (-not $edge) { Fail '找不到 Microsoft Edge 或 Google Chrome。' }
New-DesktopShortcut '教室直播（簡易版．教師2）' (Join-Path $Base 'lite-teacher2.bat') "$env:SystemRoot\System32\imageres.dll,1"

# 擷取螢幕需要「安全來源」；用獨立的瀏覽器設定檔，只把主教師機這個網址視為安全來源
$profileDir = Join-Path $env:LOCALAPPDATA 'ClassroomBroadcaster\edge-teacher2'
Start-Process -FilePath $edge -ArgumentList @(
    "--app=$origin/teacher.html?room=teacher2", "--user-data-dir=`"$profileDir`"",
    "--unsafely-treat-insecure-origin-as-secure=$origin", '--no-first-run', '--no-default-browser-check',
    '--window-size=820,960')
Say "已開啟教師 2 的直播頁面。學生觀看：$origin/?t=teacher2" Green
Start-Sleep -Seconds 5
