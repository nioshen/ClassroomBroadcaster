# ClassroomBroadcaster 共用函式（Windows 10 / 11，Windows PowerShell 5.1）
$Base = Split-Path $PSScriptRoot -Parent
$SettingsFile = Join-Path $Base 'settings.psd1'
$MtxExe = Join-Path $Base 'mediamtx.exe'
$BundledObs = Join-Path $Base 'obs\bin\64bit\obs64.exe'

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

# 自動化測試（GitHub Actions）時設定 CB_NONINTERACTIVE=1：不等待按鍵、問題一律用預設答案
$NonInteractive = [bool]$env:CB_NONINTERACTIVE

function Fail($msg) {
    Say "`n[錯誤] $msg" Red
    if (-not $NonInteractive) { Read-Host '按 Enter 關閉' }
    exit 1
}

function Get-Settings { Import-PowerShellDataFile $SettingsFile }

# 修改 settings.psd1 中的一行：  Key = 值
function Set-Setting([string]$Key, [string]$ValueLiteral) {
    $text = [IO.File]::ReadAllText($SettingsFile, [Text.Encoding]::UTF8)
    $pattern = "(?m)^([ \t]*)$Key(\s*)=.*?(\r?)$"
    if ($text -notmatch $pattern) { throw "settings.psd1 找不到設定 $Key" }
    $eval = { param($m) "$($m.Groups[1].Value)$Key$($m.Groups[2].Value)= $ValueLiteral$($m.Groups[3].Value)" }.GetNewClosure()
    $text = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]$eval)
    [IO.File]::WriteAllText($SettingsFile, $text, (New-Object Text.UTF8Encoding $true))
}

# 下載檔案、從網路解壓縮的檔案解除封鎖（避免 SmartScreen/執行原則擋住）
function Unblock-All { Get-ChildItem -Path $Base -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue }

function Get-LanIP {
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Select-Object -First 1
    if ($cfg) { return @($cfg.IPv4Address)[0].IPAddress }
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and
            $_.InterfaceAlias -notmatch 'vEthernet|VirtualBox|VMware|Loopback|Bluetooth|Tailscale|ZeroTier'
        } | Select-Object -First 1
    if ($ip) { return $ip.IPAddress }
    return $null
}

# 找 OBS：settings 指定路徑 → 登錄檔 → 預設安裝位置
function Get-ObsPath($S) {
    if ($S -and $S.ObsPath -and $S.ObsPath -ne 'auto' -and (Test-Path $S.ObsPath)) { return $S.ObsPath }
    if (Test-Path $BundledObs) { return $BundledObs }
    foreach ($key in 'HKLM:\SOFTWARE\OBS Studio', 'HKLM:\SOFTWARE\WOW6432Node\OBS Studio') {
        $dir = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).'(default)'
        if ($dir) {
            $exe = Join-Path $dir 'bin\64bit\obs64.exe'
            if (Test-Path $exe) { return $exe }
        }
    }
    foreach ($dir in "$env:ProgramFiles\obs-studio", "${env:ProgramFiles(x86)}\obs-studio") {
        $exe = Join-Path $dir 'bin\64bit\obs64.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

# 不開視窗啟動程式（避免 Windows 11 預設終端機另開分頁或視窗）
function Start-Hidden([string]$File, [string]$Arguments, [string]$WorkDir) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($psi)
}

function Test-Port([int]$port) {
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); return $true }
    catch { return $false }
}

function Set-FirewallRules([int]$HttpPort) {
    $rules = @(
        @{ Name = 'ClassroomBroadcaster TCP'; Protocol = 'TCP'; Ports = @("$HttpPort", '8889', '8888') },
        @{ Name = 'ClassroomBroadcaster UDP'; Protocol = 'UDP'; Ports = @('8189') }
    )
    foreach ($r in $rules) {
        Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow -Profile Any `
            -Protocol $r.Protocol -LocalPort $r.Ports | Out-Null
    }
    if (Test-Path $MtxExe) {
        # 若曾在 Windows 安全性提示按了「取消」會留下封鎖規則（封鎖優先於允許），一併清掉
        Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
            Where-Object { $_.Program -ieq $MtxExe } |
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Action -eq 'Block' } | Remove-NetFirewallRule
        Get-NetFirewallRule -DisplayName 'ClassroomBroadcaster MediaMTX' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName 'ClassroomBroadcaster MediaMTX' -Direction Inbound -Action Allow `
            -Profile Any -Program $MtxExe | Out-Null
    }
}

function Write-StudentShortcuts([string]$Url) {
    $deploy = Join-Path $Base 'deploy'
    New-Item -ItemType Directory -Force -Path $deploy | Out-Null
    $ascii = [Text.Encoding]::ASCII
    [IO.File]::WriteAllText((Join-Path $deploy '教室直播.url'), "[InternetShortcut]`r`nURL=$Url`r`n", $ascii)
    [IO.File]::WriteAllText((Join-Path $deploy '教室直播-教師2.url'), "[InternetShortcut]`r`nURL=${Url}?t=teacher2`r`n", $ascii)
    [IO.File]::WriteAllText((Join-Path $deploy 'student-url.txt'), "$Url`r`n", $ascii)
}

function Ask-YesNo([string]$q, [bool]$default = $true) {
    if ($NonInteractive) { return $default }
    $hint = if ($default) { '(Y/n)' } else { '(y/N)' }
    $a = Read-Host "$q $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a -match '^[yY]'
}

function Read-IPv4([string]$q) {
    while ($true) {
        $a = (Read-Host $q).Trim()
        $ip = $null
        if ([Net.IPAddress]::TryParse($a, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork') { return $a }
        Say '  格式不正確，請輸入像 192.168.10.100 的 IP。' Yellow
    }
}

function Write-NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Test-Remote([string]$ip, [int]$port, [int]$ms = 2000) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($ip, $port, $null, $null)
        return ($ar.AsyncWaitHandle.WaitOne($ms) -and $c.Connected)
    } catch { return $false } finally { $c.Close() }
}

# 第二教師機：取得主教師機 IP（第一次會詢問並存到 settings.psd1），並確認連得上
function Get-MainServerIP($S, [int]$port) {
    $main = $S.MainServerIP
    while ($true) {
        if (-not $main) {
            $main = Read-IPv4 '請輸入主教師機的 IP（主教師機狀態視窗上會顯示）'
            Set-Setting 'MainServerIP' "'$main'"
        }
        Say "檢查主教師機 $main …"
        if (Test-Remote $main $port) { return $main }
        Say "連不到主教師機 ${main}:$port。請確認主教師機已經點「教室直播 開始」。" Yellow
        $a = Read-Host '按 Enter 重試、輸入 C 更改 IP、輸入 S 略過'
        if ($a -match '^[cC]') { $main = '' }
        elseif ($a -match '^[sS]') { return $main }
    }
}

function Get-EdgePath {
    $cands = @()
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe') {
        $v = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(default)'
        if ($v) { $cands += $v.Trim('"') }
    }
    $cands += "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
              "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
              "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
              "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# 建立桌面捷徑（已存在就略過）。$AllUsers 需要系統管理員權限
function New-DesktopShortcut([string]$Name, [string]$Target, [string]$Icon, [switch]$AllUsers) {
    try {
        $desk = if ($AllUsers) { [Environment]::GetFolderPath('CommonDesktopDirectory') } else { [Environment]::GetFolderPath('Desktop') }
        $path = Join-Path $desk "$Name.lnk"
        if (Test-Path $path) { return }
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($path)
        $lnk.TargetPath = $Target
        $lnk.WorkingDirectory = $Base
        if ($Icon) { $lnk.IconLocation = $Icon }
        $lnk.Save()
        Say "已在桌面建立捷徑：$Name" Green
    } catch { }
}

# 由 mediamtx.yml 產生執行用設定（填入本機 IP 與允許推流的 IP）
function New-MtxRuntimeConfig($S, [string]$ServerIP, [string]$OutPath) {
    $extra = @($S.PublisherIPs | Where-Object { $_ } | ForEach-Object { "'$_'" })
    $pub = @("'127.0.0.1'", "'::1'") + $extra
    # teacher2：有設定 PublisherIPs 就只允許那些 IP，否則允許區網內任何電腦推流到 teacher2
    $t2 = if ($extra.Count) { '[' + ($extra -join ', ') + ']' } else { '[]' }
    $yml = [IO.File]::ReadAllText((Join-Path $Base 'mediamtx.yml'), [Text.Encoding]::UTF8)
    $yml = $yml -replace '(?m)^(\s*)ips:.*# AUTO-PUBLISHERS\s*$', ('${1}ips: [' + ($pub -join ', ') + '] # AUTO-PUBLISHERS')
    $yml = $yml -replace '(?m)^(\s*)ips:.*# AUTO-TEACHER2\s*$', ('${1}ips: ' + $t2 + ' # AUTO-TEACHER2')
    $yml = $yml -replace '(?m)^webrtcAdditionalHosts:.*$', "webrtcAdditionalHosts: ['$ServerIP'] # AUTO-HOST"
    New-Item -ItemType Directory -Force -Path (Split-Path $OutPath) | Out-Null
    Write-NoBom $OutPath $yml
}
