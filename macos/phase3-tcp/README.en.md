# Traiectus Client (Phase 3) — receives and injects mouse events on the Mac

> English translation of [`README.md`](README.md) (Chinese). The Chinese file is authoritative.

This phase connects Phase 1's capture with Phase 2's injection: **connect to the Traiectus Server on
Windows and inject the forwarded mouse events into this Mac.**

The protocol is defined by [`PROTOCOL.md`](../../PROTOCOL.md) at the repository root. The direction is
**the Mac connects to Windows** (Windows is the listening side).

---

## 1. Project layout

```text
macos/phase3-tcp/
├─ README.md                 ← this file
├─ build.sh                  ← compile + assemble the .app + sign it
├─ Info.plist                ← app metadata (includes the local-network usage note)
└─ src/
   ├─ TraiectusClient.swift    ← TCP / heartbeat / reconnect + event injection + menu-bar state
   ├─ KeyboardLink.swift       ← keyboard link (Fn key → keyboard + mouse + screen switch together)
   ├─ SleepHotKey.swift        ← sleep hotkey (system-wide hotkey → put this Mac to sleep)
   └─ ui/
      ├─ TraiectusApp.swift     ← menu-bar app entry point (LSUIElement)
      ├─ PanelView.swift        ← the panel
      ├─ SettingsView.swift     ← the settings window
      ├─ ShortcutRecorder.swift ← the "press it and it records" shortcut field in Settings
      ├─ ConnectionDiagram.swift← the connection visualisation in the panel
      └─ LinkState.swift        ← state model
```

## 2. Building

```bash
cd macos/phase3-tcp
./build.sh
```

Output: `build/Traiectus-Client.app`. The script compiles with `swiftc` and signs with a local
self-signed certificate — **rebuilding does not lose the Accessibility grant** (see
[`../phase2-cgevent/README.md`](../phase2-cgevent/README.md) §9).

## Configuration: the only place to change when your hardware changes (config.json)

These values used to be hard-coded in the source: a different monitor, keyboard or tool location
meant editing code and rebuilding. They now live in one config file:

- **Location**: `~/Library/Application Support/Traiectus/config.json`
- **Template**: [`../../config.example.json`](../../config.example.json) (copy it and edit)

```json
{
  "display": { "macInput": "17", "windowsInput": "15" },
  "keyboard": { "vendorID": "0x1B1C" },
  "tools":    { "keywatch": "", "m1ddc": "", "dwc": "" },
  "network":  { "defaultHost": "" }
}
```

| Field | What it does | Default |
|---|---|---|
| `display.macInput` | the monitor's DDC/CI input number for the Mac side | `17` (HDMI-1) |
| `display.windowsInput` | the input number for the Windows side | `15` (DP-1) |
| `keyboard.vendorID` | which vendor's keyboard to watch (to tell whether the keyboard is on the Mac) | `0x1B1C` (Corsair) |
| `tools.keywatch` / `m1ddc` / `dwc` | locations of the three external tools; empty = use the ones bundled in the app | empty |
| `network.defaultHost` | the Windows address pre-filled in the settings window | empty |

- File missing / malformed / partial → missing fields fall back to defaults and **nothing breaks**
- Restart the app after editing; the `[配置] …` line in the startup log shows the values actually in
  effect
- Input numbers differ per monitor: `m1ddc get input` reads the current value, or check the monitor's
  manual
- The signing identity can be overridden too:
  `TRAIECTUS_SIGN_IDENTITY=… TRAIECTUS_SIGN_HASH=… ./build.sh`

## 3. Running and granting permissions

```bash
open "build/Traiectus-Client.app"
```

This is a **new app** (bundle id `com.minikvm.client`), so it has to be granted permission separately:

1. click **"Request permission"** in the window
2. System Settings → Privacy & Security → **Accessibility** → enable **Traiectus Client**
3. **quit the app and open it again** (permissions are read only at startup)

Also, since macOS 15, **the first time you connect to a LAN address it asks "allow Traiectus Client to
access the local network?" — you must allow it**, otherwise it cannot reach Windows. Loopback
(127.0.0.1) is exempt.

Fill in three things in the window: **Windows' IP, the port (default 45789) and the token (the same as
on the Windows side)**, then click "Connect".

## 4. Verifying this client without Windows

The repository ships a test script that pretends to be the Windows server, so you can exercise the
client on the Mac alone:

```bash
# terminal 1: start a fake Traiectus Server
python3 tools/traiectus-test-server.py --port 45789 --token test123 --demo --duration 30

# terminal 2: let the client connect to it (the -key value pairs in --args are read as temporary prefs)
open "macos/phase3-tcp/build/Traiectus-Client.app" --args \
     -minikvm.autostart YES -minikvm.host 127.0.0.1 -minikvm.token test123
```

`--demo` makes the fake server draw a square, click the left button once and scroll once. **If the
cursor actually moves, the whole "connect → parse → inject" chain works.**

> ⚠️ **You must launch it with `open` (the same as double-clicking); do not run
> `build/Traiectus-Client.app/Contents/MacOS/TraiectusClient` straight from a terminal.**
>
> When you run that binary from a terminal, macOS attributes the permission to **the process that
> launched it** (the terminal), so the app's own `AXIsProcessTrusted()` reports "not trusted" and the
> `CGEvent`s it injects are **silently dropped** — while the very same app launched with `open` is
> "trusted" and works fine.
>
> We actually hit this trap and spent a long time on it. So:
> - to start it from the command line, use `open <app> --args ...` and let launchd start it;
> - the app also writes its own log to `~/Library/Logs/TraiectusClient.log`, so whoever launched it,
>   you can read afterwards what the app itself saw (its permission verdict, for example).

The script has another switch dedicated to verifying failure protection:

```bash
python3 tools/traiectus-test-server.py --port 45790 --token test123 --stick-button
```

It sends one `DOWN L` and then **disconnects without a release**. The client log should contain
`补发抬起（防止按键卡住）：L` — that protection prevents the "left button stuck on the Mac, every click
becomes a drag" failure.

The log appears in three places: the app window, stderr (visible when started from a terminal) and
`~/Library/Logs/TraiectusClient.log` (reopened past 1 MB).

## 5. Design points in the code worth knowing

| Design | Why |
|---|---|
| Split on `\n`, keep the remainder in a buffer (`LineFramer`) | one `recv` can return half a line, one line or several; without framing you randomly lose events |
| `releaseAllHeldButtons()` on disconnect | the protocol only sends press/release, so the receiver holds "which keys are down"; not clearing it leaves keys stuck |
| Accumulate the wheel remainder (only a full 120 scrolls a notch) | high-resolution wheels send small values like `±1`; dropping them means the wheel does nothing |
| While a button is held, send `.leftMouseDragged` / `.rightMouseDragged` / `.otherMouseDragged` | sending `.mouseMoved` all the time makes the system think the cursor is merely moving — the symptom is that you **cannot drag files, drag selected text or drag window title bars** (found once on real hardware) |
| Heartbeat 1 s / timeout 3 s | when a cable is pulled or the peer sleeps, TCP reports nothing by itself; the heartbeat has to notice |
| Reconnect backoff 0.25 → 0.5 → 1 s, capped | fast recovery without flooding the log and the CPU |
| Connection-failure log suppression | with Windows off it reconnects forever; no need to print a line every second |
| Motion as "read current position + delta" | the protocol only sends relative deltas, avoiding pointer jumps from mismatched resolution maths |
| The sleep hotkey uses Carbon `RegisterEventHotKey`, **not** the "Services" shortcut in System Settings | Services shortcuts are registered by pbs and lose to the frontmost app's menu shortcuts: Finder's ⌘1 is "as icons", browsers use it for the first tab, so the event never reaches the service. A system-wide hotkey is claimed at the window-server level and works in any app |
| Sleeping goes through `osascript → System Events`, with `pmset` as fallback | the former works with normal user rights; the latter needs root on most systems. The first trigger asks "wants to control System Events"; if you deny it, Settings shows "需要授权" |

## 6. Known limitations (stated honestly)

1. **The feel is linear**: Windows' raw counts are injected 1:1 without an acceleration curve, so it
   feels "straighter" than a directly attached Mac mouse.
2. **Coordinates are clamped to the primary display**: repeatedly hitting the screen edge and coming
   back drifts against the Windows-side position. The real fix (edge switching / position sync) is a
   later phase.
3. **Middle and side buttons** go through `otherMouseDown/Up` (button 2/3/4). The middle button is
   verified working; the side buttons may not be recognised in some apps — a macOS mapping issue.
4. **The secure desktop** (UAC, lock screen) receives no input; that is by design.
5. **The keyboard is not forwarded** — it switches in hardware.
6. **The first click on a non-active window is swallowed by the system** — that is standard macOS
   behaviour, not a problem of this project: clicking the three traffic-light buttons in the top-left
   of the Traiectus Client window with the Windows mouse **only activates the window on the first
   click**; you need a second click (same for buttons in the content area). To hit it first time:
   click anywhere in the window to activate it, or switch to the app with the keyboard first.

## 7. Measurements (2026-09-24)

### 7.1 Protocol layer (using `tools/traiectus-test-server.py`, loopback 127.0.0.1)

| Check | Result |
|---|---|
| TCP connect + handshake (`HELLO 1 Mac test123` → `HELLO-OK 1`) | ✅ |
| Two-way heartbeat (the client PINGs every second; the server's PINGs are answered correctly) | ✅ round trip 0.2–0.4 ms (loopback) |
| `MOVE` / `DOWN` / `UP` / `WHEEL` send and parse | ✅ |
| `BYE` leads to a reconnect | ✅ |
| Reconnect backoff intervals | ✅ measured 0.27 / 0.53 / 1.07 s, matching the designed 0.25 → 0.5 → 1 s cap |
| Release on disconnect | ✅ the log shows `补发抬起（防止按键卡住）：L` |
| Log suppression while it keeps failing | ✅ printed only for the first two and every tenth attempt (`连接失败（第 50 次）`…) |

### 7.2 Injection (after granting permission; the criterion is the numbers shown by `tools/mouse-event-probe.html`)

| Check | Result |
|---|---|
| Motion: the cursor draws a 120×120 square and **returns to its starting point** | ✅ confirmed visually |
| Left button | ✅ the probe page logged `左键 按下 button 0` (a real click, made by clicking the page's copy button) |
| Right button | ✅ confirmed visually (the context menu appeared) |
| Middle button | ✅ the probe page logged `中键 按下 button 1 @ (580,548)` |
| Wheel up | ✅ the probe page logged `滚轮向上 deltaY=-40` (negative = up) |
| Wheel down | ✅ the probe page logged `滚轮向下 deltaY=+40` (positive = down) |
| Interop with the real Windows side | ⏳ pending the Windows build |

> **What the wheel numbers mean**: the client maps one notch (120 in the protocol) to a number of
> "lines" (`EventInjector.linesPerDetent`), and the browser converts those to pixels (1 line ≈ 40 px).
> Measured 2026-09-24: **that constant was changed from 1 to 3** — at 1 line a notch scrolled only
> 40 px, which felt slow; at 3 lines it is about 120 px, close to a real mouse's one notch.
> It is purely a feel parameter: change this one constant (4 for faster, 2 for slower); it affects
> neither the protocol nor correctness.

> **A trap that took a while to pin down**: the first attempts to verify used "run the binary inside
> the .app straight from a terminal", and the app reported "not trusted", so we assumed the grant had
> failed and kept reinstalling it; in reality macOS attributed the permission to **the process that
> launched it**. Launching with `open` fixed everything. See the warning in §4.

## 8. What I need reported back (then on to Phase 4)

1. ~~Did `./build.sh` succeed~~ → ✅ see §7
2. ~~Was the Accessibility permission granted~~ → ✅ granted (the local-network permission is only
   needed once you connect to a real Windows machine)
3. ~~Self-test with `tools/traiectus-test-server.py --demo`~~ → ✅ square, left, right, middle and the
   wheel all passed (see §7.2)
4. **Interop with the Windows side** (not done yet): are motion, left, right, middle, the side
   buttons and the wheel all correct?
5. **Failure scenarios** (not done yet): after pulling the cable / killing one side / force-killing the
   server, does the mouse on both sides recover immediately?

> Items 4 and 5 need the Windows side built first; see
> [`../../windows/phase3-tcp/README.md`](../../windows/phase3-tcp/README.md).

## 9. Installing the macOS way (recommended)

```sh
./build.sh          # builds build/Traiectus.app
./install-app.sh    # installs to ~/Applications + creates a login item (starts at login)
./install-app.sh remove   # uninstall (removes the login item and the installed copy)
```

**Why install it this way**: this is the standard shape for a resident menu-bar tool on macOS — the
app lives in `~/Applications`, is started at login by
`~/Library/LaunchAgents/com.minikvm.client.plist`, and is normally reached through the **menu-bar
icon**. Putting the app or a shortcut on the Desktop is **neither needed nor advisable**: on macOS the
Desktop is just an ordinary folder, and macOS 26+ renders Desktop aliases through the legacy icon
path, which easily produces the "same app, two faces" problem (grey on the Desktop, transparent in
the Dock).

Ways to start it (pick one): the menu-bar icon / the Dock (if you dragged it there) / `⌘ + Space` and
search for "Traiectus" / Finder → Applications.

> `install-app.sh` updates **in place** (it does not delete the whole bundle), keeping the bundle
> inode stable so the icon cache, LaunchServices records and the Dock entry all stay valid. It also
> starts the app with `/usr/bin/open`, which keeps the app's TCC identity (Accessibility / local
> network) identical to a manual double-click.
