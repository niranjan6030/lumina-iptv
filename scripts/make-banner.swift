import AppKit
import CoreGraphics

// Draws docs/screenshots/showcase.png (1200x627 @2x) from the app screenshots.
// Usage: swift scripts/make-banner.swift docs/screenshots docs/screenshots/showcase.png
let args = CommandLine.arguments
let dir = args.count > 1 ? args[1] : "docs/screenshots"
let out = args.count > 2 ? args[2] : "docs/screenshots/showcase.png"
let W = 2400, H = 1254
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

// Background
let bg = CGGradient(colorsSpace: space, colors: [col(0.03, 0.04, 0.09), col(0.09, 0.07, 0.20)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: CGFloat(W), y: 0), options: [])
for (c, p, r) in [(col(0.35, 0.80, 1.0, 0.40), CGPoint(x: 250, y: 1100), 1300.0), (col(0.60, 0.45, 1.0, 0.45), CGPoint(x: 2200, y: 150), 1400.0)] {
    let g = CGGradient(colorsSpace: space, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: CGFloat(r), options: [])
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func text(_ s: String, _ x: CGFloat, _ yTop: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, width: CGFloat = 1000) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let p = NSMutableParagraphStyle(); p.lineSpacing = size * 0.18
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    let box = attr.boundingRect(with: NSSize(width: width, height: 2000), options: [.usesLineFragmentOrigin])
    attr.draw(with: NSRect(x: x, y: CGFloat(H) - yTop - box.height, width: width, height: box.height), options: [.usesLineFragmentOrigin])
}

// Left column
text("LUMINA", 140, 170, 56, .semibold, NSColor(red: 0.35, green: 0.80, blue: 1, alpha: 1), width: 800)
text("Live TV,\nmovies and\nseries.", 140, 250, 118, .bold, .white, width: 820)
text("IPTV player for iPhone, CarPlay,\nAndroid and Android Auto", 140, 800, 50, .regular, NSColor(white: 1, alpha: 0.75), width: 820)
text("Auto-failover  \u{00B7}  TV guide  \u{00B7}  Parental PIN", 140, 1010, 38, .medium, NSColor(white: 1, alpha: 0.55), width: 840)
text("Swift  \u{00B7}  SwiftUI  \u{00B7}  Kotlin  \u{00B7}  Compose  \u{00B7}  Media3", 140, 1085, 36, .medium, NSColor(white: 1, alpha: 0.4), width: 840)

// Phones
func phone(_ file: String, x: CGFloat, yTop: CGFloat, h: CGFloat) {
    guard let img = NSImage(contentsOfFile: "\(dir)/\(file)") else { print("missing \(file)"); return }
    let w = h * img.size.width / img.size.height
    let rect = CGRect(x: x, y: CGFloat(H) - yTop - h, width: w, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: 70, cornerHeight: 70, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -30), blur: 70, color: col(0, 0, 0, 0.6))
    ctx.addPath(path); ctx.setFillColor(col(0, 0, 0)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    img.draw(in: rect)
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(col(1, 1, 1, 0.28)); ctx.setLineWidth(5); ctx.strokePath()
}
phone("ios-live.png", x: 1010, yTop: 270, h: 1040)
phone("ios-player.png", x: 1460, yTop: 190, h: 1040)
phone("android-player.png", x: 1910, yTop: 270, h: 1040)

NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
