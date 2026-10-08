# Traiectus wire protocol v1

> English translation of [`PROTOCOL.md`](PROTOCOL.md) (Chinese). The Chinese file is the
> **authoritative** definition; if the two ever disagree, follow the Chinese one. The root README's
> early draft was only a historical note.

---

## 0. Roles and direction

```text
   mouse ──► Windows PC ──────────────────► Mac mini
             Traiectus Server (listener)     Traiectus Client (connector)
             accept()                        connect()
```

- **Windows is the listening side (server)**, **the Mac is the connecting side (client)**. The Mac
  opens the TCP connection.
- Event direction: Windows → Mac. The Mac → Windows direction carries the handshake, heartbeats and
  the two optional control requests in §3.3.
- Default port **45789** (changeable with `--port` or in the UI).

---

## 1. Transport-level conventions

| Item | Convention |
|---|---|
| Transport | TCP, IPv4 (LAN) |
| Encoding | UTF-8 |
| Framing | **One message per line, terminated by `\n`**; the receiver ignores a trailing `\r` |
| Separators | Fields are separated by spaces, **runs of spaces count as one**; command and key names are case-insensitive |
| Line limit | **256 bytes** (excluding the trailing `\n`). Anything longer is invalid data — **the connection is dropped immediately** |
| Missing-newline guard | If 1024 bytes arrive without a `\n`, that is invalid too: drop the connection |
| Queue limit | If either side's outgoing queue exceeds 8192 lines, the peer is considered too slow: drop the connection (this bounds memory) |
| Connection count | The server accepts **one** client at a time; a new connection displaces the old one |

**Why a line-based text protocol**: when something breaks, `nc` is enough to reproduce it by hand —
no packet capture needed. It costs a few bytes per message more than a binary protocol, which is
nothing at `~145 lines/s` of a dozen-odd bytes each.

---

## 2. Handshake

Once the connection is up, **the client speaks first and its first message must be `HELLO`**:

```text
HELLO <protocol version> <role> <token>
```

Example:

```text
HELLO 1 Mac mysecret
```

- `<protocol version>`: currently `1`.
- `<role>`: `Mac` or `Win` (only used in logs and troubleshooting).
- `<token>`: **everything left on that line** (spaces allowed, newlines are not). An empty token means
  no check.

After checking version and token, the server answers:

```text
HELLO-OK 1              ; accepted
ERR AUTH                ; wrong version or wrong token; the server closes the connection right after
```

Rules:

- **Until `HELLO-OK` arrives, the client must discard any event lines** (so junk from a half-open
  connection can never be injected).
- If the client does not see `HELLO-OK` within **3 seconds** of sending `HELLO`, the handshake is
  considered failed: disconnect and reconnect.
- The server forwards no events before it has received `HELLO` (events are dropped before the
  heartbeat).

> The token travels in **clear text**. Its job is to stop other devices on the same subnet from
> casually connecting and injecting mouse events into your Mac — it is **not** protection against
> eavesdropping. That strength is fine for a home LAN; do not treat it as strong authentication.

### 2.1 Pairing (added in v1.2, optional, backwards compatible)

> Goal: the user should **not have to invent a token, nor type it on both machines**.
> The first connection is approved by clicking "Allow" on Windows; the token is generated
> automatically and stored on each side.

```text
PAIR? <device name>      ; client → server: I have no token yet, please pair
PAIR-OK <token>          ; server → client: the user clicked Allow on Windows, here is the token
PAIR-NO <reason>         ; server → client: denied / timed out / already paired
```

> **The token is never supplied by the user.** Since v1.3 the server no longer has the `--token`
> "pre-set token" switch, and the client UI has no token field either — the token has exactly two
> sources: the server generates it during pairing, and both sides store it. In other words, pairing
> is the only authentication path, and the user never needs to know what the token looks like.

**Client rules**

- **Token present locally** → send `HELLO` as before; the pairing flow is not involved at all (the old
  path is unchanged).
- **No token locally** → send `PAIR? <device name>` as the first message (the device name is only
  used to show who is asking in the Windows dialog).
  - `PAIR-OK <token>` → store the token, then establish the session with a normal `HELLO`.
  - `PAIR-NO <reason>` → tell the user, and fall back to the "enter the token by hand" entry point.

**The two sides' wait windows must be offset — and that is a hard constraint:**

| Side | How long | Why |
|---|---|---|
| Server dialog | `--pair-timeout`, **60 s by default** | on expiry it answers `PAIR-NO timeout` |
| Client safety net | **120 s** | only a backstop for "the server never answered" |

The client's safety net **must be clearly longer** than the server's dialog window. A client that
times out first causes real damage: it disconnects, but the server has already generated the token,
written it to disk, and will send `PAIR-OK` down a connection nobody is listening to. Next time the
client has no token → sends `PAIR?` → the server answers `already-paired` → the user is stuck in
"you must re-pair from the Windows tray".

> So: **if the server's `--pair-timeout` goes up, the client's safety net must go up with it.**
> Conversely the client must not "give up after a moment" — a normal person sees the dialog, switches
> the monitor, moves the mouse and clicks a button; twenty-odd seconds is normal (that is why the
> server's window went from 30 s to 60 s).

- Safety net expires with no answer → treat as failed, disconnect and reconnect (asking again on the
  new connection).

**Re-pairing must produce `ERR NOPAIR` (do not skip this)**

Re-pairing on the server = delete the pairing file. But the client **still holds the old token**, so
next time it sends `HELLO 1 Mac <old token>` as usual. At that moment the server has no token at all;
if it merely answered `ERR AUTH`, the client would conclude "wrong token" → stop reconnecting
automatically, and it would **never send `PAIR?`** (it has a token locally). Both ends end up stuck,
and the only way out is clearing the token on the Mac by hand.

So when the server has **no token at all**, it must answer a `HELLO` that cannot match with a
**dedicated** error code:

```text
ERR NOPAIR              ; the server has no token configured (neither --token nor a pairing file)
```

What the client does with it: **clear the local token**, then reconnect immediately — the reconnect
naturally goes through `PAIR?`.

Keep the two error codes apart:

| Server state | `HELLO <token>` arrives | Answer | What the client does |
|---|---|---|---|
| Has a token, matches | — | `HELLO-OK` | normal connection |
| Has a token, does not match | — | `ERR AUTH` | clear the local token, reconnect immediately → pairing (usually answered `already-paired`; tell the user per the table below) |
| Has no token | any token (including empty) | `ERR NOPAIR` | clear the local token, reconnect immediately → pairing |

> Why `ERR AUTH` also clears the token: **the client no longer has a "type the token" entry point**
> (see the next section). A mismatched token therefore has to self-heal, or the user is left staring
> at a "wrong token" error with nothing to click. After clearing:
>
> - the server has no token either → the dialog appears, the user clicks Allow, fixed
> - the server really does have a token (mine is old / someone else's) → it answers
>   `PAIR-NO already-paired` → the user is told to re-pair from the Windows tray
>
> Both turn a dead end into a clear path. No loop forms: after clearing, the client sends `PAIR?`,
> and the server either shows the dialog or answers `already-paired`.

**Server rules**

- The machine **already has a token** (from `--token`, or stored by a previous pairing) → **pairing
  mode is not entered**; every `PAIR?` is answered `PAIR-NO already-paired`. Reason: otherwise anyone
  on the same subnet could re-pair, which is no protection at all. To re-pair, the user clicks
  "Re-pair" in the Windows tray (which clears the local token).
- The machine **has no token** → on `PAIR?` show a dialog with the `device name` and the source IP:
  - user clicks "Allow" → generate a 32-byte random token (hex), **write it to disk**, answer
    `PAIR-OK <token>`.
  - user clicks "Deny" → answer `PAIR-NO denied`, close the connection.
  - the dialog waits `--pair-timeout` seconds (default **60**) with no answer → answer
    `PAIR-NO timeout`, close the connection.
- With no token on the machine, **no `HELLO` is ever accepted**; every one gets `ERR NOPAIR` (an empty
  token too). This changed in v1.2: "empty token = no check" used to leave the port open to every
  device on the network. If you want to avoid typing, use pairing — do not go back to "no token".

**Security boundaries (recorded honestly)**

- The pairing window only opens when this Windows machine **has never been paired**, and approving it
  requires physical access to the Windows machine.
- The token still travels in clear text, so **passive sniffing on the same subnet can capture it** —
  the same level as the `HELLO` token in §2; pairing does not make it stronger. Real eavesdropping
  protection would need TLS/PAKE, which is out of scope for a home setup and not implemented here.
- Pairing solves "hard to remember, hard to type, easy to mistype" — it does not solve "the LAN is
  untrusted".

---

## 3. Event messages (server → client)

```text
MOVE <dx> <dy>           ; relative motion, integers, may be negative
DOWN <key>               ; press
UP <key>                 ; release
WHEEL <delta>            ; vertical wheel, one notch = 120
HWHEEL <delta>           ; horizontal wheel, one notch = 120
```

`<key>` values: `L` (left), `R` (right), `M` (middle), `X1` (side 1), `X2` (side 2).

Example:

```text
MOVE 12 -7
DOWN L
UP L
WHEEL 120
```

**Hard constraint: motion is always sent as relative deltas, never as absolute coordinates.**
Absolute coordinates would require both sides to convert resolution and scaling, and any mistake
shows up as a jumping pointer; relative deltas have no such failure mode and map one-to-one onto the
device's raw counts.

Two real-world cases for the wheel:

- an ordinary mouse gives `±120` per notch;
- a high-resolution wheel (e.g. MX Master line-by-line scrolling) can produce small values like `±1`,
  and **the receiver must accumulate them itself**: only a full 120 counts as a notch, and the
  remainder carries over.

### 3.1 Control mode (added in v1.1, server → client)

```text
MODE <Win|Mac>
```

**Purpose**: tell the client which side currently holds control. Windows supports the `Ctrl+Alt+M`
hotkey, and the two modes behave completely differently:

| Mode | Server behaviour |
|---|---|
| **Windows mode** (default) | **forwards nothing**, adds no cursor lock → Windows stays fully native (this is the gaming state) |
| **Mac mode** | forwards events + pins the Windows cursor in place with `ClipCursor` (1×1) → the cursor cannot run or click by accident, while relative motion keeps flowing |

**When it is sent**: ① on every mode switch; ② **once immediately after the handshake** (so a
reconnecting client knows the current mode at once).

**What the client must do**:

1. on `MODE Win` → **release every key still marked as pressed** (same rule as §6) and then **ignore
   subsequent event lines** (defensive; covers the race at the moment of switching)
2. on `MODE Mac` → stop ignoring and resume injecting
3. after a reconnect, always take the `MODE` the server sends after the handshake — **never carry the
   old state over**

**Compatibility**: the protocol version stays `1` (a backwards-compatible extension). Clients that do
not know it ignore the line per §5, and because "Windows mode = the server sends no events at all",
**old clients are functionally correct without changes**; the change is defensive plus status display.

### 3.2 Cursor position when switching (server behaviour, since 2026-09-26)

On every mode switch the Windows side first moves the cursor to the **centre of the primary screen**,
then decides whether to lock it:

| Switch | Server actions |
|---|---|
| → Mac mode | `SetCursorPos(centre of primary screen)` → `ClipCursor(centre, 1×1)` (move first, then lock — the order cannot be reversed) |
| → Windows mode | release pending keys → send `MODE Win` → `ClipCursor(nullptr)` → `SetCursorPos(centre of primary screen)` |

**Why pin it to the centre instead of leaving it where it was**: the Mac-side cursor is driven by
relative motion, so having both sides symmetrical means you never get the "cursor flies in from a
corner" feeling when you start using the other machine. The Mac moves its own cursor to the centre of
its primary screen on every switch too (via `kvm-keywatch --center`, called by the link script).

### 3.3 Control request (client → server, optional extension)

```text
MODE <Win|Mac>
```

**Purpose**: let the Mac side **request** a control switch, equivalent to pressing `Ctrl+Alt+M` on
Windows. This is the missing link for "one `Fn` keypress = keyboard + mouse + screen all switch":
the keyboard's `Fn` combo lives inside the keyboard firmware and never reaches the host, so the Mac
has to notice the keyboard changing owner and send this request itself.

**Server behaviour**: it takes exactly the same `SetControlMode()` path as the hotkey and broadcasts
the new `MODE <value>` to the client. The trigger (hotkey or client request) makes no difference to
either side afterwards.

**Compatibility**: again a backwards-compatible optional extension; the protocol version stays `1`.
Old clients never send it, and an old server logs one `protocol errors` entry and ignores an unknown
command (without dropping the connection).

---

## 4. Heartbeat and timeouts

```text
PING <id>                ; both directions
PONG <id>
```

- Each side sends `PING` **once per second**; `id` is an incrementing integer.
- `PING` is answered immediately with `PONG <same id>`; incoming `PONG`s are used to compute the
  round-trip time.
- **If either side receives nothing from the peer for more than 3 seconds, the connection is
  considered dead** and closed. The client then enters its reconnect flow.

That timeout is what makes "cable pulled / Mac asleep / Windows asleep" show up promptly. Without it
the TCP connection just sits there quietly and both sides assume the other is still there.

---

## 5. Disconnect and reconnect

```text
BYE                      ; polite, intentional disconnect
```

- After `BYE` or a closed TCP connection (EOF), the client enters its reconnect flow and the server
  goes back to waiting for a new connection.
- The client reconnects with **exponential backoff, capped at 1 second**: 0.25s → 0.5s → 1s → 1s → …
- The server keeps listening forever; no manual intervention is needed no matter how often the client
  reconnects.
- Authentication failure (`ERR AUTH`) **does not auto-reconnect**, so a wrong token cannot spin and
  flood the log; the user fixes it and reconnects by hand.

---

## 6. State cleanup the client must do

The protocol only sends "press" and "release", so **the receiver necessarily holds the state of which
keys are currently down**. Therefore:

> **On connection drop, heartbeat timeout, or `BYE`, the client must send a release for every key
> still marked as pressed.**

Otherwise you get the classic "left button stuck on the Mac" failure — the mouse looks perfectly
normal, but every click turns into a drag. It is very annoying and not easy to connect back to the
KVM.

By the same rule, both sides respect the project's red line: **if either side crashes or exits, the
mouse and keyboard on that machine keep working**.

---

## 7. UDP-side channels (head-start frames + address discovery)

The TCP channel carries the handshake, events, heartbeat and control requests; there are two more
**UDP** channels with completely different jobs, and **neither takes part in authentication**.

### 7.1 Head-start frame channel (server → Mac, UDP 45790)

```text
KEY <hex bytes…>         ; the keyboard receiver's status frames (whatever was read, read-only)
HB                       ; keep-alive: every 2 seconds (the first one immediately)
```

- **Why `HB` exists**: after receiving `KEY`/`HB` the Mac replies **to the source address of the
  packet** (`PING` → `PONG`, a connectivity self-check); the 2-second `HB` keeps that return path
  alive and also lets the Mac learn the server's address (one of the three discovery paths, see 7.2).
- The port is changeable with `--kb-port`; `0` = do not read frames (head-start unavailable, mouse
  forwarding unaffected).
- **Only `PING`/`PONG` travel back on this channel**: since 2026-10-01 the early UDP branch
  `MODE <Mac|Win> <token>` has been **deleted** — control switching always goes over TCP `MODE`
  (§3.1 / §3.3), and a `MODE` arriving over UDP is ignored as an unknown message.
- While there is no target address yet (no client has connected and `--mac-ip` is not set),
  `KEY`/`HB` are dropped silently — no error, no log spam.

### 7.2 Address discovery (UDP 45791)

```text
Mac     → broadcast  WHO <version>            ; version is currently 1
Windows → unicast    HERE <version> <TCP port>  ; e.g. HERE 1 45789
```

- **What it solves**: on a fresh install neither side knows where the other is — the Mac is the
  connecting side, so it has to know where to connect, while Windows cannot know where to send
  heartbeats until a client has connected at least once. One broadcast from the Mac breaks the
  deadlock.
- The Mac's three discovery paths, in order: ① broadcast `WHO` (milliseconds) ② scan its own /24
  ③ learn from the source address of the `HB` in 7.1. Once found, the address is written into the
  client settings and it connects immediately.
- Three deliberate restrictions on the server side: **only unicast back to the source** (never reply
  to a broadcast — that would be a reflection amplifier); **at most one reply per source per second**;
  **the reply carries only the version and the port**, never a token or pairing information.
- This thread **does not depend on any client connection**: the server answers from the moment it
  starts.
- The port is changeable with `--discover-port`; `0` = discovery off (the Mac then falls back to
  scanning / heartbeat).

---

## 8. Known limitations (recorded honestly)

1. **The feel is linear.** Windows sends raw counts that have not been through "enhance pointer
   precision", and the Mac injects them 1:1, so mouse-only use feels a little "straighter" than a
   directly attached Mac mouse. Acceleration curves are a later stage.
2. **Coordinates are clamped to the primary display.** Relative deltas are cut off at the screen edge,
   so repeatedly hitting the edge and coming back drifts against the Windows-side position. The real
   fix (edge switching / position sync) is a later stage.
3. **The secure desktop is out of reach.** UAC prompts, the lock screen and Ctrl+Alt+Del do not deliver
   input to user-space programs; that is by design.
4. **The keyboard is not part of this protocol.** It is switched in hardware (the K70 Pro Mini's
   2.4G / Bluetooth); the software does not touch it.
5. **Switching the monitor input is manual.** The software does not touch the monitor's input
   selection.

---

## 9. Change log

| Version | Date | Change |
|---|---|---|
| v1 | 2026-09-24 | Initial: handshake (with token), `MOVE`/`DOWN`/`UP`/`WHEEL`/`HWHEEL`, two-way heartbeat, 3 s dead-peer timeout, exponential-backoff reconnect, 256-byte line and queue limits, release-on-disconnect |
| v1.1 | 2026-09-24 | Added `MODE <Win\|Mac>` (server → client, see §3.1). Proposed and implemented by the Windows side, confirmed by the Mac side before being written into the protocol; backwards compatible, protocol version unchanged |
| v1.2 | 2026-10-01 | Added pairing: `PAIR?` / `PAIR-OK` / `PAIR-NO` / `ERR NOPAIR` (see §2.1). **Backwards compatible** — two sides that already share a token behave exactly as before; plus one behaviour change: with no token, the server accepts no `HELLO` at all (answers `ERR NOPAIR`). Protocol version stays `1` |
| v1.3 | 2026-10-01 | **The token is no longer user-supplied**: the server drops `--token`, the client drops the token field, and pairing becomes the only authentication path (see §2.1). **Not a single byte of the message format changed**; the client's handling of `ERR AUTH` changed from "stop and sit there" to "clear the token and go through pairing again". Protocol version stays `1` |
| v1.4 | 2026-10-01 | **Address discovery**: the Mac broadcasts `WHO` and the server unicasts back `HERE` (UDP 45791, see §7.2); the same day the never-used UDP `MODE` branch was deleted (control switching always goes over TCP). This revision also writes both UDP-side channels into the document (§7.1 `KEY`/`HB`, §7.2 `WHO`/`HERE`). Protocol version stays `1` |
