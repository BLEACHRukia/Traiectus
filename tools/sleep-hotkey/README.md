# 睡眠热键（SleepHotKey）

> **已被内置版本取代（2026-09-29）**：这个功能现在做进了 Traiectus 的设置里
> （`macos/phase3-tcp/src/SleepHotKey.swift` + 设置窗口的「睡眠热键」一节），
> 不再需要单独的 app 与登录项。这份独立版本保留作参考，装机时不要再安装它 ——
> 两个程序抢同一个 ⌘1，只会有一个注册成功。

按 **⌘1**（K70 上的 `⊞Win + 1`）让 Mac 立即睡眠。

## 为什么不直接用「系统设置 → 键盘 → 键盘快捷键 → 服务」

试过，pbs 里也确实写进了 `(null) - 睡眠 - runWorkflowAsService → key_equivalent = "@1"`，
但**服务快捷键排在当前 App 的菜单快捷键之后**：

- Finder 的 ⌘1 = 「显示为图标」
- Chrome / Safari 的 ⌘1 = 「第一个标签页」

前台 App 吃掉 ⌘1 之后，事件根本轮不到服务，表现就是「按下没反应」。

本工具改用 Carbon `RegisterEventHotKey` 注册**系统级热键**，
在窗口服务器层就被它接走，优先于任何 App 的菜单快捷键，因此任何界面下按下都生效。

## 组成

| 文件 | 作用 |
| --- | --- |
| `SleepHotKey.swift` | 主程序：注册热键 → 调 `osascript` 让 System Events 睡眠 |
| `Info.plist` | `LSUIElement = true`，不出现在 Dock / 程序坞 |
| `build.sh` | 编译出 `build/睡眠热键.app` |
| `com.traiectus.sleephotkey.plist` | 登录自动启动的 LaunchAgent 模板 |

## 安装位置

```
~/Applications/睡眠热键.app
~/Library/LaunchAgents/com.traiectus.sleephotkey.plist
~/Library/Logs/sleep-hotkey.log      ← 每次按下都会记一行
```

## 睡眠的实现路径

1. `osascript -e 'tell application "System Events" to sleep'`（普通用户权限即可）
2. 失败则兜底 `pmset sleepnow`（部分系统版本需要 root）

两条都失败会在日志里写 `⚠️ 两种方式都没成功`。

## 改组合键 / 停用

改 `~/Library/LaunchAgents/com.traiectus.sleephotkey.plist` 里的 `--keycode` / `--modifiers`
（`⌘`=256、`⌥`=2048、`⌃`=4096、`⇧`=512；`1` 的 keycode 是 18），
然后 `launchctl bootout gui/$(id -u)/com.traiectus.sleephotkey` 再 `launchctl bootstrap` 回来。

停用：

```sh
launchctl bootout gui/$(id -u)/com.traiectus.sleephotkey
rm ~/Library/LaunchAgents/com.traiectus.sleephotkey.plist
```

> 注意：⌘1 被全局接管后，Finder / 浏览器里的 ⌘1 也会变成睡眠。
