import SwiftUI
import AppKit
import Combine
import CoreGraphics
import Foundation
import os

// MARK: - 日志
//
// 用 os.Logger：可实时用
//   log stream --predicate 'subsystem == "com.pipbar.ddc"'
// 观察，不必翻终端历史。
let DDCLog = Logger(subsystem: "com.pipbar.ddc", category: "ddc")

// PIP 布局与输入源的码表见 MonitorProfile.swift
// （从 app bundle 的 Resources/profiles 或用户目录加载）

// MARK: - 应用状态

@MainActor
final class DisplayController: ObservableObject {

    @Published private(set) var isConnected = false
    @Published private(set) var currentLayout: MonitorProfile.PBPMode?
    @Published private(set) var brightness: Int?
    @Published private(set) var contrast: Int?
    @Published private(set) var volume: Int?
    @Published private(set) var mainInput: MonitorProfile.Input?
    @Published private(set) var pipInput: MonitorProfile.Input?
    /// 当前显示器的配置档（按 EDID 名从 shared/profiles/ 匹配）
    @Published private(set) var profile: MonitorProfile = .generic

    @Published private(set) var isBusy = false
    @Published var toast: Toast?

    /// 滑块本地状态。放在 controller 而非 View 里：
    /// View 每次弹出面板都会重建，View 内的对象会被重新创建归零。
    let brightnessModel = SliderModel()
    let volumeModel = SliderModel()

    /// 亮度上限（显示器上报，通常 100）
    @Published private(set) var brightnessMax: Int?
    /// 静音状态
    @Published private(set) var isMuted = false

    private var channel: DisplayChannel?
    /// 保护 channel：读写队列都会访问它，IOAVServiceRef 是裸指针，
    /// 并发访问会导致野指针崩溃（Crisp 用 avServiceLock 做同样的事）。
    private let channelLock = NSLock()

    private var safeChannel: DisplayChannel? {
        channelLock.lock(); defer { channelLock.unlock() }
        return channel
    }
    private func setChannel(_ ch: DisplayChannel?) {
        channelLock.lock(); channel = ch; channelLock.unlock()
    }

    /// DDC 控制器需要节流：连续快速写入会把它堵死
    private var lastWrite = Date.distantPast
    private let minWriteInterval: TimeInterval = 0.15

    /// 单一串行 DDC 队列：读和写都走这里，
    /// 保证同一时刻只有一个操作在碰 IOAVServiceRef（Crisp 的 per-display 串行队列）。
    private let ddcQueue = DispatchQueue(label: "ddc.io", qos: .userInitiated)
    /// 通道发现（IORegistry 遍历）单独一条队列，避免和 DDC 抢同一个 IOAVService
    private let discoveryQueue = DispatchQueue(label: "ddc.discovery", qos: .userInitiated)

    /// 拖动期间的"最新值"合并：只保留最后一次目标值，
    /// 避免一次拖动产生几十个排队写入（会明显滞后）。
    private var pendingBrightness: Int?
    private var pendingVolume: Int?
    private var coalesceTimer: Timer?

    struct Toast: Equatable {
        enum Kind { case success, failure, info }
        let kind: Kind
        let text: String
    }

    // MARK: - 热插拔监听

    /// 监听显示配置变化。
    ///
    /// 拔/插显示器时 macOS 会重新枚举 IORegistry，我们缓存的
    /// IOAVServiceRef 立刻失效（指向已释放对象）。必须在这里
    /// 把通道清掉并重新发现，否则后续所有写入都打空。
    ///
    /// AppKit 只提供 didChangeScreenParametersNotification（热插拔也会触发），
    /// 没有单独的 connect/disconnect 通知。再叠加 CoreDisplay 的
    /// 重配置回调兜底 —— 部分显示器热插拔时 AppKit 通知不触发。
    func startObservingTopology() {
        let nc = NotificationCenter.default

        topologyObservers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.topologyChanged(reason: "screenParameters")
        })

        let cb: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
            guard let userInfo else { return }
            let f = CGDisplayChangeSummaryFlags(rawValue: UInt32(flags.rawValue))
            // Swift 对这组 C 常量的命名不友好（.add 等不可用），
            // 直接用 CGDisplayConfiguration.h 里的定义值做位测试。
            let raw = f.rawValue
            let kAdd: UInt32    = 1 << 4   // kCGDisplayAddFlag
            let kRemove: UInt32 = 1 << 5   // kCGDisplayRemoveFlag
            let kMoved: UInt32  = 1 << 6   // kCGDisplayMovedFlag
            let kSetMain: UInt32 = 1 << 8  // kCGDisplaySetMainFlag
            let kMirror: UInt32 = 1 << 9   // kCGDisplayMirrorFlag
            var parts: [String] = []
            if raw & kAdd != 0 { parts.append("add") }
            if raw & kRemove != 0 { parts.append("remove") }
            if raw & kMoved != 0 { parts.append("moved") }
            if raw & kSetMain != 0 { parts.append("setMain") }
            if raw & kMirror != 0 { parts.append("mirror") }
            Unmanaged<DisplayController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
                .topologyChanged(reason: parts.isEmpty ? "reconfig" : parts.joined(separator: "+"))
        }
        topologyCallbackToken = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(cb, topologyCallbackToken)
    }

    private var topologyCallbackToken: UnsafeMutableRawPointer?

    private var topologyObservers: [NSObjectProtocol] = []
    private var topologyDebounce: DispatchWorkItem?

    private func topologyChanged(reason: String) {
        DDCLog.info("显示配置变化 (\(reason, privacy: .public)) — 丢弃缓存通道并重新发现")

        // 立即作废旧指针
        setChannel(nil)
        isConnected = false
        brightness = nil
        volume = nil
        contrast = nil
        currentLayout = nil
        mainInput = nil
        pipInput = nil
        brightnessModel.local = 0
        volumeModel.local = 0

        // 去抖：一次插拔可能连发多个通知
        topologyDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        topologyDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: 连接

    /// 连接/刷新。
    ///
    /// 全部 I/O 都放在 ddcQueue（单串行队列）里：
    ///   - IOAVServiceRef 是裸指针，同一时刻只能有一个操作在用；
    ///   - 每次 DDC 读要等 ~40ms 回包，7 项 ~350ms，不能占着主线程。
    func connect() {
        DDCLog.info("connect() 开始")
        discoveryQueue.async { [weak self] in
            guard let self else { return }
            // 遍历 IORegistry 找通道（几百毫秒级）
            let t0 = Date()
            let ch = DisplayDiscovery.primaryChannel()
            let profile = MonitorProfile.active(for: ch)
            DDCLog.info("发现通道: \(ch == nil ? "无" : ch!.name, privacy: .public) 耗时 \(Date().timeIntervalSince(t0))s")
            guard let ch else {
                Task { @MainActor in
                    self.setChannel(nil)
                    self.isConnected = false
                }
                return
            }
            self.setChannel(ch)

            // 读操作交给 DDC 串行队列，避免和写入并发
            self.ddcQueue.async {
                let snapshot = Self.readAll(from: ch, profile: profile)
                Task { @MainActor in
                    // 亮度读不到 = 通道堵死或显示器无响应
                    guard let b = snapshot.brightness else {
                        self.setChannel(nil)
                        self.isConnected = false
                        return
                    }
                    self.isConnected = true
                    self.profile = profile
                    self.apply(snapshot)
                }
            }
        }
    }

    /// 只重新读取（沿用已有通道）
    func refresh() {
        DDCLog.info("refresh() 开始")
        guard let ch = safeChannel else {
            DDCLog.info("refresh(): 无缓存通道，转 connect()")
            connect(); return
        }
        let profile = MonitorProfile.active(for: ch)
        ddcQueue.async {
            let t0 = Date()
            let snapshot = Self.readAll(from: ch, profile: profile)
            DDCLog.info("readAll 耗时 \(Date().timeIntervalSince(t0))s 亮度=\(String(describing: snapshot.brightness), privacy: .public) 音量=\(String(describing: snapshot.volume), privacy: .public)")
            Task { @MainActor in
                guard let b = snapshot.brightness else {
                    self.setChannel(nil)
                    self.isConnected = false
                    return
                }
                self.isConnected = true
                self.apply(snapshot)
            }
        }
    }

    /// 把快照应用到状态（主线程）
    private func apply(_ s: Snapshot) {
        if let b = s.brightness {
            brightness = b.current
            brightnessMax = b.max
        }
        if let c = s.contrast { contrast = c }
        if let v = s.volume { volume = v }
        if let m = s.muted { isMuted = m }
        if let l = s.layout { currentLayout = l }
        if let i = s.mainInput { mainInput = i }
        if let i = s.pipInput { pipInput = i }
        DDCLog.info("apply: 亮度=\(String(describing: self.brightness), privacy: .public) 音量=\(String(describing: self.volume), privacy: .public) 主输入=\(self.mainInput?.short ?? "?", privacy: .public)")
    }

    // MARK: 读取结果结构

    private struct Snapshot {
        var brightness: (current: Int, max: Int)?
        var contrast: Int?
        var volume: Int?
        var muted: Bool?
        var layout: MonitorProfile.PBPMode?
        var mainInput: MonitorProfile.Input?
        var pipInput: MonitorProfile.Input?
    }

    /// 后台线程执行实际的 DDC 读取
    private nonisolated static func readAll(from ch: DisplayChannel,
                                          profile: MonitorProfile) -> Snapshot {
        var s = Snapshot()

        // 逐项记录成功/失败：定位到底哪个 VCP 码读不出来
        func grab(_ code: UInt8, _ label: String) -> (UInt16, UInt16)? {
            if let r = ch.read(code) {
                DDCLog.debug("  ✓ 0x\(String(code, radix: 16), privacy: .public) \(label, privacy: .public) = \(r.current)/\(r.max)")
                return r
            }
            DDCLog.error("  ✗ 0x\(String(code, radix: 16), privacy: .public) \(label, privacy: .public) 读取失败")
            return nil
        }

        if let r = grab(VCP.brightness, "亮度") { s.brightness = (Int(r.0), Int(r.1)) }
        if let r = grab(VCP.contrast, "对比度") { s.contrast = Int(r.0) }
        if let r = grab(VCP.audioVolume, "音量") { s.volume = Int(r.0) }
        if let r = grab(VCP.mute, "静音") { s.muted = (r.0 == 1) }
        if let v = grab(VCP.pbpMode, "PIP布局")?.0 {
            // 只在配置档声明过的值里匹配；未知值如实上报
            s.layout = profile.modes.first { $0.value == v }
            if s.layout == nil {
                DDCLog.notice("  ! PIP布局值 \(v) 不在配置档里（该显示器可能不支持 PIP，或需补码表）")
            }
        }
        // 输入源：部分厂商（Dell）把同一个码在两个字节里各放一遍
        // （如 USB-C 读回 0x1B1B），所以取低位字节
        if let v = grab(VCP.inputSource, "主输入")?.0 {
            s.mainInput = profile.inputs.first { $0.value == (v & 0xFF) }
        }
        if let v = grab(VCP.pbpInput, "PIP输入")?.0 {
            s.pipInput = profile.inputs.first { $0.value == (v & 0xFF) }
        }
        return s
    }

    // MARK: 写入

    /// 节流写入（与读取共用同一条串行队列）。
    ///
    /// 关键三点：
    ///   1. 绝不在主线程 sleep —— 会阻塞 UI 事件循环，拖动手感全丢。
    ///   2. 必须和读走同一条队列 —— IOAVServiceRef 是裸指针，
    ///      读写并发会拿到野指针（这正是之前"调节音量就崩"的原因）。
    ///   3. 热插拔后缓存的指针已失效 —— 显示器拔插会让 IORegistry 重新枚举，
    ///      旧 IOAVServiceRef 指向的对象已被释放。此时写会静默失败。
    ///      所以写失败时丢弃通道并重新发现。
    private func write(_ code: UInt8, _ value: UInt16) {
        guard let ch = safeChannel else {
            DDCLog.error("write 0x\(String(code, radix: 16), privacy: .public) 失败：无通道")
            Task { @MainActor in self.connect() }
            return
        }
        DDCLog.debug("write 0x\(String(code, radix: 16), privacy: .public) = \(value)")

        ddcQueue.async { [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastWrite)
            if elapsed < self.minWriteInterval {
                Thread.sleep(forTimeInterval: self.minWriteInterval - elapsed)
            }
            let ok = ch.write(code, value)
            self.lastWrite = Date()
            if ok {
                DDCLog.debug("write 0x\(String(code, radix: 16), privacy: .public) 成功")
                return
            }
            // 写失败：多半是热插拔后指针失效，丢弃通道重新发现
            DDCLog.error("write 0x\(String(code, radix: 16), privacy: .public) I2C 失败 — 通道失效，重新发现")
            Task { @MainActor in
                self.setChannel(nil)
                self.isConnected = false
                self.connect()
            }
        }
    }

    /// 同步写入（仅布局切换用：需要立刻知道写没写成功）
    private func writeSync(_ code: UInt8, _ value: UInt16) -> Bool {
        guard let ch = safeChannel else { return false }
        let result = ddcQueue.sync { () -> Bool in
            let elapsed = Date().timeIntervalSince(lastWrite)
            if elapsed < minWriteInterval {
                Thread.sleep(forTimeInterval: minWriteInterval - elapsed)
            }
            let ok = ch.write(code, value)
            lastWrite = Date()
            return ok
        }
        return result
    }

    func setLayout(_ layout: MonitorProfile.PBPMode) {
        guard isConnected else { show(.failure, "显示器未连接"); return }
        isBusy = true
        defer { isBusy = false }

        guard writeSync(VCP.pbpMode, layout.value) else {
            show(.failure, "写入失败：DDC 控制器无响应")
            // 通道可能已堵，丢弃缓存下次重连
            channel = nil
            return
        }

        currentLayout = layout
        show(.success, "已切换到 \(layout.label)")

        // 切画面后 DDC 会短暂失联，稍后再读一次补齐状态
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                if self.safeChannel != nil { self.refresh() }
            }
        }
    }

    func setPIPInput(_ source: MonitorProfile.Input) {
        guard isConnected else { show(.failure, "显示器未连接"); return }
        write(VCP.pbpInput, source.value)
        pipInput = source
        show(.success, "PIP 画面来源 → \(source.short)")
    }

    func setMainInput(_ source: MonitorProfile.Input) {
        guard isConnected else { show(.failure, "显示器未连接"); return }
        write(VCP.inputSource, source.value)
        mainInput = source
        show(.success, "主画面 → \(source.short)")
    }

    /// 亮度设置
    func setBrightness(_ value: Int) {
        guard isConnected else { return }
        let upper = brightnessMax ?? 100
        let next = max(0, min(upper, value))
        pendingBrightness = next
        brightness = next
        scheduleCoalescedFlush()
    }

    /// 音量设置（拖动中会高频调用 → 合并后按 ~80ms 节奏写入）
    func setVolume(_ value: Int) {
        guard isConnected else { return }
        let next = max(0, min(100, value))
        pendingVolume = next
        volume = next
        scheduleCoalescedFlush()
        if next > 0 && isMuted {
            isMuted = false
        }
    }

    /// 切换静音
    func toggleMute() {
        guard isConnected else { return }
        let next = isMuted ? 2 : 1      // DDC/CI: 1=静音 2=取消静音
        write(VCP.mute, UInt16(next))
        isMuted.toggle()
    }

    /// 以固定节奏冲刷合并后的目标值（最新值优先）
    private func scheduleCoalescedFlush() {
        coalesceTimer?.invalidate()
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            guard let self else { return }
            if let b = self.pendingBrightness {
                self.pendingBrightness = nil
                self.write(VCP.brightness, UInt16(b))
            }
            if let v = self.pendingVolume {
                self.pendingVolume = nil
                self.write(VCP.audioVolume, UInt16(v))
            }
        }
    }

    private func show(_ kind: Toast.Kind, _ text: String) {
        toast = Toast(kind: kind, text: text)
        let t = text
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if self.toast?.text == t { self.toast = nil }
        }
    }
}
