#!/usr/bin/env python3
"""假服务端断开/恢复，验证生产客户端的真实 TCP 重连。只监听回环，不发送输入事件。"""
import pathlib, socket, subprocess, threading, time
root = pathlib.Path(__file__).resolve().parents[2]
src = root / "macos/phase3-tcp/src"
output = root / "tools/peer-address-test/build/TraiectusAddressIntegrationTests"
files = sorted(src.glob("*.swift")) + [p for p in sorted((src / "ui").glob("*.swift")) if p.name != "TraiectusApp.swift"]
subprocess.run(["swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(output.parent / "mc"), "-o", str(output), *map(str, files), str(root / "tools/peer-address-test/integration.swift")], check=True)
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 45788))
server.listen()
server.settimeout(.1)
start = time.monotonic()
stop = threading.Event()
def serve():
    while not stop.is_set():
        try: conn, _ = server.accept()
        except socket.timeout: continue
        conn.settimeout(.1)
        buffer = b""
        try:
            while not stop.is_set():
                elapsed = time.monotonic() - start
                if 3 <= elapsed < 9: break
                try: data = conn.recv(4096)
                except socket.timeout: continue
                if not data: break
                buffer += data
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    words = line.decode().split()
                    if not words: continue
                    if words[0] == "HELLO": conn.sendall(b"HELLO-OK 1\nMODE Mac\n")
                    elif words[0] == "PING": conn.sendall(("PONG " + words[1] + "\n").encode())
        except OSError: pass
        finally: conn.close()
thread = threading.Thread(target=serve, daemon=True)
thread.start()
try:
    result = subprocess.run([str(output)], timeout=25)
    raise SystemExit(result.returncode)
finally:
    stop.set()
    thread.join(timeout=1)
    server.close()
