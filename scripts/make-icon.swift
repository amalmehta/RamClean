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

func oval(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
}

func withShadow(_ alpha: CGFloat, blur: CGFloat = 22, dy: CGFloat = -12, tint: UInt32 = 0x000000, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color(tint, alpha)
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.shadowBlurRadius = blur
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// A curled ram's horn: a tapered spiral filled in one piece, with ridges and a highlight.
func horn(center c: CGPoint, start: CGFloat, dir: CGFloat) {
    let turns: CGFloat = 1.3, steps = 220
    var pts: [CGPoint] = [], widths: [CGFloat] = []
    for i in 0...steps {
        let k = CGFloat(i) / CGFloat(steps)
        let t = k * turns * 2 * .pi
        let r = 140 * (1 - k * 0.8)
        let a = start + dir * t
        pts.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
        widths.append(86 - 56 * k)
    }
    var outer: [CGPoint] = [], inner: [CGPoint] = []
    for i in pts.indices {
        let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
        let len = max(0.001, hypot(b.x - a.x, b.y - a.y))
        let n = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
        let h = widths[i] / 2
        outer.append(CGPoint(x: pts[i].x + n.x * h, y: pts[i].y + n.y * h))
        inner.append(CGPoint(x: pts[i].x - n.x * h, y: pts[i].y - n.y * h))
    }
    let shape = NSBezierPath()
    shape.move(to: outer[0])
    outer.dropFirst().forEach { shape.line(to: $0) }
    inner.reversed().forEach { shape.line(to: $0) }
    shape.close()
    shape.append(oval(pts.last!, widths.last!, widths.last!)) // rounded tip

    withShadow(0.28, blur: 20, dy: -10) { color(0xE7B65A).setFill(); shape.fill() }
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0xFFE29A), color(0xF2BC5C), color(0xC98632)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: shape.bounds.insetBy(dx: -20, dy: -20), angle: -70)
    // Ridges across the horn.
    color(0x9A6224, 0.32).setStroke()
    for i in stride(from: 10, to: steps - 6, by: 11) {
        let ridge = NSBezierPath()
        ridge.move(to: inner[i]); ridge.line(to: outer[i])
        ridge.lineWidth = 5; ridge.lineCapStyle = .round
        ridge.stroke()
    }
    // Soft highlight running along the curl.
    let shine = NSBezierPath()
    for i in pts.indices {
        let q = CGPoint(x: outer[i].x * 0.72 + pts[i].x * 0.28, y: outer[i].y * 0.72 + pts[i].y * 0.28)
        i == 0 ? shine.move(to: q) : shine.line(to: q)
    }
    shine.lineWidth = 10; shine.lineCapStyle = .round; shine.lineJoinStyle = .round
    color(0xFFFFFF, 0.35).setStroke()
    shine.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon() {
    // Squircle body on the standard macOS 824 pt grid, with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    withShadow(0.35, blur: 24) { color(0x5B6CF6).setFill(); bodyPath.fill() }
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(colors: [color(0x8A5CFF), color(0x5B6CF6), color(0x22B8C8)], atLocations: [0, 0.5, 1],
               colorSpace: .sRGB)!.draw(in: body, angle: -60)
    NSGradient(starting: color(0xFFFFFF, 0.2), ending: color(0xFFFFFF, 0))!
        .draw(in: NSRect(x: 100, y: 600, width: 824, height: 324), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Horns curl down beside the face.
    horn(center: CGPoint(x: 296, y: 556), start: 0.3, dir: 1)
    horn(center: CGPoint(x: 728, y: 556), start: .pi - 0.3, dir: -1)

    // Ears, tucked under the wool.
    for (x, angle) in [(CGFloat(350), CGFloat(22)), (CGFloat(674), CGFloat(-22))] {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: x, yBy: 516); t.rotate(byDegrees: angle); t.concat()
        withShadow(0.25, blur: 10, dy: -5) { color(0x3A3A50).setFill(); oval(.zero, 156, 68).fill() }
        color(0xF3A7B8).setFill()
        oval(CGPoint(x: x < 512 ? -12 : 12, y: 0), 100, 30).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Face.
    let face = oval(CGPoint(x: 512, y: 448), 304, 384)
    withShadow(0.3, blur: 24, dy: -12) { color(0x3A3A50).setFill(); face.fill() }
    NSGradient(starting: color(0x4C4C64), ending: color(0x2C2C3E))!.draw(in: face, angle: -90)

    // Wool: a fluffy cap of overlapping puffs, with a soft shade underneath.
    let puffs: [(CGFloat, CGFloat, CGFloat)] = [
        (512, 716, 96), (432, 700, 80), (592, 700, 80), (372, 650, 66), (652, 650, 66),
        (470, 770, 66), (554, 770, 66), (512, 622, 70), (448, 612, 56), (576, 612, 56),
        (400, 600, 50), (624, 600, 50),
    ]
    withShadow(0.22, blur: 18, dy: -10, tint: 0x1B1B4A) {
        color(0xDCDDF0).setFill()
        for (x, y, r) in puffs { oval(CGPoint(x: x, y: y - 8), r * 2, r * 2).fill() }
    }
    color(0xFCFCFF).setFill()
    for (x, y, r) in puffs { oval(CGPoint(x: x, y: y + 4), r * 2 - 10, r * 2 - 10).fill() }
    color(0xFFFFFF, 0.9).setFill()
    for (x, y, r) in puffs where y > 690 { oval(CGPoint(x: x - r * 0.25, y: y + r * 0.3), r * 0.7, r * 0.45).fill() }

    // Happy closed eyes, rosy cheeks, muzzle and smile.
    for x in [CGFloat(448), 576] {
        let eye = NSBezierPath()
        eye.appendArc(withCenter: CGPoint(x: x, y: 474), radius: 30, startAngle: 20, endAngle: 160)
        eye.lineWidth = 15; eye.lineCapStyle = .round
        color(0xFFFFFF).setStroke(); eye.stroke()
    }
    color(0xF29DB0, 0.6).setFill()
    oval(CGPoint(x: 404, y: 414), 58, 32).fill(); oval(CGPoint(x: 620, y: 414), 58, 32).fill()
    NSGradient(starting: color(0x6A6A86), ending: color(0x55556E))!.draw(in: oval(CGPoint(x: 512, y: 342), 196, 124), angle: -90)
    color(0x262636).setFill()
    oval(CGPoint(x: 481, y: 358), 26, 18).fill(); oval(CGPoint(x: 543, y: 358), 26, 18).fill()
    let smile = NSBezierPath()
    smile.appendArc(withCenter: CGPoint(x: 512, y: 336), radius: 34, startAngle: 210, endAngle: 330)
    smile.lineWidth = 9; smile.lineCapStyle = .round
    color(0x262636).setStroke(); smile.stroke()

    // Sparkles: "clean".
    withShadow(0.15, blur: 10, dy: -4) {
        color(0xFFFFFF).setFill()
        sparkle(CGPoint(x: 800, y: 806), 74).fill()
        color(0xFFFFFF, 0.9).setFill()
        sparkle(CGPoint(x: 706, y: 860), 30).fill()
        sparkle(CGPoint(x: 210, y: 300), 44).fill()
    }
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
