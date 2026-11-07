// 사용: swift make_icon.swift <SF Symbol> <hex1> <hex2> <out.png>
import AppKit
let a = CommandLine.arguments
func color(_ h: String) -> NSColor {
    let v = UInt32(h, radix: 16)!
    return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let inset: CGFloat = 100, rect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: color(a[2]), ending: color(a[3]))!.draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: a[1], accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let sz = sym.size
sym.draw(in: NSRect(x: (S - sz.width) / 2, y: (S - sz.height) / 2, width: sz.width, height: sz.height))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[4]))
