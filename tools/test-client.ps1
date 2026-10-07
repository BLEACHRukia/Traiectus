# ============================================================================
#  Traiectus 服务端自检客户端（在 Windows 上跑，不需要 Mac）
# ----------------------------------------------------------------------------
#  用途：单独验证 Windows 服务端自己的协议层是否工作
#    1) 鉴权：没给 -Token 时先走配对（PAIR? → 在 Windows 上点「允许」→ PAIR-OK <口令>），
#       然后照常 HELLO → 服务端应当回 HELLO-OK 1
#    2) 服务端每秒发 PING   → 脚本回 PONG，服务端不应报错
#    3) 脚本发 PING 42      → 服务端应当回 PONG 42
#
#  ⚠ 不要用这个脚本发 MOVE / DOWN / UP / WHEEL。
#    那些是"服务端 → 客户端"方向的命令；客户端发过去只会让服务端记一条
#    「收到不认识的命令」。鼠标事件必须由真实的鼠标移动产生。
#
#  用法（普通 PowerShell，不需要管理员）：
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\test-client.ps1
#        ↑ 默认就是配对模式：运行后在 Windows 上点「允许」即可（和真客户端一样）
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\test-client.ps1 -Server 192.168.1.20 -Port 45789
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\test-client.ps1 -Token <已有的口令>
#        ↑ 已经从 paired.json 拿到口令时，可以跳过配对直接握手
# ============================================================================

param(
    [string]$Server = "127.0.0.1",
    [int]$Port = 45789,
    [string]$Token = ""
)

$ErrorActionPreference = "Stop"

function Say([string]$Text, [string]$Color = "Gray") {
    Write-Host $Text -ForegroundColor $Color
}

Say ""
Say "=== Traiectus 服务端自检 ===" "Cyan"
if ($Token) {
    Say ("目标: {0}:{1}   口令: 已提供" -f $Server, $Port)
} else {
    Say ("目标: {0}:{1}   口令: 没有 → 先配对（记得在 Windows 上点「允许」）" -f $Server, $Port)
}
Say ""

$client = New-Object System.Net.Sockets.TcpClient
try {
    $client.Connect($Server, $Port)
} catch {
    Say ("[失败] 连不上 {0}:{1} —— {2}" -f $Server, $Port, $_.Exception.Message) "Red"
    Say "       先确认服务端正在运行，且防火墙放行的是「专用网络」。" "Yellow"
    exit 1
}
Say "[通过] TCP 连接已建立" "Green"

$stream = $client.GetStream()
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Send-Line([string]$Line) {
    Say ("  >> " + $Line) "DarkGray"
    $bytes = $utf8.GetBytes($Line + "`n")
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

# 在给定毫秒内收集对端发来的完整行
function Receive-Lines([int]$Milliseconds) {
    $deadline = (Get-Date).AddMilliseconds($Milliseconds)
    $buffer = ""
    $lines = @()
    while ((Get-Date) -lt $deadline) {
        if ($stream.DataAvailable) {
            $chunk = New-Object byte[] 4096
            $read = $stream.Read($chunk, 0, $chunk.Length)
            if ($read -gt 0) {
                $buffer += $utf8.GetString($chunk, 0, $read)
                while ($buffer.Contains("`n")) {
                    $idx = $buffer.IndexOf("`n")
                    $line = $buffer.Substring(0, $idx)
                    $buffer = $buffer.Substring($idx + 1)
                    $lines += $line.TrimEnd([char]13)
                }
            }
        } else {
            Start-Sleep -Milliseconds 40
        }
    }
    return $lines
}

$handshakeOk = $false
$serverPing = $false
$pongSent = $false
$pingAnswered = $false

# ---- 1) 鉴权 + 握手 ----
# 口令只有两个来源：配对时服务端生成、或调用方用 -Token 给。脚本不猜、不默认。
Say ""
Say "[1/4] 握手" "Yellow"

if (-not $Token) {
    Say "      本地没有口令 → 发 PAIR? 请求配对。请在**这台 Windows** 上点「允许」" "Yellow"
    Send-Line "PAIR? traiectus-test-client"
    $pairDeadline = (Get-Date).AddSeconds(90)      # 服务端确认框默认 60 秒，脚本等久一点
    while (-not $Token -and (Get-Date) -lt $pairDeadline) {
        foreach ($line in (Receive-Lines 300)) {
            Say ("  << " + $line)
            if ($line -match "^PAIR-OK\s+(.+)$") {
                $Token = $Matches[1].Trim()
                Say "      [通过] 配对成功，已拿到口令" "Green"
            } elseif ($line -match "^PAIR-NO\s+(.+)$") {
                Say ("      [失败] 服务端拒绝配对：" + $Matches[1]) "Red"
                Say "             常见原因：已经配对过（用托盘「重新配对」）、或确认框超时" "Yellow"
                $client.Close()
                exit 3
            }
        }
    }
    if (-not $Token) {
        Say "      [失败] 90 秒内没有配对结果 —— 确认框点了吗？" "Red"
        $client.Close()
        exit 3
    }
}

Send-Line "HELLO 1 Win $Token"
foreach ($line in (Receive-Lines 800)) {
    Say ("  << " + $line)
    if ($line -match "^HELLO-OK") { $handshakeOk = $true }
    if ($line -match "^ERR") { Say "       服务端拒绝了握手（口令或协议版本不符）" "Red" }
}
if ($handshakeOk) {
    Say "      [通过] 收到 HELLO-OK" "Green"
} else {
    Say "      [失败] 没有收到 HELLO-OK" "Red"
}

# ---- 2)+3) 心跳与主动 PING：必须边收边立刻回，不能先阻塞收集 ----
# 说明：PROTOCOL.md 第 4 节规定「超过 3 秒没收到对端任何数据即判定连接失效」。
# 如果先调 Receive-Lines 2500 阻塞收集完再回 PONG，回包会晚 2.5 秒以上，
# 服务端会按协议先判超时断开——那是脚本的问题，不是服务端的问题。
Say ""
Say "[2/4] 等待服务端心跳（每轮 200ms 收一次，收到 PING 立刻回 PONG）" "Yellow"
Say "[3/4] 同时脚本发 PING 42，期待 PONG 42" "Yellow"
Send-Line "PING 42"

$pumpDeadline = (Get-Date).AddSeconds(3)
while ((Get-Date) -lt $pumpDeadline) {
    foreach ($line in (Receive-Lines 200)) {
        Say ("  << " + $line)
        if ($line -match "^PING\s+(\S+)") {
            $serverPing = $true
            Send-Line ("PONG " + $Matches[1])
            $pongSent = $true
        }
        if ($line -match "^PONG\s+42$") { $pingAnswered = $true }
    }
}

if ($serverPing) {
    Say "      [通过] 服务端确实在发 PING，脚本已及时回 PONG" "Green"
} else {
    Say "      [失败] 3 秒内没收到任何 PING" "Red"
}
if ($pingAnswered) {
    Say "      [通过] 服务端正确回了 PONG 42" "Green"
} else {
    Say "      [失败] 没收到 PONG 42" "Red"
}

# ---- 4) 断开 ----
Say ""
Say "[4/4] 发 BYE 断开" "Yellow"
Send-Line "BYE"
Start-Sleep -Milliseconds 400
$client.Close()

# ---- 汇总 ----
$r1 = "失败"; if ($handshakeOk) { $r1 = "通过" }
$r2 = "失败"; if ($serverPing) { $r2 = "通过" }
$r3 = "未测到"; if ($pongSent) { $r3 = "通过" }
$r4 = "失败"; if ($pingAnswered) { $r4 = "通过" }

Say ""
Say "=== 结果汇总 ===" "Cyan"
Say ("  握手 HELLO-OK ............ " + $r1)
Say ("  收到服务端 PING .......... " + $r2)
Say ("  回 PONG 给服务端 ......... " + $r3)
Say ("  服务端回应脚本 PING ...... " + $r4)
Say ""
Say "四项全通过 = 服务端协议层没问题；接下来该用真实鼠标产生事件、和 Mac 联调" "Gray"
Say "（见 Windows端操作步骤.md 第 7、8 节）。" "Gray"
Say ""

if ($handshakeOk -and $serverPing -and $pingAnswered) { exit 0 }
exit 2
