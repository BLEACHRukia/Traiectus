# Traiectus Server (Phase 3) - Windows-side capture and forwarding

On top of Phase 1 (read-only Raw Input capture, proven on real hardware) this
phase adds a TCP server: **it forwards the mouse events to the Mac, using the
protocol.**

The protocol is defined in [`../../PROTOCOL.md`](../../PROTOCOL.md). The direction is
**the Mac connects to us**: this program is the listening side, default port
`45789`.

> **Path note.** In the authoritative repository these sources live under
> `windows/phase3-tcp/`; in the plain Windows working copy the folder is just
> `phase3-tcp\`.

---

## 1. Safety design (not one red line has been relaxed)

| Requirement | How this phase does it |
|---|---|
| Does not affect the Windows mouse | Read-only capture; no hooking, no interception, no `BlockInput`, no `SendInput`. **The one exception is the temporary `ClipCursor` lock in Mac mode** (a feature the user asked for; see section 10) |
| Does not affect the keyboard | Only the mouse usage is registered, so keyboard events never reach this process |
| No drivers / no kernel / no admin | Pure user mode: WinSock + Raw Input |
| No changes to system settings / registry / G HUB / DPI / firmware | Not a single byte. `ClipCursor` only changes the runtime cursor range and is restored on exit |
| **Does not change firewall rules** | Not one rule. On first run Windows asks; **whether to allow it is your decision** |
| Mouse is fine after exit / crash | In Windows mode there is no state to restore; **Mac mode holds one `ClipCursor` state that must be released** - covered by a separate watchdog plus the system escape hatch, see section 10 |
| Mouse is fine after the network drops | If it cannot send, the packet is dropped. The local mouse is never affected, because this program never affects local input |

## 2. Build

### Option A: w64devkit (same as Phase 1, no install)

```bat
cd phase3-tcp
mkdir build 2>nul

"%USERPROFILE%\tools\w64devkit\bin\g++.exe" -std=c++17 -O2 -Wall -Wextra -municode -mconsole ^
   -DUNICODE -D_UNICODE -D__USE_MINGW_ANSI_STDIO=1 -static -static-libgcc -static-libstdc++ ^
   -o build\Traiectus-Server.exe src\main.cpp ^
   -luser32 -lgdi32 -lws2_32 -lsetupapi -lhid -lbcrypt
```

(Better: just run `build-mingw.bat` - it finds the compiler for you.)

### Option B: MSVC

Run `build.bat` from "x64 Native Tools Command Prompt for VS 2022"; the output is
`build\Traiectus-Server.exe`. `CMakeLists.txt` is there as well and builds the
same thing.

> `-static` is not optional: without it the exe depends on
> `libstdc++-6.dll` / `libgcc_s_seh-1.dll`, which breaks the moment it is copied
> somewhere else.

## 3. Running it

```bat
rem 1) See which mouse-class devices exist
build\Traiectus-Server.exe --list

rem 2) Just run it: **nothing to configure** - the first start detects
rem    "the mouse you are actually using" within 8 seconds (log line
rem    DEVICE PICK <string>), and the tray writes it back to config.ini.
rem    No token either: the first time a Mac connects, click "Allow" once.
build\Traiectus-Server.exe

rem 3) Troubleshooting: print every forwarded event
build\Traiectus-Server.exe --verbose
```

Stop it with **Ctrl+C** in the console.

> `&` is a command separator in cmd.exe, so a device string **must be quoted**.

### UI language

`--lang zh|en` selects the language of the interfaces this program draws (the
pairing dialog, the `--show` window, `--help`, `--list`). Without it, the Windows
UI language is used. **The logs stay Chinese in both cases** - the tray finds the
server-ready line, the device lines and the hotkey lines by grepping the log.

### All command-line options (`--help` is authoritative; this is a quick reference)

| Option | What it does |
|---|---|
| `--device <substring>` | Forward only mice whose device path contains the substring; empty = auto-detect the one you use |
| `--detect` | Force one more device detection (what the tray's "Detect mouse…" uses) |
| `--port <port>` | TCP listen port, default 45789 |
| `--kb-port <port>` | UDP port for head-start frames / heartbeat to the Mac, default 45790; 0 = do not read frames |
| `--discover-port <port>` | UDP port for address discovery, default 45791; 0 = off |
| `--mac-ip <address>` | Where to send head-start frames; default = the connected client's IP |
| `--no-kb` | Do not read keyboard receiver frames (no head-start; mouse forwarding unaffected) |
| `--pair-file <path>` | Pairing file location |
| `--pair-timeout <sec>` | How long the pairing dialog waits, default 60 (**do not exceed 120**) |
| `--hotkey <combo>` | Mouse-switch hotkey, default `Ctrl+Alt+M`; `off` = no hotkey |
| `--bind <address>` | Listen address, default `0.0.0.0` |
| `--lang zh\|en` | UI language (see above) |
| `--list` | List mouse-class devices and exit |
| `--verbose` | Print every forwarded event |
| `--show` | Also show a small window (not needed for normal use) |
| `--start-in-mac-mode` | Start in Mac mode |
| `--watchdog <pid>` | Internal: watchdog |

## 4. Firewall (this step is your call)

On first run Windows shows "Windows Defender Firewall has blocked some features
of this app". **Tick "Private networks" and allow.**

> Do not tick "Public networks" - that would open the port on every network you
> ever join, including a cafe's Wi-Fi. "Private" is enough at home or in the
> office.

For a tighter rule, add one inbound rule for this program only (needs
**administrator** rights, and it is a firewall change - run it yourself):

```bat
rem add: allow only this program, only the private profile, only this TCP port
netsh advfirewall firewall add rule name="Traiectus server TCP 45789" dir=in action=allow ^
  program="C:\full\path\build\Traiectus-Server.exe" protocol=TCP localport=45789 ^
  profile=private enable=yes

rem remove it again when you do not need it
netsh advfirewall firewall delete rule name="Traiectus server TCP 45789"
```

If Windows has classified your network as "Public", that rule will not apply -
changing the network profile is a system setting change, so that one is yours to
weigh; it will not be done for you. (There is also
`Traiectus-防火墙放行.bat` in the repository root, which runs this with UAC
elevation and keeps the rules port-scoped.)

## 5. Checking that the Mac can reach it

```bat
rem see this PC's IP and network profile
ipconfig
```

From the **Mac**:

```bash
nc -vz <windows-ip> 45789      # "succeeded" means the port is reachable
```

## 6. Test checklist (do these in order when pairing up with the Mac)

| # | Do this | Expect |
|---|---|---|
| 1 | Move the mouse on Windows | The Mac cursor follows, same direction, no jumping |
| 2 | Left / right click on the Mac | Real clicks, while the Windows-local mouse is unaffected |
| 3 | Middle button, side buttons | Observe with a browser page (it shows button 1/3/4) |
| 4 | Wheel up / down | Same direction as on Windows |
| 5 | Type on Windows | Completely unaffected; keyboard events never enter this program |
| 6 | Close the Mac client | Windows prints "no data from the peer for 3 seconds" within 3 s and returns to waiting |
| 7 | Reopen the Mac client | Reconnects within 1 s (the client backs off up to 1 s) |
| 8 | Unplug the network cable | Both sides detect the drop; both mice are completely normal |
| 9 | Force-kill `Traiectus-Server.exe` | The Windows mouse is **immediately** normal |
| 10 | Close the console window | The program exits; the mouse is normal |

## 7. Implementation notes

```text
Main thread : hidden window + Raw Input (WM_INPUT)
              └─ filter by device -> produce protocol lines -> send queue
Network thread: one select() handles accept / recv / send / heartbeat
              └─ non-blocking socket, so a slow peer never blocks the main thread
```

| Design | Why |
|---|---|
| Every ``WM_INPUT`` sends one `MOVE dx dy` | No merging, no rewriting: the device's raw relative counts are what gets forwarded |
| Send queue capped at 8192 lines, then disconnect | Stops memory growing without bound if the peer cannot keep up |
| Non-blocking + partial-write handling | One `send` may push out half a line; the rest waits for the next writable moment |
| Heartbeat every 1 s / timeout at 3 s | Detects online/offline promptly; without it TCP can hang silently |
| A new connection displaces the old one | A restarted or reconnecting Mac is never stuck behind a stale connection |
| `SO_EXCLUSIVEADDRUSE` | Stops another program on this machine from grabbing the port |
| Relative deltas only | Absolute coordinates would jump whenever resolutions or scaling differ |

## 8. Known limitations

1. **Nothing is captured on the secure desktop** (UAC prompts, Ctrl+Alt+Del, the
   lock screen). That is by Windows design and cannot be worked around in user
   mode.
2. **Applications see roughly 145 packets/second** (measured in Phase 1). That is
   Windows' input delivery granularity, not packet loss.
3. **Absolute-coordinate devices** (RDP, drawing tablets) are ignored with a
   one-off notice.
4. **The keyboard is not forwarded** - switch it in hardware.
5. **Anti-cheat**: this program only reads input and sends it over the network;
   it does not inject, does not touch memory and does not hook. Still, quit it
   before playing a competitive game.
6. **Proxy software must let the LAN through.** The server uses plain sockets, so
   "system proxy settings" do not affect it; but a proxy in **TUN / virtual
   adapter mode** operates at the IP layer and routes by rule. If "private ranges
   direct" is not covered, packets are swallowed **with no error at all**: the
   Mac quietly stops receiving `KEY` status frames (no head start, the screen
   takes a second longer), `HB`, and the `HERE` reply. See the troubleshooting
   section of `launcher/说明.en.md`. (Every LAN-based KVM / screen-sharing /
   streaming tool has this requirement - it is not specific to this program.)

## 9. Pre-release self-check

1. Does it build? (see section 2)
2. Without `--device`, does the log show `DEVICE PICK <your mouse>` (automatic
   detection working)?
3. Is the firewall allowed (the dialog's "Private networks", or a manual rule)?
4. Did all 10 items of section 6 pass?

---

## 10. Control switching and the cursor lock (Phase 5 / 6, implemented early)

| Item | Implementation |
|---|---|
| Global hotkey | `RegisterHotKey` with a configurable combination, default **`Ctrl+Alt+M`**; `--hotkey <combo>` changes it (`off` = do not register). The tray's "Set mouse-switch hotkey" edits it and writes it back to `config.ini`. On start it prints one machine-readable line: `HOTKEY OK/FAIL/OFF <combo> [code]` (which the tray reads to show ✓ / ✗ taken). Syntax: modifiers joined with `+`, the last part is the main key, at least one modifier is required, the main key is A–Z / 0–9 / F1–F24 |
| Windows mode (default) | Nothing is forwarded and no lock is applied -> Windows is completely native (this is the gaming state) |
| Mac mode | Events are forwarded and `ClipCursor` pins the Windows cursor in place (1x1) |
| Mode notification | `MODE <Win\|Mac>` after the handshake and on every switch (protocol v1.1, see [`../../PROTOCOL.md`](../../PROTOCOL.md) §3.1) |
| Order of switching | Entering Mac: **lock the cursor first, then start forwarding** (the other way round lets the cursor run loose for a moment). Returning to Windows: **release any held buttons -> send `MODE Win` -> stop forwarding -> unlock** |
| Disconnect / exit | Client disconnect, Ctrl+C, closing the window, being force-killed - all return to Windows mode and release the lock |
| Force-kill backstop | A separate watchdog process (the same exe in `--watchdog <pid>` mode) unlocks within 200 ms |
| Start-up options | `--start-in-mac-mode` starts directly in Mac mode; `start-server.bat mac` is the same thing |

### Why the watchdog is mandatory (measured - do not remove it)

**A `ClipCursor` lock is not released when the process is force-killed**, which
leaves the Windows mouse trapped in a 1x1 area. That is exactly the state red
lines 13/14 forbid ("a crash must not make the mouse unusable"), so the watchdog
is **not optional**.

Another equally important measurement: **whenever any elevated window takes
focus, Windows clears everybody else's `ClipCursor` restriction** - opening Task
Manager with `Ctrl+Shift+Esc` frees the cursor immediately. That is a system-level
escape hatch, **more reliable than our own watchdog**; do not try to "fix" it.

### Known limitations

1. The watchdog only guards for up to **12 hours**, then exits by itself (after
   that a force-kill has no automatic unlock).
2. **Clicks are not suppressed**: in Mac mode a click still lands on the pinned
   1x1 point in Windows (usually harmless). Suppressing clicks as well would need
   a low-level mouse hook, which the red lines forbid.
3. Nothing is captured on the secure desktop (UAC prompts, the lock screen).

### Before you replace the exe

The watchdog is **the same exe**: if you delete or overwrite a running
`Traiectus-Server.exe`, the watchdog that is already guarding keeps running until
it decides to exit (the lock is released, or it times out). The normal exit path
does not have this problem.

---

## 11. Where the token comes from, and "Re-pair" (protocol v1.2)

### Where the token comes from (the server does **not** cache it)

```
pairing file  <- default <exe dir>\..\paired.json (the launcher passes --pair-file)
                 it holds one line: the 64-hex token generated during pairing
no file       -> HELLO gets ERR NOPAIR (the client then starts pairing itself)
```

**The `--token` option has been removed** (2026-10-01): pairing is the only
authentication path. Having both used to fight each other - once `--token` was
set, the pairing dialog could never appear again. The protocol is unchanged;
`HELLO` still carries the token, it just always comes from the pairing file.

Pairing flow: the Mac sends `PAIR? <device name>` -> Windows shows its own
confirmation dialog -> "Allow" generates a 64-hex token, writes it to the pairing
file and replies `PAIR-OK <token>`; "Deny" or closing the window replies
`PAIR-NO denied`; nobody touching it replies `PAIR-NO timeout`
(**60 seconds** by default, adjustable with `--pair-timeout <sec>` - it used to be
30, which is too short in practice: you have to click Connect on the other machine
and switch the monitor input first).

> ⚠️ **Hard constraint: the client's safety net must be longer than the server's
> confirmation window.** The Mac has a "give up waiting for `PAIR-OK`" safety net
> (currently **120 seconds**). Raising `--pair-timeout` above that creates a
> deadlock: the user clicks Allow at 40 s, but the Mac gave up at 120 s, the
> `PAIR-OK` goes into a connection nobody is reading, the token lands in
> `paired.json` while the Mac never received it, and the next connection is
> `already-paired`.
>
> The connection stays open during pairing: it is normal for the client not to
> send anything yet, and the server will not declare it dead.

### When you are stuck: `PAIR-NO already-paired`

```
Windows already has a pairing file (a token exists), but the Mac lost its copy
   -> the Mac sends PAIR?, Windows replies PAIR-NO already-paired (by design, so
      a stranger cannot displace an existing pairing)
   -> the Mac stops reconnecting and the user is stuck
```

**There is exactly one way out**: Windows tray -> "**Re-pair**" (deletes the
pairing file) -> the Mac clicks Connect again -> click "Allow". The Mac no longer
has a "type the token" box, so this is the only route.

---

## 12. Address discovery (UDP 45791)

On a fresh install neither side knows where the other is: the Mac is the one that
connects, so it has to learn the address first; and the server, having never had a
client, does not know who to send its heartbeat to - a deadlock. So the Mac
shouts first:

```
Mac     -> broadcasts "WHO 1"        (the second field is the protocol version)
Windows -> unicasts back "HERE 1 45789"   (the third field is the TCP port)
```

It is implemented in `DiscoveryThread()`: a separate UDP socket that **does not
depend on any client connection**, so the server can answer the moment it starts.
That is exactly why "a brand-new install is found automatically" works. Change
the port with `--discover-port` (default 45791, `0` = off).

### Three deliberate restrictions (security related, do not remove)

| Restriction | Why |
|---|---|
| **Only unicast back to the sender**, never a broadcast reply | A broadcast reply is ammunition for reflection amplification |
| **At most one reply per source per second** (the log uses the same rate limit) | Anti-flood; otherwise a single script can fill your network and your log |
| The reply contains **only the version and the port**, no token or pairing data | A port scan can already learn those two, so nothing extra is exposed |

A version mismatch (say `WHO 99`) -> **no reply**, just one log line, so old and
new versions simply ignore each other. Any other datagram (including the old
`MODE`) is ignored - **no error packet is ever sent**.

### Self-test (no Mac needed)

```powershell
$u = New-Object System.Net.Sockets.UdpClient
$u.Client.ReceiveTimeout = 3000
$b = [Text.Encoding]::ASCII.GetBytes("WHO 1")
$u.Send($b, $b.Length, "127.0.0.1", 45791) > $null
$ep = New-Object System.Net.IPEndPoint([Net.IPAddress]::Any, 0)
[Text.Encoding]::ASCII.GetString($u.Receive([ref]$ep))     # expect: HERE 1 45789
```
