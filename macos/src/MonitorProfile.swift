import Foundation
import os

// MARK: - 显示器配置档（按显示器分文件）
//
// 设计：**一台显示器一个配置文件**，文件名用 EDID 里的显示器名。
//
//   shared/profiles/DELL S3423DWC.json
//
// 这样：
//   - 加一台新显示器 = 新增一个文件，不动已有配置
//   - 同一台显示器换台 Mac 不用重新测码表
//   - 码表可以提交到仓库共享（它描述的是显示器，不是机器）
//
// 查找策略：
//   1. 环境变量 PIPBAR_PROFILES_DIR 指定的目录（测试用）
//   2. 从可执行文件位置向上找 shared/profiles/
//   3. 从工作目录向上找
//   4. 用户配置目录 ~/Library/Application Support/PipBar/profiles/
//
// 匹配方式：文件名（大小写不敏感、忽略空格）等于 EDID 显示器名。
// 匹配不到就用兜底（通用输入源 + 无 PIP 码表），界面会提示去建配置。

// MARK: - 数据结构

/// 单台显示器的配置档
struct MonitorProfile: Identifiable {

    struct PBPMode: Identifiable, Hashable {
        let value: UInt16
        let id: String
        let label: String
        let icon: String
    }

    struct Input: Identifiable, Hashable {
        let value: UInt16
        let id: String
        let label: String
        let short: String
    }

    /// EDID 报告的显示器名，用作配置档的键
    let edidName: String
    let vendor: String
    let model: String
    let vendorIdHex: String
    let modes: [PBPMode]
    let inputs: [Input]
    /// 从哪个文件加载的（用户配置目录时为 true，用于界面提示）
    let isUserDefined: Bool

    var id: String { edidName }

    /// 界面标题
    var displayName: String {
        let v = vendor.trimmingCharacters(in: .whitespaces)
        let m = model.trimmingCharacters(in: .whitespaces)
        if v.isEmpty && m.isEmpty { return edidName }
        if m.isEmpty { return v }
        if v.isEmpty { return m }
        // EDID 名通常已经含厂商，避免重复
        if edidName.uppercased().contains(v.uppercased()) { return edidName }
        return "\(v) \(m)"
    }

    /// 是否已配置 PIP 码表
    var hasPBP: Bool { !modes.isEmpty }

    /// 通用兜底：只有标准输入源，无实测码值
    static let generic = MonitorProfile(
        edidName: "", vendor: "", model: "未配置", vendorIdHex: "",
        modes: [],
        inputs: [
            .init(value: 15, id: "dp1",   label: "DisplayPort 1", short: "DP1"),
            .init(value: 16, id: "dp2",   label: "DisplayPort 2", short: "DP2"),
            .init(value: 17, id: "hdmi1", label: "HDMI 1",        short: "HDMI1"),
            .init(value: 18, id: "hdmi2", label: "HDMI 2",        short: "HDMI2"),
            .init(value: 27, id: "usbc",  label: "USB-C",         short: "USB-C"),
        ],
        isUserDefined: false
    )

    // MARK: 规范化

    /// 文件名 ↔ EDID 名 的匹配键：去掉空格、大写
    static func normalizeKey(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .uppercased()
    }
}

// MARK: - 配置档仓库

/// 管理 `shared/profiles/` 下的所有配置档，按 EDID 显示器名索引。
enum ProfileStore {

    private static let log = Logger(subsystem: "com.pipbar.ddc", category: "profile")
    private static let dirName = "shared/profiles"

    /// 缓存，避免每次访问都读盘
    private static var cache: [String: MonitorProfile]?
    private static var cacheStamp: Date?

    // MARK: 加载

    /// 拿到某台显示器的配置档；找不到返回 nil
    static func profile(forEDIDName edidName: String) -> MonitorProfile? {
        loadAll()[MonitorProfile.normalizeKey(edidName)]
    }

    /// 拿到配置档；找不到返回通用兜底
    static func profileOrGeneric(forEDIDName edidName: String) -> MonitorProfile {
        profile(forEDIDName: edidName) ?? .generic
    }

    /// 全部已配置的显示器
    static func allProfiles() -> [MonitorProfile] {
        Array(loadAll().values)
    }

    private static func loadAll() -> [String: MonitorProfile] {
        // 5 秒内的重复调用走缓存
        if let c = cache, let s = cacheStamp,
           Date().timeIntervalSince(s) < 5 {
            return c
        }

        var result: [String: MonitorProfile] = [:]
        for dir in searchDirs() {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
            else { continue }

            for f in files where f.pathExtension.lowercased() == "json" {
                guard let p = parse(at: f) else { continue }
                let key = MonitorProfile.normalizeKey(p.edidName.isEmpty
                                        ? f.deletingPathExtension().lastPathComponent
                                        : p.edidName)
                // 先找到的优先（搜索顺序即优先级）
                if result[key] == nil { result[key] = p }
            }
            if !result.isEmpty { break }
        }

        cache = result
        cacheStamp = Date()
        if result.isEmpty {
            log.notice("未找到任何显示器配置档（目录: \(self.dirName, privacy: .public)）")
        } else {
            log.info("已加载 \\(result.count) 份配置档")
        }
        return result
    }

    /// 配置档搜索顺序（优先级从高到低）：
    ///
    ///   1. `PIPBAR_PROFILES_DIR`   —— 环境变量，测试/特殊场景
    ///   2. `~/Library/Application Support/PipBar/profiles` —— 用户自己的
    ///   3. **app bundle 内的 `Resources/profiles`** —— 随 app 打包分发
    ///   4. 项目目录 `shared/profiles` —— 从源码运行时（开发）
    ///
    /// 第 3 项是关键：配置档跟着 app 走，用户不用操心文件放哪。
    /// 第 2 项让用户可以覆盖或新增自己显示器的码表。
    private static func searchDirs() -> [URL] {
        var dirs: [URL] = []

        if let env = ProcessInfo.processInfo.environment["PIPBAR_PROFILES_DIR"] {
            dirs.append(URL(fileURLWithPath: env))
        }
        // 用户配置（可覆盖打包的，也可新增自己显示器的）
        dirs.append(userDir())

        // app bundle：Resources/profiles（跟着 app 走）
        if let res = Bundle.main.resourceURL {
            dirs.append(res.appendingPathComponent("profiles"))
        }

        // 源码树：从可执行文件位置和当前目录向上找
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var roots: [URL] = [
            URL(fileURLWithPath: CommandLine.arguments.first ?? "")
                .deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            home,
        ]
        for name in ["projects", "Projects", "Developer", "code", "repos", "workspace"] {
            roots.append(home.appendingPathComponent(name))
        }

        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(url.path).inserted { dirs.append(url) }
        }
        for root in roots {
            var d = root
            for _ in 0..<7 {
                add(d.appendingPathComponent(dirName))
                let parent = d.deletingLastPathComponent()
                if parent.path == d.path { break }
                d = parent
            }
        }
        // 常见克隆位置的直接子目录（~/projects/<repo>/shared/profiles）
        for baseName in ["projects", "Projects", "Developer", "code",
                         "repos", "workspace", "src"] {
            let base = home.appendingPathComponent(baseName)
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants])
            else { continue }
            for kid in kids where kid.hasDirectoryPath {
                add(kid.appendingPathComponent(dirName))
            }
        }

        let fm = FileManager.default
        let existing = dirs.filter { fm.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            log.notice("未找到任何配置档目录。已尝试:")
            for d in dirs.prefix(10) { log.notice("  \(d.path, privacy: .public)") }
        } else {
            log.info("配置档目录: \(existing.map(\.path).joined(separator: ", "), privacy: .public)")
        }
        return existing
    }

    /// 用户自己的配置目录
    static func userDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("PipBar/profiles")
    }

    // MARK: 解析

    private static func parse(at url: URL) -> MonitorProfile? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            log.error("配置档解析失败: \\(url.path, privacy: .public)")
            return nil
        }

        let p = root["profile"] as? [String: Any] ?? [:]
        let vendor = p["vendor"] as? String ?? ""
        let model = p["model"] as? String ?? ""
        // EDID 名：优先取配置里写的，否则用文件名
        let edid = p["edidName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        let vendorId = p["vendorIdHex"] as? String ?? ""

        var modes: [MonitorProfile.PBPMode] = []
        if let list = (root["pbpModes"] as? [String: Any])?["modes"] as? [[String: Any]] {
            modes = list.compactMap { e in
                guard let v = e["value"] as? Int, let id = e["id"] as? String,
                      let label = e["label"] as? String
                else { return nil }
                return MonitorProfile.PBPMode(value: UInt16(v), id: id, label: label,
                               icon: e["icon"] as? String ?? "rectangle")
            }
        }

        var inputs: [MonitorProfile.Input] = []
        if let list = root["inputs"] as? [[String: Any]] {
            inputs = list.compactMap { e in
                guard let v = e["value"] as? Int, let id = e["id"] as? String,
                      let label = e["label"] as? String, let short = e["short"] as? String
                else { return nil }
                return MonitorProfile.Input(value: UInt16(v), id: id, label: label, short: short)
            }
        }

        return MonitorProfile(
            edidName: edid, vendor: vendor, model: model, vendorIdHex: vendorId,
            modes: modes,
            inputs: inputs.isEmpty ? MonitorProfile.generic.inputs : inputs,
            isUserDefined: url.path.hasPrefix(ProfileStore.userDir().path)
                || url.path.hasPrefix(Bundle.main.resourceURL?.path ?? "\u{0}")
        )
    }

    /// 让下一次 loadAll 重新读盘（用户刚改了配置文件时调用）
    static func invalidate() {
        cache = nil
        cacheStamp = nil
    }
}

// MARK: - 便捷访问

extension MonitorProfile {
    /// 当前活跃配置（按 EDID 名取）
    static func active(for channel: DisplayChannel?) -> MonitorProfile {
        guard let channel else { return .generic }
        return ProfileStore.profileOrGeneric(forEDIDName: channel.name)
    }
}
