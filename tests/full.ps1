# 完整驗證（以系統管理員身分執行一次）：ci.ps1 → OBS 版延遲／60 人負載／OBS 重開恢復 → 簡易版延遲／60 人負載／重新分享恢復
# 結果寫到 tests\out\（full-summary.json、各項 .json、截圖）。執行期間螢幕會出現測試用的瀏覽器視窗，請不要操作滑鼠鍵盤。
param([int]$Viewers = 60, [int]$Seconds = 60, [switch]$SkipCI)
$ErrorActionPreference = 'Stop'
trap { ("{0} {1}" -f (Get-Date -Format s), ($_ | Out-String)) | Add-Content (Join-Path $PSScriptRoot 'out\full-error.txt') -Encoding UTF8; break }
$env:CB_NONINTERACTIVE = '1'
$Root = Split-Path $PSScriptRoot -Parent
$Out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
# 同時只能跑一份（兩份會搶同一個埠與 OBS，結果互相干擾）
$Lock = Join-Path $Out 'full.lock'
if (Test-Path $Lock) {
    $old = 0; [void][int]::TryParse((Get-Content $Lock -Raw).Trim(), [ref]$old)
    if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) { Write-Host '另一份完整測試正在執行，這份不執行。' -ForegroundColor Yellow; Start-Sleep 5; exit 2 }
}
Set-Content $Lock $PID -Encoding ASCII
try { Start-Transcript -Path (Join-Path $Out ('full-' + (Get-Date -Format 'HHmmss') + '.log')) | Out-Null } catch { Write-Host "無法記錄 transcript：$($_.Exception.Message)" }
. (Join-Path $Root 'scripts\common.ps1')
$summary = [ordered]@{}
Get-Process obs64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue   # 上一輪留下的 OBS

function Wait-Until([scriptblock]$cond, [int]$sec) {
    $d = (Get-Date).AddSeconds($sec)
    while ((Get-Date) -lt $d) { if (& $cond) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}
function Start-Script([string]$script, [string]$logName) {
    return Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root "scripts\$script")`"" `
        -RedirectStandardOutput (Join-Path $Out "$logName.log") -RedirectStandardError (Join-Path $Out "$logName.err")
}
function Invoke-Node([string]$name, [string[]]$nodeArgs) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    $p = Start-Process -FilePath 'node' -ArgumentList $nodeArgs -WorkingDirectory $PSScriptRoot -NoNewWindow -PassThru `
        -RedirectStandardOutput (Join-Path $Out "$name.log") -RedirectStandardError (Join-Path $Out "$name.err")
    $null = $p.Handle; $p.WaitForExit()
    Get-Content (Join-Path $Out "$name.log") -Encoding UTF8 | Select-Object -First 30
    $summary[$name] = if ($p.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
}
function Invoke-Load([string]$mode, [switch]$Screen) {
    Write-Host "`n=== load-$mode ===" -ForegroundColor Cyan
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'load.ps1')`"", '-Mode', $mode, '-Viewers', $Viewers, '-Seconds', $Seconds)
    if ($Screen) { $a += '-Screen' }
    $p = Start-Process powershell.exe -ArgumentList $a -NoNewWindow -PassThru
    $null = $p.Handle; $p.WaitForExit()
    $summary["load-$mode"] = if ($p.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
}

# 上一輪留下的伺服器還佔著 8080 時，測試會連到舊的伺服器，結果不可信
foreach ($port in 8080, 8889) {
    if (-not (Wait-Until { -not (Test-Port $port) } 90)) { throw "埠 $port 仍被其他程式佔用（可能是上一輪測試留下的），請關閉後再執行。" }
}
# ---------------------------------------------------------------- 1. ci.ps1
if (-not $SkipCI) {
    Write-Host '=== ci.ps1 ===' -ForegroundColor Cyan
    $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'ci.ps1')`"" -NoNewWindow -PassThru
    $null = $p.Handle; $p.WaitForExit()   # 不用 -Wait：它會連 OBS 等子孫行程一起等
    $summary['ci'] = if ($p.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
}

# ---------------------------------------------------------------- 2. OBS 版
$env:CB_RUN_SECONDS = '900'
$proc = Start-Script 'start.ps1' 'full-start'
$online = Wait-Until {
    try { $x = (Invoke-RestMethod 'http://127.0.0.1:9997/v3/paths/list' -TimeoutSec 2 -UseBasicParsing).items | Where-Object { $_.name -eq 'teacher1' }; $x -and $x.ready } catch { $false }
} 120
$summary['OBS 自動開播'] = if ($online) { 'PASS' } else { 'FAIL' }
if ($online) {
    Start-Sleep -Seconds 3
    Invoke-Node 'latency-whep' @('latency.mjs', 'whep', '15')
    Invoke-Load 'whep'
    Invoke-Node 'recover-whep' @('recover.mjs', 'whep')
    Start-Sleep -Seconds 5
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $Out 'desktop-obs-after-restart.png'), [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
$cfgLogs = Join-Path $Root 'obs\config\obs-studio\logs'
if (Test-Path $cfgLogs) { Get-ChildItem $cfgLogs | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { Copy-Item $_.FullName (Join-Path $Out ('full-obs-' + $_.Name)) } }
& (Join-Path $Root 'scripts\stop.ps1') -Quiet
Get-Process obs64 -ErrorAction SilentlyContinue | Stop-Process -Force
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

# ---------------------------------------------------------------- 3. 簡易版
$proc = Start-Script 'lite-start.ps1' 'full-lite-start'
if (Wait-Until { Test-Port 8080 } 60) {
    Start-Sleep -Seconds 3
    Invoke-Node 'latency-lite' @('latency.mjs', 'lite', '15')
    Invoke-Load 'lite' -Screen
    Invoke-Node 'recover-lite' @('recover.mjs', 'lite')
} else { $summary['簡易版啟動'] = 'FAIL' }
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*edge-teacher*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$summary | ConvertTo-Json | Set-Content (Join-Path $Out 'full-summary.json') -Encoding UTF8
Write-Host "`n=== 結果 ===" -ForegroundColor Cyan
$summary.GetEnumerator() | ForEach-Object { Write-Host ("{0,-16} {1}" -f $_.Key, $_.Value) }
try { Stop-Transcript | Out-Null } catch { }
Remove-Item $Lock -Force -ErrorAction SilentlyContinue
Set-Content (Join-Path $Out 'full.done') (Get-Date -Format s) -Encoding ASCII
