# Windows 端

通过 **Twinkle Tray 的命名管道**控制显示器，不需要自己实现 DDC/CI。

## 为什么走 Twinkle Tray

Windows 上有两条路可以发 DDC/CI：

1. **自己 P/Invoke `dxva2.dll`** —— 绕了 9 个版本没调通
   （`handle` 恒为 `0x0`，详见 [`deprecated/`](deprecated/)）
2. **调 Twinkle Tray 的命名管道** —— ✅ 验证可用

Twinkle Tray 用的是原生 C++（node-ddcci），已经在同一台显示器上跑通。
走它的管道等于「借用」已验证的实现，省掉整个 DDC 层。

> 这也意味着 **Twinkle Tray 必须运行**（任务栏托盘图标可见）。

## 通道

```
\\.\pipe\twinkle-tray\cmds     UTF-8 JSON，单次请求-响应
```

## 用法

```powershell
cd 目录          # 例如 \\你的机器\共享名\PipBar

.\tools\tt.ps1 list              # 列出显示器
.\tools\tt.ps1 get brightness    # 读属性
.\tools\tt.ps1 show 0x60         # 读 VCP 码
.\tools\tt.ps1 show 0x60 -low    # 读 VCP 码（取低字节）
.\tools\tt.ps1 go 0xE9 36        # 写 VCP 码
```

## 命令

| 命令 | 说明 |
|---|---|
| `list` | 列出所有显示器（JSON，含 `name` / `brightness` / `features` 等） |
| `get <属性>` | 读内置属性：`brightness` `volume` `contrast` `name` `connector` `serial` … |
| `show <hex>` | 读任意 VCP 码 |
| `show <hex> -low` | 同上，取低位字节（见下方 Dell 怪癖） |
| `go <hex> <值>` | 写 VCP 码 |

## VCP 码

| 码 | 含义 | 取值 |
|---|---|---|
| `0x10` | 亮度 | 0–100 |
| `0x12` | 对比度 | 0–100 |
| `0x60` | 主画面输入源 | 15/16/17/18/27 |
| `0x62` | 音量 | 0–100 |
| `0x8D` | 静音 | 1=静音 2=取消 |
| `0xE8` | PIP 小窗输入源（Dell 私有） | 同 `0x60` |
| `0xE9` | PIP/PBP 布局（Dell 私有） | 见下表 |

### PIP/PBP 布局值

| 值 | 布局 |
|---|---|
| 0 | 关闭 |
| 33 | PIP 右上小窗 |
| 34 | PIP 右上大窗 |
| 36 | 50 : 50 |
| 41 | 25 : 75 |
| 42 | 75 : 25 |
| 45 | 33 : 67 |
| 46 | 67 : 33 |

⚠️ **m1ddc 文档标注的 43/44 在这台显示器上是错的**（那是别的 Dell 型号）。
本表由「实体按键切换 + 程序回读」逐一确认。

## 两个必须知道的坑

### 1. Dell 输入源是双字节编码

读 `0x60` 时 USB-C 返回 `6939`（`0x1B1B`），而不是标准的 `27`（`0x001B`）——
同一个码在两个字节里各放了一遍。

**比对时取低位字节**：

```powershell
$(([int](.\tools\tt.ps1 show 0x60)) -band 0xFF)     # 27
```

`tt.ps1 show -low` 已经内置了这个处理。

### 2. Twinkle Tray 有缓存

它缓存了显示器状态。写完不 `refresh` 就读，会拿到 `undefined`。

`tt.ps1` 的 `show` 已内置：读之前先 `refresh` 并等 800ms。

## Macro Deck 布局

[`macro-deck/`](macro-deck/) 下是 Macro Deck 3 的自定义视图布局（XML），
用于手机端一键控制：

| 文件 | 内容 |
|---|---|
| `pbp.xml` | PIP/PBP 布局网格（关闭/5:5/1:3/3:1） |
| `pip.xml` | PIP 相关布局 |
| `source-list.xml` | 信号源列表 |
| `source-list-pip.xml` | PIP 模式下的信号源列表 |
| `display-duo.xml` | 亮度 + 对比度 双滑块面板 |
| `volume.xml` | 音量面板 |
| `monitor-title.xml` | 显示器标题栏 |

### 布局怎么工作

XML 只负责**画面**（`layer` / `rect` / `line` / `text` / `slider`），
**不包含命令**。实际执行的命令在 Macro Deck 的动作里配置。

状态高亮靠条件样式：

```xml
<style when="pbp == 46" color="#3d7fd6" />
```

变量绑定：

```xml
<text>{{brightness:0}}</text>        <!-- 变量缺失时显示 0 -->
<slider value="{{contrast}}" />      <!-- 绑定到 contrast 变量 -->
```

### 配套的 Macro Deck 动作

每个按钮/滑块在 Macro Deck 里配置动作，执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\tt.ps1 go 0xE9 36
```

对应关系：

| 操作 | 命令 |
|---|---|
| 切布局 | `tt.ps1 go 0xE9 <值>` |
| 切信号源 | `tt.ps1 go 0x60 <值>` |
| 调亮度 | `tt.ps1 set brightness <0-100>` |
| 读当前布局 | `tt.ps1 show 0x60` |

## 与 macOS 端的区别

| | macOS | Windows |
|---|---|---|
| DDC 实现 | 自己写的（`src/DDCNative.swift`） | 借用 Twinkle Tray |
| 通道 | `IOAVService`（Apple 私有 API） | `dxva2.dll` → Twinkle Tray 管道 |
| 前置条件 | 无 | Twinkle Tray 必须运行 |

码表和 VCP 码两边通用（`shared/profiles/`）。

## 已知问题

**两台机器不要同时控 DDC。** Mac 的 PipBar 和 Windows 的 Twinkle Tray
会争抢同一个 I2C 总线，可能把显示器的 DDC 控制器搞到无响应。

如果出现「Mac 侧所有 VCP 读取失败」，但 Windows 正常：
关闭 PIP/PBP（会重建 DDC 通道）通常能恢复。
