# 已废弃

## `ddc-probe.ps1`

**用途**：直接用 PowerShell P/Invoke 调 `dxva2.dll`，探测显示器 DDC/CI 能力。

**为什么废弃**：

在 PowerShell 里 P/Invoke `GetPhysicalMonitorsFromHMONITOR` 无法正确工作 ——
函数返回 `TRUE`，但 `PHYSICAL_MONITOR` 数组保持全零（`desc=''`、`handle=0x0`）。

试过并排除的可能：

| 尝试 | 结果 |
|---|---|
| `[In, Out]` 标注 | API 是 `[Out]`，`[In]` 会把零数组写回 |
| `string` + `ByValTStr` | 结构体膨胀，句柄偏移错位 |
| `char[]` | `Marshal.SizeOf` = 136，应为 264（`WCHAR` 是 2 字节） |
| `ushort[]` + `[Out]` | SizeOf 正确 = 264，但仍返回零数组 |
| 逻辑全部移进 C# | PowerShell 不再触碰数组，**仍然失败** |

同样的 P/Invoke 在 C++ 里正常 —— Twinkle Tray 的 node-ddcci 就这么用。

**替代方案**：用 [`../tools/tt.ps1`](../tools/tt.ps1) 走 Twinkle Tray 的命名管道。
Twinkle Tray 已经用原生 C++ 验证过这条路可行，无需自己实现 DDC 层。

**保留理由**（可选）：里面的 P/Invoke 声明、结构体布局和错误诊断逻辑，
作为 .NET 侧 DDC 编程的参考仍有价值。
