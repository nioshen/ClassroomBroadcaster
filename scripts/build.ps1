# ClassroomBroadcaster 完整版打包工具
# 在任何一台「有網路」的 Windows 10 / 11 電腦執行一次（不需系統管理員權限）：
#   下載 MediaMTX、免安裝版 OBS Studio、Visual C++ 執行階段，放進這個資料夾，
#   之後把整個資料夾（或產生的 zip）複製到教師機即可直接使用，不必再下載或安裝。
# 同時會產生只有簡易版的 ClassroomBroadcaster-lite.zip。只要簡易版時用 -LiteOnly（不需網路、不下載任何東西）。
param([switch]$LiteOnly)
. (Join-Path $PSScriptRoot 'common.ps1')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # PowerShell 5.1 顯示下載進度會讓下載慢很多
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# PowerShell 5.1 預設會在 zip 內用「\」當路徑分隔，部分解壓縮工具不認得；改成標準的「/」（必須在載入 ZipFile 前設定）
try { [AppContext]::SetSwitch('Switch.System.IO.Compression.ZipFile.UseBackslash', $false) } catch { }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Host.UI.RawUI.WindowTitle = 'ClassroomBroadcaster 完整版打包'
Set-Location $Base

$Hdr = @{ 'User-Agent' = 'ClassroomBroadcaster-build' }
# GitHub API 查詢用（GitHub Actions 裡用 GITHUB_TOKEN 避免流量限制；下載檔案時不帶，避免轉址到 CDN 時出錯）
$ApiHdr = @{ 'User-Agent' = 'ClassroomBroadcaster-build' }
if ($env:GITHUB_TOKEN) { $ApiHdr['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
$Dl = Join-Path $Base 'packages'
New-Item -ItemType Directory -Force -Path $Dl | Out-Null

function Get-Release([string]$repo) {
    Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $ApiHdr -UseBasicParsing
}

function Get-Asset($rel, [string]$pattern) {
    $a = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $a) { throw "在 $($rel.tag_name) 找不到符合 $pattern 的檔案" }
    return $a
}

# 下載並以 SHA256 驗證（GitHub 提供 digest 時）
function Save-Asset($asset, [string]$expectSha) {
    $out = Join-Path $Dl $asset.name
    if (-not $expectSha -and $asset.digest -and $asset.digest -like 'sha256:*') { $expectSha = $asset.digest.Substring(7) }
    if ((Test-Path $out) -and $expectSha -and ((Get-FileHash $out -Algorithm SHA256).Hash -ieq $expectSha)) {
        Say "  已有 $($asset.name)（略過下載）" Green
        return $out
    }
    Say "  下載 $($asset.name)（$([math]::Round($asset.size / 1MB, 1)) MB）…"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $out -Headers $Hdr -UseBasicParsing
    if ($expectSha) {
        $actual = (Get-FileHash $out -Algorithm SHA256).Hash
        if ($actual -ine $expectSha) { Remove-Item $out -Force; throw "$($asset.name) 的 SHA256 檢查碼不符，下載可能損毀，請重新執行。" }
        Say '  檢查碼驗證通過' Green
    }
    return $out
}

function Expand-Zip([string]$zip, [string]$dest) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
}

# zip 輸出位置：預設放在資料夾的上一層；CB_ZIP_OUT 可指定完整版 zip 的路徑，簡易版放在同一個資料夾
$ZipOut = if ($env:CB_ZIP_OUT) { $env:CB_ZIP_OUT } else { Join-Path (Split-Path $Base -Parent) 'ClassroomBroadcaster-full.zip' }
$LiteZipOut = Join-Path (Split-Path $ZipOut -Parent) 'ClassroomBroadcaster-lite.zip'

# 簡易版 zip：只放簡易版需要的檔案（不含 OBS、MediaMTX），解壓縮後的資料夾名稱也標註 lite
function New-LiteZip([string]$out) {
    $stage = Join-Path $env:TEMP ('cbl_' + [guid]::NewGuid().ToString('N'))
    $dst = Join-Path $stage 'ClassroomBroadcaster-lite'
    New-Item -ItemType Directory -Force -Path (Join-Path $dst 'scripts') | Out-Null
    foreach ($f in 'lite-start.bat', 'lite-teacher2.bat', 'settings.psd1') {
        if (Test-Path (Join-Path $Base $f)) { Copy-Item (Join-Path $Base $f) $dst }
    }
    Copy-Item (Join-Path $Base 'README-lite.md') (Join-Path $dst 'README.md')
    Copy-Item (Join-Path $Base 'lite') $dst -Recurse
    foreach ($f in 'common.ps1', 'lite-start.ps1', 'lite-admin.ps1', 'lite-teacher2.ps1') {
        Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $dst 'scripts')
    }
    if (Test-Path $out) { Remove-Item $out -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $out, [IO.Compression.CompressionLevel]::Optimal, $false)
    Remove-Item $stage -Recurse -Force
    Say "已產生簡易版：$out" Green
}

Clear-Host
if ($LiteOnly) {
    Say '============ ClassroomBroadcaster 簡易版打包 ============' Cyan
    Say '不需網路，只打包簡易版需要的檔案。'
} else {
    Say '============ ClassroomBroadcaster 完整版打包 ============' Cyan
    Say '會下載：MediaMTX（約 15 MB）、OBS Studio 免安裝版（約 150 MB）、VC++ 執行階段（約 25 MB）'
}
Say ''

if ($LiteOnly) {
    try { New-LiteZip $LiteZipOut } catch { Fail ("簡易版打包失敗：$($_.Exception.Message)") }
    if (-not $NonInteractive) { Read-Host "`n按 Enter 關閉" }
    exit 0
}

try {
    # ---------- 1. MediaMTX ----------
    Say '[1/3] MediaMTX' Cyan
    $rel = Get-Release 'bluenviron/mediamtx'
    $asset = Get-Asset $rel '_windows_amd64\.zip$'
    $sha = $null
    $sumAsset = $rel.assets | Where-Object { $_.name -eq 'checksums.sha256' } | Select-Object -First 1
    if ($sumAsset -and -not $asset.digest) {
        $sumFile = Join-Path $env:TEMP 'mediamtx-checksums.sha256'
        Invoke-WebRequest -Uri $sumAsset.browser_download_url -OutFile $sumFile -Headers $Hdr -UseBasicParsing
        $line = Get-Content $sumFile | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1
        if ($line) { $sha = ($line -split '\s+')[0] }
    }
    $zip = Save-Asset $asset $sha
    $tmp = Join-Path $env:TEMP ('mtx_' + [guid]::NewGuid().ToString('N'))
    Expand-Zip $zip $tmp
    & (Join-Path $PSScriptRoot 'stop.ps1') -Quiet -KeepOBS
    Copy-Item (Get-ChildItem $tmp -Recurse -Filter 'mediamtx.exe' | Select-Object -First 1).FullName $MtxExe -Force
    Remove-Item $tmp -Recurse -Force
    Set-Content (Join-Path $Base 'mediamtx.version.txt') $rel.tag_name -Encoding ASCII
    Say "  MediaMTX $($rel.tag_name) 完成" Green

    # ---------- 2. OBS Studio 免安裝版 ----------
    Say "`n[2/3] OBS Studio 免安裝版" Cyan
    if (Get-Process obs64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $BundledObs }) {
        throw '資料夾內的 OBS 正在執行，請先關閉 OBS 再打包。'
    }
    $rel = Get-Release 'obsproject/obs-studio'
    $asset = Get-Asset $rel '^OBS-Studio-[\d\.]+-Windows(-x64)?\.zip$'
    $zip = Save-Asset $asset $null
    $obsDir = Join-Path $Base 'obs'
    # 暫存放在同一個磁碟（避免跨磁碟搬移資料夾失敗，例如資料夾在隨身碟）
    $keepCfg = Join-Path $Base ('_obscfg_' + [guid]::NewGuid().ToString('N'))
    if (Test-Path "$obsDir\config") { Move-Item "$obsDir\config" $keepCfg }     # 保留已建立的設定
    $tmp = Join-Path $Base ('_obs_' + [guid]::NewGuid().ToString('N'))
    Say '  解壓縮中（檔案較多，請稍候）…'
    Expand-Zip $zip $tmp
    $exe = Get-ChildItem $tmp -Recurse -Filter 'obs64.exe' | Where-Object { $_.FullName -match '\\bin\\64bit\\obs64\.exe$' } | Select-Object -First 1
    if (-not $exe) { throw 'OBS 壓縮檔內找不到 bin\64bit\obs64.exe' }
    $obsRoot = $exe.Directory.Parent.Parent.FullName
    if (Test-Path $obsDir) { Remove-Item $obsDir -Recurse -Force }
    Move-Item $obsRoot $obsDir
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    if (Test-Path $keepCfg) { Move-Item $keepCfg "$obsDir\config" }
    Set-Content (Join-Path $obsDir 'portable_mode.txt') '' -Encoding ASCII
    Set-Content (Join-Path $Base 'obs.version.txt') $rel.tag_name -Encoding ASCII
    Say "  OBS Studio $($rel.tag_name)（免安裝模式）完成" Green

    # ---------- 3. VC++ 執行階段 ----------
    Say "`n[3/3] Microsoft Visual C++ 執行階段" Cyan
    $vcDir = Join-Path $Base 'vcredist'
    New-Item -ItemType Directory -Force -Path $vcDir | Out-Null
    $vc = Join-Path $vcDir 'vc_redist.x64.exe'
    Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vc -UseBasicParsing
    $sig = Get-AuthenticodeSignature $vc
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') {
        Remove-Item $vc -Force
        throw 'VC++ 執行階段的數位簽章驗證失敗，請重新執行。'
    }
    Say '  完成（已驗證 Microsoft 數位簽章）' Green
} catch {
    Fail ("打包失敗：$($_.Exception.Message)`n請確認這台電腦可以連上 github.com 與 aka.ms，再重新執行 build.bat。")
}

# ---------- 清理不需帶走的暫存 ----------
foreach ($d in 'run', 'logs', 'deploy') { if (Test-Path (Join-Path $Base $d)) { Remove-Item (Join-Path $Base $d) -Recurse -Force } }

Say "`n================ 完整版準備完成 ================" Green
Say "這個資料夾現在可以直接複製到教師機使用（不需網路、不需安裝）："
Say "  $Base"
if (Ask-YesNo "`n要另外產生一個 zip 檔方便複製嗎？" $true) {
    $zipOut = $ZipOut
    if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
    Say '壓縮中…'
    # packages 內是下載的原始檔，教師機用不到，不放進 zip
    $stage = Join-Path $env:TEMP ('cb_' + [guid]::NewGuid().ToString('N'))
    $dst = Join-Path $stage 'ClassroomBroadcaster'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Get-ChildItem $Base -Force | Where-Object { $_.Name -notin 'packages', 'dist', 'tests', '.git', '.github', '.gitignore' } |
        ForEach-Object { Copy-Item $_.FullName $dst -Recurse -Force }
    # 這台電腦的 OBS 設定（螢幕解析度、紀錄檔）不帶走：每台教師機第一次啟動時會依自己的螢幕重新建立
    if (Test-Path "$dst\obs\config") { Remove-Item "$dst\obs\config" -Recurse -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipOut, [IO.Compression.CompressionLevel]::Optimal, $false)
    Remove-Item $stage -Recurse -Force
    Say "已產生完整版：$zipOut" Green
    New-LiteZip $LiteZipOut
}
if (-not $NonInteractive) { Read-Host "`n按 Enter 關閉" }
