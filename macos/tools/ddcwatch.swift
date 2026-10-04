import Foundation

// MARK: - ddcwatch
//
// 读显示器当前状态。排查 DDC 问题时的第一工具。
//
// 构建:
//   swiftc -O -parse-as-library -o ddcwatch \
//          ../src/DDCNative.swift ../src/MonitorProfile.swift ddcwatch.swift \
//          -framework AppKit -framework IOKit
//
// 用法:
//   ./ddcwatch          读一次全部状态
//   ./ddcwatch watch    持续监视 PIP 布局变化（配合显示器实体按键）
//
// 典型用法：想知道某个布局对应哪个 VCP 码时，
// 开着 `watch` 然后用实体按键在 OSD 里切换 —— 每次变化会打印码值。

enum VCPName: String {
    case layout = "0xE9  PIP 布局"
    case pipInput = "0xE8  PIP 输入"
    case input = "0x60  主输入"
    case brightness = "0x10  亮度"
    case contrast = "0x12  对比度"
    case volume = "0x62  音量"
    case mute = "0x8D  静音"

    var code: UInt8 {
        switch self {
        case .layout:     return VCP.pbpMode
        case .pipInput:   return VCP.pbpInput
        case .input:      return VCP.inputSource
        case .brightness: return VCP.brightness
        case .contrast:   return VCP.contrast
        case .volume:     return VCP.audioVolume
        case .mute:       return VCP.mute
        }
    }

    static let displayOrder: [VCPName] =
        [.layout, .pipInput, .input, .brightness, .contrast, .volume, .mute]
}

@main
struct DDCWatch {

    /// 带重试的读取：显示器切画面瞬间 DDC 会短暂失联
    static func read(_ ch: DisplayChannel, _ name: VCPName, retries: Int = 4) -> (UInt16, UInt16)? {
        for _ in 0..<retries {
            if let r = ch.read(name.code) { return (r.current, r.max) }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return nil
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    static func describeLayout(_ v: UInt16, profile: MonitorProfile) -> String {
        profile.modes.first { $0.value == v }?.label ?? "未知"
    }

    /// 返回 (标签, 是否做过低位掩码)
    static func describeInput(_ raw: UInt16, profile: MonitorProfile) -> (String, Bool) {
        let masked = raw & 0xFF
        let label = profile.inputs.first { $0.value == masked }?.short ?? "?"
        return (label, raw != masked)
    }

    // MARK: - 入口

    static func main() {
        guard let ch = DisplayDiscovery.primaryChannel() else {
            print("未找到外接显示器")
            print("检查线缆连接，并确认显示器已上电。")
            exit(1)
        }

        let profile = MonitorProfile.active(for: ch)
        let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "once"
        if mode == "watch" { watch(ch, profile) } else { once(ch, profile) }
    }

    // MARK: 一次性读取

    static func once(_ ch: DisplayChannel, _ profile: MonitorProfile) {
        print("显示器: \(ch.name)")
        if profile.isUserDefined || profile.hasPBP {
            print("配置档: \(profile.displayName)  (\(profile.modes.count) 种 PIP 布局)")
        } else {
            print("配置档: 未找到 —— 该显示器的 PIP 码表需要自己测")
            print("        参考 shared/profiles/_template.json 新建一份")
        }
        print(String(repeating: "─", count: 60))
        for name in VCPName.displayOrder {
            guard let (cur, max) = read(ch, name) else {
                print("  \(name.rawValue)  = 读取失败")
                continue
            }
            var extra = ""
            switch name {
            case .layout:
                extra = "   → \(describeLayout(cur, profile: profile))"
            case .input, .pipInput:
                let (label, masked) = describeInput(cur, profile: profile)
                extra = "   → \(label)"
                if masked {
                    extra += "  (原始 0x\(String(cur, radix: 16))，Dell 双字节编码，已取低字节)"
                }
            case .mute:
                extra = cur == 1 ? "   → 已静音" : "   → 未静音"
            default:
                extra = " / \(max)"
            }
            print("  \(name.rawValue)  = \(cur)\(extra)")
        }
    }

    // MARK: 持续监视

    static func watch(_ ch: DisplayChannel, _ profile: MonitorProfile) {
        print("监视中 — 现在用显示器实体按键切换 PIP 布局")
        print("每次变化会打印对应码值。Ctrl+C 停止。")
        print(String(repeating: "─", count: 60))

        var last: UInt16?
        var failStreak = 0

        while true {
            if let (v, _) = read(ch, .layout, retries: 2) {
                failStreak = 0
                if v != last {
                    let ts = timestamp()
                    let note = last == nil ? "（初始）" : "（原 \(last!))"
                    print("[\(ts)]  VCP 0xE9 = \(v)  →  \(describeLayout(v, profile: profile))\(note)")
                    if let (i, _) = read(ch, .pipInput, retries: 2) {
                        let (label, _) = describeInput(i, profile: profile)
                        print("[\(ts)]  PIP 输入 = \(label)")
                    }
                    last = v
                }
            } else {
                failStreak += 1
                if failStreak == 3 {
                    print("连续读取失败 — 试试用实体按键打开一次 OSD 菜单唤醒 DDC 控制器")
                    print("（仍无响应则拔插视频线；完全无响应时需断电 10 秒）")
                }
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
    }
}
