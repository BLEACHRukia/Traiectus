# Traiectus - Windows-side operation steps

> From a clean Windows machine to the Mac being driven by this mouse: every step.
> Design and implementation notes are in [`README.en.md`](README.en.md);
> the protocol is in [`../PROTOCOL.md`](../PROTOCOL.md).
>
> **Path note.** The authoritative repository keeps the Windows sources under
> `windows/` (`windows/phase3-tcp/...`). In the plain Windows working copy that
> folder is just `phase3-tcp\`. The commands below use the short form - add the
> `windows\` prefix if you are working inside the main repository checkout.

---

## 0. How to read this

Do the steps in order. Every step says what to do and what you should see.

If you just want it running as fast as possible:

```bat
cd phase3-tcp
build-mingw.bat
build\Traiectus-Server.exe
```

Then click "Connect" on the Mac; a dialog appears on Windows - click "Allow".
That is all.

---

## 1. Background (30 seconds)

Traiectus is a personal, lightweight KVM: it "copies" the mouse attached to
Windows to the Mac over the LAN.

```text
mouse ──► Windows PC ──────────────► Mac mini
          Traiectus Server            Traiectus Client
          (listening side)            (connecting side)
          read-only capture           injects with CGEvent
          + TCP forwarding
```

- **Windows is the listening side**; the Mac connects to it. Default TCP port
  **45789**.
- Protocol: line-based text (`HELLO` / `MOVE` / `DOWN` / `UP` / `WHEEL` /
  `PING` / `BYE` ...), authoritative definition in `PROTOCOL.md`.
- The keyboard is **not** forwarded (switch it in hardware), and the monitor
  input is **not** switched.

## 2. Safety red lines (not one of them may be broken)

These are hard constraints of the project, not slogans:

1. Never affect normal Windows mouse input
2. Never affect the Windows keyboard
3. Never modify Windows system files, the registry or system settings
4. No drivers, no kernel components, no `SetWindowsHookEx`
5. Never touch G HUB, the mouse DPI or its firmware
6. **Never change firewall rules** (that is yours to do, by hand, on purpose)
7. After the program exits or crashes, the local mouse must be completely normal
8. **Movement is sent as relative deltas only, never absolute coordinates**
9. No injection, no interception, no blocking of local input (the only injection
   happens on the Mac side)

The single place that changes local runtime state is the **cursor lock**
(`ClipCursor`) while in Mac mode. It has two backstops: an independent watchdog
process, and Windows' own escape hatch (any elevated window taking focus clears
the restriction).

## 3. What you need

| Needed | Notes |
|---|---|
| Windows 10 / 11 | only public Win32 APIs are used |
| A C++ compiler | [w64devkit](https://github.com/skeeto/w64devkit/releases) (unzip and go) or VS 2022 |
| Traiectus Client already on the Mac | this repository only contains the Windows side |
| Both machines on the same LAN | wired or wireless, same subnet |

**Not** needed: administrator rights, drivers, SDKs, Python, any runtime.

## 4. Build

### Option A: w64devkit (recommended - no install, no admin)

Double-click `build-mingw.bat`, or from a command prompt:

```bat
cd /d <path to Traiectus>\phase3-tcp
build-mingw.bat
```

The script finds `g++.exe` by itself (it tries `%USERPROFILE%\tools\w64devkit\bin`,
then `C:\w64devkit\bin`, then falls back to `PATH`) and prints the full output and
the error code if the build fails.

> **Do not retype the multi-line command** - copying the `^` line continuations
> from a document into cmd goes wrong easily. If you insist, the equivalent is:
>
> ```bat
> cd /d <path>\phase3-tcp
> mkdir build 2>nul
>
> "%USERPROFILE%\tools\w64devkit\bin\g++.exe" -std=c++17 -O2 -Wall -Wextra -municode -mconsole ^
>    -DUNICODE -D_UNICODE -D__USE_MINGW_ANSI_STDIO=1 -static -static-libgcc -static-libstdc++ ^
>    -o build\Traiectus-Server.exe src\main.cpp ^
>    -luser32 -lgdi32 -lws2_32 -lsetupapi -lhid -lbcrypt
> ```

### Option B: MSVC

Open "x64 Native Tools Command Prompt for VS 2022":

```bat
cd /d <path>\phase3-tcp
build.bat
```

(`build.bat` and `CMakeLists.txt` both pass `/utf-8`, which is required: the
sources contain UTF-8 text.)

### Output

`build\Traiectus-Server.exe` - **statically linked**, so it runs on another
machine without shipping any DLL.

### If the build fails

The first error is the cause; the rest of the output is usually a chain reaction
from it. The usual culprit is a compiler that is too old (this needs C++17).

## 5. Self-checks that do not need the Mac

```bat
rem 1) List mouse-class devices and confirm your mouse is there
build\Traiectus-Server.exe --list
rem    e.g. VID_xxxx&PID_xxxx&MI_00  (LIGHTSPEED receiver)

rem 2) Help only
build\Traiectus-Server.exe --help

rem 3) Start it (no device filter yet - just to see that it comes up)
build\Traiectus-Server.exe --port 45789
rem    Expected: the listen address plus one auth status line ("not paired yet"
rem    or "paired"), then one statistics line per second
```

**Also confirm**: the Windows mouse and keyboard stay completely normal
throughout, and still are after you press Ctrl+C.

```bat
rem 4) Protocol self-test: leave the server running, run this in another window
powershell -NoProfile -ExecutionPolicy Bypass -File ..\tools\test-client.ps1
rem    Without -Token it goes through pairing: click "Allow" on Windows.
rem    Expected: HELLO-OK / the server's PING arrives / you reply PONG /
rem              the server answers your own PING.
rem    This needs no Mac, so it isolates "is the server's protocol layer healthy".
rem    NOTE: do not send MOVE/DOWN/UP/WHEEL from this script - those go the
rem          other way (server -> client) and the server will log them as
rem          unknown commands. Mouse events must come from a real mouse.
```

Also worth knowing: `--lang zh|en` selects the UI language of this run
(pairing dialog, `--show` window, `--help`, `--list`). Without it the Windows UI
language is used. Logs stay Chinese either way.

## 6. Firewall (your decision, do not change it silently)

The first run makes Windows show "Windows Defender Firewall has blocked some
features of this app".

- **Tick "Private networks" and allow.** Do not tick "Public networks" - that
  would open the port on every network you ever join, including public Wi-Fi.
- If the dialog does not appear, or nothing was allowed, you can add a minimal
  rule from an **elevated** command prompt (**you run it**):

```bat
netsh advfirewall firewall add rule name="Traiectus server TCP 45789" dir=in action=allow ^
  program="<full path>\build\Traiectus-Server.exe" protocol=TCP localport=45789 ^
  profile=private enable=yes
```

**Do not** work around this by "turning the firewall off for a moment".

> There is also a ready-made helper: `Traiectus-防火墙放行.bat` in the repository
> root (it elevates itself). It makes sure the two **port-scoped** inbound rules
> exist - TCP 45789 (mouse events) and UDP 45791 (address discovery) - and removes
> old **program-scoped** leftovers. It does not change ports, does not touch the
> proxy and does not add any auto-start entry.

## 7. Getting the Mac to connect (pairing the first time)

1. Find this PC's LAN address:

   ```bat
   ipconfig
   ```

2. Start the server:

   ```bat
   build\Traiectus-Server.exe
   ```

   The start-up banner shows one auth status line: a fresh machine says
   **not paired yet** (that is normal, not a warning); an already paired one says
   **paired (token from ...\paired.json)**.

   > By default you do not pass `--device`: the server watches for 8 seconds to
   > see which device really moves and picks your mouse, printing a
   > `DEVICE PICK <device string>` line. To pin one by hand:
   > `--device "VID_xxxx&PID_xxxx&MI_00"` (the `&` is a command separator in cmd,
   > so the quotes are not optional).

3. On the Mac: open the Client and **leave the address empty** - it tries the
   address it remembers, then broadcasts `WHO 1` on the subnet (UDP 45791); the
   server unicasts back `HERE 1 45789`, so the Mac fills in address and port
   itself. Click Connect. The first time, macOS asks "allow access to the local
   network" - allow it.

   If this Windows machine has never been paired, **a dialog appears on the
   Windows screen** (two lines plus "Allow / Deny"). Click "Allow" and pairing is
   done; nothing has to be typed on the Mac.

4. On a successful handshake the Windows console shows a line like:

   ```text
   [..] 客户端 已连接（握手完成）| 发送   0 行/秒 | 队列   0 | 往返 0 ms | 本机捕获   0 pkt/s
   ```

   and the Mac log shows the matching handshake line. (Server logs are Chinese on
   purpose - see §5 of the task description / the repository README.)

## 8. Test checklist (in order, record each result)

| # | Do this | Expect |
|---|---|---|
| 1 | Move the mouse on Windows | The Mac cursor follows, same direction (right->right, down->down), no jumping |
| 2 | Left / right click on the Mac | Real clicks; the Windows-local mouse keeps working normally |
| 3 | Middle button, side buttons | On the Mac, a browser page should show button 1 / 3 / 4 |
| 4 | Wheel up / down | Same direction as Windows (deltaY negative = up, positive = down) |
| 5 | Type and work on Windows | Completely unaffected; keyboard events never enter this program at all |
| 6 | Close the Mac client | Windows prints "no data from the peer for 3 seconds" within 3 s, returns to waiting; the mouse is fine |
| 7 | Reopen the Mac client | Reconnects automatically within 1 s |
| 8 | Unplug the network / turn Wi-Fi off | Both sides detect the drop; both mice are completely normal |
| 9 | Force-kill `Traiectus-Server.exe` from Task Manager | The Windows mouse is **immediately** completely normal |
| 10 | Close the console window | The program exits, the mouse is normal |

**Requirement**: for items 1-10 record what *actually* happened, not "should be
fine". Items 6-10 are what this project lives on - if any of them fails, do not
add features before it is fixed.

## 9. Diagnosing problems

| Symptom | Look here first |
|---|---|
| Mac cannot connect | On the Mac `nc -vz <windows-ip> 45789`; on Windows `netstat -ano \| findstr 45789` to see whether it is listening; make sure the firewall rule is **Private** |
| Connected but nothing moves | Is "本机捕获 pkt/s" (local capture) on the Windows console 0? Then the device filter is wrong - re-check with `--list`; add `--verbose` to see whether events are being sent |
| Events are sent but the Mac does nothing | Accessibility permission on the Mac side |
| Log says "unknown command received" | The two sides disagree about the protocol version - compare `PROTOCOL.md` |
| Handshake fails | The pairing files disagree, or the protocol version is not 1 |
| Windows says paired, the Mac says it cannot connect | Tray right-click -> "Re-pair" on Windows, then reconnect from the Mac and click "Allow" |
| Screen switching takes a second longer | A TUN-mode proxy on Windows is swallowing LAN packets - set the private ranges to direct |

## 10. Stopping and cleaning up

**Started from the tray:** right-click the dot -> "Quit". The server, the
watchdog, the ports and the cursor lock are all cleaned up at once (a Job Object,
see `launcher/说明.en.md` section 5).

**Started by hand:** press Ctrl+C in the console, or close the window.

Neither leaves a service, an auto-start entry, a registry key or a driver behind.

If you installed into `%LOCALAPPDATA%\Traiectus\`, double-click
`launcher\卸载 Traiectus.bat` to remove it.

---

## Appendix: these behaviours are deliberate, do not "fix" them

- Movement is sent as relative deltas only. Absolute coordinates would jump when
  the two machines have different resolutions or display scaling.
- A new connection displaces the old one, so a restarted Mac is never stuck
  behind a stale connection.
- `ClipCursor` being cleared by an elevated window is a **good** thing - it is
  the system-level escape hatch.
- Nothing is received on the secure desktop (UAC prompt, lock screen). That is by
  Windows design; every user-mode program behaves this way.
- TCP framing is handled by a line buffer: the code never assumes that one
  `recv()` returns exactly one message.
