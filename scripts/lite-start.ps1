# ClassroomBroadcaster 簡易版（純瀏覽器，不需 OBS / MediaMTX）主教師機啟動
# 只用 Windows 內建的 PowerShell 5.1 與 Microsoft Edge；第一次會要求一次系統管理員權限設定防火牆
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
Set-Location $Base
$Host.UI.RawUI.WindowTitle = 'ClassroomBroadcaster 教室直播（簡易版）'

$S = Get-Settings
$Port = [int]$S.HttpPort
$Www = Join-Path $Base 'lite\www'
Unblock-All

# ---------- 1. 防火牆（只有第一次需要系統管理員權限） ----------
function Test-LiteFirewall {
    $r = Get-NetFirewallRule -DisplayName 'ClassroomBroadcaster Lite' -ErrorAction SilentlyContinue
    if (-not $r) { return $false }
    $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    return (@($pf.LocalPort) -contains "$Port")
}
if (-not (Test-LiteFirewall)) {
    Say '第一次使用：設定 Windows 防火牆，讓學生電腦可以連線。' Yellow
    Say '接下來會跳出「使用者帳戶控制」視窗，請按「是」。' Yellow
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -Wait `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\lite-admin.ps1`" -Port $Port"
    } catch { }
    if (Test-LiteFirewall) { Say '防火牆設定完成。' Green }
    else { Say '防火牆沒有設定成功：本機可以使用，但學生電腦可能連不上。下次啟動會再試一次。' Red }
}

# ---------- 2. 啟動直播伺服器 ----------
if (Test-Port $Port) {
    Fail "埠 $Port 已被使用。可能已經開了另一個直播程式（OBS 版或簡易版），請先關閉它；`n或在 settings.psd1 修改 HttpPort。"
}
$ServerIP = Select-LanIP $S   # 多張網卡時會讓老師選擇
if (-not $ServerIP) { $ServerIP = '127.0.0.1'; Say '偵測不到區網 IP，請在 settings.psd1 的 ServerIP 填入本機 IP。' Yellow }
$StudentUrl = "http://${ServerIP}:$Port/"

if (-not ('ClassroomLite.Server' -as [type])) {
    Say '載入直播伺服器…'
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $Base 'lite\relay.cs'))) -Language CSharp -IgnoreWarnings
}
$extra = @($S.PublisherIPs | Where-Object { $_ })
# teacher2：有設定 PublisherIPs 就只允許那些 IP，否則區網內任何電腦都可以推流到 teacher2
$rooms = if ($extra.Count) { 'teacher1,teacher2' } else { 'teacher1,teacher2*' }
try {
    [ClassroomLite.Server]::Start($Port, $Www, $rooms, ($extra -join ','), $StudentUrl)
} catch {
    Fail "直播伺服器啟動失敗：$($_.Exception.InnerException.Message)$($_.Exception.Message)"
}
Write-StudentShortcuts $StudentUrl
New-DesktopShortcut '教室直播（簡易版）' (Join-Path $Base 'lite-start.bat') "$env:SystemRoot\System32\imageres.dll,1"

# ---------- 3. 開啟教師端頁面 ----------
$edge = Get-EdgePath
$teacherUrl = "http://localhost:$Port/teacher.html"
if ($edge) {
    $profileDir = Join-Path $env:LOCALAPPDATA 'ClassroomBroadcaster\edge-teacher'
    Start-Process -FilePath $edge -ArgumentList @(
        "--app=$teacherUrl", "--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check',
        '--window-size=820,960')
} else {
    Start-Process $teacherUrl
}

# ---------- 4. 狀態面板 ----------
$lastOut = $null; $lastTime = $null
# 自動化測試用：CB_RUN_SECONDS 秒後自動結束
$RunUntil = if ($env:CB_RUN_SECONDS) { (Get-Date).AddSeconds([int]$env:CB_RUN_SECONDS) } else { $null }
try {
    while ($true) {
        Stay-Awake
        $st = $null
        try { $st = [ClassroomLite.Server]::StatusJson() | ConvertFrom-Json } catch {}
        try { Clear-Host } catch { }
        Say '========= ClassroomBroadcaster 教室直播（簡易版）=========' Cyan
        Say "  學生觀看網址：$StudentUrl" Green
        Say "  教師 2 網址：  ${StudentUrl}?t=teacher2"
        Say "  教師端頁面：  $teacherUrl（不小心關掉可以重新開這個網址）"
        Say '------------------------------------------------------'
        $totalOut = 0
        foreach ($r in @($st.rooms)) {
            if (-not $r) { continue }
            $totalOut += [double]$r.bytesOut
            $state = if ($r.online) { '● 直播中' } else { '○ 未開播' }
            $color = if ($r.online) { 'Green' } else { 'DarkGray' }
            $from = if ($r.online -and $r.publisher -and $r.publisher -ne '127.0.0.1' -and $r.publisher -ne '::1') { "（來自 $($r.publisher)）" } else { '' }
            Say ("  {0,-9} {1}   觀看人數：{2}{3}" -f $r.name, $state, $r.viewers, $from) $color
        }
        $now = Get-Date
        if ($lastTime -and $totalOut -ge $lastOut) {
            Say ('  目前總輸出流量：{0:N1} Mbps' -f (($totalOut - $lastOut) * 8 / ($now - $lastTime).TotalSeconds / 1e6))
        }
        $lastOut = $totalOut; $lastTime = $now
        Say '------------------------------------------------------'
        Say '  按 Q 結束直播（關閉這個視窗也會結束直播）' Yellow
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
    try { [ClassroomLite.Server]::Stop() } catch {}
}
