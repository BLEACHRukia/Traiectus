# Troubleshooting

> English translation of [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) (Chinese). If the two ever
> disagree, the Chinese file is authoritative. Log output is Chinese by design, so the log lines
> quoted below are kept verbatim.

Ordered "most common first". Every step tells you **where to look** and **what you should see**.

---

## 0. Read the logs first — don't guess

| Side | Log |
|---|---|
| Mac | `~/Library/Logs/Traiectus.log` (the `[配置]` line at startup shows the parameters actually in effect) |
| Windows server | the server window; also written to `windows\phase3-tcp\build\server-live.log` |
| Windows head-start frame reader | **inside the server log** (since 3b the server does this itself — there is no separate bridge process or log any more) |
| System power events | on the Mac: `pmset -g log \| grep -E "Entering Sleep\|Wake from"` |

---

## 1. The Mac can't connect to Windows

Check in this order — **eight times out of ten it's the first two**:

1. **Is the Windows server running at all?** The Mac log will show endless reconnects. The server
   is a manual entry point (the tray icon), deliberately not a login item.
2. **Firewall**: Windows must allow **TCP 45789** (the protocol) and **UDP 45790** (head-start
   frames + the heartbeat return path; switching control goes over TCP and does not need UDP
   45791, but leaving that older rule in place is harmless).
   The repo has `windows/control-channel/Traiectus-firewall.ps1`.
3. **Token mismatch**: the token on the Mac must match `windows/phase3-tcp/token.txt` (the same
   word, no spaces). A failed handshake shows up as `ERR` in the Mac log and the panel shows
   "异常" (error).
4. **Two clients running?** If the log keeps repeating `已多次「握手成功后又失联」`, remember the
   server accepts only one client at a time — make sure there is no second instance.
5. **Is the subnet actually reachable?** On the Mac: `nc -z <Windows-IP> 45789`.

---

## 2. The mouse doesn't move on the Mac (but the cursor is "locked" in the middle of Windows)

1. **Accessibility permission**: System Settings → Privacy & Security → **Accessibility** → tick
   Traiectus. The log says it directly: `[启动] 辅助功能权限：未授权`.
2. **The mouse must be on the wireless link**: the Windows server filters by device
   (`--device VID_…`) and only captures input from the 2.4G receiver. If you switch the mouse to
   wired, its device id changes — re-check it in `windows/phase3-tcp/`
   (`list-rawinput-devices.ps1`).
3. **Rebuilding dropped the permission again**: with an ad-hoc signature, every rebuild changes
   the app's TCC identity. Run `macos/phase3-tcp/make-signing-identity.sh` once to create a
   self-signed certificate; after that, rebuilds keep the grant.

---

## 3. The monitor doesn't follow

1. **The monitor's DDC/CI switch**: ASUS and others have a separate OSD item and it may ship
   disabled. While it is off, no software can switch the input.
2. **DDC/CI only works on the input that is currently displayed**: while the screen is on DP, the
   Mac cannot see the monitor at all (it doesn't even appear in `system_profiler`) — so
   "switch back to the Mac" must be issued **by the side that is on screen at that moment**. That
   is why both sides need the ability to switch.
3. **Wrong input numbers**: `17 = HDMI-1`, `15 = DP-1` are the values measured on this machine;
   they change with the monitor. They live in the `display` section of
   `~/Library/Application Support/Traiectus/config.json`.
   The log shows the value actually used and the exit code:
   `[联动] 屏幕 → Mac/HDMI（m1ddc 62 ms，退出码 0）`.
4. **Occasional failure right after wake**: DDC can fail once with exit code 1 after ~20 ms when
   the machine has just woken. The code retries three times; seeing "重试N次" in the log is normal.

---

## 4. The keyboard switched host but the screen didn't follow

1. **Is `kvm-keywatch` running?** `[联动] ⚠ 找不到 kvm-keywatch` in the log means it wasn't found
   (normally it is bundled with the app in `Contents/Resources/`).
2. **Is the vendor ID right?** It watches the keyboard vendor (Corsair `0x1B1C` by default).
   A different brand means editing `keyboard.vendorID` in `config.json`.
3. **Did the keyboard really "leave"?** The tool detects the keyboard appearing/disappearing on
   the Mac; if the keyboard is plugged into the other machine (e.g. USB on Windows), the Mac side
   sees no change at all.
4. **The head-start needs the server to find the receiver**: the server's startup log says
   "找到接收器 VID_1B1C … usage=0x0002"; if it can't find it, it says "抢跑不可用，鼠标转发不受影响"
   and retries every 30 seconds. In that case only the Mac's own detection works (about 1.7 s
   slower in the Windows direction) — but the switch still happens.

---

## 5. Sleep hand-off doesn't work

1. **Is the "键盘联动" (keyboard link) switch on** in the settings panel? With the link off, the
   whole sleep hand-off is skipped.
2. **Automation permission**: the sleep action goes through `osascript → System Events`, so
   System Settings → Privacy & Security → **Automation** must have Traiectus ticked. Without it
   the settings page shows "需要授权".
3. **The app must be alive**: the Mac has to **sleep**, not shut down — after a shutdown nobody is
   there to connect when Windows comes up.
4. **Compare the timeline**:

   ```text
   [22:48:34.594] 睡眠快捷键触发 → 请求睡眠
   [22:48:34.696] [联动] 系统即将睡眠 → 把屏幕与鼠标交给 Windows
   [22:48:39]     ← pmset：系统真正睡下去（比交接晚约 4 秒，正常）
   ```

---

## 6. Other traps we have hit

| Symptom | Cause / what to do |
|---|---|
| After moving the repo, the build can't find `SwiftShims` | Delete `macos/phase3-tcp/.build` and `build/module-cache`, then build again |
| The Dock icon turned into a question mark | The bundle id changed. Remove the Dock tile and drag it back |
| The desktop icon is still the old one after a rebuild | `build.sh` updates the `.app` in place (it doesn't delete it), so the icon cache lags — wait, or refresh with `lsregister -f` |
| Windows cursor is still locked after quitting the tray | A 200 ms watchdog unlocks it; if it didn't, run `windows/tools/清理旧版本残留.bat` |
| `start-server.bat` says "没有找到握手口令" | Create `token.txt` (one line) next to it, or set the `TRAIECTUS_TOKEN` environment variable |
| The tray dialog says "token 还是占位符" | `launcher\config.ini` isn't filled in — copy it from `config.example.ini` and put the token in |
| A search reports a flood of files as leaked | Search **case-sensitively**: the share name `SHARED` (upper case) matches case-insensitive searches |
