# 路线图 / Roadmap

> 开源后的第一项功能 / First feature after the open-source release

## 1. 界面英文本地化（两端） —— ✅ 已完成

**当时的现状**：Mac app 的界面、提示、日志全是中文；Windows 托盘的右键菜单也是中文
（启动 / 重启 / 打开日志目录 / 检测鼠标 / 设置鼠标切换快捷键 / 重新配对 / 退出）。

**为什么先做这个**：官网已经有英文版（`traiectus.cn/en`），但软件界面只有中文 ——
英文用户看到的是「英文页面 + 中文界面截图」。这也是英文用户第一个会提的需求。
（官网英文页里的设置窗口截图，现已暂时移除，等软件有英文界面再补。）

**做了什么**

- **Mac**：界面文案抽成中英对照表（`macos/phase3-tcp/src/Localization.swift`，159 条），
  设置里可切 中文 / English，**点一下当场生效**；设置页、面板、状态文字、权限提示都在范围内
- **Windows**：托盘菜单、弹窗、配对框、启动横幅、`--help` / `--list` 全部中英双语
  （`windows/launcher/i18n.h`，113 条）；语言三级优先：
  `--lang` > `config.ini` 的 `[ui] language` > 系统 UI 语言
- **日志保持中文** —— 排查时两端对得上更重要，只本地化"用户可见的界面"

**做完之后**：官网中英两版各自配上了本语言的界面截图。

**顺着做完的（原计划里没有）**

- 仓库文档双语化：12 份英文版（`README.en.md`、`PROTOCOL.en.md`、`docs/*.en.md`、
  Windows / Mac 的 `*.en.md`），中文保持默认文件名（GitHub 首页显示中文）
- 官网英文页的「Read the docs」改指向 `README.en.md`（中文默认页不再把英文用户带走）

---

## 其它（尚未排期）

- 官网加演示 GIF / 短视频（按一次键 → 键盘、鼠标、屏幕一起换边）
- 官网 `/docs`：快速开始 + 常见问题（内容可从仓库 `README` / `docs/TROUBLESHOOTING.md` 搬）
- Windows 端键盘接口三元组参数化（`--kbd-vid` / `--kbd-usage-page` / `--kbd-usage`，
  见 `给Windows端/2026-10-03-鼠标设备自动识别-任务单-给Windows端.md` 末尾）
