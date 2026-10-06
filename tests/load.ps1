# 負載測試：N 個連線同時觀看 S 秒，記錄伺服器 CPU 使用率與總流量（結果寫到 tests\out\load-<模式>.json / load-<模式>-cpu.json）
#   .\tests\load.ps1 -Mode lite   簡易版：需先啟動 lite-start.ps1（或其他方式啟動的簡易版伺服器）
#   .\tests\load.ps1 -Mode whep   OBS 版：需先啟動 start.ps1，且 OBS 正在直播到 teacher1
#   -Screen（簡易版）教師端擷取這台電腦的真實螢幕，而不是測試圖樣
param([ValidateSet('lite', 'whep')][string]$Mode = 'lite', [int]$Viewers = 60, [int]$Seconds = 60, [switch]$Screen)
$ErrorActionPreference = 'Stop'
$Out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Get-ServerBytes {
    try {
        if ($Mode -eq 'lite') {
            $s = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/api/status' -TimeoutSec 2 -UseBasicParsing
            return [double](($s.rooms | Measure-Object -Property bytesOut -Sum).Sum)
        }
        $l = Invoke-RestMethod -Uri 'http://127.0.0.1:9997/v3/paths/list' -TimeoutSec 2 -UseBasicParsing
        $sum = 0
        foreach ($i in $l.items) { if ($null -ne $i.outboundBytes) { $sum += [double]$i.outboundBytes } elseif ($i.bytesSent) { $sum += [double]$i.bytesSent } }
        return $sum
    } catch { return $null }
}

# 伺服器行程：簡易版 = 監聽 8080 的行程（PowerShell）；OBS 版 = mediamtx.exe
$port = if ($Mode -eq 'lite') { 8080 } else { 8889 }
$srvPid = (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
if (-not $srvPid) { throw "找不到監聽埠 $port 的伺服器，請先啟動直播系統。" }
$srv = Get-Process -Id $srvPid
$cores = [Environment]::ProcessorCount
Write-Host "伺服器行程：$($srv.ProcessName) ($srvPid)，邏輯處理器 $cores 個"

$node = Start-Process -FilePath 'node' -ArgumentList (@('load.mjs', $Mode, $Viewers, $Seconds) + @(if ($Screen) { '--screen' })) -WorkingDirectory $PSScriptRoot `
    -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $Out "load-$Mode.log") -RedirectStandardError (Join-Path $Out "load-$Mode.err")
$null = $node.Handle   # 保留行程控制代碼，結束後才讀得到 ExitCode

# 等連線建立（node 先開瀏覽器、建立連線），再開始量測
Start-Sleep -Seconds 8
$samples = @()
$b0 = Get-ServerBytes; $t0 = Get-Date
$cpu0 = $srv.TotalProcessorTime; $tc0 = Get-Date
$measure = [Math]::Max(10, $Seconds - 12)
for ($i = 0; $i -lt $measure -and -not $node.HasExited; $i++) {
    Start-Sleep -Seconds 1
    # 效能計數器名稱會依系統語言翻譯，改用 CIM（名稱固定）
    $total = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
    $srv.Refresh()
    $now = Get-Date
    $proc = ($srv.TotalProcessorTime - $cpu0).TotalSeconds / ($now - $tc0).TotalSeconds / $cores * 100
    $cpu0 = $srv.TotalProcessorTime; $tc0 = $now
    $samples += [ordered]@{ t = $i + 1; systemCpu = [Math]::Round($total, 1); serverCpu = [Math]::Round($proc, 2) }
}
$b1 = Get-ServerBytes; $t1 = Get-Date
$node.WaitForExit()

$sec = ($t1 - $t0).TotalSeconds
$srvCpu = @($samples | ForEach-Object { $_.serverCpu })
$sysCpu = @($samples | ForEach-Object { $_.systemCpu })
$summary = [ordered]@{
    mode = $Mode; viewers = $Viewers; seconds = $Seconds; logicalCpus = $cores; server = "$($srv.ProcessName) ($srvPid)"
    serverCpuAvg = [Math]::Round(($srvCpu | Measure-Object -Average).Average, 2)
    serverCpuMax = [Math]::Round(($srvCpu | Measure-Object -Maximum).Maximum, 2)
    systemCpuAvg = [Math]::Round(($sysCpu | Measure-Object -Average).Average, 1)
    systemCpuMax = [Math]::Round(($sysCpu | Measure-Object -Maximum).Maximum, 1)
    serverBytes = if ($null -ne $b0 -and $null -ne $b1) { $b1 - $b0 } else { $null }
    serverMbps = if ($null -ne $b0 -and $null -ne $b1) { [Math]::Round(($b1 - $b0) * 8 / $sec / 1e6, 1) } else { $null }
    nodeExit = $node.ExitCode
    samples = $samples
}
$summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Out "load-$Mode-cpu.json") -Encoding UTF8
Get-Content (Join-Path $Out "load-$Mode.log") -Encoding UTF8
$summary.Remove('samples')
[pscustomobject]$summary | Format-List
exit $node.ExitCode
