# MiniKVM — Phase 2：macOS 鼠标事件合成测试程序（Swift + CGEvent）

> **历史记录**：本文写于产品名为 MiniKVM 的时期（2026-09-29 正式改名为 **Traiectus**）。
> 正文保留当时的原名/路径，以免记录失真；当前名称与路径见 `README.md`。


本阶段只做一件事：**在 Mac 上证明"用 macOS 官方 API 合成鼠标事件"可行**，并搞定「辅助功能」权限。

本阶段**不联网**、**不接收 Windows 的数据**（那是 Phase 3）。它只在你点按钮时，让 Mac 自己动一下光标。

---

## 1. 需要什么

- Mac（你的 Mac mini，Apple Silicon / arm64）
- **Xcode**，或者只要 **Command Line Tools**：

  ```bash
  xcode-select --install
  ```

  （装了完整 Xcode 也可以，两者都自带 `swiftc`）
- 不需要 Homebrew、不需要任何第三方库、不需要安装任何运行时。

---

## 2. 项目结构

```text
macos/phase2-cgevent/
├─ README.md                    ← 本文件
├─ build.sh                     ← 一条命令编译 + 打包成 .app
├─ Info.plist                   ← App 元信息（bundle id / 最低系统版本等）
└─ src/
   └─ MiniKVMPhase2.swift       ← 全部代码（SwiftUI 界面 + CGEvent 合成）
```

---

## 3. 编译

把整个 `MiniKVM` 文件夹复制到 Mac 上（U 盘、隔空投送、或者你自己熟悉的任何方式），然后：

```bash
cd MiniKVM/macos/phase2-cgevent
chmod +x build.sh      # 只需要一次
./build.sh
```

成功后会看到：

```text
✅ 构建完成： build/MiniKVM.app
```

脚本做三件事：用 `swiftc` 编译 → 组装标准 `.app` 目录 + Info.plist → ad-hoc 签名（让权限能绑定到这个 App 上）。

> 如果你更习惯 Xcode：新建一个 macOS App 工程（SwiftUI，Interface 选 SwiftUI），把 `src/MiniKVMPhase2.swift` 的内容整个粘进 `ContentView.swift` 之类的位置，删掉模板自带的 `@main` 冲突文件即可。两条路等价，`build.sh` 只是省事。

---

## 4. 运行与授权

```bash
open "build/MiniKVM.app"
```

窗口里最上面一行会显示权限状态（红点 = 未授权）。

**授权步骤：**

1. 点窗口里的 **「请求权限」**（会弹出系统提示），或者点 **「打开系统设置」** 直接跳到对应页面
2. 路径是：**系统设置 → 隐私与安全性 → 辅助功能**
3. 如果列表里没有 `MiniKVM`，点 **+** 手动添加：

   ```text
   <你的路径>/MiniKVM/macos/phase2-cgevent/build/MiniKVM.app
   ```

4. 打开开关
5. **退出并重新打开这个 App**（权限是启动时读取的，不重启不生效）

> 重要：权限是跟 **App 的路径 + 签名身份** 绑定的。授权之后**不要再移动这个 .app**，否则可能失效，需要重新授权。
> 但**重新编译不再需要重新授权**了——因为 App 现在用一张本机自签名证书签名，而不是 ad-hoc 签名，详见第 9 节。

---

## 5. 测试清单

先按顺序做，每一项都对照"预期"。

### Test 1：移动

点 **「移动测试（画圈）」** → 光标应该以当前位置为圆心画一个半径 180 像素的圆，约 1 秒画完，然后**回到原位**。

- 窗口日志里会打印圆心坐标和"移动测试完成，光标已复位"
- 如果光标完全不动 → 权限没生效（见上面第 4 步），日志里也会有 ⚠︎ 提示

### Test 2 / 3：左键、右键

> 建议先把光标移到**桌面空白处**，再点按钮，避免误点到别的东西。

点 **「左键」** → 桌面／窗口应该产生一次真实的左键单击（比如点桌面会取消选中）。
点 **「右键」** → 应该弹出右键菜单。

### Test 4：中键

中键在桌面上没有任何反应，而**点本窗口的按钮本身就会把光标挪到窗口上**——所以中键和滚轮都做成了「**延迟 5 秒执行**」，按下按钮后你有时间把光标放到目标上：

1. 用浏览器打开仓库里的 `tools/mouse-event-probe.html`（纯本地页面，把浏览器实际收到的按键编号与滚轮数值直接显示出来）
2. 点窗口里延迟那行的 **「中键」**
3. 立刻把光标移到那个页面上，**停住别动**
4. 倒计时结束（日志逐秒打印 `… 还有 N 秒`，最后打印执行坐标），页面上应出现 `中键 按下 button 1`

### Test 5：滚轮

同样用延迟那行：

1. 光标停在 `tools/mouse-event-probe.html` 上
2. 点 **「滚轮上」** → 页面应打印 `滚轮向上 deltaY=<负数>`
3. 点 **「滚轮下」** → 页面应打印 `滚轮向下 deltaY=<正数>`
4. 再用真鼠标在同一页面滚一下做对照：合成事件的 `deltaY` 符号应与真鼠标一致

> 为什么用这个页面而不是"看某个软件有没有反应"：看软件反应测的是**那个软件的约定**（中键关标签只有部分浏览器支持，而且前提是手上的设备真能发出中键）；而这个页面直接显示的是**事件本身**。合成事件与真鼠标在这个页面上的表现应当一模一样。

### Test 6：全套

点 **「▶︎ 全套测试（约 6 秒）」** → 依次执行：画圈 → 左键 → 右键 → 中键 → 滚轮上 → 滚轮下，日志会逐条记录。

> 注意：全套测试是在**光标当前所在位置**依次执行的，所以它只能证明"事件确实按顺序发出去了"，测不出中键／滚轮的真实效果（在桌面上按中键本来就没反应）。中键和滚轮请按上面 Test 4／5 单独测。

---

## 6. 实现原理（这一阶段用了哪些官方 API）

| 用途 | API | 说明 |
|---|---|---|
| 权限检查 | `AXIsProcessTrusted()` | ApplicationServices，返回是否已有辅助功能权限 |
| 弹授权提示 | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` | 系统会把本 App 加进"辅助功能"列表 |
| 打开设置页 | `NSWorkspace.open("x-apple.systempreferences:...?Privacy_Accessibility")` | 直接跳到辅助功能面板 |
| 读取光标位置 | `CGEvent(source: nil)?.location` | 全局坐标，原点在主显示器左上角，y 向下 |
| 移动光标 | `CGEvent(mouseEventSource:mouseType:.mouseMoved:mouseCursorPosition:mouseButton:)` + `post(tap: .cghidEventTap)` | 发到 HID 事件层，等同于真实鼠标移动 |
| 左/右键 | `.leftMouseDown/.leftMouseUp`、`.rightMouseDown/.rightMouseUp` | 成对 down/up 才是一次完整点击 |
| 中键 | `.otherMouseDown/.otherMouseUp` + `mouseButton: .center` | 中键在 CoreGraphics 里属于 "other button" |
| 滚轮 | `CGEvent(scrollWheelEvent2Source:units:.line:wheelCount:wheel1:wheel2:wheel3:)` | `wheel1` 正数向上、负数向下，1 格 = 1 行 |

这些都是 **CoreGraphics / ApplicationServices 的现行 API**，没有一个是被 macOS 废弃的；没有用 Qt，也没有用任何第三方输入库。

---

## 7. 已知限制与"我不确定"的地方（如实说明）

> **编译状态（2026-09-24 更新）：`./build.sh` 已在 Mac 上实测通过** —— swiftc 6.4（Command Line Tools）／arm64／macOS 13+ 目标，产出 `build/MiniKVM.app`（Mach-O arm64，ad-hoc 签名 `codesign --verify --deep --strict` 通过）。首编时确实有报错，已修，见下面第 1、2 条。

1. ~~这份 Swift 代码无法在写它的那台机器上编译验证~~ → **已解决**：首次编译报 `'main' attribute cannot be used in a module that contains top-level code`，原因是 `swiftc` 对单文件默认按"顶层代码脚本"处理。修法是给 `build.sh` 的 `swiftc` 调用加 **`-parse-as-library`**（已加）。
2. ~~`kAXTrustedCheckOptionPrompt` 的类型~~ → **已解决**：本机 SDK 里它是 `Unmanaged<CFString>`，原来的 `kAXTrustedCheckOptionPrompt as String` 报 `cannot convert value of type 'Unmanaged<CFString>' to type 'String'`。已按预案改成 `kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String`。
3. **授权后必须重启 App**，否则 `CGEventPost` 静默无效（这也是新手最容易踩的坑）。
4. **Secure Input 限制**：当焦点在密码框等启用"安全输入"的地方时，macOS 会忽略合成的键盘事件；鼠标事件通常不受影响，但如果将来做键盘转发，这条会成为限制。
5. **多显示器**：当前代码把坐标限制在**主显示器**范围内（`CGMainDisplayID()`）。你只共用一台显示器，所以够用；将来要支持多屏需要按各屏的 `CGDisplayBounds` 分别限制。
6. **坐标 y 轴方向**：CGEvent 用的是"左上角原点、y 向下"，而 `NSEvent.mouseLocation` 是"左下角原点、y 向上"。这份代码统一用 `CGEvent(source: nil).location`，所以内部是一致的——Phase 3 换算坐标时也要注意别混用。
7. **点击的实际效果**取决于光标下的东西。测试时请把光标放在安全位置，避免误触。

---

## 8. 实测结果（2026-09-24，本机已完成）

| 项 | 结果 |
|---|---|
| `./build.sh` 编译 | ✅ 通过（首编的两处报错已修，见第 7 节） |
| 辅助功能权限 | ✅ 拿到，重启 App 后启动日志显示"已授权" |
| Test 1 移动 | ✅ 光标画圈并复位 |
| Test 2／3 左键、右键 | ✅ 产生真实点击 |
| Test 4 中键 | ✅ 通过（用观察页验证，与真鼠标表现一致） |
| Test 5 滚轮上／下 | ✅ 方向正确 |
| Test 6 全套 | ✅ 六个动作按顺序执行完毕，日志完整 |
| 重新编译后授权是否失效 | ✅ **已实测验证**：改用证书签名后重新编译并重启，启动日志仍为"已授权"，全程没有再动辅助功能设置（见第 9 节） |

> 说明：以上由你在真机上逐项实测确认通过。观察页上 `deltaY` 的具体数值当时没有逐条记录下来。

全部通过后进入 **Phase 3：Windows → Mac 的 TCP 通信**——把 Phase 1 抓到的事件按协议发过来，Mac 端用本阶段的 CGEvent 代码落地执行。协议草案已经写在项目根目录的 `README.md` 里（`MOVE/DOWN/UP/WHEEL`，行文本 + `\n` 分隔，含粘包/分包/心跳处理）。

---

## 9. 签名与授权：为什么重新编译后不用重新授权

**问题**：原本 `build.sh` 用的是 ad-hoc 签名（`codesign --sign -`）。这种 App 没有任何身份证书，macOS 只能靠**二进制指纹（cdhash）**来认它。结果是每改一行代码重新编译，指纹就变一次，macOS 就把这个 App 当成"另一个程序"，之前授过的「辅助功能」权限全部作废——而权限又是 `CGEventPost` 生效的前提，于是表现为"程序跑得好好的，但合成的事件完全没反应"。

**解决**：给这个 App 配一张**本机自签名的代码签名证书**，私钥存在登录钥匙串里，以后每次编译都用它签。

签名的"指定要求"因此从

```text
designated => cdhash H"…"                                                ← 每次编译都变
```

变成

```text
designated => identifier "com.minikvm.app" and certificate leaf = H"…"   ← 不变
```

所以**重新编译不会再让授权失效**。证书有效期 10 年。

**验证**：2026-09-24 改用证书签名后，重新编译并重启 App，启动日志第一行仍为 `[启动] 辅助功能权限：已授权`，且全程没有再修改辅助功能设置。在改用证书之前，每次重新编译都必须把辅助功能里那条记录删掉重加才能恢复。

### 证书是怎么建的（换机器或证书丢了时照做一遍）

```bash
# 1) 生成密钥 + 自签名证书，扩展用途必须是 codeSigning
#    配置文件里写：basicConstraints=critical,CA:false
#                 keyUsage=critical,digitalSignature
#                 extendedKeyUsage=critical,codeSigning
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout dev.key -out dev.crt -config openssl.cnf

# 2) 打包并导入登录钥匙串（-A 表示允许本机程序使用该私钥，不再逐个弹窗）
openssl pkcs12 -export -inkey dev.key -in dev.crt -out dev.p12 \
  -name "MiniKVM Dev Code Signing" -passout pass:任意密码
security import dev.p12 -k ~/Library/Keychains/login.keychain-db \
  -P 任意密码 -T /usr/bin/codesign -A

# 3) 不需要设置"信任"、不需要管理员密码，直接可用
codesign --force --sign "MiniKVM Dev Code Signing" build/MiniKVM.app
codesign -d -r- build/MiniKVM.app     # 确认 designated 里是 certificate leaf，而不是 cdhash
```

仓库里的 `MiniKVM-dev-cert.pem` 只是**公钥证书**（便于识别与记录），私钥**从不进仓库**，只存在登录钥匙串里。证书丢了也不影响使用，重建一张、再授权一次即可。
