#!/usr/bin/env bash
# build-app.sh — 构建并安装 PipBar.app
#
# 直接构建到 ~/Applications/PipBar.app —— 唯一一份，不会出现重复图标
#
# 用法:
#   ./build-app.sh          构建 app + 安装 + 重启
#   ./build-app.sh --no-run 只构建 app，不启动
#   ./build-app.sh --tools  构建调试工具 ddcwatch
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
APP="$HOME/Applications/PipBar.app"   # 直接构建到安装位置，避免出现第二份副本
# 模块缓存放项目外：只是编译加速产物，不该堆在源码目录里
CACHE_DIR="${TMPDIR:-/tmp}/pipbar-swcache"
mkdir -p "$CACHE_DIR"

RUN_AFTER=1
[ "${1:-}" = "--no-run" ] && RUN_AFTER=0

mkdir -p "$HOME/Applications"
# 先退出正在运行的实例，否则它的代码签名锁住文件删不掉
if pgrep -f "PipBar.app" >/dev/null 2>&1; then
    pkill -f "PipBar.app" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "PipBar.app" >/dev/null 2>&1 || break
        sleep 0.3
    done
    pgrep -f "PipBar.app" >/dev/null 2>&1 && pkill -9 -f "PipBar.app" || true
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译…"
xcrun swiftc -O \
  -module-cache-path "$CACHE_DIR" \
  -o "$APP/Contents/MacOS/PipBar" \
  "$ROOT/src/DDCNative.swift" \
  "$ROOT/src/MonitorProfile.swift" \
  "$ROOT/src/DisplayController.swift" \
  "$ROOT/src/SliderControls.swift" \
  "$ROOT/src/PipMenuView.swift" \
  "$ROOT/src/app/main.swift" \
  -framework SwiftUI -framework AppKit -framework Network -framework IOKit

# 调试工具（不随 app 分发，需要时用 --tools 单独构建）
if [ "${1:-}" = "--tools" ]; then
    swiftc -O -parse-as-library \
      -module-cache-path "$CACHE_DIR" \
      -o "$HERE/ddcwatch" \
      "$ROOT/src/DDCNative.swift" \
      "$ROOT/src/MonitorProfile.swift" \
      "$HERE/ddcwatch.swift" \
      -framework AppKit -framework IOKit
    echo "✓ 调试工具已构建: $HERE/ddcwatch"
    echo "  用法: $HERE/ddcwatch [watch]"
    exit 0
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PipBar</string>
    <key>CFBundleDisplayName</key>
    <string>PipBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.pipbar.ddc</string>
    <key>CFBundleExecutable</key>
    <string>PipBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>

    <!-- 关键：菜单栏 agent，不显示 Dock 图标 -->
    <key>LSUIElement</key>
    <true/>

    <key>NSHighResolutionCapable</key>
    <true/>

    <key>CFBundleIconFile</key>
    <string>PipBar</string>
</dict>
</plist>
PLIST

# 配置档打进 Resources —— 跟着 app 走，用户不用操心文件放哪
if [ -d "$ROOT/../shared/profiles" ]; then
    rm -rf "$APP/Contents/Resources/profiles"
    cp -R "$ROOT/../shared/profiles" "$APP/Contents/Resources/profiles"
    # _template.json 只是模板，不必分发
    rm -f "$APP/Contents/Resources/profiles/_template.json"
    COUNT=$(ls "$APP/Contents/Resources/profiles"/*.json 2>/dev/null | wc -l | tr -d ' ')
    echo "  已打包 $COUNT 份显示器配置档"
else
    echo "  ⚠️ 未找到 shared/profiles/"
fi

# 图标
if [ -f "$ROOT/.iconwork/PipBar.icns" ]; then
    cp "$ROOT/.iconwork/PipBar.icns" "$APP/Contents/Resources/PipBar.icns"
else
    echo "  (无图标，运行 tools/make-icon.py 生成)"
fi

# ad-hoc 签名，避免 Gatekeeper 拦截
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ 构建完成: $APP"

if [ "$RUN_AFTER" = "1" ]; then
    open "$APP"
    sleep 1
    echo "  已启动 — 看菜单栏的画中画图标"
fi
