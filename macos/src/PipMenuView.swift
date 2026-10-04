import SwiftUI
import AppKit

// MARK: - 菜单栏面板

struct PipMenuView: View {
    @ObservedObject var ctrl: DisplayController

    private let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: width)
        .onAppear {
            // 面板每次弹出都会重建视图，这里保证读数是新鲜的
            if !ctrl.isConnected { ctrl.connect() } else { ctrl.refresh() }
        }
    }

    // MARK: 顶部状态

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ctrl.isConnected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(ctrl.profile.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let layout = ctrl.currentLayout {
                    Text(layout.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }

            if ctrl.isConnected {
                HStack(spacing: 12) {
                    readout("亮度", ctrl.brightness)
                    readout("对比度", ctrl.contrast)
                    if let v = ctrl.volume { readout("音量", v) }
                    Spacer()
                }
            } else {
                Text("显示器未连接")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func readout(_ label: String, _ value: Int?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if ctrl.isConnected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    BrightnessControl(ctrl: ctrl, model: ctrl.brightnessModel)
                    VolumeControl(ctrl: ctrl, model: ctrl.volumeModel)
                    if ctrl.profile.hasPBP {
                        Divider()
                        pipSection
                        if let layout = ctrl.currentLayout, layout.id != "off" {
                            pipSourceSection
                        }
                    }
                    Divider()
                    mainSourceSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 470)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("未检测到外接显示器")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("重新检测") { ctrl.connect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }

        Divider()

        if let toast = ctrl.toast {
            HStack(spacing: 6) {
                Image(systemName: toast.kind == .failure
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(toast.kind == .failure ? .orange : .green)
                Text(toast.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }

        Divider()

        HStack {
            Button("刷新") { ctrl.connect() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            Spacer()
            Text("右键图标可退出")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: PIP 布局

    private var pipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("PIP / PBP 布局")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(ctrl.profile.modes) { layout in
                    layoutButton(layout)
                }
            }
        }
    }

    private func layoutButton(_ layout: MonitorProfile.PBPMode) -> some View {
        let isActive = ctrl.currentLayout == layout
        return Button {
            ctrl.setLayout(layout)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: layout.icon)
                    .font(.system(size: 10))
                    .frame(width: 12)
                Text(layout.label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ctrl.isBusy)
    }

    // MARK: PIP 画面来源

    private var pipSourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sourceRow("PIP 画面", current: ctrl.pipInput) { ctrl.setPIPInput($0) }
        }
    }

    // MARK: 主画面来源

    private var mainSourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sourceRow("主画面", current: ctrl.mainInput) { ctrl.setMainInput($0) }
        }
    }

    /// 一行信号源选择
    private func sourceRow(_ label: String, current: MonitorProfile.Input?, _ action: @escaping (MonitorProfile.Input) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(label)
            HStack(spacing: 4) {
                ForEach(ctrl.profile.inputs) { src in
                    sourceChip(src, active: current == src) { action(src) }
                }
            }
        }
    }

    private func sourceChip(_ src: MonitorProfile.Input, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(src.short)
                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.4)
    }
}
