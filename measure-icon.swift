#!/usr/bin/env swift
// 测量图标 PNG/ICNS 中非透明内容所占的边界框，用于对比不同 app 图标的内边距
import Cocoa

func measure(_ path: String) {
    guard let img = NSImage(contentsOfFile: path) else {
        print("❌ 无法读取 \(path)")
        return
    }
    var best: NSBitmapImageRep?
    var bestArea = 0
    for case let rep as NSBitmapImageRep in img.representations {
        let area = rep.pixelsWide * rep.pixelsHigh
        if area > bestArea { bestArea = area; best = rep }
    }
    guard let rep = best, let data = rep.bitmapData else {
        print("⚠️ 无 bitmap: \(path)")
        return
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let bpr = rep.bytesPerRow
    let spp = rep.samplesPerPixel
    let alphaIdx = rep.hasAlpha ? (spp - 1) : -1
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            let a = alphaIdx >= 0 ? data[y * bpr + x * spp + alphaIdx] : 255
            if a > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    let name = (path as NSString).lastPathComponent
    let wPct = Int(Double(maxX - minX + 1) / Double(w) * 100)
    let hPct = Int(Double(maxY - minY + 1) / Double(h) * 100)
    print("\(name): \(w)x\(h) | left=\(minX) right=\(w - 1 - maxX) top=\(minY) bottom=\(h - 1 - maxY) | 图形占 \(wPct)%x\(hPct)%")
}

for p in CommandLine.arguments.dropFirst() { measure(p) }
