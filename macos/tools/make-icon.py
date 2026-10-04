#!/usr/bin/env python3
"""
make-icon.py — 生成 PipBar 的 app 图标

画一个 macOS 风格圆角方形 + 画中画小窗图案（呼应 app 的 PIP 功能），
直接用 CoreGraphics 渲染成 PNG，再拼成 .icns。
"""
import subprocess
import os
import struct
import zlib

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), ".iconwork")

# 需要的尺寸（macOS 图标标准档位）
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def make_png(size: int, out: str):
    """用 Swift + CoreGraphics 渲染一个尺寸的 PNG。"""
    swift = f'''
import AppKit
import CoreGraphics

let size = {size}
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {{
    exit(1)
}}

let s = CGFloat(size)
// macOS 圆角矩形留白比例
let inset = s * 0.06
let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
let radius = rect.width * 0.2237

// 背景：蓝色渐变
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path)
ctx.clip()

let colors = [
    CGColor(red: 0.25, green: 0.52, blue: 0.96, alpha: 1),
    CGColor(red: 0.11, green: 0.30, blue: 0.72, alpha: 1)
] as CFArray
if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {{
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY),
                           options: [])
}}

// 主画面（白色圆角矩形，描边风格）
let mainRect = CGRect(x: rect.minX + rect.width * 0.14,
                      y: rect.minY + rect.height * 0.30,
                      width: rect.width * 0.72,
                      height: rect.height * 0.40)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.setLineWidth(max(1, s * 0.045))
ctx.addPath(CGPath(roundedRect: mainRect, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
ctx.strokePath()

// PIP 小窗：右上角实心白块
let pipW = rect.width * 0.30
let pipH = rect.height * 0.26
let pipRect = CGRect(x: mainRect.maxX - pipW - rect.width * 0.06,
                     y: mainRect.maxY - pipH - rect.height * 0.06,
                     width: pipW, height: pipH)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(CGPath(roundedRect: pipRect, cornerWidth: s * 0.025, cornerHeight: s * 0.025, transform: nil))
ctx.fillPath()

// 底部支脚（显示器感）
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
ctx.setLineWidth(max(1, s * 0.04))
ctx.move(to: CGPoint(x: rect.midX, y: mainRect.minY - rect.height * 0.10))
ctx.addLine(to: CGPoint(x: rect.midX, y: mainRect.minY - rect.height * 0.02))
ctx.strokePath()
ctx.move(to: CGPoint(x: rect.midX - rect.width * 0.16, y: mainRect.minY - rect.height * 0.01))
ctx.addLine(to: CGPoint(x: rect.midX + rect.width * 0.16, y: mainRect.minY - rect.height * 0.01))
ctx.strokePath()

guard let img = ctx.makeImage() else {{ exit(1) }}
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else {{ exit(1) }}
try! data.write(to: URL(fileURLWithPath: "{out}"))
'''
    src = os.path.join(OUT_DIR, f"icon_{size}.swift")
    with open(src, "w") as f:
        f.write(swift)
    env = dict(os.environ)
    cache = os.path.join(os.environ.get("TMPDIR", "/tmp").rstrip("/"),
                         "pipbar-swcache")
    os.makedirs(cache, exist_ok=True)
    env["CLANG_MODULE_CACHE_PATH"] = cache
    env["SWIFT_MODULECACHE_PATH"] = cache
    r = subprocess.run(
        ["xcrun", "swift", "-module-cache-path", cache, src],
        capture_output=True, text=True, env=env,
    )
    if r.returncode != 0 or not os.path.exists(out):
        print(f"  ✗ {size}px 失败: {r.stderr[:200]}")
        return False
    return True


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("渲染图标尺寸…")
    for s in SIZES:
        out = os.path.join(OUT_DIR, f"icon_{s}.png")
        if make_png(s, out):
            print(f"  ✓ {s}x{s}")

    # 拼成 iconset 再转 icns
    iconset = os.path.join(OUT_DIR, "PipBar.iconset")
    os.makedirs(iconset, exist_ok=True)
    mapping = {
        16: ["icon_16x16.png", "icon_16x16@2x.png"],
        32: ["icon_32x32.png", "icon_32x32@2x.png"],
        128: ["icon_128x128.png", "icon_128x128@2x.png"],
        256: ["icon_256x256.png", "icon_256x256@2x.png"],
        512: ["icon_512x512.png", "icon_512x512@2x.png"],
    }
    for base, names in mapping.items():
        for n in names:
            src = os.path.join(OUT_DIR, f"icon_{base}.png")
            dst = os.path.join(iconset, n)
            if os.path.exists(src):
                subprocess.run(["cp", src, dst])

    icns = os.path.join(OUT_DIR, "PipBar.icns")
    r = subprocess.run(
        ["iconutil", "-c", "icns", iconset, "-o", icns],
        capture_output=True, text=True,
    )
    if r.returncode == 0 and os.path.exists(icns):
        print(f"✓ 生成 {icns}")
        print(icns)
    else:
        print(f"✗ iconutil 失败: {r.stderr[:300]}")
        sys.exit(1)


if __name__ == "__main__":
    import sys
    main()
