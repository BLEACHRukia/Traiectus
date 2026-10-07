# Test plan and record: keyboard status-frame rules

> English translation of [`TESTING.md`](TESTING.md) (Chinese). The Chinese file is authoritative.
> Log output is Chinese by design, so the log lines quoted below are kept verbatim.

Updated: 2026-09-30

## 0. In one sentence

Before and after changing the detection logic, run the three layers below: **offline unit tests →
synthetic frames end-to-end → real keypresses**. **The first two need neither the keyboard nor the
monitor**, so they can be run at any time and can go into CI.

## 1. The three layers

| Layer | Needs | How to run | What it proves |
|---|---|---|---|
| ① Offline unit tests | just `swiftc` | `./tools/frame-rules-test/run.sh` | the detection logic itself is correct (pure functions) |
| ② Synthetic frames end-to-end | just the app running | send one frame to UDP 45790 | the chain receive → record → decide → log works |
| ③ Real keypresses | keyboard + monitor | `Fn+Caps` / `Fn+T` | real frames are recognised by the rules; head-start timing is unchanged |

### ① Offline unit tests

```bash
./tools/frame-rules-test/run.sh
# expected: 全部通过：57/57   (all passed: 57/57)
```

Coverage:

- the two built-in K70 default rules (to Windows / back to Mac)
- frames that must not match: direction byte outside the rules, a completely different prefix, a frame
  shorter than the rule
- malformed input does not crash: `ZZ ZZ`, an empty string, only `KEY`
- the `0x` prefix form parses
- `mask` semantics: ignored bits take effect; a wrong mask length falls back to "compare everything"
- the ring buffer: eviction at the limit, de-duplicated counting of unmatched frames
- **the six outcomes of the health check** (the wording is shown directly to users, so it is tested
  too): both directions recognised / only "to Windows" recognised / only "back to Mac" recognised /
  frames exist but no rule matches / nothing was ever switched, so prompt to re-run / nothing readable
  at all → head-start unavailable; plus "when nothing is readable, spell out the cost (1.7 s)"
- **learning rules from two sets of samples** (the core of the learning wizard): K70 samples produce
  exactly the built-in default rules; bytes that vary within a group get masked out; "rules keep only
  up to the last distinguishing byte"; and the three failure cases (identical on both sides / one side
  sent nothing / malformed input) each get a specific reason
- **writing the config file does not lose other fields**: a changed monitor input, default host,
  keyboard VID and unknown-frame policy all survive; an all-`ff` mask is deliberately not written,
  a mask with ignored bits must be written

To add a case: append one `check(...)` line to `tools/frame-rules-test/main.swift` with the new
keyboard's frame samples.

### ② Synthetic frames end-to-end (no keyboard needed)

```bash
# a frame no rule matches → only recorded + a warning, no screen switch
printf 'KEY 11 22 33 44 55 66 77 88' | nc -u -w1 127.0.0.1 45790
printf 'KEY ZZ ZZ'                   | nc -u -w1 127.0.0.1 45790   # malformed input
printf 'GARBAGE'                     | nc -u -w1 127.0.0.1 45790   # should be rejected by the KEY prefix test

grep -E "未匹配的状态帧|无法解析的帧" ~/Library/Logs/Traiectus.log | tail -5
```

> ⚠️ **Safety rule: synthetic tests only use frames that no rule matches.**
> Sending a matching frame really performs the head-start (screen switch + handing over mouse
> control); with Windows off, the picture would switch to an input with no signal. To test the
> matching path, use layer ③ with the real keyboard.

Criteria: the same frame sent twice warns only once (de-duplication works); `GARBAGE` produces no
output; the process stays alive.

### ③ Real keypresses

1. Press `Fn+Caps` (to Windows), wait two seconds, then press `Fn+T` (back to Mac)
2. Check:

```bash
grep -E "未匹配|无法解析|抢跑|屏幕 →" ~/Library/Logs/Traiectus.log | tail -10
```

Criteria:

- both directions show `⚡ Windows 抢跑` plus `屏幕 → …（m1ddc …，退出码 0）`
- **no "未匹配的状态帧" at all** — if one appears, the real frames and the rules disagree (see §3)

## 2. Confirming at startup which rule set is in use

```text
[联动] 已启动（检测：kvm-keywatch；抢跑：UDP 45790；状态帧规则：内置默认（K70 Pro Mini））
[配置] …；状态帧规则=内置默认（K70 Pro Mini）；来源：（没有配置文件，全部用默认值）
```

- rules configured → `config.json（N 条）`
- not configured → `内置默认（K70 Pro Mini）`

## 3. A real case: the mask written the wrong way round (2026-09-30, caught by the offline tests)

| | |
|---|---|
| **Symptom** | "back to Mac" frames were classified as `windows`, and frames whose direction byte is `03` were classified as `windows` too — **every frame was classified as "to Windows"** |
| **Cause** | the rule's `mask` was written `ff ff ff ff ff 00`, so byte 6 (the **direction byte**) was masked with `00` = ignored; both rules then matched the same set of frames and the first one listed won |
| **How it was found** | offline test groups 1 and 2. Relying on real hardware, the symptom is "the head-start goes the wrong way every time", which is very hard to pin down |
| **Three places fixed** | the built-in default rules, `config.example.json`, and the `docs/design/…` document (a new "mask trap" warning) |
| **Conclusion** | **the byte that distinguishes direction must be masked with `ff`** |

## 4. Measurements from 2026-09-30

**① Offline tests**

```text
全部通过：57/57      （规则 20 + 体检结论 9 + 学规则 14 + 配置合并 8 + 诊断报告 6）
```

**② Synthetic frames**

```text
[12:04:53.008] [联动] ⚠ 收到未匹配的状态帧：11 22 33 44 55 66 77 88（规则里没有它，已记录…）
[12:04:54.024] [联动] ⚠ 收到无法解析的帧：zz zz（不是十六进制字节？已记录）
```

(the same frame twice warns once; `GARBAGE` produces nothing; the process stays alive)

**③ Real keypresses**

```text
[12:05:48.961] [联动] ⚡ Windows 抢跑：键盘正在去 Windows
[12:05:49.045] [联动] 屏幕 → Windows/DP（m1ddc 83 ms，退出码 0）
[12:05:49.046] [联动] 已请求鼠标控制权 → Win（抢跑）
[12:05:54.225] [联动] ⚡ Windows 抢跑：键盘正在回 Mac
[12:05:54.289] [联动] 屏幕 → Mac/HDMI（m1ddc 64 ms，退出码 0）
[12:05:54.289] [联动] 已请求鼠标控制权 → Mac（抢跑）
```

**Zero "unmatched" warnings on real frames** → the built-in rules agree with the frames the keyboard
actually emits; turning them into rules changed no verdicts.

## 5. Regression checklist (run this whenever rules or the detection logic change)

- [ ] ① offline tests all green (`./tools/frame-rules-test/run.sh`)
- [ ] ② the three synthetic inputs behave correctly: unmatched de-duplicated / unparsable / rejected
      by the prefix
- [ ] ③ both directions head-start on real hardware, with **no** unmatched warnings
- [ ] the source of the "status frame rules" in the startup log matches expectations (built-in
      defaults / `config.json` with N rules)

## 6. Related files

| | |
|---|---|
| Design | [`design/2026-09-30-键盘状态帧检测与验证.md`](design/2026-09-30-键盘状态帧检测与验证.md) |
| Detection and recording code | [`../macos/phase3-tcp/src/KeyboardFrameRules.swift`](../macos/phase3-tcp/src/KeyboardFrameRules.swift) |
| Offline tests | [`../tools/frame-rules-test/`](../tools/frame-rules-test) |
