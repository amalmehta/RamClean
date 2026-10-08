// Draws RamClean's app icon and writes the AppIcon asset catalog.
// Run: swift scripts/make-icon.swift   (from the repo root)
import AppKit

let size: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Four-pointed sparkle centred at `c` with radius `r`.
func sparkle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let w = r * 0.26
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + w * 0.35, y: c.y + w), controlPoint2: CGPoint(x: c.x + w, y: c.y + w * 0.35))
    p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + w, y: c.y - w * 0.35), controlPoint2: CGPoint(x: c.x + w * 0.35, y: c.y - w))
    p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - w * 0.35, y: c.y - w), controlPoint2: CGPoint(x: c.x - w, y: c.y - w * 0.35))
    p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - w, y: c.y + w * 0.35), controlPoint2: CGPoint(x: c.x - w * 0.35, y: c.y + w))
    p.close()
    return p
}

func drawIcon() {
    // Squircle body on the standard macOS 824 pt grid, with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    color(0x2C5BE0).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(colors: [color(0x4F7DFF), color(0x2A55D8), color(0x10B3A3)], atLocations: [0, 0.5, 1],
               colorSpace: .sRGB)!.draw(in: body, angle: -60)
    // Gentle glow from the top.
    NSGradient(starting: color(0xFFFFFF, 0.22), ending: color(0xFFFFFF, 0))!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Memory stick, tilted slightly so it feels lively.
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 500, yBy: 470)
    t.rotate(byDegrees: -8)
    t.concat()

    let stickShadow = NSShadow()
    stickShadow.shadowColor = color(0x0A1E5C, 0.35)
    stickShadow.shadowOffset = NSSize(width: 0, height: -14)
    stickShadow.shadowBlurRadius = 26
    NSGraphicsContext.saveGraphicsState()
    stickShadow.set()
    let stick = NSRect(x: -300, y: -130, width: 600, height: 260)
    // The stick, with its key notch cut out of the bottom edge (clip away the notch).
    let mask = NSBezierPath(rect: NSRect(x: -1000, y: -1000, width: 2000, height: 2000))
    mask.append(NSBezierPath(roundedRect: NSRect(x: 60, y: -160, width: 30, height: 70), xRadius: 13, yRadius: 13))
    mask.windingRule = .evenOdd
    mask.addClip()
    color(0xF7FAFF).setFill()
    NSBezierPath(roundedRect: stick, xRadius: 30, yRadius: 30).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gold contacts along the bottom.
    let gold = NSGradient(starting: color(0xFFD66B), ending: color(0xE8A93A))!
    var x: CGFloat = -268
    while x < 270 {
        if !(x > 40 && x < 100) {
            gold.draw(in: NSBezierPath(roundedRect: NSRect(x: x, y: -112, width: 22, height: 54), xRadius: 6, yRadius: 6), angle: -90)
        }
        x += 36
    }

    // Four chips.
    for i in 0..<4 {
        let cx = -258 + CGFloat(i) * 132
        let chip = NSRect(x: cx, y: -28, width: 110, height: 124)
        NSGradient(starting: color(0x26345F), ending: color(0x141C38))!
            .draw(in: NSBezierPath(roundedRect: chip, xRadius: 14, yRadius: 14), angle: -90)
        color(0xFFFFFF, 0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: cx + 14, y: 70, width: 82, height: 10), xRadius: 5, yRadius: 5).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Sparkles: "clean".
    color(0xFFFFFF).setFill()
    sparkle(CGPoint(x: 748, y: 742), 118).fill()
    color(0xFFFFFF, 0.9).setFill()
    sparkle(CGPoint(x: 640, y: 812), 46).fill()
    sparkle(CGPoint(x: 838, y: 618), 34).fill()
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try png(pt * scale).write(to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: set.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted])
    .write(to: URL(fileURLWithPath: "App/Assets.xcassets/Contents.json"))
try png(1024).write(to: URL(fileURLWithPath: "docs/images/icon.png"))
print("Wrote App/Assets.xcassets/AppIcon.appiconset and docs/images/icon.png")
