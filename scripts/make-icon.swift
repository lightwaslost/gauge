// Draws the Gauge app icon and writes Resources/AppIcon.icns (+ Resources/AppIcon.png at 1024px).
// Run: swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle-ish tile inset like standard macOS icons.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.23, blue: 0.29, alpha: 1),
    ])!.draw(in: tilePath, angle: 90)

    let center = NSPoint(x: 512 * s, y: 440 * s)
    let radius = 270 * s

    // Track.
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 200, endAngle: -20, clockwise: true)
    track.lineWidth = 64 * s
    track.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.12).setStroke()
    track.stroke()

    // Value arc with a blue → teal sweep, clipped to a stroked path.
    let value = NSBezierPath()
    value.appendArc(withCenter: center, radius: radius, startAngle: 200, endAngle: 70, clockwise: true)
    value.lineWidth = 64 * s
    value.lineCapStyle = .round
    let cg = NSGraphicsContext.current!.cgContext
    cg.saveGState()
    cg.addPath(value.cgPath)
    cg.setLineWidth(64 * s)
    cg.setLineCap(.round)
    cg.replacePathWithStrokedPath()
    cg.clip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.48, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.83, blue: 0.80, alpha: 1),
    ])!.draw(in: NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: tile.height), angle: 20)
    cg.restoreGState()

    // Needle pointing at the end of the value arc.
    let angle = 70.0 * Double.pi / 180
    let tip = NSPoint(x: center.x + CGFloat(cos(angle)) * (radius - 70 * s),
                      y: center.y + CGFloat(sin(angle)) * (radius - 70 * s))
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: tip)
    needle.lineWidth = 34 * s
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 48 * s, y: center.y - 48 * s, width: 96 * s, height: 96 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try render(1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
