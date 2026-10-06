# 簡易靜態網頁伺服器：提供學生播放頁（www 資料夾）
# 由 start.ps1 以系統管理員身分啟動；不需安裝任何軟體
param(
    [int]$Port = 8080,
    [string]$Root = (Join-Path (Split-Path $PSScriptRoot -Parent) 'www')
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path $Root).Path.TrimEnd('\')
$RootPrefix = $Root + '\'
try { $Host.UI.RawUI.WindowTitle = "ClassroomBroadcaster 網頁伺服器 :$Port" } catch {}

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
try {
    $listener.Start()
} catch {
    Write-Host "無法啟動網頁伺服器（埠 $Port）：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '請確認以系統管理員身分執行，且埠沒有被其他程式佔用。'
    Start-Sleep -Seconds 10
    exit 1
}
Write-Host "播放頁伺服器已啟動：http://+:$Port/  （根目錄 $Root）" -ForegroundColor Green

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        try {
            $rel = [Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
            if ([string]::IsNullOrEmpty($rel) -or $rel.EndsWith('/')) { $rel += 'index.html' }
            $full = [IO.Path]::GetFullPath((Join-Path $Root $rel))

            if (-not $full.StartsWith($RootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $full -PathType Leaf)) {
                $res.StatusCode = 404
                $bytes = [Text.Encoding]::UTF8.GetBytes('404 Not Found')
                $res.ContentType = 'text/plain; charset=utf-8'
            } else {
                $ext = [IO.Path]::GetExtension($full).ToLower()
                $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
                $bytes = [IO.File]::ReadAllBytes($full)
            }
            # 不快取：更新播放頁後學生重新整理就是新版
            $res.Headers['Cache-Control'] = 'no-store'
            $res.ContentLength64 = $bytes.Length
            if ($req.HttpMethod -ne 'HEAD') { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
        } catch {
            try { $res.StatusCode = 500 } catch {}
        } finally {
            try { $res.Close() } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
