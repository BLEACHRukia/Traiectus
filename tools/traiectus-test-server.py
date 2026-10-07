#!/usr/bin/env python3
# ============================================================================
#  Traiectus 测试服务器（模拟 Windows 端）
# ----------------------------------------------------------------------------
#  用途：在没有 Windows 机器的情况下，单独验证 Mac 客户端。
#
#  它实现了 PROTOCOL.md 里服务端该有的最小集合：
#    * 等客户端连上来，校验 HELLO 的协议版本与口令
#    * 回 HELLO-OK，然后（--demo）按脚本走一遍动作演示
#    * 每秒发 PING、回应客户端的 PING，并打印收到的一切
#    * --duration 到期后发 BYE，用来验证客户端的断线重连
#
#  它只用于测试，不是产品的一部分。
#
#  用法：
#    python3 tools/minikvm-test-server.py --port 45789 --token test123 --demo
# ============================================================================

import argparse
import socket
import threading
import time


def stamp() -> str:
    t = time.time()
    return time.strftime("%H:%M:%S", time.localtime(t)) + f".{int(t * 1000) % 1000:03d}"


def log(msg: str) -> None:
    print(f"[{stamp()}] {msg}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1", help="监听地址")
    parser.add_argument("--port", type=int, default=45789)
    parser.add_argument("--token", default="", help="期望的口令（空 = 不校验）")
    parser.add_argument("--duration", type=float, default=30.0, help="保持连接的秒数")
    parser.add_argument("--demo", action="store_true", help="握手后自动走一遍动作演示")
    parser.add_argument("--demo-delay", type=float, default=3.0,
                        help="演示开始前等几秒（给人留出看屏幕的时间），默认 3 秒")
    parser.add_argument("--stage", choices=["all", "motion", "wheel"], default="all",
                        help="演示哪一段：motion=方形+左键+右键；wheel=滚轮+中键；all=两者都做")
    parser.add_argument("--stick-button", action="store_true",
                        help="测试用：发一次 DOWN L 后直接断开，验证客户端是否补发抬起")
    parser.add_argument("--quiet-heartbeat", action="store_true", help="不逐条打印 PING/PONG")
    args = parser.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(1)
    log(f"监听 {args.host}:{args.port}（口令 {args.token!r}），等待 Mac 客户端连接…")

    conn, addr = server.accept()
    conn.settimeout(0.2)
    log(f"已接受连接：{addr[0]}:{addr[1]}")

    send_lock = threading.Lock()

    def send(line: str) -> None:
        with send_lock:
            conn.sendall((line + "\n").encode("utf-8"))

    state = {"handshaken": False}
    ping_sent_at: dict[str, float] = {}
    move_count = 0

    def handle(text: str) -> None:
        nonlocal move_count
        parts = text.split()
        if not parts:
            return
        cmd = parts[0].upper()

        if cmd == "PING":
            if not args.quiet_heartbeat:
                log(f"  << {text}")
            if len(parts) == 2:
                send(f"PONG {parts[1]}")
            return

        if cmd == "PONG":
            rtt = (time.time() - ping_sent_at.pop(parts[1], time.time())) * 1000
            if not args.quiet_heartbeat:
                log(f"  << {text}   （往返 {rtt:.1f} ms）")
            if move_count:
                log(f"     （本轮共发过 {move_count} 条 MOVE）")
                move_count = 0
            return

        if cmd == "HELLO":
            log(f"  << {text}")
            version = parts[1] if len(parts) > 1 else ""
            token = " ".join(parts[3:])
            if version != "1":
                log(f"  ** 协议版本不符（收到 {version}）→ 回 ERR AUTH")
                send("ERR AUTH")
                return
            if token != args.token:
                log(f"  ** 口令不符（收到 {token!r}）→ 回 ERR AUTH")
                send("ERR AUTH")
                return
            state["handshaken"] = True
            send("HELLO-OK 1")
            log("  >> HELLO-OK 1  握手完成")
            return

        if cmd == "BYE":
            log(f"  << {text}")
            return

        log(f"  << {text}   （不认识的命令）")

    def demo() -> None:
        log(f"  >> {args.demo_delay:.0f} 秒后开始动作演示（阶段：{args.stage}）")
        time.sleep(args.demo_delay)

        if args.stage in ("all", "motion"):
            steps, px = 10, 12
            log(f"  >> 演示：向右 → 向下 → 向左 → 向上（每边 {steps * px} 像素，应当回到原位）")
            for dx, dy, tag in ((px, 0, "右"), (0, px, "下"), (-px, 0, "左"), (0, -px, "上")):
                for _ in range(steps):
                    send(f"MOVE {dx} {dy}")
                    time.sleep(0.03)
                log(f"     已完成：{tag}")
                time.sleep(0.15)
            log("  >> 演示：左键 按下 → 抬起")
            send("DOWN L")
            time.sleep(0.15)
            send("UP L")
            time.sleep(0.5)
            log("  >> 演示：右键 按下 → 抬起（桌面上会弹出右键菜单）")
            send("DOWN R")
            time.sleep(0.15)
            send("UP R")
            time.sleep(0.5)

        if args.stage in ("all", "wheel"):
            log("  >> 演示：滚轮 +120 → -120")
            send("WHEEL 120")
            time.sleep(0.25)
            send("WHEEL -120")
            time.sleep(0.4)
            log("  >> 演示：中键 按下 → 抬起（落在光标当前所在位置）")
            send("DOWN M")
            time.sleep(0.1)
            send("UP M")
        log("  >> 演示结束")

    buffer = b""
    started = time.time()
    last_receive = time.time()
    next_self_ping = time.time() + 1.0
    demo_thread: threading.Thread | None = None

    while time.time() - started < args.duration:
        # 专门用来验证"断开时补发抬起"这条保护：按下左键后不给抬起就断开，
        # 客户端应当自行补一个 UP L，否则 Mac 上的左键会卡住。
        if args.stick_button and state["handshaken"] and time.time() - started > 2.0:
            log("  ** 测试：发送 DOWN L 后直接断开（不补 UP）")
            send("DOWN L")
            time.sleep(1.0)
            break

        try:
            data = conn.recv(4096)
            if not data:
                log("客户端关闭了连接（EOF）")
                break
            buffer += data
            last_receive = time.time()
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                line = raw.decode("utf-8", "replace").rstrip("\r")
                if line.split() and line.split()[0].upper() == "MOVE":
                    move_count += 1
                else:
                    handle(line)
                if state["handshaken"] and demo_thread is None and args.demo:
                    demo_thread = threading.Thread(target=demo, daemon=True)
                    demo_thread.start()
        except socket.timeout:
            pass
        except ConnectionResetError:
            log("连接被重置（客户端可能已退出）")
            break

        if state["handshaken"] and time.time() > next_self_ping:
            pid = str(int(time.time() * 1000) % 1000000)
            ping_sent_at[pid] = time.time()
            send(f"PING {pid}")
            if not args.quiet_heartbeat:
                log(f"  >> PING {pid}")
            next_self_ping = time.time() + 1.0

    if state["handshaken"] and not args.stick_button:
        log("发送 BYE，关闭连接（客户端应当进入重连流程）")
        try:
            send("BYE")
        except OSError:
            pass
    conn.close()
    server.close()
    log("测试服务器结束")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
