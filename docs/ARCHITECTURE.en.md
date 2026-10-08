# Architecture and design rationale

> English translation of [`ARCHITECTURE.md`](ARCHITECTURE.md) (Chinese). The Chinese file is
> authoritative.

This document answers "why is each mechanism designed this way". For protocol details see
[`../PROTOCOL.md`](../PROTOCOL.md); for the process and the measured data see [`devlog/`](devlog).

---

## 1. Components

| Component | Where | Responsibility |
|---|---|---|
| **Traiectus Client** | Mac (SwiftUI menu-bar app) | connects to Windows, injects mouse events, keyboard link, sleep hand-off, sleep hotkey |
| **Traiectus Server** | Windows (C++ / Raw Input) | captures the mouse read-only, forwards according to control mode, pins the Windows cursor while Mac mode is active |
| **Traiectus Launcher** | Windows (tray entry point `Traiectus.exe`) | the user's only entry point: starts/restarts the server and the watchdog, the three tray status lines, detect mouse, set mouse-switch hotkey, re-pair, switch language, open log folder, quit |
| **Head-start frame reader** (inside the server since 3b) | Windows (C++, same exe as the mouse forwarding) | watches the keyboard receiver's status frames read-only → UDP tells the Mac to "head-start". **The old PowerShell bridge is retired** (its job moved into the server, so a distribution needs only one exe) |
| **kvm-keywatch** | Mac (C, IOKit) | watches the keyboard device appear/disappear on the Mac — i.e. "has the keyboard left?" |
| **m1ddc / dwc** | Mac (external CLIs, bundled with the app) | switch the monitor's input source over DDC/CI |
| **UI language tables** | Mac: `src/Localization.swift` (159 entries); Windows: `launcher/i18n.h` (113 entries) | Chinese original → English lookups; **UI only, logs stay Chinese** (keeping both ends aligned when debugging matters more) |

**How the UI language takes effect**: on the Mac you switch it in Settings → General → Language and it
**applies instantly, no restart**; on Windows the priority is `--lang` > `config.ini` `[ui] language` >
the system UI language (the tray can switch it too, and writes it back to the ini). Both tables fall
back to the Chinese original when a string has no entry — better Chinese than a blank or a raw key.

**Why the keyboard is detected as "device appeared/disappeared" rather than by reading key values**:
combos like `Fn+Caps` / `Fn+T` are handled **inside the keyboard firmware**, so the host never sees
that key at all. The only thing the host can observe is "this USB/Bluetooth keyboard device
disappeared from my side". That check needs **no permissions and no hooks**; the price is that you
only know it *left*, not where it went.

---

## 2. Mouse forwarding

```text
mouse ──2.4G──► Windows server ──TCP (LAN, line protocol)──► Mac client ──CGEvent──► system
                    │
                    └─ read-only Raw Input: no interception, the local Windows mouse keeps working
```

Key points:

- **Line protocol** (`\n` framing): one `recv` can return half a line, one line or several;
  `LineFramer` does the splitting and holds the remainder.
- **Dragging while a button is held** must send drag events such as `*.leftMouseDragged` — sending
  `mouseMoved` all the time makes the system think the cursor is merely moving, and the symptom is
  that you **cannot drag windows or files** (this bug showed up once on real hardware).
- **Release on disconnect**: `releaseAllHeldButtons()` when the connection drops, or keys stay stuck.
- **Wheel remainder accumulation**: high-resolution wheels send small values like `±1`; only a full
  notch (120) scrolls, otherwise the wheel does nothing at all.
- **Create the events with the HID system source**: some apps with automation features look at the
  event's source ID and may ignore synthetic events that do not come from HID.

---

## 3. One key switches everything (keyboard → screen + mouse)

```text
you press Fn+Caps
   │
   ├─ keyboard firmware: switch to the 2.4G host (Windows)   ← the host never sees this key
   │
   ├─ ① Windows server: the receiver emits status frame 00 00 01 36 00 02
   │       └─► UDP 45790 → Mac: "the keyboard is on its way"   ← about 1.7 s earlier than the Mac would notice
   │
   └─ ② Mac side: the keyboard disappears from the Bluetooth link
           └─► kvm-keywatch event → the keyboard has left, confirmed

After ① or ② the Mac does three things: switch the monitor input → move the cursor to the
centre of the screen → hand mouse control to Windows
```

**Why the head-start exists**: the Mac side can only see "the keyboard left" once the Bluetooth link
actually drops — measured **1.56–1.82 s later** than the receiver's status frame (and it is **only an
advantage in the Windows direction**: going back, the 2.4G drop and the Bluetooth reconnect happen
nearly together — measured only 0.13–0.28 s earlier, i.e. there was never any head-start that way).
The receiver emits a frame the moment the keyboard arrives, so the head-start wipes out those 1.7 s.

> Early on this frame reading lived in a separate PowerShell bridge; **since 3b it is inside the
> server** (read-only, enumerated by usagePage/usage, no hard-coded DevicePath), so a distribution
> needs only one exe.
>
> One measured conclusion along the way: **switching mouse control (`MODE`) has always travelled as a
> TCP protocol line**, never over UDP 45791 — the early "bridge relays the Mac's UDP replies to 45791"
> was actually redundant.

**Why move the cursor to the centre before switching the screen**: mouse control changes hands at the
same time as the input source; without re-associating, the cursor can end up off-screen or be
detached by the system (`CGAssociateMouseAndMouseCursorPosition`).

---

## 4. Sleep hand-off

```text
press ⌘1 (global hotkey; changeable in Settings)
   └─► NSWorkspace.willSleepNotification
          ├─ switch the monitor input to Windows
          └─ MODE Win (hand mouse control to Windows)

the system actually sleeps ≈ 4 s later (we finished the hand-off long before that)

wake (press any key)
   └─► didWakeNotification → wait 1.5 s for the Bluetooth ownership to settle
          ├─ switch back to HDMI (**not conditional on the peer being online** — Windows is often
          │   not connected yet at the moment of waking)
          └─ MODE Mac
```

**Why "the keyboard left the Mac" is not what triggers the sleep hand-off**: putting the Mac to sleep
tears down the keyboard's Bluetooth link, and the link would misread that as "the keyboard left".
Triggering off that side effect would make the hand-off wait 1.4 s; with the link disabled you would
wait for the server to notice the client is gone — **4–5 s of stall**. Listening to the system event
instead makes it 0.19 s.

**Why it "does nothing" while asleep**: the keyboard events during that window are the aftershock of
"the Mac went to sleep" (measured: the keyboard briefly hops to 2.4G and back). Only state is synced,
no actions fire, and a 60 s watchdog plus a 3 s wake grace period keep IOKit's replayed events from
switching the screen away the moment it wakes.

---

## 5. Why no hooks and no drivers

The design red lines (written at the very start of the project; every later trade-off respects them):

1. never affect normal Windows mouse input — hence **read-only** Raw Input, no interception
2. no drivers, no kernel extensions, no modified system files
3. no changes to G HUB / DPI / mouse firmware / network proxy
4. after exit, the Windows mouse must be exactly as it was (= it was never changed)

The one place that steps over the line is **pinning the cursor on the Windows side** (using
`ClipCursor` while Mac mode is active), and that comes with a 200 ms watchdog: even if the process is
force-killed, the cursor unlocks itself.

---

## 6. Known architectural boundaries

| Boundary | Explanation |
|---|---|
| Switching the keyboard's host is manual | that is the keyboard firmware's business. Only with the keyboard's USB cable plugged into the Mac can a vendor HID command be used (`00 08 01 3A 00 <mode>`, verified on the K70 Pro Mini) |
| The Mac must **sleep**, not shut down | the app has to stay alive so it can reconnect by itself when Windows comes up |
| DDC/CI only works on the current input | while the screen is on DP the Mac cannot see the monitor, so "switch back to the Mac" must be issued by the side that is on screen |
| Whether the monitor has "input auto-detect" changes the feel | if it does, "Mac sleeps → the picture moves by itself" is the monitor's doing; if not, it is entirely the software |
| Mouse coordinates are clamped to the primary display | repeatedly hitting the edge accumulates drift; edge switching is future work |
