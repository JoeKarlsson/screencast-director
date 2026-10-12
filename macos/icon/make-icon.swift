// Draws the app icon: a viewfinder (four corner brackets) around a record dot, on indigo.
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

// Indigo to violet, the renderer's default background in a single calm wash.
let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x2a3a8c), rgb(0x6b5bb5), rgb(0x9a7cc4)] as CFArray, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])

// Viewfinder: four corner brackets with rounded corners.
let frame = CGRect(x: 312, y: 312, width: 400, height: 400)
let arm: CGFloat = 118
let radius: CGFloat = 44
ctx.setStrokeColor(rgb(0xffffff))
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
for (cx, cy, dx, dy) in [
  (frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
  (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0),
] {
  let p = CGMutablePath()
  p.move(to: CGPoint(x: cx, y: cy + dy * arm))
  p.addLine(to: CGPoint(x: cx, y: cy + dy * radius))
  p.addQuadCurve(to: CGPoint(x: cx + dx * radius, y: cy), control: CGPoint(x: cx, y: cy))
  p.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
  ctx.addPath(p)
}
ctx.strokePath()

// Record dot with a soft glow.
let dot = CGRect(x: 512 - 82, y: 512 - 82, width: 164, height: 164)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xff3b30, 0.75))
ctx.setFillColor(rgb(0xff3b30))
ctx.fillEllipse(in: dot)
ctx.restoreGState()

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
