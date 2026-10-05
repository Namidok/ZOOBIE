// Draws ZOOBIE's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root; needs iconutil, which ships with macOS)
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    // macOS icon grid: an 824 pt rounded square centred in 1024, with room for the drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    context.addPath(tilePath)
    context.setFillColor(NSColor(srgbRed: 0.02, green: 0.05, blue: 0.14, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    // Background: deep navy with the avatars' dithered checker band and a hologram-cyan bloom.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let base = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.11, green: 0.18, blue: 0.36, alpha: 1).cgColor,
        NSColor(srgbRed: 0.02, green: 0.05, blue: 0.14, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.setFillColor(NSColor(srgbRed: 0.46, green: 0.58, blue: 0.67, alpha: 0.10).cgColor)
    let cell: CGFloat = 16
    for row in 0..<Int(824 / cell) where (row / 6) % 2 == 0 { // checker bands, like the portraits' backdrops
        for column in stride(from: row % 2, to: Int(824 / cell), by: 2) {
            context.fill(CGRect(x: 100 + CGFloat(column) * cell, y: 100 + CGFloat(row) * cell, width: cell, height: cell))
        }
    }
    let bloom = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.56, green: 0.90, blue: 0.95, alpha: 0.35).cgColor,
        NSColor(srgbRed: 0.56, green: 0.90, blue: 0.95, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(bloom, startCenter: CGPoint(x: 480, y: 540), startRadius: 0,
                               endCenter: CGPoint(x: 480, y: 540), endRadius: 420, options: [])
    context.restoreGState()

    // The 8-bit arrow pointer (same mask as PointerShape in DesignSystem.swift), tip at top-left, glowing.
    let mask = ["#.........", "##........", "###.......", "####......", "#####.....", "######....", "#######...", "########..",
                "#########.", "##########", "######....", "###.###...", "##..###...", "#....###..", ".....###..", "......##.."]
    let pixel: CGFloat = 30
    let origin = CGPoint(x: 512 - 5 * pixel + 10, y: 512 + 8 * pixel) // top-left of the mask, in flipped-up coordinates
    let arrow = CGMutablePath()
    for (row, line) in mask.enumerated() {
        for (column, character) in line.enumerated() where character == "#" {
            arrow.addRect(CGRect(x: origin.x + CGFloat(column) * pixel, y: origin.y - CGFloat(row + 1) * pixel, width: pixel, height: pixel))
        }
    }
    context.saveGState()
    context.setShadow(offset: CGSize(width: 10, height: -10), blur: 0, color: NSColor(srgbRed: 0.02, green: 0.07, blue: 0.16, alpha: 1).cgColor)
    context.addPath(arrow)
    context.setFillColor(NSColor(srgbRed: 0.56, green: 0.90, blue: 0.95, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.setShadow(offset: .zero, blur: 60, color: NSColor(srgbRed: 0.56, green: 0.90, blue: 0.95, alpha: 0.8).cgColor)
    context.addPath(arrow)
    context.clip()
    let fill = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.79, green: 0.96, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.56, green: 0.90, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(fill, start: CGPoint(x: 512, y: origin.y), end: CGPoint(x: 512, y: origin.y - 16 * pixel), options: [])
    context.restoreGState()

    // Hairline highlight on the tile edge.
    context.addPath(tilePath)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    context.setLineWidth(3)
    context.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ZOOBIE-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
