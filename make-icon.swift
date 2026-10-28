import Cocoa

// Renders the app icon into an .iconset folder: make-icon.swift <out.iconset>
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(red: 0.93, green: 0.52, blue: 0.33, alpha: 1),
               ending: NSColor(red: 0.78, green: 0.35, blue: 0.22, alpha: 1))!.draw(in: bg, angle: -90)
    let glyph = NSAttributedString(string: "✳︎", attributes: [
        .font: NSFont.systemFont(ofSize: s * 0.5, weight: .bold), .foregroundColor: NSColor.white])
    let g = glyph.size()
    glyph.draw(at: NSPoint(x: (s - g.width) / 2, y: (s - g.height) / 2))
    // Notification badge
    let d = s * 0.22
    let badge = NSBezierPath(ovalIn: NSRect(x: rect.maxX - d * 0.75, y: rect.maxY - d * 0.75, width: d, height: d))
    NSColor.systemGreen.setFill()
    badge.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
