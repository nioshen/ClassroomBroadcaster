# OBS 相關：自動建立「Classroom」設定檔與場景、檢查 VC++ 執行階段、啟動 OBS
# 需先 dot-source common.ps1

function Test-ObsPortable([string]$Obs) { return $Obs -and ($Obs -ieq $BundledObs) }

function Get-ObsConfigRoot([string]$Obs) {
    if (Test-ObsPortable $Obs) { return (Join-Path $Base 'obs\config\obs-studio') }
    return (Join-Path $env:APPDATA 'obs-studio')
}

# 主螢幕的實際解析度與裝置名稱（例如 \\.\DISPLAY1）；OBS 的「螢幕擷取」用這個名稱指定螢幕
function Get-PrimaryScreen {
    try {
        if (-not ('CB.Dpi' -as [type])) {
            Add-Type -Namespace CB -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
        }
        [void][CB.Dpi]::SetProcessDPIAware()          # 取得未經顯示縮放的真實解析度
        Add-Type -AssemblyName System.Windows.Forms
        $p = [System.Windows.Forms.Screen]::PrimaryScreen
        return @([int]$p.Bounds.Width, [int]$p.Bounds.Height, [string]$p.DeviceName)
    } catch { }
    $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
    if ($vc) { return @([int]$vc.CurrentHorizontalResolution, [int]$vc.CurrentVerticalResolution, '\\.\DISPLAY1') }
    return @(1920, 1080, '\\.\DISPLAY1')
}

function ConvertTo-JsonString([string]$s) { return '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }

# 場景裡的螢幕若是空的或已不存在（換了螢幕、重新接線），改成目前的主螢幕；老師在 OBS 手動選過的螢幕不動
function Update-ObsMonitor([string]$SceneFile) {
    if (-not (Test-Path $SceneFile)) { return }
    $text = [IO.File]::ReadAllText($SceneFile, [Text.Encoding]::UTF8)
    $m = [regex]::Match($text, '"monitor_id"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if (-not $m.Success) { return }
    $cur = $m.Groups[1].Value.Replace('\\', '\')
    $names = @()
    try { Add-Type -AssemblyName System.Windows.Forms; $names = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.DeviceName }) } catch { }
    $isLegacyName = $cur -like '\\.\DISPLAY*'
    if ($cur -and $cur -ne 'DUMMY' -and (-not $isLegacyName -or $names -contains $cur)) { return }
    $primary = (Get-PrimaryScreen)[2]
    $text = $text.Substring(0, $m.Index) + '"monitor_id": ' + (ConvertTo-JsonString $primary) + $text.Substring($m.Index + $m.Length)
    Write-NoBom $SceneFile $text
}

# OBS 31 以後：上次沒有正常關閉（直接關機、強制結束）會在下次啟動時跳出「安全模式」詢問視窗，擋住自動開播
function Clear-ObsSentinel([string]$Obs) {
    $dir = Join-Path (Get-ObsConfigRoot $Obs) '.sentinel'
    if (Test-Path $dir) { Get-ChildItem $dir -Filter 'run_*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
}

# 確認 OBS 有「Classroom」設定檔與場景；沒有就建立，推流網址不同就更新
function Ensure-ObsConfig([string]$Obs, [string]$WhipUrl) {
    $cfgRoot = Get-ObsConfigRoot $Obs
    $basic = Join-Path $cfgRoot 'basic'
    $profDir = Join-Path $basic 'profiles\Classroom'
    $sceneDir = Join-Path $basic 'scenes'
    $sceneFile = Join-Path $sceneDir 'Classroom.json'
    $svcFile = Join-Path $profDir 'service.json'
    $svcJson = '{"type":"whip_custom","settings":{"server":"' + $WhipUrl + '","bearer_token":""}}'

    # 免安裝版：略過第一次執行的設定精靈，預設使用 Classroom
    if (Test-ObsPortable $Obs) {
        New-Item -ItemType Directory -Force -Path $cfgRoot | Out-Null
        $pm = Join-Path $Base 'obs\portable_mode.txt'
        if (-not (Test-Path $pm)) { Set-Content $pm '' -Encoding ASCII }
        foreach ($f in 'global.ini', 'user.ini') {
            $p = Join-Path $cfgRoot $f
            if (-not (Test-Path $p)) {
                Write-NoBom $p ("[General]`r`nFirstRun=true`r`nEnableAutoUpdates=false`r`n`r`n" +
                    "[Basic]`r`nProfile=Classroom`r`nProfileDir=Classroom`r`nSceneCollection=Classroom`r`nSceneCollectionFile=Classroom`r`n`r`n" +
                    "[BasicWindow]`r`nWarnBeforeStartingStream=false`r`nWarnBeforeStoppingStream=false`r`nWarnBeforeStoppingRecord=false`r`n")
            }
        }
    }

    if (-not (Test-Path (Join-Path $profDir 'basic.ini'))) {
        # 解析度：畫布 = 螢幕原生解析度；輸出最高 1080p（文字清楚又省頻寬）
        $size = Get-PrimaryScreen
        $bw = $size[0]; $bh = $size[1]
        if ($bh -gt 1080) { $oh = 1080; $ow = [int]([math]::Round($bw * 1080 / $bh / 2) * 2) }
        else { $ow = $bw - ($bw % 2); $oh = $bh - ($bh % 2) }
        New-Item -ItemType Directory -Force -Path $profDir | Out-Null
        $ini = "[General]`r`nName=Classroom`r`n`r`n" +
               "[Video]`r`nBaseCX=$bw`r`nBaseCY=$bh`r`nOutputCX=$ow`r`nOutputCY=$oh`r`nFPSType=0`r`nFPSCommon=30`r`nScaleType=bicubic`r`n`r`n" +
               "[Output]`r`nMode=Advanced`r`n`r`n" +
               "[AdvOut]`r`nEncoder=obs_x264`r`nAudioEncoder=ffmpeg_opus`r`nTrackIndex=1`r`nApplyServiceSettings=true`r`nTrack1Bitrate=128`r`n`r`n" +
               "[Audio]`r`nSampleRate=48000`r`nChannelSetup=Stereo`r`n"
        Write-NoBom (Join-Path $profDir 'basic.ini') $ini
        # x264 低延遲：CBR 4 Mbps、關鍵影格 1 秒、baseline（無 B 影格）
        Write-NoBom (Join-Path $profDir 'streamEncoder.json') `
            '{"rate_control":"CBR","bitrate":4000,"keyint_sec":1,"preset":"veryfast","profile":"baseline","tune":"zerolatency","x264opts":""}'
        Write-NoBom $svcFile $svcJson
        Say "已建立 OBS 設定檔 Classroom（螢幕 ${bw}×${bh}，輸出 ${ow}×${oh} @30fps）" Green
    } elseif (-not ((Get-Content $svcFile -Raw -ErrorAction SilentlyContinue) -like "*$WhipUrl*")) {
        Write-NoBom $svcFile $svcJson
        Say "已更新 OBS 推流位址：$WhipUrl" Green
    }

    if (-not (Test-Path $sceneFile)) {
        New-Item -ItemType Directory -Force -Path $sceneDir | Out-Null
        $size = Get-PrimaryScreen
        $bw = $size[0]; $bh = $size[1]
        $monJson = ConvertTo-JsonString $size[2]
        $srcId = [guid]::NewGuid().ToString()
        $sceneId = [guid]::NewGuid().ToString()
        $json = @"
{
  "name": "Classroom",
  "current_scene": "教學畫面",
  "current_program_scene": "教學畫面",
  "scene_order": [ { "name": "教學畫面" } ],
  "sources": [
    {
      "id": "monitor_capture", "versioned_id": "monitor_capture",
      "name": "螢幕擷取", "uuid": "$srcId",
      "settings": { "monitor_id": $monJson, "method": 0, "capture_cursor": true },
      "enabled": true, "flags": 0, "mixers": 0, "volume": 1.0, "muted": false,
      "hotkeys": {}, "filters": [], "private_settings": {}
    },
    {
      "id": "scene", "versioned_id": "scene",
      "name": "教學畫面", "uuid": "$sceneId",
      "settings": {
        "id_counter": 1, "custom_size": false,
        "items": [
          {
            "name": "螢幕擷取", "source_uuid": "$srcId", "id": 1,
            "visible": true, "locked": false, "rot": 0.0,
            "pos": { "x": 0.0, "y": 0.0 }, "scale": { "x": 1.0, "y": 1.0 },
            "align": 5, "bounds_type": 2, "bounds_align": 0,
            "bounds": { "x": $($bw).0, "y": $($bh).0 },
            "crop_left": 0, "crop_top": 0, "crop_right": 0, "crop_bottom": 0,
            "private_settings": {}
          }
        ]
      },
      "enabled": true, "flags": 0, "mixers": 0,
      "hotkeys": {}, "filters": [], "private_settings": {}
    }
  ],
  "groups": [],
  "transitions": [],
  "current_transition": "Fade",
  "transition_duration": 300,
  "quick_transitions": [],
  "saved_projectors": [],
  "modules": {},
  "preview_locked": false,
  "scaling_enabled": false
}
"@
        Write-NoBom $sceneFile $json
        Say '已建立 OBS 場景 Classroom（擷取主螢幕）' Green
    } else {
        Update-ObsMonitor $sceneFile
    }
}

# 免安裝版 OBS 需要 Microsoft Visual C++ 2015-2022 執行階段；缺少時用隨附的安裝檔靜默安裝（只做一次）
function Ensure-VCRedist {
    $marker = Join-Path $Base 'run\vcredist.ok'
    if (Test-Path $marker) { return }
    $ok = $false
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64') {
        $v = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($v -and $v.Installed -eq 1 -and $v.Major -ge 14 -and $v.Minor -ge 40) { $ok = $true }
    }
    $exe = Join-Path $Base 'vcredist\vc_redist.x64.exe'
    if (-not $ok -and (Test-Path $exe)) {
        Say '安裝 Microsoft Visual C++ 執行階段（OBS 需要，只需一次）…'
        $p = Start-Process -FilePath $exe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
        if ($p.ExitCode -in 0, 1638, 3010) { $ok = $true } else { Say "VC++ 執行階段安裝回傳代碼 $($p.ExitCode)" Yellow }
    }
    if ($ok) {
        New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
        Set-Content $marker 'ok' -Encoding ASCII
    }
}

function Start-Obs($S, [string]$Obs) {
    Clear-ObsSentinel $Obs
    $obsArgs = @('--startstreaming', '--disable-updater', '--disable-missing-files-check')
    if (Test-ObsPortable $Obs) { $obsArgs += '--portable' }
    if ($S.ObsProfile)    { $obsArgs += @('--profile', "`"$($S.ObsProfile)`"") }
    if ($S.ObsCollection) { $obsArgs += @('--collection', "`"$($S.ObsCollection)`"") }
    Start-Process -FilePath $Obs -ArgumentList $obsArgs -WorkingDirectory (Split-Path $Obs)
}
