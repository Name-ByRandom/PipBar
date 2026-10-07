# PipBar

macOS 菜单栏工具，通过 **DDC/CI** 控制显示器的 PIP/PBP 布局、亮度、音量和输入源。
不用碰显示器上的实体按键。

**通用工具** —— 任何支持 DDC/CI 的显示器都能用，配置自己的码表即可。
（[shared/profiles/](shared/profiles/) 里有实测过的配置档可参考。）

## 快速开始

```bash
git clone <this-repo>
cd pipbar

# 1. 为你的显示器建一份配置
cp shared/profiles/_template.json "shared/profiles/<你的显示器名>.json"
$EDITOR "shared/profiles/<你的显示器名>.json"

# 2. 构建并运行
cd macos && ./tools/build-app.sh
```

之后 `open ~/Applications/PipBar.app` 启动。
菜单栏（右上角）出现图标，点它打开面板。**右键图标 = 退出**。

## 配置显示器

**一台显示器一个文件**，放在 `shared/profiles/`，文件名用 EDID 里的显示器名
（匹配时忽略大小写和空格）：

```
shared/profiles/
├── _template.json          填写模板
├── DELL S3423DWC.json      实测实例
└── <你的显示器>.json       ← 你填这份
```

必填项：

```json
"profile": {
  "edidName": "DELL S3423DWC",
  "vendor": "Dell",
  "model": "S3423DWC",
  "vendorIdHex": "10AC"
}
```

因为码表描述的是**显示器**而不是某台 Mac，所以可以直接提交到仓库共享。

### 查你的显示器信息

```bash
cd macos
./tools/build-app.sh --tools     # 构建调试工具
./tools/ddcwatch                 # 第一行就是 EDID 显示器名，用它做文件名
```

### 填 PIP/PBP 码表

**码表因显示器而异，没有通用值。** 测出来：

```bash
./tools/ddcwatch watch
```

然后用显示器**实体按键**在 OSD 里逐个切换布局 —— `ddcwatch` 会实时打印每次变化
对应的 VCP 码：

```
[20:14:31]  VCP 0xE9 = 36  →  50 : 50
[20:14:35]  VCP 0xE9 = 41  →  25 : 75
```

把测到的值填进 `pbpModes`。显示器不支持 PIP 就留空数组，界面会隐藏该区
（亮度/音量/输入源仍然可用）。

> **不要照抄别人的码表** —— 即使同厂商不同型号也可能完全不同。
> 有些第三方工具文档里的码值对特定型号是错的。

## 目录结构

```
pipbar/
├── shared/                     显示器配置（跨平台）
│   ├── profiles/                  一台显示器一个 json
│   │   ├── _template.json           填写模板
│   │   └── <EDID 显示器名>.json      码表
│   └── NOTES.md                  通用踩坑记录
│
├── macos/                      macOS 实现
│   ├── src/                       Swift 源码（自研 DDC/CI）
│   ├── tools/                     构建脚本 + 调试工具 + 图标生成
│   ├── .iconwork/                 生成的 app 图标
│   └── README.md
│
├── windows/                    Windows 实现（借用 Twinkle Tray）
│   ├── tools/tt.ps1               Twinkle Tray 管道客户端
│   ├── macro-deck/                Macro Deck 3 自定义视图布局
│   ├── deprecated/                已废弃：P/Invoke 探测脚本
│   └── README.md
│
└── LICENSE                     MIT
```

两端共用 `shared/profiles/` 里的码表 —— 因为码表描述的是**显示器**，不是某台机器。

配置档在构建时会被拷进 app bundle 的 `Contents/Resources/profiles/`，
所以装好的 app 不依赖源码目录。用户自己的码表放
`~/Library/Application Support/PipBar/profiles/`。

## 实现要点

与具体显示器无关的通用经验，完整版见 [shared/NOTES.md](shared/NOTES.md)。

### 读数必须校验

DDC/CI 读回的 8 字节响应要验证签名、**VCP 码回显**、**校验和**，缺一不可。
少任何一条都会读到 EDID 残片或空帧 —— 表现为读出无意义的值（如 `110`）。

### 写入要节流

连续快速写入会让部分显示器的 DDC 控制器堵死。本项目所有 DDC 读写走**单条串行队列**，
两次写入间隔 ≥150ms。

### 读写不能并发

`IOAVServiceRef` 是裸指针，并发访问会拿到野指针。必须串行化。

### I/O 不能在主线程

显示器发现要遍历 IORegistry 树（几百毫秒），每次 DDC 读要等回包（~40ms）。
跑在主线程会冻结界面。

## 开发

```bash
cd macos
./tools/build-app.sh          # 构建 app + 安装 + 启动
./tools/build-app.sh --no-run # 只构建
./tools/build-app.sh --tools  # 构建调试工具 ddcwatch
python3 tools/make-icon.py    # 重新生成 app 图标
```

排查问题时看实时日志：

```bash
log stream --predicate 'subsystem == "com.pipbar.ddc"' --level debug
```

## 已知限制

- **macOS 端仅支持 Apple Silicon**。依赖 IOKit 私有 API（`IOAVService*`），
  Intel Mac 不适用。
- **只支持 DP Alt Mode（USB-C）连接**。m1ddc 类工具无法通过 HDMI 控制。
- **Windows 端需要 Twinkle Tray 运行** —— 它借用了 Twinkle Tray 已验证的 DDC 实现，
  详见 [windows/README.md](windows/README.md)。
- **多显示器**未做选择界面。按 EDID 显示器名匹配配置档，匹配不到就用第一块外接屏。
- **不要让两台机器同时控 DDC。** 会争抢 I2C 总线，可能让显示器 DDC 控制器无响应
  （表现为所有 VCP 读取失败；关闭 PIP/PBP 通常能恢复）。

## License

MIT，见 [LICENSE](LICENSE)。
