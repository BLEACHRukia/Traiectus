# Sleep hotkey (SleepHotKey)

> English translation of [`README.md`](README.md) (Chinese). The Chinese file is authoritative.

> **Superseded by the built-in version (2026-09-29)**: this feature now lives in Traiectus' settings
> (`macos/phase3-tcp/src/SleepHotKey.swift` plus the "Sleep hotkey" section of the settings window),
> so the separate app and login item are no longer needed. This standalone version is kept for
> reference — **do not install it**: two programs fighting over the same ⌘1 means only one of them
> can register.

Press **⌘1** (`⊞Win + 1` on the K70) to put the Mac to sleep immediately.

## Why not just use "System Settings → Keyboard → Keyboard Shortcuts → Services"

We tried it, and pbs really did record
`(null) - 睡眠 - runWorkflowAsService → key_equivalent = "@1"`, but **services shortcuts rank behind
the current app's menu shortcuts**:

- Finder's ⌘1 is "as icons"
- Chrome / Safari's ⌘1 is "first tab"

Once the frontmost app eats ⌘1, the event never reaches the service — the symptom is "I press it and
nothing happens".

This tool instead registers a **system-wide hotkey** with Carbon's `RegisterEventHotKey`, which is
claimed at the window-server level ahead of any app's menu shortcuts, so it works whatever is in
front.

## Contents

| File | Purpose |
| --- | --- |
| `SleepHotKey.swift` | the program: registers the hotkey → calls `osascript` to have System Events sleep |
| `Info.plist` | `LSUIElement = true`, so it never appears in the Dock |
| `build.sh` | builds `build/睡眠热键.app` |
| `com.traiectus.sleephotkey.plist` | the LaunchAgent template for starting at login |

## Install locations

```
~/Applications/睡眠热键.app
~/Library/LaunchAgents/com.traiectus.sleephotkey.plist
~/Library/Logs/sleep-hotkey.log      ← one line per press
```

## How sleeping is implemented

1. `osascript -e 'tell application "System Events" to sleep'` (works with normal user rights)
2. if that fails, fall back to `pmset sleepnow` (needs root on some system versions)

If both fail, the log says `⚠️ 两种方式都没成功` (neither method worked).

## Changing the combination / disabling it

Edit `--keycode` / `--modifiers` in
`~/Library/LaunchAgents/com.traiectus.sleephotkey.plist`
(`⌘`=256, `⌥`=2048, `⌃`=4096, `⇧`=512; the keycode for `1` is 18), then
`launchctl bootout gui/$(id -u)/com.traiectus.sleephotkey` followed by `launchctl bootstrap`.

To disable:

```sh
launchctl bootout gui/$(id -u)/com.traiectus.sleephotkey
rm ~/Library/LaunchAgents/com.traiectus.sleephotkey.plist
```

> Note: once ⌘1 is taken over globally, ⌘1 in Finder and browsers puts the Mac to sleep too.
