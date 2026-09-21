import AppKit

/// Draws the macdm icon: blue→indigo gradient squircle, white download
/// arrow landing into an open tray. `appStyle` = macOS icon (margin, softer),
/// otherwise full-bleed extension style.
func drawIcon(size s: CGFloat, appStyle: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Background squircle with soft drop shadow
    let inset: CGFloat = appStyle ? s * 0.075 : 0
    let side = s - 2 * inset
    let bgRect = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = (appStyle ? 0.225 : 0.185) * side
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.035,
                  color: CGColor(red: 0, green: 0, blue: 0.25, alpha: 0.38))
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.30, green: 0.61, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.29, green: 0.25, blue: 0.90, alpha: 1),
    ])!
    gradient.draw(in: bgPath, angle: -90)
    ctx.restoreGState()

    // Glassy highlight on the upper half
    let gloss = NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.0)])!
    let glossPath = NSBezierPath(roundedRect: CGRect(x: bgRect.minX + side * 0.012,
                                                     y: bgRect.midY + side * 0.01,
                                                     width: side * 0.976,
                                                     height: side * 0.478),
                                 xRadius: radius * 0.72, yRadius: radius * 0.72)
    gloss.draw(in: glossPath, angle: -90)

    // Thin inner border for depth
    NSColor(white: 1, alpha: 0.25).setStroke()
    let border = NSBezierPath(roundedRect: bgRect.insetBy(dx: side * 0.006, dy: side * 0.006),
                              xRadius: radius * 0.97, yRadius: radius * 0.97)
    border.lineWidth = s * 0.006
    border.stroke()

    // ---- glyph: white arrow + open tray ----
    let cx = s / 2
    NSColor.white.setFill()

    // arrow head (triangle)
    let headW = (appStyle ? 0.30 : 0.36) * s
    let tipY = (appStyle ? 0.462 : 0.50) * s
    let headTop = tipY + 0.16 * s
    let head = NSBezierPath()
    head.move(to: NSPoint(x: cx - headW / 2, y: headTop))
    head.line(to: NSPoint(x: cx + headW / 2, y: headTop))
    head.line(to: NSPoint(x: cx, y: tipY))
    head.close()
    head.fill()

    // arrow shaft
    let shaftW = (appStyle ? 0.125 : 0.15) * s
    let shaft = NSBezierPath(roundedRect: CGRect(x: cx - shaftW / 2, y: headTop - s * 0.015,
                                                 width: shaftW, height: 0.19 * s),
                             xRadius: shaftW * 0.18, yRadius: shaftW * 0.18)
    shaft.fill()

    // open tray (U shape) + outward lips
    let trayW = (appStyle ? 0.40 : 0.46) * s
    let trayH = 0.125 * s
    let trayTop = tipY - 0.070 * s
    let trayBottom = trayTop - trayH
    let tray = NSBezierPath()
    tray.lineWidth = s * 0.048
    tray.lineCapStyle = .round
    tray.lineJoinStyle = .round
    tray.move(to: NSPoint(x: cx - trayW / 2, y: trayTop))
    tray.line(to: NSPoint(x: cx - trayW / 2, y: trayBottom))
    tray.line(to: NSPoint(x: cx + trayW / 2, y: trayBottom))
    tray.line(to: NSPoint(x: cx + trayW / 2, y: trayTop))
    NSColor.white.setStroke()
    tray.stroke()

    let lip = NSBezierPath()
    lip.lineWidth = s * 0.048
    lip.lineCapStyle = .round
    let lipLen = s * 0.045
    lip.move(to: NSPoint(x: cx - trayW / 2 - lipLen, y: trayTop))
    lip.line(to: NSPoint(x: cx - trayW / 2, y: trayTop))
    lip.move(to: NSPoint(x: cx + trayW / 2, y: trayTop))
    lip.line(to: NSPoint(x: cx + trayW / 2 + lipLen, y: trayTop))
    lip.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

let outApp = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/appicons"
let outExt = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/exticons"
try! FileManager.default.createDirectory(atPath: outApp, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(atPath: outExt, withIntermediateDirectories: true)

// App icon sizes (iconset)
for size in [16, 32, 128, 256, 512, 1024] {
    write(drawIcon(size: CGFloat(size), appStyle: true), to: "\(outApp)/icon_\(size).png")
}

// Extension icons: chunkier glyph, full bleed
for size in [16, 32, 48, 128, 256] {
    write(drawIcon(size: CGFloat(size), appStyle: false), to: "\(outExt)/ext_\(size).png")
}
print("icons written")
