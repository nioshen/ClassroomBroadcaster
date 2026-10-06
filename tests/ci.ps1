# ClassroomBroadcaster 自動化測試（GitHub Actions windows-latest，Windows PowerShell 5.1，系統管理員）
# 先執行 build.ps1 產生完整版，再跑這個腳本。結果寫到 tests\out\（results.json、截圖、紀錄檔）
$ErrorActionPreference = 'Stop'
$env:CB_NONINTERACTIVE = '1'
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'scripts\common.ps1')
. (Join-Path $Root 'scripts\obs.ps1')
$Out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$results = [ordered]@{}

function Record([string]$name, [string]$status, [string]$detail = '') {
    $results[$name] = [ordered]@{ status = $status; detail = $detail }
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$status]
    Write-Host "[$status] $name $detail" -ForegroundColor $color
}
function Wait-Until([scriptblock]$cond, [int]$sec) {
    $d = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $d) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}
function Get-MtxPath([string]$name) {
    try { return (Invoke-RestMethod -Uri 'http://127.0.0.1:9997/v3/paths/list' -TimeoutSec 2 -UseBasicParsing).items | Where-Object { $_.name -eq $name } }
    catch { return $null }
}
function Invoke-E2E([string]$mode, [string]$channel) {
    $p = Start-Process -FilePath 'node' -ArgumentList 'e2e.mjs', $mode, $channel -WorkingDirectory $PSScriptRoot -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $Out "$mode-$channel.log") -RedirectStandardError (Join-Path $Out "$mode-$channel.err")
    $json = Join-Path $Out "$mode-$channel.json"
    $r = if (Test-Path $json) { Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    return @{ ok = ($p.ExitCode -eq 0); result = $r }
}
function Save-Screenshot([string]$name) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
        $bmp.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
    } catch { Write-Host "截圖失敗：$($_.Exception.Message)" }
}
function Start-Script([string]$script, [string]$logName) {
    return Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root "scripts\$script")`"" `
        -RedirectStandardOutput (Join-Path $Out "$logName.log") -RedirectStandardError (Join-Path $Out "$logName.err")
}

# ---------------------------------------------------------------- 1. 語法
$parseErrors = @()
foreach ($f in Get-ChildItem (Join-Path $Root 'scripts') -Filter *.ps1) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    foreach ($e in $errs) { $parseErrors += "$($f.Name):$($e.Extent.StartLineNumber) $($e.Message)" }
}
if ($parseErrors.Count) { Record 'PowerShell 5.1 語法檢查' FAIL ($parseErrors -join '; ') } else { Record 'PowerShell 5.1 語法檢查' PASS }

# ---------------------------------------------------------------- 2. 設定檔讀寫
$backup = [IO.File]::ReadAllBytes($SettingsFile)
try {
    Set-Setting 'MainServerIP' "'10.0.0.5'"
    Set-Setting 'PublisherIPs' "@('10.0.0.6')"
    $s = Get-Settings
    if ($s.MainServerIP -eq '10.0.0.5' -and $s.PublisherIPs[0] -eq '10.0.0.6') { Record '設定檔讀寫' PASS } else { Record '設定檔讀寫' FAIL "讀回 $($s.MainServerIP)" }
} catch { Record '設定檔讀寫' FAIL $_.Exception.Message }
finally { [IO.File]::WriteAllBytes($SettingsFile, $backup) }

# ---------------------------------------------------------------- 3. 簡易版伺服器編譯（.NET Framework 內建 C# 編譯器）
try {
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $Root 'lite\relay.cs'))) -Language CSharp -IgnoreWarnings
    Record '簡易版伺服器編譯（C# 5）' PASS
} catch { Record '簡易版伺服器編譯（C# 5）' FAIL $_.Exception.Message }

# ---------------------------------------------------------------- 4. OBS 版完整流程（start.ps1）
$env:CB_RUN_SECONDS = '300'
$proc = Start-Script 'start.ps1' 'start'
$up = Wait-Until { (Test-Port 8080) -and (Test-Port 8889) } 90
if ($up) { Record 'OBS 版：啟動 MediaMTX 與播放頁' PASS } else { Record 'OBS 版：啟動 MediaMTX 與播放頁' FAIL '90 秒內沒有啟動（見 start.log）' }

if ($up) {
    $fw = Get-NetFirewallRule -DisplayName 'ClassroomBroadcaster TCP' -ErrorAction SilentlyContinue
    if ($fw) { Record 'OBS 版：防火牆規則' PASS } else { Record 'OBS 版：防火牆規則' FAIL }
    $lnk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) '教室直播 開始.lnk'
    if (Test-Path $lnk) { Record 'OBS 版：桌面捷徑' PASS } else { Record 'OBS 版：桌面捷徑' WARN '找不到捷徑' }

    $online = Wait-Until { $x = Get-MtxPath 'teacher1'; $x -and ($x.online -or $x.ready) } 120
    Start-Sleep -Seconds 3
    Save-Screenshot 'desktop-obs'
    if ($online) {
        Record 'OBS 版：OBS 自動開始直播（WHIP）' PASS
        foreach ($ch in 'chrome', 'msedge') {
            $r = Invoke-E2E 'whep' $ch
            if ($r.ok) { Record "OBS 版：學生播放 OBS 畫面（$ch）" PASS } else { Record "OBS 版：學生播放 OBS 畫面（$ch）" FAIL "見 whep-$ch.json" }
        }
    } else {
        Record 'OBS 版：OBS 自動開始直播（WHIP）' WARN '雲端測試機可能沒有顯示卡／桌面，改用瀏覽器推流測試伺服器與播放頁'
    }
    # 不論 OBS 是否成功，都另外用瀏覽器推流測試 MediaMTX + 播放頁（先關 OBS，避免兩邊搶同一個頻道）
    Get-Process obs64 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    foreach ($ch in 'chrome', 'msedge') {
        $r = Invoke-E2E 'whip' $ch
        if ($r.ok) { Record "OBS 版：瀏覽器推流＋學生播放（$ch）" PASS } else { Record "OBS 版：瀏覽器推流＋學生播放（$ch）" FAIL "見 whip-$ch.json" }
    }
}
$cfgRoot = Join-Path $Root 'obs\config\obs-studio'
if (Test-Path "$cfgRoot\logs") { Copy-Item "$cfgRoot\logs\*" $Out -ErrorAction SilentlyContinue }
foreach ($f in 'basic\profiles\Classroom\basic.ini', 'basic\profiles\Classroom\service.json', 'basic\scenes\Classroom.json', 'user.ini') {
    if (Test-Path "$cfgRoot\$f") { Copy-Item "$cfgRoot\$f" (Join-Path $Out ('obs-' + ($f -replace '[\\]', '_'))) }
}
if (Test-Path (Join-Path $Root 'logs\mediamtx.log')) { Copy-Item (Join-Path $Root 'logs\mediamtx.log') $Out }
& (Join-Path $Root 'scripts\stop.ps1') -Quiet
Get-Process obs64 -ErrorAction SilentlyContinue | Stop-Process -Force
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# ---------------------------------------------------------------- 5. 簡易版完整流程（lite-start.ps1）
$env:CB_RUN_SECONDS = '240'
$proc = Start-Script 'lite-start.ps1' 'lite-start'
if (Wait-Until { Test-Port 8080 } 60) {
    Record '簡易版：啟動伺服器' PASS
    foreach ($ch in 'msedge', 'chrome') {
        $r = Invoke-E2E 'lite' $ch
        $codec = if ($r.result -and $r.result.teacher) { $r.result.teacher.codec } else { '?' }
        if ($r.ok) { Record "簡易版：教師推流＋學生播放（$ch）" PASS "編碼 $codec" } else { Record "簡易版：教師推流＋學生播放（$ch）" FAIL "編碼 $codec，見 lite-$ch.json" }
    }
} else { Record '簡易版：啟動伺服器' FAIL '60 秒內沒有啟動（見 lite-start.log）' }
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*edge-teacher*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- 結果
$results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Out 'results.json') -Encoding UTF8
$md = @('| 測試項目 | 結果 | 說明 |', '|---|---|---|')
foreach ($k in $results.Keys) { $md += "| $k | $($results[$k].status) | $($results[$k].detail) |" }
$md | Set-Content (Join-Path $Out 'summary.md') -Encoding UTF8
if ($env:GITHUB_STEP_SUMMARY) { $md | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding UTF8 }
$failed = @($results.Values | Where-Object { $_.status -eq 'FAIL' }).Count
Write-Host "`n失敗項目：$failed"
exit ([int]($failed -gt 0))
