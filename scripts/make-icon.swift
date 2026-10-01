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
    context.setFillColor(NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.09, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    // Background: dark gradient with a soft blue bloom behind the pointer.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let base = CGGradient(colorsSpace: space, colors: [
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.035, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let bloom = CGGradient(colorsSpace: space, colors: [
        NSColor(calibratedRed: 0.96, green: 0.65, blue: 0.14, alpha: 0.42).cgColor,
        NSColor(calibratedRed: 0.96, green: 0.65, blue: 0.14, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(bloom, startCenter: CGPoint(x: 470, y: 540), startRadius: 0,
                               endCenter: CGPoint(x: 470, y: 540), endRadius: 420, options: [])
    context.restoreGState()

    // The pointer (tip at top-left, like the cursor buddy), with a glow.
    let glyph = CGRect(x: 395, y: 270, width: 320, height: 420)
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: glyph.minX, y: glyph.maxY))
    outline.addLine(to: CGPoint(x: glyph.minX, y: glyph.minY))
    outline.addLine(to: CGPoint(x: glyph.minX + glyph.width * 0.34, y: glyph.maxY - glyph.height * 0.74))
    outline.addLine(to: CGPoint(x: glyph.maxX, y: glyph.maxY - glyph.height * 0.7))
    outline.closeSubpath()
    // One solid shape with rounded corners: the triangle merged with its own rounded stroke.
    let pointer = outline.union(outline.copy(strokingWithWidth: 40, lineCap: .round, lineJoin: .round, miterLimit: 10))
    context.saveGState()
    context.setShadow(offset: .zero, blur: 70, color: NSColor(calibratedRed: 1.0, green: 0.68, blue: 0.2, alpha: 0.85).cgColor)
    context.addPath(pointer)
    context.setFillColor(NSColor(calibratedRed: 0.96, green: 0.65, blue: 0.14, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(pointer)
    context.clip()
    let fill = CGGradient(colorsSpace: space, colors: [
        NSColor(calibratedRed: 1.0, green: 0.77, blue: 0.42, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.02, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(fill, start: CGPoint(x: glyph.minX, y: glyph.maxY), end: CGPoint(x: glyph.maxX, y: glyph.minY), options: [])
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
