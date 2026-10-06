# 簡易版：一次性的防火牆設定（由 lite-start.ps1 以系統管理員身分呼叫，只在第一次執行）
param([int]$Port = 8080)
$ErrorActionPreference = 'SilentlyContinue'
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# 若曾在 Windows 安全性提示按了「取消」，會留下封鎖 PowerShell 的規則（封鎖優先於允許），先清掉
Get-NetFirewallApplicationFilter | Where-Object { $_.Program -ieq $ps } |
    Get-NetFirewallRule | Where-Object { $_.Action -eq 'Block' -and $_.Direction -eq 'Inbound' } | Remove-NetFirewallRule

foreach ($n in 'ClassroomBroadcaster Lite', 'ClassroomBroadcaster Lite App') {
    Get-NetFirewallRule -DisplayName $n | Remove-NetFirewallRule
}
New-NetFirewallRule -DisplayName 'ClassroomBroadcaster Lite' -Direction Inbound -Action Allow -Profile Any `
    -Protocol TCP -LocalPort $Port | Out-Null
# 只允許 PowerShell 在這個埠接受連線（避免跳出 Windows 安全性警告）
New-NetFirewallRule -DisplayName 'ClassroomBroadcaster Lite App' -Direction Inbound -Action Allow -Profile Any `
    -Program $ps -Protocol TCP -LocalPort $Port | Out-Null
