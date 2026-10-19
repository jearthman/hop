// Renders Hop's app icon into an .iconset folder for iconutil.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Body: macOS icon grid (824/1024) with a blue→violet gradient.
    let body = NSBezierPath(roundedRect: r(0.098, 0.098, 0.804, 0.804), xRadius: 0.18 * s, yRadius: 0.18 * s)
    NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.45, blue: 1.0, alpha: 1),
               ending: NSColor(srgbRed: 0.56, green: 0.27, blue: 0.93, alpha: 1))!.draw(in: body, angle: -90)

    func window(_ frame: NSRect, alpha: CGFloat) {
        let path = NSBezierPath(roundedRect: frame, xRadius: 0.035 * s, yRadius: 0.035 * s)
        NSColor(white: 1, alpha: alpha).setFill()
        path.fill()
        // title bar dots
        let dot = 0.022 * s
        for i in 0..<3 {
            let x = frame.minX + 0.03 * s + CGFloat(i) * dot * 1.6
            let y = frame.maxY - 0.045 * s
            NSColor(srgbRed: 0.45, green: 0.38, blue: 0.95, alpha: alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
        }
    }
    window(r(0.30, 0.42, 0.44, 0.30), alpha: 0.45)
    window(r(0.22, 0.28, 0.46, 0.32), alpha: 0.97)

    // Magnifier over the front window.
    let lens = r(0.52, 0.22, 0.20, 0.20)
    let ring = NSBezierPath(ovalIn: lens)
    ring.lineWidth = 0.035 * s
    NSColor(srgbRed: 0.42, green: 0.33, blue: 0.95, alpha: 1).setStroke()
    NSColor(white: 1, alpha: 0.35).setFill()
    ring.fill()
    ring.stroke()
    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: lens.maxX - 0.02 * s, y: lens.minY + 0.02 * s))
    handle.line(to: NSPoint(x: lens.maxX + 0.07 * s, y: lens.minY - 0.07 * s))
    handle.lineWidth = 0.05 * s
    handle.lineCapStyle = .round
    handle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
}
