# ============================================================================
#  设置静态IP.ps1 —— 把某张网卡从 DHCP 改成静态 IPv4（或者改回 DHCP）
# ----------------------------------------------------------------------------
#  2026-10-07 固定两台 IP 那一单要用：路由器里找不到「地址保留」，
#  改走"在这台 Windows 上直接设静态 IP"，地址必须挑在路由器 DHCP 池**外面**。
#
#  用法（必须以**管理员**身份运行）：
#      .\设置静态IP.ps1 -IP 192.168.1.250
#      .\设置静态IP.ps1 -Dhcp                 # 改回 DHCP（还原）
#      .\设置静态IP.ps1 -IP 192.168.1.250 -Adapter "以太网"
#
#  它只做两件事：改 IPv4 地址、改 DNS。不碰防火墙、不碰代理、不碰别的网卡。
#  改回去就一句：-Dhcp
# ============================================================================

[CmdletBinding()]
param(
    [string]   $Adapter = "WLAN",
    [string]   $IP      = "",
    [string]   $Mask    = "255.255.255.0",
    [string]   $Gateway = "192.168.1.1",
    [string[]] $Dns     = @("119.29.29.29", "114.114.114.114"),
    [switch]   $Dhcp
)

$ErrorActionPreference = "Stop"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "[error] 需要管理员权限 —— 请右键「使用 PowerShell 运行（管理员）」，或用 Start-Process -Verb RunAs" -ForegroundColor Red
    exit 1
}

if (-not (Get-NetAdapter -Name $Adapter -ErrorAction SilentlyContinue)) {
    Write-Host "[error] 找不到网卡：$Adapter" -ForegroundColor Red
    Get-NetAdapter | Select-Object Name, Status, MacAddress | Format-Table -AutoSize
    exit 1
}

Write-Host ""
Write-Host "=== 改之前 ===" -ForegroundColor Cyan
netsh interface ip show config name="$Adapter"

if ($Dhcp) {
    Write-Host "=== 改回 DHCP ===" -ForegroundColor Cyan
    netsh interface ip set address name="$Adapter" source=dhcp
    netsh interface ip set dns     name="$Adapter" source=dhcp
} else {
    if (-not $IP) { Write-Host "[error] 没有给 -IP（要还原请用 -Dhcp）" -ForegroundColor Red; exit 1 }

    # 占位检查：目标地址现在有没有人应答（有应答就中止，避免直接撞车）
    if (Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "[warn] $IP 现在能 ping 通 —— 可能已被占用，请换一个地址。已中止。" -ForegroundColor Yellow
        exit 2
    }

    Write-Host "=== 设为静态 $IP ===" -ForegroundColor Cyan
    netsh interface ip set address name="$Adapter" static $IP $Mask $Gateway
    netsh interface ip set dns     name="$Adapter" static $Dns[0] primary
    for ($i = 1; $i -lt $Dns.Count; $i++) {
        netsh interface ip add dns name="$Adapter" $Dns[$i] index=$($i + 1)
    }
}

Write-Host ""
Write-Host "=== 改之后 ===" -ForegroundColor Cyan
netsh interface ip show config name="$Adapter"
Write-Host ""
Write-Host "还原命令：.\设置静态IP.ps1 -Dhcp" -ForegroundColor DarkGray
