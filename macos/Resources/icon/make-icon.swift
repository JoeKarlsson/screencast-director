// Generates the app icon: ScreencastDirector.icns and icon-1024.png.
//
//   swift macos/Resources/icon/make-icon.swift
//
// Layered "glass" style on Apple's 1024 grid: an 824 pt continuous-corner body
// with a drop shadow, an indigo-to-violet base with a specular top rim,
// frosted viewfinder brackets and a glossy red record dot. Small sizes (32 px
// and under) are drawn with bolder, more opaque brackets and fewer effects so
// they stay legible.

import AppKit
import CoreGraphics
import Foundation

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let resources = here.deletingLastPathComponent()

// MARK: - Helpers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

/// Apple-style continuous-corner rounded rect (the iOS/macOS "squircle"
/// curve: each corner is three Béziers spanning 1.52866 r along each edge).
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    // One corner in local coordinates: u runs along the edge away from the
    // corner, v inward. Points listed from the edge before the corner to the
    // edge after it, as (u, v) pairs measured from the corner.
    let p = CGMutablePath()
    let corners: [(CGPoint, CGFloat, CGFloat, Bool)] = [
        // corner, x sign, y sign, swap (traverse order)
        (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1, false),
        (CGPoint(x: rect.maxX, y: rect.minY), -1, 1, true),
        (CGPoint(x: rect.minX, y: rect.minY), 1, 1, false),
        (CGPoint(x: rect.minX, y: rect.maxY), 1, -1, true),
    ]
    // Corner curve from the top edge to the right edge of a top-right corner,
    // as (distance from corner along x, distance from corner along y).
    let seg: [(CGFloat, CGFloat)] = [
        (1.52866, 0),
        (1.08849, 0), (0.86840, 0), (0.66993, 0.06416),
        (0.37942, 0.18381), (0.18381, 0.37942), (0.06416, 0.66993),
        (0, 0.86840), (0, 1.08849), (0, 1.52866),
    ]
    for (i, (c, sx, sy, swap)) in corners.enumerated() {
        let pts = seg.map { a, b -> CGPoint in
            let (dx, dy) = swap ? (b, a) : (a, b)
            return CGPoint(x: c.x + sx * dx * r, y: c.y + sy * dy * r)
        }
        if i == 0 { p.move(to: pts[0]) } else { p.addLine(to: pts[0]) }
        p.addCurve(to: pts[3], control1: pts[1], control2: pts[2])
        p.addCurve(to: pts[6], control1: pts[4], control2: pts[5])
        p.addCurve(to: pts[9], control1: pts[7], control2: pts[8])
    }
    p.closeSubpath()
    return p
}

/// The four viewfinder corners as one stroked outline (y up, 1024 space).
func brackets(inset: CGFloat, arm: CGFloat, radius: CGFloat, width: CGFloat) -> CGPath {
    let lo = inset, hi = 1024 - inset
    let line = CGMutablePath()
    // corner at (cx, cy); arms run along dx and dy.
    for (cx, cy, dx, dy) in [(lo, hi, 1.0, -1.0), (hi, hi, -1.0, -1.0),
                             (lo, lo, 1.0, 1.0), (hi, lo, -1.0, 1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        line.move(to: CGPoint(x: cx + dx * arm, y: cy))
        line.addArc(tangent1End: CGPoint(x: cx, y: cy),
                    tangent2End: CGPoint(x: cx, y: cy + dy * arm), radius: radius)
        line.addLine(to: CGPoint(x: cx, y: cy + dy * arm))
    }
    return line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

// MARK: - Drawing

func draw(_ ctx: CGContext, px: Int) {
    let small = px <= 32
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    // Body: 824 on the 1024 grid, centered.
    let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let body = squircle(bodyRect, radius: 185)

    // Drop shadow (Apple template: soft, slightly below).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x3A2C9A))
    ctx.fillPath()
    ctx.restoreGState()

    // Base gradient: indigo at the top to violet at the bottom.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0x5A4FE6)), (0.55, rgb(0x5B3CC9)), (1, rgb(0x7A3FC4))]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft light pooling from above.
    ctx.drawRadialGradient(gradient([(0, rgb(0x9E9BFF, 0.45)), (1, rgb(0x9E9BFF, 0))]),
                           startCenter: CGPoint(x: 512, y: 960), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 960), endRadius: 620, options: [])
    // Slight darkening at the bottom for weight.
    ctx.drawLinearGradient(gradient([(0, rgb(0x1A0B4A, 0.0)), (1, rgb(0x1A0B4A, 0.28))]),
                           start: CGPoint(x: 512, y: 420), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Glass rim: a bright specular edge along the top, a faint one at the bottom.
    if !small {
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        let rim = body.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(rim)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.75)), (0.32, rgb(0xFFFFFF, 0.08)),
                                         (0.7, rgb(0xFFFFFF, 0.04)), (1, rgb(0xFFFFFF, 0.22))]),
                               start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        ctx.restoreGState()
    }

    // Viewfinder brackets: frosted glass with a light edge.
    let width: CGFloat = small ? 64 : 54
    let frame = brackets(inset: small ? 270 : 286, arm: small ? 168 : 158,
                         radius: small ? 58 : 62, width: width)
    // Shadow under the glass so it floats over the base.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: rgb(0x1B0E5C, small ? 0.0 : 0.45))
    ctx.addPath(frame)
    ctx.setFillColor(rgb(0xFFFFFF, small ? 0.96 : (px <= 64 ? 0.42 : 0.22)))
    ctx.fillPath()
    ctx.restoreGState()
    if !small {
        ctx.saveGState()
        ctx.addPath(frame)
        ctx.clip()
        // Frosted body, brighter at the top of each arm.
        ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.5)), (1, rgb(0xFFFFFF, 0.26))]),
                               start: CGPoint(x: 512, y: 760), end: CGPoint(x: 512, y: 260), options: [])
        // Edge light: an inner stroke, bright on top, softer below.
        let edge = frame.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(edge)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 1.0)), (1, rgb(0xFFFFFF, 0.5))]),
                               start: CGPoint(x: 512, y: 760), end: CGPoint(x: 512, y: 260), options: [])
        ctx.restoreGState()
    }

    // Record dot: a glossy red sphere with a colored glow.
    let c = CGPoint(x: 512, y: 512)
    let r: CGFloat = small ? 100 : 92
    let dot = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    if !small {
        ctx.saveGState()
        ctx.drawRadialGradient(gradient([(0, rgb(0xFF3B30, 0.55)), (0.5, rgb(0xFF2D55, 0.18)), (1, rgb(0xFF2D55, 0))]),
                               startCenter: c, startRadius: r * 0.8, endCenter: c, endRadius: r * 2.1, options: [])
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: rgb(0x4A0624, small ? 0 : 0.35))
    ctx.addPath(dot)
    ctx.setFillColor(rgb(0xF2352B))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(dot)
    ctx.clip()
    // Body shading, lit from above.
    let lightAt = CGPoint(x: c.x, y: c.y + r * 0.45)
    ctx.drawRadialGradient(gradient([(0, rgb(0xFF6A55)), (0.5, rgb(0xFF3B30)), (0.88, rgb(0xE5262B)), (1, rgb(0xD01F2C))]),
                           startCenter: lightAt, startRadius: 0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation])
    if !small {
        // Warm bounce light in the lower half, like light passing through red glass.
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y - r * 0.55)
        ctx.scaleBy(x: 1, y: 0.55)
        ctx.drawRadialGradient(gradient([(0, rgb(0xFF9A7A, 0.55)), (1, rgb(0xFF9A7A, 0))]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 0.8, options: [])
        ctx.restoreGState()
        // Specular highlight: a soft, wide gleam near the top.
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y + r * 0.52)
        ctx.scaleBy(x: 1, y: 0.52)
        ctx.drawRadialGradient(gradient([(0, rgb(0xFFFFFF, 0.9)), (0.45, rgb(0xFFFFFF, 0.45)), (1, rgb(0xFFFFFF, 0))]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 0.66, options: [])
        ctx.restoreGState()
        // Thin light rim on the upper edge.
        let edge = dot.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.addPath(edge)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF, 0.6)), (0.5, rgb(0xFFFFFF, 0.0))]),
                               start: CGPoint(x: c.x, y: c.y + r), end: CGPoint(x: c.x, y: c.y - r), options: [])
    }
    ctx.restoreGState()
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, px: px)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Output

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("ScreencastDirector.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: here.appendingPathComponent("icon-1024.png"))

let icns = resources.appendingPathComponent("ScreencastDirector.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icns.path)")
print("Iconset: \(iconset.path)")
