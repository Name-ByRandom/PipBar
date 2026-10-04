import AppKit
import SwiftUI

// MARK: - 菜单栏宿主
//
// 不用 SwiftUI 的 MenuBarExtra Scene：swiftc 单文件编译产物在
// macOS 14+ 上 MenuBarExtra 不显示（缺少 Scene 生命周期支持）。
// 改用最底层、兼容性最好的 NSStatusItem + NSHostingView。

@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let controller = DisplayController()

    static let shared = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏 agent：不出现在 Dock、不抢焦点
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "pip",
                accessibilityDescription: "PIP 控制")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PipMenuView(ctrl: controller))

        // 监听显示器热插拔：拔插后 IORegistry 会重排，
        // 缓存的 IOAVServiceRef 立即失效，必须重建
        controller.startObservingTopology()
        controller.connect()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        // 右键直接退出，省得进面板找
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            NSApp.terminate(nil)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { StatusItemController.shared }
app.delegate = delegate
app.run()
