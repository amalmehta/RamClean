// Draws the icon shown on each kind of RamClean notification: one bold white SF Symbol
// on a colour that tells the kinds apart, even at the small size macOS shows them.
// Run: swift scripts/make-notification-art.swift   (from the repo root)
import AppKit

let canvas: CGFloat = 1000
let pixels = 600

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

struct Art {
    let name: String
    let symbol: String
    let top: UInt32, bottom: UInt32
}

let arts: [Art] = [
    Art(name: "notif-idle", symbol: "moon.zzz.fill", top: 0x8A5CFF, bottom: 0x4B47D6),          // "Quit Spotify?"
    Art(name: "notif-stuck", symbol: "hourglass", top: 0xFFCF4A, bottom: 0xF5961F),             // "… didn't quit"
    Art(name: "notif-quit-done", symbol: "arrow.clockwise", top: 0x2FD39A, bottom: 0x14A6B8),   // "Quit … — Relaunch"
    Art(name: "notif-problem", symbol: "questionmark", top: 0xFF8A8A, bottom: 0xE5506E),        // "Couldn't …"
    Art(name: "notif-memory", symbol: "memorychip.fill", top: 0x5AA8FF, bottom: 0x4A5BF0),      // memory alert
    Art(name: "notif-cpu", symbol: "cpu.fill", top: 0xFF7A45, bottom: 0xE8344A),                // CPU alert
    Art(name: "notif-disk", symbol: "internaldrive.fill", top: 0xC06CFF, bottom: 0xF0569C),     // disk alert
]

func render(_ art: Art) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx

    // Full-bleed background: macOS rounds the corners of notification pictures itself.
    let bg = NSRect(x: 0, y: 0, width: canvas, height: canvas)
    NSGradient(starting: color(art.top), ending: color(art.bottom))!.draw(in: bg, angle: -60)
    NSGradient(starting: color(0xFFFFFF, 0.2), ending: color(0xFFFFFF, 0))!
        .draw(in: NSRect(x: 0, y: 600, width: canvas, height: 400), angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: art.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        fatalError("No SF Symbol named \(art.symbol)")
    }
    // Fit the symbol in the middle 58% of the square, keeping its proportions.
    let box: CGFloat = canvas * 0.58
    let s = symbol.size, k = min(box / s.width, box / s.height)
    let rect = NSRect(x: (canvas - s.width * k) / 2, y: (canvas - s.height * k) / 2, width: s.width * k, height: s.height * k)
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 30
    shadow.set()
    symbol.draw(in: rect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "App/NotificationArt", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for art in arts { try render(art).write(to: dir.appendingPathComponent("\(art.name).png")) }
print("Wrote \(arts.count) icons to App/NotificationArt")
