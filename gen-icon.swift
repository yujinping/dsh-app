#!/usr/bin/env swift

import Cocoa

// ─── 参数 ───────────────────────────────────────────────────
let outputDir = "/tmp/dsh-icon.iconset"

// 配色
let bgColor     = NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)  // #F5F7FA
let accentColor = NSColor(red: 0.0, green: 0.48, blue: 0.76, alpha: 1)   // #007ACC

// ─── 创建 iconset 目录 ─────────────────────────────────────
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// ─── 绘制图标（精确像素尺寸） ─────────────────────────────
func drawIcon(logicalSize: Int, scale: Int) -> NSImage {
    let pixelSize = logicalSize * scale
    let s = CGFloat(pixelSize)

    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // Apple 图标规范：squircle 四周留 ~10% 透明边距（图形占画布约 80%）
    // 否则图标贴满画布，Launchpad 渲染时比其他 app 大 ~20%
    let margin = s * 0.10
    let rect = NSRect(x: margin, y: margin,
                      width: s - 2 * margin, height: s - 2 * margin)
    let radius = rect.width * 0.2237   // Apple squircle 圆角 ≈ 22.37% 宽度
    let roundRect = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    roundRect.addClip()

    // 浅灰蓝背景
    bgColor.setFill()
    roundRect.fill()

    // ── D 符号（约 27% 逻辑尺寸，在内框居中） ──
    let dScale = CGFloat(logicalSize) * 0.27 * CGFloat(scale)
    let cx = s * 0.5
    let cy = s * 0.5

    let dArc = NSBezierPath()
    dArc.appendArc(withCenter: NSPoint(x: cx, y: cy),
                   radius: dScale * 0.35,
                   startAngle: 140, endAngle: 320,
                   clockwise: true)
    dArc.lineWidth = dScale * 0.28
    dArc.lineCapStyle = .round
    dArc.lineJoinStyle = .round
    accentColor.withAlphaComponent(0.90).setStroke()
    dArc.stroke()

    let dVert = NSBezierPath()
    let lineX = cx - dScale * 0.35
    let lineTop = cy + dScale * 0.35
    let lineBot = cy - dScale * 0.35
    dVert.move(to: NSPoint(x: lineX, y: lineTop))
    dVert.line(to: NSPoint(x: lineX, y: lineBot))
    dVert.lineWidth = dScale * 0.28
    dVert.lineCapStyle = .round
    dVert.lineJoinStyle = .round
    accentColor.withAlphaComponent(0.90).setStroke()
    dVert.stroke()

    NSGraphicsContext.restoreGraphicsState()

    // 创建 NSImage 时使用逻辑尺寸（点），不是像素尺寸！
    let image = NSImage(size: NSSize(width: logicalSize, height: logicalSize))
    image.addRepresentation(bitmap)
    return image
}

// ─── 生成各尺寸 PNG ───────────────────────────────────────
let sizes: [(logicalSize: Int, scale: Int, name: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

for spec in sizes {
    let img = drawIcon(logicalSize: spec.logicalSize, scale: spec.scale)

    guard let rep = img.representations.first as? NSBitmapImageRep else {
        print("❌ 无法获取 bitmap \(spec.name)")
        continue
    }
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        print("❌ 无法编码 \(spec.name)")
        continue
    }

    let path = "\(outputDir)/\(spec.name)"
    try? pngData.write(to: URL(fileURLWithPath: path))

    let actualW = rep.pixelsWide
    let actualH = rep.pixelsHigh
    let expectedPixels = spec.logicalSize * spec.scale
    let status = (actualW == expectedPixels && actualH == expectedPixels) ? "✅" : "⚠️ 期望\(expectedPixels)实际\(actualW)"
    print("  \(status) \(spec.name) (\(actualW)x\(actualH))")
}

print("✅ 所有图标已生成到 \(outputDir)")