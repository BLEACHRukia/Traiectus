# Roadmap

> English translation of [`ROADMAP.md`](ROADMAP.md) (Chinese). The Chinese file is authoritative.

## 1. UI localisation (both sides) — ✅ done

**Where it stood back then**: the Mac app's UI, prompts and logs were all Chinese; the Windows tray's
right-click menu was Chinese too (start / restart / open log folder / detect mouse / set mouse-switch
hotkey / re-pair / quit).

**Why it came first**: the website already had an English version (`traiectus.cn/en`) while the app
UI was Chinese only — English users got "English page + screenshots of a Chinese UI". It is also the
first thing English users ask for. (The settings-window screenshot was temporarily removed from the
English page until the app had an English UI.)

**What was done**

- **Mac**: the UI strings became a Chinese/English table
  (`macos/phase3-tcp/src/Localization.swift`, 159 entries) with a 中文 / English switch in Settings
  that **applies instantly**; settings page, panel, status text and permission prompts included
- **Windows**: tray menu, dialogs, pairing dialog, startup banner, `--help` and `--list` are all
  bilingual (`windows/launcher/i18n.h`, 113 entries); language priority is
  `--lang` > `config.ini` `[ui] language` > the system UI language
- **Logs stay Chinese** — keeping both sides aligned when debugging matters more; only the
  "user-visible interface" is localised

**Once it was done**: the Chinese and English pages of the website each carry screenshots in their
own language.

**Done along the way (was not planned)**

- the repository's docs became bilingual: 12 English files (`README.en.md`, `PROTOCOL.en.md`,
  `docs/*.en.md`, and the Windows / Mac `*.en.md`), with Chinese keeping the default file names (so
  GitHub shows Chinese)
- the English page's "Read the docs" now points at `README.en.md` (the Chinese default page no longer
  takes English readers with it)

---

## Other items (not scheduled yet)

- a demo GIF / short video on the website (press one key → keyboard, mouse and screen all switch)
- a `/docs` section on the website: quick start + FAQ (content can come from the repository `README`
  and `docs/TROUBLESHOOTING.md`)
- parameterising the Windows-side keyboard interface triple
  (`--kbd-vid` / `--kbd-usage-page` / `--kbd-usage`,
  see the end of `给Windows端/2026-10-03-鼠标设备自动识别-任务单-给Windows端.md`)
