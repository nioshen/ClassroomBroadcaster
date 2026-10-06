# ClassroomBroadcaster 一鍵啟動（OBS + MediaMTX 版；由 start.bat / teacher2.bat 以系統管理員身分呼叫）
param([ValidateSet('server', 'publisher')][string]$Role = 'server')
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'obs.ps1')
$ErrorActionPreference = 'Stop'
Set-Location $Base
$Host.UI.RawUI.WindowTitle = 'ClassroomBroadcaster 教室直播'

$S = Get-Settings
Unblock-All

# ======================================================================
# 第二教師機：只開 OBS 推流
# ======================================================================
if ($Role -eq 'publisher') {
    $obs = Get-ObsPath $S
    if (-not $obs) { Fail '找不到 OBS。請使用完整版資料夾（含 obs 資料夾），或在這台電腦安裝 OBS Studio。' }
    $main = Get-MainServerIP $S 8889
    if (Test-ObsPortable $obs) { Ensure-VCRedist }
    Ensure-ObsConfig $obs "http://${main}:8889/teacher2/whip"
    New-DesktopShortcut '教室直播 開始（教師2）' (Join-Path $Base 'teacher2.bat') "$obs,0" -AllUsers
    if (Get-Process obs64 -ErrorAction SilentlyContinue) {
        Say 'OBS 已在執行中：請在 OBS 按「開始直播」。' Yellow
    } else {
        Say '啟動 OBS 並開始直播…'
        Start-Obs $S $obs
    }
    Say "`n學生觀看教師 2：http://${main}:$($S.HttpPort)/?t=teacher2" Green
    Start-Sleep -Seconds 8
    exit 0
}

# ======================================================================
# 主教師機
# ======================================================================
$MtxYml  = Join-Path $Base 'mediamtx.yml'
$RunDir  = Join-Path $Base 'run'
$LogDir  = Join-Path $Base 'logs'
$Runtime = Join-Path $RunDir 'mediamtx.runtime.yml'
$PidFile = Join-Path $RunDir 'pids.json'
$Paths   = @('teacher1', 'teacher2')

if (-not (Test-Path $MtxExe)) { Fail "找不到 mediamtx.exe。`n請先在有網路的電腦執行一次 build.bat 產生完整版，或改用免安裝的 lite-start.bat（簡易版）。" }
foreach ($d in $RunDir, $LogDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# 1. 先關掉上次沒關乾淨的程式
& (Join-Path $PSScriptRoot 'stop.ps1') -Quiet -KeepOBS

# 簡易版（或其他程式）還佔著網頁埠時，學生會連到那邊而看不到 OBS 畫面，先擋下來
$HttpPort = [int]$S.HttpPort
Start-Sleep -Milliseconds 500
if (Test-Port $HttpPort) {
    Fail "埠 $HttpPort 已被使用。可能簡易版（lite-start.bat）還開著，請先在它的黑色視窗按 Q 關閉；`n或在 settings.psd1 修改 HttpPort。"
}

# 2. IP 與防火牆
$ServerIP = Select-LanIP $S   # 多張網卡時會讓老師選擇
if (-not $ServerIP) { Fail '偵測不到區網 IP，請在 settings.psd1 的 ServerIP 直接填入本機 IP。' }
$StudentUrl = "http://${ServerIP}:$HttpPort/"
Say "伺服器 IP：$ServerIP" Cyan
Say '設定 Windows 防火牆…'
Set-FirewallRules $HttpPort

# 3. 產生執行用設定檔
New-MtxRuntimeConfig $S $ServerIP $Runtime

# 4. 啟動 MediaMTX（背景、不開視窗）
function Start-Mtx {
    $p = Start-Hidden $MtxExe "`"$Runtime`"" $Base
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if ($p.HasExited) { break }
        if (Test-Port 8889) { return $p }
        Start-Sleep -Milliseconds 300
    }
    $log = Join-Path $LogDir 'mediamtx.log'
    $tail = if (Test-Path $log) { (Get-Content $log -Tail 15) -join "`n" } else { '' }
    Fail "MediaMTX 啟動失敗。最近的紀錄：`n$tail"
}
Say '啟動 MediaMTX…'
$mtx = Start-Mtx

# 5. 啟動學生播放頁伺服器（背景、不開視窗）
Say '啟動學生播放頁伺服器…'
$serve = Join-Path $PSScriptRoot 'serve.ps1'
$www = Join-Path $Base 'www'
$web = Start-Hidden "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    "-NoProfile -ExecutionPolicy Bypass -File `"$serve`" -Port $HttpPort -Root `"$www`"" $Base
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 300
    if ($web.HasExited) { break }
    if (Test-Port $HttpPort) { $ok = $true; break }
}
if (-not $ok) { Fail "播放頁伺服器啟動失敗（埠 $HttpPort 可能被其他程式佔用，可在 settings.psd1 改 HttpPort）。" }

function Save-Pids { @{ mediamtx = $mtx.Id; web = $web.Id } | ConvertTo-Json | Set-Content $PidFile -Encoding UTF8 }
Save-Pids
Write-StudentShortcuts $StudentUrl

# 6. 啟動 OBS（第一次會自動建立設定）
New-DesktopShortcut '教室直播 開始' (Join-Path $Base 'start.bat') "$MtxExe,0" -AllUsers
New-DesktopShortcut '教室直播 停止' (Join-Path $Base 'stop.bat') "$env:SystemRoot\System32\shell32.dll,27" -AllUsers
if ($S.StartOBS) {
    $obs = Get-ObsPath $S
    if (Get-Process obs64 -ErrorAction SilentlyContinue) {
        Say 'OBS 已在執行中：請在 OBS 按「開始直播」。' Yellow
    } elseif ($obs) {
        if (Test-ObsPortable $obs) { Ensure-VCRedist }
        Ensure-ObsConfig $obs 'http://127.0.0.1:8889/teacher1/whip'
        Say '啟動 OBS 並開始直播…'
        Start-Obs $S $obs
    } else {
        Say '找不到 OBS，請手動開啟 OBS 並按「開始直播」。' Yellow
    }
}
if ($S.OpenPreview) { Start-Process $StudentUrl }

# 7. 狀態面板
$lastOut = $null; $lastTime = $null
# 自動化測試用：CB_RUN_SECONDS 秒後自動結束
$RunUntil = if ($env:CB_RUN_SECONDS) { (Get-Date).AddSeconds([int]$env:CB_RUN_SECONDS) } else { $null }
try {
    while ($true) {
        Stay-Awake
        if ($mtx.HasExited) {
            Say 'MediaMTX 意外結束，重新啟動中…' Red
            $mtx = Start-Mtx; Save-Pids
        }
        if ($web.HasExited) {
            Say '播放頁伺服器意外結束，重新啟動中…' Red
            $web = Start-Hidden "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                "-NoProfile -ExecutionPolicy Bypass -File `"$serve`" -Port $HttpPort -Root `"$www`"" $Base
            Save-Pids
        }
        $list = $null
        try { $list = Invoke-RestMethod -Uri 'http://127.0.0.1:9997/v3/paths/list' -TimeoutSec 2 -UseBasicParsing } catch {}

        try { Clear-Host } catch { }
        Say '============ ClassroomBroadcaster 教室直播 ============' Cyan
        Say "  學生觀看網址：$StudentUrl" Green
        Say "  教師 2 網址：  ${StudentUrl}?t=teacher2"
        Say "  OBS 推流（本機）：    http://127.0.0.1:8889/teacher1/whip"
        Say "  OBS 推流（教師機 2）：http://${ServerIP}:8889/teacher2/whip"
        Say '------------------------------------------------------'

        $totalOut = 0
        foreach ($name in $Paths) {
            $item = if ($list) { $list.items | Where-Object { $_.name -eq $name } } else { $null }
            $online = $item -and ($item.online -or $item.ready)
            $readers = if ($item) { @($item.readers) } else { @() }
            $rtc = @($readers | Where-Object { $_.type -like 'webRTC*' }).Count
            $other = $readers.Count - $rtc
            if ($item) {
                $o = if ($null -ne $item.outboundBytes) { $item.outboundBytes } else { $item.bytesSent }
                if ($o) { $totalOut += [double]$o }
            }
            $state = if ($online) { '● 直播中' } else { '○ 未開播' }
            $color = if ($online) { 'Green' } else { 'DarkGray' }
            $extra = if ($other -gt 0) { "（另有相容模式 $other）" } else { '' }
            Say ("  {0,-9} {1}   觀看人數：{2}{3}" -f $name, $state, $rtc, $extra) $color
        }
        $now = Get-Date
        if ($lastTime -and $totalOut -ge $lastOut) {
            $mbps = ($totalOut - $lastOut) * 8 / ($now - $lastTime).TotalSeconds / 1e6
            Say ('  目前總輸出流量：{0:N1} Mbps' -f $mbps)
        }
        $lastOut = $totalOut; $lastTime = $now
        if (-not $list) { Say '  （讀不到 MediaMTX 狀態）' Yellow }
        Say '------------------------------------------------------'
        Say '  按 Q 結束直播系統（關閉此視窗不會停止，請用 Q 或 stop.bat）' Yellow

        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 100
            if ($RunUntil -and (Get-Date) -gt $RunUntil) { return }
            try {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Q') { return }
                }
            } catch { }   # 沒有主控台（例如自動化測試）時忽略按鍵
        }
    }
} finally {
    Say "`n正在關閉…" Yellow
    & (Join-Path $PSScriptRoot 'stop.ps1') -Quiet
}
