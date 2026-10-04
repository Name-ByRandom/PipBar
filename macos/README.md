# macOS 实现

PipBar 的 macOS 版本。菜单栏 app，通过 DDC/CI 控制显示器。

## 构建

```bash
./tools/build-app.sh              # 构建 + 安装到 ~/Applications + 启动
./tools/build-app.sh --no-run     # 只构建，不启动
./tools/build-app.sh --tools      # 构建调试工具 ddcwatch
python3 tools/make-icon.py         # 重新生成 app 图标
```

改完代码直接跑 `./tools/build-app.sh` 即可 —— 它会先退出旧实例，
重新编译、安装并启动。

## 源码结构

| 文件 | 职责 |
|---|---|
| `src/DDCNative.swift` | DDC/CI 协议：读/写报文、响应校验、显示器发现 |
| `src/MonitorProfile.swift` | 加载配置档（app bundle / 用户目录 / 源码树） |
| `src/DisplayController.swift` | 状态管理、并发调度（单串行队列 + 锁） |
| `src/SliderControls.swift` | 亮度/音量滑块 |
| `src/PipMenuView.swift` | 面板界面 |
| `src/app/main.swift` | NSStatusItem + NSPopover 宿主 |
| `../shared/profiles/` | 显示器码表，构建时拷进 app bundle |

## 调试工具

```bash
./tools/ddcwatch          # 读一次全部状态
./tools/ddcwatch watch    # 持续监视 PIP 布局变化
```

配置新显示器时用 `watch` 模式配合实体按键测码表 ——
详见 [../shared/NOTES.md](../shared/NOTES.md)。

## 日志

```bash
log stream --predicate 'subsystem == "com.pipbar.ddc"' --level debug
```

## 实现约束

用 `swiftc` 直接编译（无 Xcode 工程、无 SwiftPM、无第三方依赖）。
这带来几个必须遵守的限制：

- **`@State` 不可用** —— 它是 SwiftUI 的属性包装器宏，单文件编译加载不了
  `SwiftUIMacros` 插件。需要本地状态时用 `ObservableObject`，
  且必须由**长生命周期对象**（如 `DisplayController`）持有 ——
  View 每次弹出面板都会重建，View 内的对象会被重新创建归零。
- **`MenuBarExtra` 不工作** —— SwiftUI Scene 在单文件编译产物上不显示，
  必须用 `NSStatusItem` + `NSHostingView`。
- **模块缓存要指定路径** —— 默认写系统临时目录会被拒。
  构建脚本已指向 `$TMPDIR/pipbar-swcache`。

## 平台限制

- 仅 **Apple Silicon**。依赖 IOKit 私有 API（`IOAVServiceCreateWithService` 等）。
- 仅 **DisplayPort Alt Mode（USB-C）** 连接。m1ddc 类方案无法走 HDMI。
