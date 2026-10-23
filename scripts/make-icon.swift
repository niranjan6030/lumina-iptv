import AppKit
import CoreGraphics

// Draws the app icon: deep gradient, two colour pools, white play.tv glyph.
// Usage: swift scripts/make-icon.swift <out.png>
let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let full = CGRect(x: 0, y: 0, width: size, height: size)
let base = CGGradient(colorsSpace: space, colors: [color(0.05, 0.07, 0.14), color(0.11, 0.08, 0.24)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])

for (c, p) in [(color(0.35, 0.80, 1.0, 0.60), CGPoint(x: 200, y: 830)), (color(0.60, 0.45, 1.0, 0.60), CGPoint(x: 850, y: 190))] {
    let g = CGGradient(colorsSpace: space, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: 640, options: [])
}

// Glyph, drawn through AppKit into the same CGContext.
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
if let sym = NSImage(systemSymbolName: "play.tv.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 460, weight: .semibold)) {
    let white = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceIn)
        return true
    }
    let w = white.size.width, h = white.size.height
    white.draw(in: NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h),
               from: .zero, operation: .sourceOver, fraction: 0.97)
}
NSGraphicsContext.restoreGraphicsState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
