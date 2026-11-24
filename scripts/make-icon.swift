// Draws CapyBar's app icon and writes Resources/AppIcon.icns and docs/icon.png.
//   swift scripts/make-icon.swift
//
// The capybara is the menu bar icon's silhouette (Sources/CapyBar/CapybaraIcon.swift),
// in cream on a terracotta tile; the short strip above it stands for the menu bar.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let output = root.appendingPathComponent("Resources/AppIcon.icns")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func oval(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

/// The menu bar capybara in profile, in its own 20 × 18 point space, y pointing down.
func capybaraPath() -> NSBezierPath {
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
    let body = NSBezierPath()
    body.move(to: point(1.3, 7.6))
    body.curve(to: point(6.4, 3.0), controlPoint1: point(1.3, 5.0), controlPoint2: point(3.6, 3.1))
    body.curve(to: point(10.2, 3.7), controlPoint1: point(7.8, 2.95), controlPoint2: point(9.0, 3.2))
    body.curve(to: point(18.9, 12.2), controlPoint1: point(14.8, 4.4), controlPoint2: point(18.8, 7.4))
    body.curve(to: point(17.2, 17), controlPoint1: point(19.0, 15.0), controlPoint2: point(18.2, 16.7))
    body.line(to: point(14.4, 17))
    body.curve(to: point(13.2, 15.0), controlPoint1: point(14.3, 16.0), controlPoint2: point(13.9, 15.2))
    body.line(to: point(11.0, 14.9))
    body.line(to: point(10.6, 17))
    body.line(to: point(8.4, 17))
    body.curve(to: point(7.3, 11.8), controlPoint1: point(8.5, 15.0), controlPoint2: point(8.2, 12.9))
    body.curve(to: point(3.8, 10.4), controlPoint1: point(6.3, 10.9), controlPoint2: point(5.0, 10.7))
    body.curve(to: point(1.3, 7.6), controlPoint1: point(2.3, 10.0), controlPoint2: point(1.3, 9.2))
    body.close()
    body.append(oval(9.15, 2.75, 1.15))
    return body
}

/// Eye and nostril, cut out of the silhouette so the tile shows through.
func capybaraHoles() -> NSBezierPath {
    let holes = oval(6.65, 5.25, 0.65)
    holes.append(oval(2.35, 6.85, 0.45))
    return holes
}

/// One icon on a 1024 canvas, following the macOS grid: an 824 pt rounded square,
/// 100 pt in from every edge. Layout is designed on a 200-unit tile.
func drawIcon() {
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let unit = tile.width / 200
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    let background = NSGradient(starting: color(0xD46B47), ending: color(0xB04D30))!

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0xC2593A).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    background.draw(in: tile, angle: -90)

    // A soft highlight along the top edge, as on the system icons.
    NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.12))?
        .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: 90)

    // Menu bar strip above the capybara.
    let bar = NSRect(x: tile.minX + 30 * unit, y: tile.maxY - 28 * unit, width: 140 * unit, height: 6 * unit)
    color(0xFFD29A).setFill()
    NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()

    // The capybara: the 20 × 18 glyph scaled 7× on the 200-unit tile, y-down.
    var transform = AffineTransform(translationByX: tile.minX + 30 * unit, byY: tile.maxY - 37 * unit)
    transform.scale(x: 7 * unit, y: -7 * unit)
    let capybara = capybaraPath()
    capybara.transform(using: transform)
    let holes = capybaraHoles()
    holes.transform(using: transform)

    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = color(0x5A2414, alpha: 0.35)
    lift.shadowBlurRadius = 20
    lift.shadowOffset = NSSize(width: 0, height: -8)
    lift.set()
    color(0xFFF4E8).setFill()
    capybara.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    capybara.addClip()
    NSGradient(starting: color(0xFFF8F0), ending: color(0xF6E3CF))?.draw(in: capybara.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    holes.addClip()
    background.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: 1024, height: 1024)
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Shrinks a PNG in place with pngquant (`brew install pngquant`) when it is installed:
/// the icon is mostly gradients and blurred shadows, which a 256-colour palette keeps
/// visually identical at about a fifth of the size. Without pngquant the PNG stays as is.
func quantize(_ file: URL) {
    let pngquant = Process()
    pngquant.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    pngquant.arguments = ["pngquant", "--quality=85-98", "--speed", "1", "--strip", "--force", "--ext", ".png", file.path]
    pngquant.standardError = FileHandle.nullDevice
    guard (try? pngquant.run()) != nil else { return }
    pngquant.waitUntilExit()
}

// icns chunk types holding a PNG, smallest first. Written by hand instead of with
// iconutil, which re-expands palette PNGs to full RGBA and undoes the compression.
let sizes: [(type: String, pixels: Int)] = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
    ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
]

func bigEndian(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("CapyBar-icon-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: scratch)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

var pngs: [Int: Data] = [:]
for pixels in Set(sizes.map(\.pixels)) {
    let file = scratch.appendingPathComponent("\(pixels).png")
    try png(pixels: pixels).write(to: file)
    quantize(file)
    pngs[pixels] = try Data(contentsOf: file)
}

var body = Data()
for (type, pixels) in sizes {
    let data = pngs[pixels]!
    body += Data(type.utf8) + bigEndian(data.count + 8) + data
}
try (Data("icns".utf8) + bigEndian(body.count + 8) + body).write(to: output)
print("Wrote \(output.path)")

// The README header shows the 256 px icon.
let readmeIcon = root.appendingPathComponent("docs/icon.png")
try FileManager.default.createDirectory(at: readmeIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
try pngs[256]!.write(to: readmeIcon)
print("Wrote \(readmeIcon.path)")
