#!/usr/bin/env swift
import AppKit

// Reproducible vector artwork. Run from the repository root:
// swift scripts/generate-app-icon.swift
let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = projectRoot.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarSync-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(size: Int) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: size * 4, bitsPerPixel: 32)!
    let context = CGContext(data: bitmap.bitmapData, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tile = rounded(CGRect(x: 64, y: 64, width: 896, height: 896), 202)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -9), blur: 18, color: color(0x002E2B, alpha: 0.20))
    context.setFillColor(color(0x12746D))
    context.addPath(tile)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(0x0C5C58), color(0x249C91)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 64),
                               end: CGPoint(x: 512, y: 960), options: [])
    context.restoreGState()
    context.addPath(rounded(CGRect(x: 66, y: 66, width: 892, height: 892), 200))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.13))
    context.setLineWidth(3)
    context.strokePath()

    // One high-contrast calendar silhouette, with two binder tabs.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
                      color: color(0x003D39, alpha: 0.22))
    context.setFillColor(color(0xFFFFFF))
    context.addPath(rounded(CGRect(x: 224, y: 206, width: 576, height: 584), 76))
    context.fillPath()
    context.restoreGState()
    context.setFillColor(color(0xFFFFFF))
    for x: CGFloat in [346, 622] {
        context.addPath(rounded(CGRect(x: x, y: 742, width: 56, height: 112), 28))
        context.fillPath()
    }
    context.setFillColor(color(0x167D75))
    context.addPath(rounded(CGRect(x: 280, y: 658, width: 464, height: 26), 13))
    context.fillPath()

    // Opposed arcs are a single sync symbol, without tiny date numerals.
    let center = CGPoint(x: 512, y: 438)
    let radius: CGFloat = 122
    let ink = color(0x147B73)
    func arrow(start: CGFloat, end: CGFloat) {
        let startRadians = start * .pi / 180
        let endRadians = end * .pi / 180
        context.setStrokeColor(ink)
        context.setLineWidth(42)
        context.setLineCap(.butt)
        context.addArc(center: center, radius: radius, startAngle: startRadians,
                       endAngle: endRadians - 5 * .pi / 180, clockwise: false)
        context.strokePath()
        context.setFillColor(ink)
        context.fillEllipse(in: CGRect(x: center.x + radius * cos(startRadians) - 21,
                                       y: center.y + radius * sin(startRadians) - 21,
                                       width: 42, height: 42))

        let tip = CGPoint(x: center.x + radius * cos(endRadians),
                          y: center.y + radius * sin(endRadians))
        let forward = CGPoint(x: -sin(endRadians), y: cos(endRadians))
        let normal = CGPoint(x: cos(endRadians), y: sin(endRadians))
        let point = CGPoint(x: tip.x + forward.x * 40, y: tip.y + forward.y * 40)
        let base = CGPoint(x: tip.x - forward.x * 40, y: tip.y - forward.y * 40)
        context.beginPath()
        context.move(to: point)
        context.addLine(to: CGPoint(x: base.x + normal.x * 44, y: base.y + normal.y * 44))
        context.addLine(to: CGPoint(x: base.x - normal.x * 44, y: base.y - normal.y * 44))
        context.closePath()
        context.setFillColor(ink)
        context.fillPath()
    }
    arrow(start: 12, end: 154)
    arrow(start: 192, end: 334)
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try render(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated Resources/AppIcon.png and Resources/AppIcon.icns")
