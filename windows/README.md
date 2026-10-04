# Windows 实现（待做）

macOS 版本已完成，Windows 端暂不需要。

## 如果将来要做

**直接复用 [../shared/profiles/](../shared/profiles/) 里的配置档** ——
码表、输入源、厂商怪癖都在那里，**不要重新摸**。每台显示器一个 json，
文件名是 EDID 显示器名，两端通用。

### 需要重新验证的

**HDMI 通道下 DDC/CI 是否响应。** macOS 走 DisplayPort Alt Mode，DDC 正常。
部分显示器在 HDMI 下不响应 DDC/CI —— 如果这台也是，PIP 模式就**无法从 Windows 控制**
（切换 PIP 必须通过当前活动的那条视频链路发 DDC，而活动链路是 Mac 的 DP）。

验证方法：用调试工具读一次 VCP `0x10`（亮度），能读到有效值就说明 DDC 通。

### 实现建议

- **PowerShell**（`dxva2.dll` 的 `Get/SetVCPFeatureAndVCPFeatureReply`）——
  那台机器不用装编译环境，随手能跑，适合调试工具
- **C# 小 exe** —— 性能更好，但需要 .NET SDK

### 必须遵守的两条（否则会踩坑）

1. **输入源取低位字节** `value & 0xFF` —— 部分厂商把码在两个字节里各放一遍
2. **写入串行化 + 间隔 ≥150ms** —— 连续写会把部分显示器的 DDC 控制器写堵

完整踩坑记录见 [../shared/NOTES.md](../shared/NOTES.md)。
