import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

/// Everything about the look of each output frame: the native counterpart of src/Screencast.tsx.
/// Built once per plan; `render` is called by the compositor for every frame.
public final class Scene: @unchecked Sendable {
  public let plan: Plan
  public let mapped: [MappedSegment]
  let zooms: [OutZoom]
  let layouts: [OutLayout]
  let pages: [Page]
  let clicks: [(f: Double, x: Double, y: Double)]
  let chips: [(f: Double, label: String)]
  let callouts: [(s: Double, e: Double, text: String)]
  let half: Int
  let W: Double
  let H: Double
  /// Size scale relative to 1080p (by the short side, so vertical video isn't oversized).
  let u: Double
  let look: Look
  let watermark: CGImage?
  /// Clicks in output frames, for cropped formats whose camera rests on the last click.
  let focusClicks: [(f: Double, x: Double, y: Double)]

  struct Page {
    var words: [(text: String, startF: Double)]
    var startF: Double
    var endF: Double
  }

  public var fps: Int { plan.output.fps }
  public var frameCount: Int { totalFrames(mapped) }

  /// Transcript words (source times), for captions and SRT export.
  public let words: [Word]

  public init(plan: Plan, words: [Word], clicks: [InputEvent], shortcuts: [InputEvent]) {
    self.plan = plan
    self.words = words
    let fps = plan.output.fps
    mapped = mapSegments(plan.segments, fps: fps)
    zooms = zoomsToOut(plan.zooms, mapped, fps: fps)
    layouts = layoutsToOut(plan, mapped)
    half = max(1, Int((plan.style.transition * Double(fps) / 2).rounded()))
    W = Double(plan.output.width)
    H = Double(plan.output.height)
    u = min(W, H) / 1080
    look = plan.look ?? Look()
    Fonts.register(look.fontFiles)
    watermark = look.watermark.flatMap { w in
      CGImageSourceCreateWithURL(URL(fileURLWithPath: w.image) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
    let m = mapped
    focusClicks = clicks.compactMap { c in
      guard (0...1).contains(c.x), (0...1).contains(c.y) else { return nil }
      return srcToOut(m, c.t, fps: fps).map { ($0, c.x, c.y) }
    }
    self.clicks =
      plan.clickRipples ? clicks.compactMap { c in srcToOut(m, c.t, fps: fps).map { ($0, c.x, c.y) } } : []
    chips =
      plan.shortcutChips
      ? shortcuts.compactMap { k in srcToOut(m, k.t, fps: fps).map { ($0, k.label ?? "") } } : []
    callouts = plan.callouts.compactMap { c in
      guard let s = srcToOut(m, c.start, fps: fps) else { return nil }
      return (s, srcToOut(m, c.end, fps: fps) ?? s + Double(fps) * 3, c.text)
    }
    pages = plan.captions.enabled ? Scene.captionPages(words, m, fps: fps, maxWords: plan.captions.maxWords) : []
  }

  static func captionPages(_ words: [Word], _ mapped: [MappedSegment], fps: Int, maxWords: Int) -> [Page] {
    var pages: [Page] = []
    var lastEnd = -Double.infinity
    for w in words {
      guard let startF = srcToOut(mapped, w.start, fps: fps) else { continue }
      let endF = srcToOut(mapped, max(w.start, w.end - 0.001), fps: fps) ?? startF + 3
      let pause = w.start - lastEnd > 0.8
      if pages.isEmpty || pause || pages[pages.count - 1].words.count >= maxWords {
        pages.append(Page(words: [], startF: startF, endF: endF))
      }
      pages[pages.count - 1].words.append((w.text, startF))
      pages[pages.count - 1].endF = endF
      lastEnd = w.end
    }
    return pages
  }

  // MARK: Rendering

  static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

  /// Composes one output frame. `screen`/`camera` are the decoded source frames (camera may be absent).
  public func render(frame f: Int, screen: CIImage?, camera: CIImage?) -> CIImage {
    // A cropped screen (vertical, square) rests on the last click instead of the center.
    let clicks = focusClicks
    let base: ((Int) -> (Double, Double))? =
      plan.style.screenAspect == nil
      ? nil
      : { frame in clicks.last(where: { $0.f <= Double(frame) }).map { ($0.x, $0.y) } ?? (0.5, 0.5) }
    let cam = cameraAt(f, zooms: zooms, halfWidth: half, base: base)
    let boxes = layoutAt(f, plan: plan, ranges: layouts, halfWidth: half)
    var image = background()

    let b = boxes.screen
    if let screen, b.opacity > 0.01 {
      image = shadow(b, opacity: 0.45, blur: 40 * u, drop: 30 * u).composited(over: image)
      image = screenCard(screen, box: b, cam: cam).composited(over: image)
    }
    let cb = boxes.cam
    if let camera, plan.camera != nil, cb.opacity > 0.01 {
      image = shadow(cb, opacity: 0.5 * cb.opacity, blur: 30 * u, drop: 20 * u).composited(over: image)
      image = cameraCard(camera, box: cb).composited(over: image)
    }
    if let overlay = overlays(frame: Double(f), screen: b, cam: cam, camBox: camera != nil && plan.camera != nil ? cb : nil) {
      image = overlay.composited(over: image)
    }
    return image.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
  }

  /// A box (top-left coordinates) as a Core Image rect (bottom-left origin).
  func ciRect(_ b: Box) -> CGRect { CGRect(x: b.x, y: H - b.y - b.h, width: b.w, height: b.h) }

  func background() -> CIImage {
    let c0 = Scene.color(plan.style.background.first ?? "#1d2b64")
    let c1 = Scene.color(plan.style.background.last ?? "#f8cdda")
    let g = CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(x: 0, y: H), "inputPoint1": CIVector(x: W, y: 0),
        "inputColor0": CIColor(cgColor: c0), "inputColor1": CIColor(cgColor: c1),
      ])!
    return g.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
  }

  func roundedMask(_ rect: CGRect, radius: Double) -> CIImage {
    let r = min(radius, min(rect.width, rect.height) / 2)
    return CIFilter(
      name: "CIRoundedRectangleGenerator",
      parameters: ["inputExtent": CIVector(cgRect: rect), "inputRadius": r, "inputColor": CIColor.white])!.outputImage!
  }

  func masked(_ image: CIImage, _ rect: CGRect, radius: Double, opacity: Double) -> CIImage {
    var out = image.cropped(to: rect).applyingFilter(
      "CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": roundedMask(rect, radius: radius)])
    if opacity < 0.999 {
      out = out.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }
    return out
  }

  func shadow(_ b: Box, opacity: Double, blur: Double, drop: Double) -> CIImage {
    let rect = ciRect(b).offsetBy(dx: 0, dy: -drop)
    let shape = CIFilter(
      name: "CIRoundedRectangleGenerator",
      parameters: [
        "inputExtent": CIVector(cgRect: rect), "inputRadius": min(b.r, min(b.w, b.h) / 2),
        "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: opacity * b.opacity),
      ])!.outputImage!
    return shape.applyingGaussianBlur(sigma: blur / 2)
  }

  static func scaled(_ image: CIImage, by k: Double) -> CIImage {
    // Lanczos when shrinking (a 4K capture into a 1080p card); plain affine when enlarging.
    if k < 0.99 {
      return image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": k, "inputAspectRatio": 1.0])
    }
    return image.transformed(by: CGAffineTransform(scaleX: k, y: k))
  }

  /// Where source pixels land: output = (tx + k * x, ty + k * y), top-left coordinates. The card is
  /// covered (cropped when its shape differs from the recording) and centered on the camera focus,
  /// clamped so the recording always fills the card.
  func screenMap(_ b: Box, _ cam: CameraState) -> (k: Double, tx: Double, ty: Double) {
    let srcW = plan.source.width, srcH = plan.source.height
    let k = max(b.w / srcW, b.h / srcH) * cam.scale
    var tx = b.x + b.w / 2 - cam.x * srcW * k
    var ty = b.y + b.h / 2 - cam.y * srcH * k
    tx = min(b.x, max(tx, b.x + b.w - srcW * k))
    ty = min(b.y, max(ty, b.y + b.h - srcH * k))
    return (k, tx, ty)
  }

  func screenCard(_ src: CIImage, box b: Box, cam: CameraState) -> CIImage {
    let (k0, tx, ty) = screenMap(b, cam)
    // The decoded frame may differ from source.json's size; scale relative to it.
    let k = k0 * plan.source.width / src.extent.width
    let moved = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
    let placed = moved.transformed(by: CGAffineTransform(translationX: tx, y: H - ty - src.extent.height * k))
    return masked(placed, ciRect(b), radius: b.r, opacity: b.opacity)
  }

  func cameraCard(_ src: CIImage, box b: Box) -> CIImage {
    let cw = src.extent.width, ch = src.extent.height
    let k = max(b.w / cw, b.h / ch)
    let moved = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
    let r = ciRect(b)
    let placed = moved.transformed(
      by: CGAffineTransform(translationX: r.midX - cw * k / 2, y: r.midY - ch * k / 2))
    return masked(placed, r, radius: b.r, opacity: b.opacity)
  }

  // MARK: Overlays (CoreGraphics + CoreText, drawn in top-left coordinates)

  func overlays(frame f: Double, screen b: Box, cam: CameraState, camBox: Box?) -> CIImage? {
    let fps = Double(plan.output.fps)
    let page = pages.first { f >= $0.startF && f < $0.endF + fps * 0.4 }
    let chip = chips.last { f >= $0.f && f < $0.f + fps * 1.2 }
    let callout = callouts.first { f >= $0.s && f < $0.e }
    let ripples = clicks.filter { f >= $0.f && f <= $0.f + fps * 0.5 }
    let border = camBox.map { $0.opacity > 0.01 } ?? false
    let brackets = look.frame == "brackets" && b.opacity > 0.01
    if page == nil && chip == nil && callout == nil && ripples.isEmpty && !border && !brackets && watermark == nil { return nil }

    guard
      let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    // Flip to top-left coordinates like the CSS version; text is unflipped per draw.
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)

    if b.opacity > 0.01, !ripples.isEmpty {
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), cornerWidth: b.r, cornerHeight: b.r, transform: nil))
      ctx.clip()
      for c in ripples {
        let age = (f - c.f) / (fps * 0.5)
        let (k, tx, ty) = screenMap(b, cam)
        let cx = tx + k * c.x * plan.source.width
        let cy = ty + k * c.y * plan.source.height
        // Sized like the CSS version: px inside the zoomed card, so they grow with the zoom.
        let d = (18 + age * 50) * u * cam.scale
        let rect = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        let accent = Scene.color(look.accent ?? "#78a0ff")
        ctx.setFillColor(accent.copy(alpha: 0.25 * (1 - age))!)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(look.accent == nil ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9 * (1 - age)) : accent.copy(alpha: 0.9 * (1 - age))!)
        ctx.setLineWidth(3 * u)
        ctx.strokeEllipse(in: rect)
      }
      ctx.restoreGState()
    }

    if let cb = camBox, border {
      let r = min(cb.r, min(cb.w, cb.h) / 2)
      ctx.setStrokeColor(Scene.color(look.cameraBorder ?? "#ffffff").copy(alpha: 0.85 * cb.opacity)!)
      ctx.setLineWidth(3 * u)
      ctx.addPath(
        CGPath(
          roundedRect: CGRect(x: cb.x, y: cb.y, width: cb.w, height: cb.h).insetBy(dx: 1.5 * u, dy: 1.5 * u),
          cornerWidth: max(0, r - 1.5 * u), cornerHeight: max(0, r - 1.5 * u), transform: nil))
      ctx.strokePath()
    }

    if let callout {
      pill(
        ctx,
        Scene.text(
          callout.text, size: (look.titleFont == nil ? 40 : 46) * u, weight: .bold, font: look.titleFont,
          color: look.titleText ?? "#ffffff"),
        centerX: W / 2, top: H * 0.06, padX: 28 * u, padY: 14 * u,
        radius: 14 * u, fill: Scene.color(look.titleBackground ?? "#0f0f14").copy(alpha: look.titleBackground == nil ? 0.85 : 1)!)
    }
    if let chip {
      let s = Scene.text(chip.label, size: 44 * u, weight: .semibold, kern: 4 * u, font: look.chipFont, color: look.chipText ?? "#ffffff")
      let size = Scene.measure(s, maxWidth: W)
      pill(
        ctx, s, centerX: W / 2, top: H - H * 0.2 - size.height - 20 * u, padX: 22 * u, padY: 10 * u, radius: 12 * u,
        fill: Scene.color(look.chipBackground ?? "#0f0f14").copy(alpha: 0.88)!)
    }
    if let page {
      let s = NSMutableAttributedString()
      for (i, w) in page.words.enumerated() {
        let spoken = f >= w.startF
        let isCurrent = spoken && (i + 1 == page.words.count || f < page.words[i + 1].startF)
        let color = isCurrent && look.captionHighlight != nil ? look.captionHighlight! : (look.captionText ?? "#ffffff")
        s.append(
          Scene.text(
            w.text + (i < page.words.count - 1 ? " " : ""), size: 42 * u, weight: .semibold, alpha: spoken ? 1 : 0.5,
            font: look.captionFont, color: color))
      }
      let size = Scene.measure(s, maxWidth: W * 0.8 - 52 * u)
      pill(
        ctx, s, centerX: W / 2, top: H - H * 0.07 - size.height - 24 * u, padX: 26 * u, padY: 12 * u, radius: 14 * u,
        fill: Scene.color(look.captionBackground ?? "#0a0a0e").copy(alpha: look.captionBackgroundOpacity ?? 0.78)!,
        maxWidth: W * 0.8 - 52 * u)
    }
    if brackets { drawBrackets(ctx, b) }
    if let watermark, let w = look.watermark { drawWatermark(ctx, watermark, w) }

    guard let cg = ctx.makeImage() else { return nil }
    return CIImage(cgImage: cg)
  }

  enum Weight { case semibold, bold }

  static func text(
    _ str: String, size: Double, weight: Weight, alpha: Double = 1, kern: Double = 0, font name: String? = nil,
    color: String = "#ffffff"
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
    var align = CTTextAlignment.center
    let para = withUnsafePointer(to: &align) {
      CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: $0)], 1)
    }
    var attrs: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): weighted,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): Scene.color(color).copy(alpha: alpha)!,
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
    ]
    if kern != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
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
    fill: CGColor, maxWidth: Double? = nil
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
    CTFrameDraw(frame, ctx)
    ctx.restoreGState()
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

  static func color(_ hex: String) -> CGColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    return CGColor(
      srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, alpha: 1)
  }
}
