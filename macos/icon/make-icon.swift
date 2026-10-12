// Draws the app icon: the app's own output look. A screen card floating on the default
// indigo-to-pink background, viewfinder brackets framing a zoom on a click, and a record dot.
//
//   swift macos/icon/make-icon.swift out.png     # 1024x1024 PNG
//
// macos/icon/make-icns.sh turns that into ScreencastDirector.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let ctx = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size))  // draw top-down
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
  CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Body on Apple's icon grid: 824 pt square, 100 pt margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = rounded(body, 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x1d2b64))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// The renderer's default background, top-left indigo to bottom-right pink.
let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x26357a), rgb(0x8a6fb0), rgb(0xf3c4d6)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])

// Screen card with a soft shadow, like a rendered frame.
let card = CGRect(x: 190, y: 270, width: 644, height: 430)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 26), blur: 60, color: rgb(0x000000, 0.5))
ctx.addPath(rounded(card, 34))
ctx.setFillColor(rgb(0x1b2130))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(rounded(card, 34))
ctx.clip()
// Window chrome and a few content bars.
ctx.setFillColor(rgb(0x262d3f))
ctx.fill(CGRect(x: card.minX, y: card.minY, width: card.width, height: 58))
for (i, c) in [0xff5f57, 0xfebc2e, 0x28c840].enumerated() {
  ctx.setFillColor(rgb(UInt32(c)))
  ctx.fillEllipse(in: CGRect(x: card.minX + 30 + CGFloat(i) * 36, y: card.minY + 19, width: 20, height: 20))
}
let bars: [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] = [
  (40, 100, 230, 0x6ee7b7, 0.9), (40, 150, 330, 0x8b95ad, 0.55), (40, 200, 280, 0x8b95ad, 0.55),
  (40, 290, 180, 0x8b95ad, 0.4), (40, 340, 250, 0x8b95ad, 0.4),
]
for (x, y, w, c, a) in bars {
  ctx.addPath(rounded(CGRect(x: card.minX + x, y: card.minY + y, width: w, height: 24), 12))
  ctx.setFillColor(rgb(c, a))
  ctx.fillPath()
}
// The thing being clicked: a button on the right.
let button = CGRect(x: card.minX + 390, y: card.minY + 200, width: 200, height: 70)
ctx.addPath(rounded(button, 20))
ctx.setFillColor(rgb(0x5b8def))
ctx.fillPath()
ctx.restoreGState()

// Viewfinder brackets framing the zoom target.
let focus = button.insetBy(dx: -46, dy: -52)
let arm: CGFloat = 54
ctx.setStrokeColor(rgb(0xffffff))
ctx.setLineWidth(15)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
for (cx, cy, dx, dy) in [
  (focus.minX, focus.minY, 1.0, 1.0), (focus.maxX, focus.minY, -1.0, 1.0),
  (focus.minX, focus.maxY, 1.0, -1.0), (focus.maxX, focus.maxY, -1.0, -1.0),
] {
  let p = CGMutablePath()
  p.move(to: CGPoint(x: cx, y: cy + dy * arm))
  p.addLine(to: CGPoint(x: cx, y: cy))
  p.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
  ctx.addPath(p)
  ctx.strokePath()
}

// Click ripple and cursor.
let click = CGPoint(x: button.midX + 20, y: button.midY + 6)
for (r, a) in [(66.0, 0.35), (44.0, 0.55)] {
  ctx.setStrokeColor(rgb(0xffffff, a))
  ctx.setLineWidth(7)
  ctx.strokeEllipse(in: CGRect(x: click.x - r, y: click.y - r, width: r * 2, height: r * 2))
}
let cursor = CGMutablePath()
let s: CGFloat = 2.1
let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 46), (11, 36), (19, 54), (27, 50), (19, 33), (33, 33)]
cursor.move(to: CGPoint(x: click.x + pts[0].0 * s, y: click.y + pts[0].1 * s))
for (x, y) in pts.dropFirst() { cursor.addLine(to: CGPoint(x: click.x + x * s, y: click.y + y * s)) }
cursor.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: rgb(0x000000, 0.45))
ctx.addPath(cursor)
ctx.setFillColor(rgb(0x111111))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(cursor)
ctx.setStrokeColor(rgb(0xffffff))
ctx.setLineWidth(7)
ctx.strokePath()

// Record dot, top right.
let dot = CGRect(x: 760, y: 170, width: 86, height: 86)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xff3b30, 0.8))
ctx.setFillColor(rgb(0xff3b30))
ctx.fillEllipse(in: dot)
ctx.restoreGState()
ctx.setStrokeColor(rgb(0xffffff, 0.9))
ctx.setLineWidth(8)
ctx.strokeEllipse(in: dot.insetBy(dx: -10, dy: -10))

// Thin inner highlight on the edge, so it holds up on a dark Dock.
ctx.restoreGState()
ctx.addPath(rounded(body.insetBy(dx: 1.5, dy: 1.5), 184))
ctx.setStrokeColor(rgb(0xffffff, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(out.path)") }
print("Wrote \(out.path)")
