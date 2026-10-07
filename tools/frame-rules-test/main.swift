// ============================================================================
//  键盘状态帧规则的离线测试
// ----------------------------------------------------------------------------
//  不需要键盘、不需要设备、不联网 —— 纯函数测试。
//  跑法：./run.sh
//
//  这套测试是"验证层"的种子（设计见 docs/design/2026-09-30-键盘状态帧检测与验证.md）：
//  以后把真实采集的帧样本喂进来，就成了规则的回放测试，可以进 CI。
// ============================================================================

import Foundation

var passed = 0
var failed = 0

func check(_ name: String, _ got: String?, _ want: String?) {
    if got == want {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name)  期望 \(want ?? "nil")，实际 \(got ?? "nil")")
    }
}

func check(_ name: String, _ got: Int, _ want: Int) {
    if got == want {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name)  期望 \(want)，实际 \(got)")
    }
}

func checkContains(_ name: String, _ text: String, _ needle: String) {
    if text.contains(needle) {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name)  文案里没有「\(needle)」：\(text)")
    }
}

let classifier = KeyboardFrameClassifier(rules: KeyboardFrameClassifier.k70Default,
                                         unknownPolicy: "log")

print("== 1. 内置 K70 默认规则（= 配置化之前写死的那两条）==")
check("去 Win：00 00 01 36 00 02 00 00",
      classifier.side(forFrameText: "00 00 01 36 00 02 00 00"), "windows")
check("回 Mac：00 00 01 36 00 00 00 00",
      classifier.side(forFrameText: "00 00 01 36 00 00 00 00"), "mac")
check("带 KEY 前缀也认",
      classifier.side(forFrameText: "KEY 00 00 01 36 00 02 00 00"), "windows")
check("大写 KEY 也认",
      classifier.side(forFrameText: "KEY 00 00 01 36 00 00 00 00"), "mac")

print("== 2. 不该命中的（以前被静默丢掉，现在要能看出来）==")
check("第 6 字节是 03（规则里没有）",
      classifier.side(forFrameText: "00 00 01 36 00 03 00 00"), nil)
check("前缀完全不同",
      classifier.side(forFrameText: "11 22 33 44 55 66 77 88"), nil)
check("帧比规则短",
      classifier.side(forFrameText: "00 00 01 36"), nil)

print("== 3. 畸形输入不能崩 ==")
check("非法十六进制", classifier.side(forFrameText: "KEY ZZ ZZ ZZ"), nil)
check("空串", classifier.side(forFrameText: ""), nil)
check("只有一个 token", classifier.side(forFrameText: "KEY"), nil)
check("0x 前缀形式能解析",
      classifier.side(forFrameText: "0x00 0x00 0x01 0x36 0x00 0x02"), "windows")

print("== 4. mask 语义 ==")
// 只比前 6 字节、忽略第 7 字节 → 第 7 字节不同也该命中
check("mask 为 00 的字节不参与比对",
      classifier.side(forFrameText: "00 00 01 36 00 02 FF EE"), "windows")
// 自定义规则：只看第 4 字节（0x36）—— 模拟"别的键盘"
if let custom = KeyboardFrameRule(side: "windows", match: "00 00 01 36", mask: "00 00 00 ff") {
    let alt = KeyboardFrameClassifier(rules: [custom], unknownPolicy: "log")
    check("自定义规则：看第 4 字节",
          alt.side(forFrameText: "AA BB CC 36 DD"), "windows")
    check("自定义规则：第 4 字节不符则不命中",
          alt.side(forFrameText: "AA BB CC 37 DD"), nil)
} else {
    failed += 1
    print("  ✗ 自定义规则解析失败")
}
// mask 长度不对 → 回落到"全都要比"
if let bad = KeyboardFrameRule(side: "mac", match: "00 00 01 36", mask: "ff ff") {
    check("mask 长度不对时回落到全比较",
          KeyboardFrameClassifier(rules: [bad], unknownPolicy: "log")
              .side(forFrameText: "00 00 01 37"), nil)
} else {
    failed += 1
    print("  ✗ 规则解析失败")
}

print("== 5. 帧环形缓冲（先记录、再判定）==")
let log = KeyboardFrameLog(limit: 10)
log.record(hex: "a", side: "windows")
log.record(hex: "b", side: nil)
log.record(hex: "c", side: "mac")
log.record(hex: "b", side: nil)          // 同一个未匹配帧再来一次
log.record(hex: "d", side: nil)
check("记录条数", log.snapshot().count, 5)
check("未匹配帧去重后 2 种", log.unmatchedSummary().count, 2)
check("b 出现 2 次",
      log.unmatchedSummary().first(where: { $0.hex == "b" })?.count ?? -1, 2)

let big = KeyboardFrameLog(limit: 10)
for i in 0..<25 { big.record(hex: "f\(i)", side: nil) }
check("超过上限后只保留最近 10 条", big.snapshot().count, 10)
check("最老的被丢掉（第一条是 f15）", big.snapshot().first?.hex ?? "", "f15")

print("== 6. 体检结论的六种分支（结论文案是给用户看的，也要测）==")
func probe(frames: Int, w: Int, m: Int, unmatched: [(String, Int)] = [],
           changes: Int, slept: Bool = false) -> KeyboardProbeReport {
    KeyboardProbeReport(seconds: 15, frames: frames, matchedWindows: w, matchedMac: m,
                        unmatched: unmatched, ownershipChanges: changes, slept: slept)
}

checkContains("两方向都认得出 → 支持抢跑（两个方向）",
              probe(frames: 2, w: 1, m: 1, changes: 2).verdict, "两个方向")
checkContains("只认去 Win（常态）",
              probe(frames: 1, w: 1, m: 0, changes: 1).verdict, "去 Win")
checkContains("只认回 Mac（少见）",
              probe(frames: 1, w: 0, m: 1, changes: 1).verdict, "回 Mac")
checkContains("有帧但规则全不认 → 不支持抢跑",
              probe(frames: 3, w: 0, m: 0, unmatched: [("11 22 33", 3)], changes: 2).verdict,
              "不支持抢跑")
checkContains("没切换过 → 提示重跑",
              probe(frames: 0, w: 0, m: 0, changes: 0).verdict, "没检测到键盘切换")
checkContains("完全读不到 → 用不了抢跑",
              probe(frames: 0, w: 0, m: 0, changes: 2).verdict, "读不到状态帧")
checkContains("读不到时的明细要写清代价（1.7 秒）",
              probe(frames: 0, w: 0, m: 0, changes: 2).detail, "1.7 秒")
checkContains("窗口里睡过要提示",
              probe(frames: 1, w: 1, m: 0, changes: 1, slept: true).detail, "睡过")
checkContains("未匹配帧要出现在明细里",
              probe(frames: 3, w: 0, m: 0, unmatched: [("ab cd", 3)], changes: 2).detail, "ab cd×3")

print("== 7. 从样本学规则（学习向导的核心）==")

// ① 用 K70 真机的两条帧：学出来的规则要能用
let learnK70 = KeyboardRuleBuilder.build(
    framesA: ["00 00 01 36 00 02 00 00"], sideA: "windows",
    framesB: ["00 00 01 36 00 00 00 00"], sideB: "mac")
check("K70 样本能学出规则", learnK70.isOK ? "ok" : (learnK70.failure ?? "?"), "ok")
check("前 6 字节都恒定 → 掩码全比", learnK70.maskHex, "ff ff ff ff ff ff")
if learnK70.isOK {
    let c = KeyboardFrameClassifier(rules: learnK70.rules, unknownPolicy: "log")
    check("学出的规则认出「去 Win」", c.side(forFrameText: "00 00 01 36 00 02 00 00"), "windows")
    check("学出的规则认出「回 Mac」", c.side(forFrameText: "00 00 01 36 00 00 00 00"), "mac")
    check("学出的规则不认无关帧（03）", c.side(forFrameText: "00 00 01 36 00 03 00 00"), nil)
}

// ② 组内会变的字节要被掩掉（例如帧尾带序号）
let learnVary = KeyboardRuleBuilder.build(
    framesA: ["00 00 01 36 00 02 aa", "00 00 01 36 00 02 bb"], sideA: "windows",
    framesB: ["00 00 01 36 00 00 cc", "00 00 01 36 00 00 dd"], sideB: "mac")
// 区分位在第 6 字节 → 规则只保留前 6 字节；第 7 字节（会变）根本不进规则
check("规则只保留到最后一个区分位", learnVary.maskHex, "ff ff ff ff ff ff")
if learnVary.isOK {
    let c = KeyboardFrameClassifier(rules: learnVary.rules, unknownPolicy: "log")
    check("A 组样本 1 → windows", c.side(forFrameText: "00 00 01 36 00 02 aa"), "windows")
    check("A 组样本 2（末字节不同）→ windows", c.side(forFrameText: "00 00 01 36 00 02 bb"), "windows")
    check("B 组样本 → mac", c.side(forFrameText: "00 00 01 36 00 00 dd"), "mac")
}

// ③ 两侧样本一样 → 学不出，而且原因要具体
let learnSame = KeyboardRuleBuilder.build(
    framesA: ["00 00 01 36 00 02"], sideA: "windows",
    framesB: ["00 00 01 36 00 02"], sideB: "mac")
check("两侧相同 → 判定失败", learnSame.isOK ? "ok" : "failed", "failed")
checkContains("失败原因提到「区分不开」", learnSame.failure ?? "", "区分不开")
checkContains("明细提示可能是接口选错", learnSame.detail, "FF42/01")

// ④ 一侧没帧 / 畸形输入
let learnEmpty = KeyboardRuleBuilder.build(framesA: [], sideA: "windows",
                                          framesB: ["00 00 01 36 00 00"], sideB: "mac")
check("一侧没帧 → 失败", learnEmpty.isOK ? "ok" : "failed", "failed")
let learnGarbage = KeyboardRuleBuilder.build(framesA: ["zz zz"], sideA: "windows",
                                            framesB: ["00 00"], sideB: "mac")
check("畸形输入 → 失败", learnGarbage.isOK ? "ok" : "failed", "failed")

print("== 8. 规则写进配置文件时，不能弄丢别的字段 ==")
let tmpConfig = NSTemporaryDirectory() + "traiectus-config-test.json"
// 造一份"用户已经改过"的配置：显示器输入源、默认地址、键盘 VID、未知帧策略都不是默认值
let seed = """
{
  "display": { "macInput": "18", "windowsInput": "16" },
  "network": { "defaultHost": "10.0.0.5" },
  "keyboard": { "vendorID": "0x1234", "detect": { "unknownFramePolicy": "ignore" } }
}
"""
try? seed.write(toFile: tmpConfig, atomically: true, encoding: .utf8)

if let rule = KeyboardFrameRule(side: "windows", match: "11 22 33", mask: "ff ff ff") {
    do {
        try TraiectusConfig.saveRules([rule], to: tmpConfig)
        let text = (try? String(contentsOfFile: tmpConfig, encoding: .utf8)) ?? ""
        checkContains("保留修改过的显示器输入源", text, "\"macInput\" : \"18\"")
        checkContains("保留修改过的默认地址", text, "\"defaultHost\" : \"10.0.0.5\"")
        checkContains("保留键盘 VID", text, "\"vendorID\" : \"0x1234\"")
        checkContains("保留原有的未知帧策略", text, "\"unknownFramePolicy\" : \"ignore\"")
        checkContains("写入了新规则", text, "\"match\" : \"11 22 33\"")
        // 全 ff 的掩码**故意不写**（解码时默认就是"全部都要比"），配置文件更干净
        check("全 ff 掩码不该写出 mask 键", text.contains("\"mask\"") ? "有" : "无", "无")

        // 带忽略位的掩码必须写出来
        if let masked = KeyboardFrameRule(side: "mac", match: "11 22 00", mask: "ff ff 00") {
            try TraiectusConfig.saveRules([rule, masked], to: tmpConfig)
            let text2 = (try? String(contentsOfFile: tmpConfig, encoding: .utf8)) ?? ""
            checkContains("带忽略位的掩码要写出来", text2, "\"mask\" : \"ff ff 00\"")
            checkContains("同一次写入的两条规则都在", text2, "\"match\" : \"11 22 00\"")
        } else {
            failed += 1
            print("  ✗ 造掩码规则失败")
        }
    } catch {
        failed += 1
        print("  ✗ saveRules 抛错：\(error)")
    }
} else {
    failed += 1
    print("  ✗ 造规则失败")
}
try? FileManager.default.removeItem(atPath: tmpConfig)

print("== 9. 诊断报告：JSON 能解析回来，内容齐全 ==")
let sampleFrames = [
    KeyboardFrameLog.Entry(at: Date(timeIntervalSince1970: 1_800_000_000),
                           hex: "00 00 01 36 00 02 00 00", side: "windows"),
    KeyboardFrameLog.Entry(at: Date(timeIntervalSince1970: 1_800_000_001),
                           hex: "11 22 33", side: nil),
]
let report = KeyboardDiagnosticReport(
    when: Date(timeIntervalSince1970: 1_800_000_002),
    summary: "抢跑说「键盘正在回 Mac」，但 8 秒内没等到",
    detail: ["抢跑方向：回 Mac", "实际归属：键盘不在 Mac 上"],
    rules: ["windows：00 00 01 36 00 02"],
    frames: sampleFrames)
let reportJSON = report.json
if let data = reportJSON.data(using: .utf8),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    check("kind 正确", obj["kind"] as? String ?? "", "keyboard-diagnostic")
    check("帧条数写对", obj["frameCount"] as? Int ?? -1, 2)
    let frames = obj["frames"] as? [[String: Any]] ?? []
    check("第一条帧的判定是 windows", frames.first?["verdict"] as? String ?? "", "windows")
    check("没匹配上的帧标成 unmatched", frames.last?["verdict"] as? String ?? "", "unmatched")
    checkContains("summary 在里面（能直接看懂发生了什么）", reportJSON, "回 Mac")
    checkContains("规则也在里面", reportJSON, "00 00 01 36 00 02")
} else {
    failed += 1
    print("  ✗ 诊断报告 JSON 解析失败：\(reportJSON.prefix(80))")
}

print("")
print(failed == 0 ? "全部通过：\(passed)/\(passed)" : "有失败：通过 \(passed)，失败 \(failed)")
exit(failed == 0 ? 0 : 1)
