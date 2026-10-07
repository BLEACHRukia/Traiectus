# Roadmap

> English translation of [`ROADMAP.md`](ROADMAP.md) (Chinese). The Chinese file is authoritative.

## 1. UI localisation (both sides)

**Where it stood**: the Mac app's UI, prompts and logs were all Chinese; the Windows tray's
right-click menu was Chinese too (start / restart / open log folder / detect mouse / set mouse-switch
hotkey / re-pair / quit).

**Why it came first**: the website already had an English version (`traiectus.cn/en`) while the app
UI was Chinese only — English users got "English page + screenshots of a Chinese UI". It is also the
first thing English users ask for. (The settings-window screenshot was temporarily removed from the
English page until the app had an English UI.)

**What was needed**

- **Mac**: pull the UI strings out into a `Localizable.strings` (`zh-Hans` / `en`) that follows the
  system language; settings page, panel, status text and permission prompts included
- **Windows**: tray menu and startup banner switch with the system language (or a `--lang en` flag)
- **Logs stay Chinese** — keeping both sides aligned when debugging matters more; only the
  "user-visible interface" is localised

**Once it is done**: the Chinese and English pages of the website can each carry screenshots of their
own language.

---

## Other items (not scheduled yet)

- a demo GIF / short video on the website (press one key → keyboard, mouse and screen all switch)
- a `/docs` section on the website: quick start + FAQ (content can come from the repository `README`
  and `docs/TROUBLESHOOTING.md`)
- parameterising the Windows-side keyboard interface triple
  (`--kbd-vid` / `--kbd-usage-page` / `--kbd-usage`,
  see the end of `给Windows端/2026-10-03-鼠标设备自动识别-任务单-给Windows端.md`)
