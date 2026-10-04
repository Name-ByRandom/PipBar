import SwiftUI

// MARK: - 亮度 / 音量滑块
//
// 移植自 Crisp (didriksg/Crisp) 的 BrightnessSliderView / VolumeSliderView。
//
// 关键行为（照搬 Crisp）：
//   - 松手时才真正写入 DDC，拖动过程只更新本地值。
//     Dell 的 DDC 控制器在连续快速写入下会堵死（实测批量写只有第一次生效），
//     滑块拖动会产生几十次写入，必须合并成一次。
//   - 拖动时屏蔽外部读数回写，否则会和手指"打架"。
//   - 音量不做淡入淡出，跳变是对的；亮度点击滑块是滑向目标。
//
// 注：本项目用 swiftc 单文件编译，无法加载 SwiftUIMacros 插件，
// 因此 @State（宏）不可用，改用 ObservableObject 承载本地状态。

// MARK: 步进按钮

struct StepButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: 本地状态容器

/// 滑块的本地拖动状态。
/// 必须由长生命周期对象（DisplayController）持有，不能在 View 里 new。
final class SliderModel: ObservableObject {
    @Published var local: Double = 0
    @Published var maxValue: Double = 100
    @Published var isDragging = false
}

// MARK: 亮度

struct BrightnessControl: View {
    @ObservedObject var ctrl: DisplayController
    /// 由父视图持有（@StateObject），保证跨重建存活。
    /// 注意：不能写成 `@ObservedObject var model = BrightnessModel()` ——
    /// 那样每次视图重建都会新建一个归零的实例，把真实读数冲掉。
    @ObservedObject var model: SliderModel

    private var step: Double { 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text("亮度")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.local))")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                StepButton(systemName: "sun.min.fill") { step(-step) }

                Slider(
                    value: $model.local,
                    in: 0...max(100, model.maxValue),
                    onEditingChanged: { editing in
                        model.isDragging = editing
                        if !editing {
                            // 松手才写：整段拖动合并成一次 DDC 写入
                            ctrl.setBrightness(Int(model.local.rounded()))
                        }
                    }
                )
                .controlSize(.small)
                .accessibilityLabel("显示器亮度")

                StepButton(systemName: "sun.max.fill") { step(step) }
            }
        }
        .onAppear(perform: sync)
        .onChange(of: ctrl.brightness) { _, newValue in
            guard !model.isDragging, let v = newValue else { return }
            model.local = Double(v)
        }
        .onChange(of: ctrl.brightnessMax) { _, newValue in
            model.maxValue = Double(newValue ?? 100)
        }
    }

    private func sync() {
        model.maxValue = Double(ctrl.brightnessMax ?? 100)
        if let b = ctrl.brightness {
            model.local = Double(b)
        } else if model.local == 0 {
            // 读不到时给个合理默认值，避免滑块显示 0 且看不出范围
            model.local = 50
        }
    }

    private func step(_ delta: Double) {
        let next = max(0, min(max(100, model.maxValue), model.local + delta))
        model.local = next
        ctrl.setBrightness(Int(next.rounded()))
    }
}

// MARK: 音量

struct VolumeControl: View {
    @ObservedObject var ctrl: DisplayController
    /// 同上：必须由父视图持有，不能用默认初始化。
    @ObservedObject var model: SliderModel

    private var step: Double { 100.0 / 16.0 }   // 与音量键步进一致

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text("音量")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    if ctrl.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(ctrl.isMuted ? "静音" : "\(Int(model.local))")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                StepButton(systemName: "speaker.fill") { step(-step) }

                Slider(
                    value: $model.local,
                    in: 0...100,
                    onEditingChanged: { editing in
                        model.isDragging = editing
                        if !editing {
                            // 松手补写一次，确保最终值落地
                            ctrl.setVolume(Int(model.local.rounded()))
                        }
                    }
                )
                .controlSize(.small)
                .accessibilityLabel("显示器音量")
                // 与 Crisp 一致：音量在拖动过程中就写入（音量跳变是对的，
                // 且写入有节流，不会像亮度那样把 Dell 控制器写堵）
                .onChange(of: model.local) { _, newValue in
                    guard model.isDragging else { return }
                    ctrl.setVolume(Int(newValue.rounded()))
                }

                StepButton(systemName: "speaker.wave.3.fill") { step(step) }
            }

            Button {
                ctrl.toggleMute()
            } label: {
                Label(ctrl.isMuted ? "取消静音" : "静音",
                      systemImage: ctrl.isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 10))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .onAppear {
            if let v = ctrl.volume {
                model.local = Double(v)
            } else if model.local == 0 {
                model.local = 50
            }
        }
        .onChange(of: ctrl.volume) { _, newValue in
            guard !model.isDragging, let v = newValue else { return }
            model.local = Double(v)
        }
    }

    private func step(_ delta: Double) {
        let next = max(0, min(100, model.local + delta))
        model.local = next
        ctrl.setVolume(Int(next.rounded()))
    }
}
