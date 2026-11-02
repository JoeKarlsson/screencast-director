import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Vision

// Intro and outro cards, and the text, cursor, brackets, watermark and colors Scene draws with.
extension Scene {
  // MARK: Intro and outro cards

  static func loadImage(_ path: String) -> CGImage? {
    CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
  }

  /// True when the background is dark enough for light text.
  var darkBackground: Bool {
    let lum = plan.style.background.map { hex -> Double in
      let c = Scene.color(hex).components ?? [0, 0, 0]
      return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }
    return (lum.reduce(0, +) / Double(max(1, lum.count))) < 0.55
  }

  /// A full-frame title card on the video's background: logo, title in the title font, an accent
  /// bar, subtitle, and the look's brackets. The intro's text fades out at its end, the outro's
  /// fades in at its start; frame 0 shows the title at full strength (it's the first thing seen).
  func card(_ c: Card, _ fallback: Card?, logo: CGImage?, frame f: Int, length: Int, intro: Bool) -> CIImage {
    let image = background()
    guard
      let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)

    let fade = max(1, Double(fps) * 0.3)
    let alpha = intro ? min(1, Double(length - f) / fade) : min(1, Double(f + 1) / fade)
    let dark = darkBackground
    let textColor = dark ? (look.captionText ?? "#ffffff") : (look.titleText ?? "#15151C")
    let accent = look.accent ?? "#78a0ff"
    let title = c.title ?? fallback?.title ?? ""
    let subtitle = c.subtitle ?? fallback?.subtitle ?? ""
    let maxW = W * 0.78

    let titleStr = Scene.text(title, size: 96 * u, weight: .bold, alpha: alpha, font: look.titleFont, color: textColor)
    let subStr = Scene.text(
      subtitle, size: 38 * u, weight: .semibold, alpha: alpha * (dark ? 1 : 0.75), font: look.captionFont,
      color: dark ? accent : textColor)
    let titleSize = title.isEmpty ? .zero : Scene.measure(titleStr, maxWidth: maxW)
    let subSize = subtitle.isEmpty ? .zero : Scene.measure(subStr, maxWidth: maxW)
    let logoH = logo == nil ? 0 : 0.075 * min(W, H)
    let bar = (w: 96 * u, h: 8 * u)
    let gap = 34 * u
    var total = titleSize.height + bar.h + gap
    if logoH > 0 { total += logoH + gap * 1.4 }
    if subSize.height > 0 { total += gap + subSize.height }
    var y = (H - total) / 2

    if let logo, logoH > 0 {
      let w = logoH * Double(logo.width) / Double(logo.height)
      ctx.saveGState()
      ctx.setAlpha(alpha)
      ctx.translateBy(x: (W - w) / 2, y: y + logoH)
      ctx.scaleBy(x: 1, y: -1)
      ctx.draw(logo, in: CGRect(x: 0, y: 0, width: w, height: logoH))
      ctx.restoreGState()
      y += logoH + gap * 1.4
    }
    let clear = CGColor(gray: 0, alpha: 0)
    if titleSize.height > 0 {
      pill(ctx, titleStr, centerX: W / 2, top: y, padX: 0, padY: 0, radius: 0, fill: clear, maxWidth: maxW)
      y += titleSize.height + gap
    }
    ctx.setFillColor(Scene.color(accent).copy(alpha: alpha)!)
    ctx.fill(CGRect(x: (W - bar.w) / 2, y: y, width: bar.w, height: bar.h))
    y += bar.h + gap
    if subSize.height > 0 {
      pill(ctx, subStr, centerX: W / 2, top: y, padX: 0, padY: 0, radius: 0, fill: clear, maxWidth: maxW)
    }
    if look.frame == "brackets" {
      let ins = insets(plan)
      let m = ins.margin + ins.bracket + 10 * u
      drawBrackets(ctx, Box(x: m, y: m, w: W - 2 * m, h: H - 2 * m, r: 24 * u, opacity: 1))
    }
    guard let cg = ctx.makeImage() else { return image }
    return CIImage(cgImage: cg).composited(over: image).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
  }

  enum Weight { case semibold, bold }

  static func text(
    _ str: String, size: Double, weight: Weight, alpha: Double = 1, kern: Double = 0, font name: String? = nil,
    color: String = "#ffffff", align: CTTextAlignment = .center, stroke: Double = 0
  ) -> NSAttributedString {
    let weighted: CTFont
    if let name, !name.isEmpty {
      weighted = CTFontCreateWithName(name as CFString, size, nil)
    } else {
      let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
      let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
      let w: Double = weight == .bold ? 0.4 : 0.3
      let desc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: [kCTFontWeightTrait: w]] as CFDictionary)
      weighted = CTFontCreateCopyWithAttributes(font, size, nil, desc)
    }
    var align = align
    let para = withUnsafePointer(to: &align) {
      CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: $0)], 1)
    }
    var attrs: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): weighted,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): Scene.color(color).copy(alpha: alpha)!,
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
    ]
    if kern != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
    if stroke > 0 {
      // Negative width fills and strokes: bold captions get a dark outline that reads on anything.
      attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -stroke
      attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor(gray: 0, alpha: alpha)
    }
    return NSAttributedString(string: str, attributes: attrs)
  }

  static func measure(_ s: NSAttributedString, maxWidth: Double) -> CGSize {
    let fs = CTFramesetterCreateWithAttributedString(s)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
      fs, CFRange(location: 0, length: 0), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
    return CGSize(width: ceil(size.width), height: ceil(size.height))
  }

  /// Draws text centered in a rounded pill whose top edge is at `top` (top-left coordinates).
  func pill(
    _ ctx: CGContext, _ s: NSAttributedString, centerX: Double, top: Double, padX: Double, padY: Double, radius: Double,
    fill: CGColor, maxWidth: Double? = nil, mark: (NSRange, CGColor)? = nil
  ) {
    let size = Scene.measure(s, maxWidth: maxWidth ?? W)
    let rect = CGRect(x: centerX - size.width / 2 - padX, y: top, width: size.width + 2 * padX, height: size.height + 2 * padY)
    ctx.setFillColor(fill)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    // CoreText draws y-up: flip locally around the text box.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: rect.minY + padY + size.height)
    ctx.scaleBy(x: 1, y: -1)
    let path = CGPath(rect: CGRect(x: rect.minX + padX, y: 0, width: size.width, height: size.height), transform: nil)
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0), path, nil)
    if let (range, color) = mark { fillMark(ctx, frame, range, color, x: rect.minX + padX) }
    CTFrameDraw(frame, ctx)
    ctx.restoreGState()
  }

  /// A rounded box behind `range` of a laid-out frame (karaoke captions), in the frame's y-up space.
  func fillMark(_ ctx: CGContext, _ frame: CTFrame, _ range: NSRange, _ color: CGColor, x: Double) {
    guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
    for (i, line) in lines.enumerated() {
      let r = CTLineGetStringRange(line)
      let lo = max(range.location, r.location), hi = min(range.location + range.length, r.location + r.length)
      guard hi > lo else { continue }
      var ascent: CGFloat = 0, descent: CGFloat = 0
      _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
      let x0 = CTLineGetOffsetForStringIndex(line, lo, nil), x1 = CTLineGetOffsetForStringIndex(line, hi, nil)
      let pad = 7 * u
      let box = CGRect(x: x + origins[i].x + x0 - pad, y: origins[i].y - descent - pad * 0.5, width: x1 - x0 + 2 * pad, height: ascent + descent + pad)
      ctx.setFillColor(color)
      ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil))
      ctx.fillPath()
    }
  }

  /// The smoothed pointer position (0..1 of the screen) at an output frame, plus a press pulse
  /// (1 = normal size, briefly larger just after a click). nil when there's no pointer data.
  func cursorPosition(frame f: Double) -> (x: Double, y: Double, pulse: Double)? {
    guard !pointer.isEmpty, let t = outToSrc(mapped, f, fps: plan.output.fps) else { return nil }
    // Hide it before the first sample and after a long gap (pointer on another display).
    guard t >= pointer[0].t - 0.2, t <= pointer[pointer.count - 1].t + 2 else { return nil }
    let sigma = max(0.001, (plan.cursor?.smoothing ?? 0.12) / 2)
    // Gaussian-weighted average of the samples around t, which also interpolates between them.
    var lo = 0, hi = pointer.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if pointer[mid].t < t - 3 * sigma - 0.05 { lo = mid + 1 } else { hi = mid }
    }
    var sx = 0.0, sy = 0.0, sw = 0.0
    var i = lo
    while i < pointer.count, pointer[i].t <= t + 3 * sigma + 0.05 {
      let d = (pointer[i].t - t) / sigma
      let w = exp(-0.5 * d * d)
      sx += pointer[i].x * w
      sy += pointer[i].y * w
      sw += w
      i += 1
    }
    if sw < 1e-6 {
      // No sample close by: hold the last known position.
      let last = pointer.last { $0.t <= t } ?? pointer[0]
      sx = last.x
      sy = last.y
      sw = 1
    }
    var pulse = 1.0
    if let c = clickTimes.last(where: { $0 <= t }), t - c < 0.3 {
      pulse = 1 + 0.25 * sin(.pi * (t - c) / 0.3)
    }
    return (sx / sw, sy / sw, pulse)
  }

  /// The arrow from the app icon, tip at `at`, white with a dark outline.
  func drawCursor(_ ctx: CGContext, at p: CGPoint, height h: Double) {
    let s = h / 54
    let pts: [(Double, Double)] = [(0, 0), (0, 46), (11, 36), (19, 54), (27, 50), (19, 33), (33, 33)]
    let path = CGMutablePath()
    path.move(to: p)
    for (x, y) in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x + x * s, y: p.y + y * s)) }
    path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 2 * s), blur: 6 * s, color: CGColor(gray: 0, alpha: 0.4))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 0.08, alpha: 1))
    ctx.setLineWidth(max(1.2, 3 * s))
    ctx.setLineJoin(.round)
    ctx.strokePath()
  }

  /// Corner brackets: thick rounded corners just outside the screen card.
  func drawBrackets(_ ctx: CGContext, _ b: Box) {
    let t = 12 * u
    let gap = 10 * u
    let arm = min(b.w, b.h) * 0.16
    let r = max(b.r, 24 * u)
    let outer = CGRect(x: b.x - gap - t, y: b.y - gap - t, width: b.w + 2 * (gap + t), height: b.h + 2 * (gap + t))
    ctx.saveGState()
    ctx.setStrokeColor(Scene.color(look.accent ?? "#ffe500").copy(alpha: b.opacity)!)
    ctx.setLineWidth(t)
    ctx.setLineCap(.butt)
    let o = outer.insetBy(dx: t / 2, dy: t / 2)
    for (cx, cy, dx, dy) in [(o.minX, o.minY, 1.0, 1.0), (o.maxX, o.minY, -1.0, 1.0), (o.minX, o.maxY, 1.0, -1.0), (o.maxX, o.maxY, -1.0, -1.0)] {
      let p = CGMutablePath()
      p.move(to: CGPoint(x: cx, y: cy + dy * arm))
      p.addLine(to: CGPoint(x: cx, y: cy + dy * r))
      p.addQuadCurve(to: CGPoint(x: cx + dx * r, y: cy), control: CGPoint(x: cx, y: cy))
      p.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
      ctx.addPath(p)
    }
    ctx.strokePath()
    ctx.restoreGState()
  }

  func drawWatermark(_ ctx: CGContext, _ img: CGImage, _ w: Look.Watermark) {
    let h = (w.height ?? 0.035) * min(W, H)
    let width = h * Double(img.width) / Double(img.height)
    let ins = insets(plan)
    if ins.fullBleed {
      // Same inset as every other overlay, in the chosen corner.
      let corner = w.corner ?? "topLeft"
      let x = corner.hasSuffix("Left") ? ins.safe : W - ins.safe - width
      let y = corner.hasPrefix("top") ? ins.safe : H - ins.safe - h
      ctx.saveGState()
      ctx.setAlpha(w.opacity ?? 0.9)
      ctx.translateBy(x: x, y: y + h)
      ctx.scaleBy(x: 1, y: -1)
      ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
      ctx.restoreGState()
      return
    }
    // Sit in the margin outside the screen (and its brackets), lined up with the screen's edge.
    let pad = plan.style.padding * min(W, H)
    let inset = look.frame == "brackets" ? 22 * u : 0
    let band = max(h + 8 * u, pad - inset)
    let corner = w.corner ?? "bottomRight"
    let x = corner.hasSuffix("Left") ? pad : W - pad - width
    let y = corner.hasPrefix("top") ? (band - h) / 2 : H - band / 2 - h / 2
    ctx.saveGState()
    ctx.setAlpha(w.opacity ?? 0.9)
    // The context is flipped to top-left; flip back locally so the image isn't upside down.
    ctx.translateBy(x: x, y: y + h)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
    ctx.restoreGState()
  }

  /// Black or white, whichever reads better on `hex`.
  static func readableOn(_ hex: String) -> String {
    let c = color(hex).components ?? [0, 0, 0]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] > 0.6 ? "#111111" : "#ffffff"
  }

  static func color(_ hex: String) -> CGColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    return CGColor(
      srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, alpha: 1)
  }
}
