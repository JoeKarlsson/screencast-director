import CoreGraphics
import CoreImage
import CoreText
import Foundation

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
  /// Font scale relative to the 1080p sizes used in the Remotion version.
  let u: Double

  struct Page {
    var words: [(text: String, startF: Double)]
    var startF: Double
    var endF: Double
  }

  public var fps: Int { plan.output.fps }
  public var frameCount: Int { totalFrames(mapped) }

  public init(plan: Plan, words: [Word], clicks: [InputEvent], shortcuts: [InputEvent]) {
    self.plan = plan
    let fps = plan.output.fps
    mapped = mapSegments(plan.segments, fps: fps)
    zooms = zoomsToOut(plan.zooms, mapped, fps: fps)
    layouts = layoutsToOut(plan, mapped)
    half = max(1, Int((plan.style.transition * Double(fps) / 2).rounded()))
    W = Double(plan.output.width)
    H = Double(plan.output.height)
    u = H / 1080
    let m = mapped
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
    let cam = cameraAt(f, zooms: zooms, halfWidth: half)
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

  func screenCard(_ src: CIImage, box b: Box, cam: CameraState) -> CIImage {
    let srcW = src.extent.width, srcH = src.extent.height
    let k = b.w / srcW * cam.scale
    let moved = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
    // See README "zoom math": source pixel (x, y-up) -> output, with the zoom focus at the card center.
    let tx = b.x - (cam.x * cam.scale - 0.5) * b.w
    let ty = H - b.y - k * srcH + (cam.y * cam.scale - 0.5) * b.h
    let placed = moved.transformed(by: CGAffineTransform(translationX: tx, y: ty))
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
    if page == nil && chip == nil && callout == nil && ripples.isEmpty && !border { return nil }

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
        let cx = b.x + (c.x * cam.scale - cam.x * cam.scale + 0.5) * b.w
        let cy = b.y + (c.y * cam.scale - cam.y * cam.scale + 0.5) * b.h
        // Sized like the CSS version: px inside the zoomed card, so they grow with the zoom.
        let d = (18 + age * 50) * u * cam.scale
        let rect = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        ctx.setFillColor(CGColor(srgbRed: 120 / 255, green: 160 / 255, blue: 1, alpha: 0.25 * (1 - age)))
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9 * (1 - age)))
        ctx.setLineWidth(3 * u)
        ctx.strokeEllipse(in: rect)
      }
      ctx.restoreGState()
    }

    if let cb = camBox, border {
      let r = min(cb.r, min(cb.w, cb.h) / 2)
      ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85 * cb.opacity))
      ctx.setLineWidth(3 * u)
      ctx.addPath(
        CGPath(
          roundedRect: CGRect(x: cb.x, y: cb.y, width: cb.w, height: cb.h).insetBy(dx: 1.5 * u, dy: 1.5 * u),
          cornerWidth: max(0, r - 1.5 * u), cornerHeight: max(0, r - 1.5 * u), transform: nil))
      ctx.strokePath()
    }

    if let callout {
      pill(
        ctx, Scene.text(callout.text, size: 40 * u, weight: .bold), centerX: W / 2, top: H * 0.06, padX: 28 * u, padY: 14 * u,
        radius: 14 * u, fill: CGColor(srgbRed: 15 / 255, green: 15 / 255, blue: 20 / 255, alpha: 0.85))
    }
    if let chip {
      let s = Scene.text(chip.label, size: 44 * u, weight: .semibold, kern: 4 * u)
      let size = Scene.measure(s, maxWidth: W)
      pill(
        ctx, s, centerX: W / 2, top: H - H * 0.2 - size.height - 20 * u, padX: 22 * u, padY: 10 * u, radius: 12 * u,
        fill: CGColor(srgbRed: 15 / 255, green: 15 / 255, blue: 20 / 255, alpha: 0.85))
    }
    if let page {
      let s = NSMutableAttributedString()
      for (i, w) in page.words.enumerated() {
        let alpha = f >= w.startF ? 1.0 : 0.5
        s.append(Scene.text(w.text + (i < page.words.count - 1 ? " " : ""), size: 42 * u, weight: .semibold, alpha: alpha))
      }
      let size = Scene.measure(s, maxWidth: W * 0.8 - 52 * u)
      pill(
        ctx, s, centerX: W / 2, top: H - H * 0.07 - size.height - 24 * u, padX: 26 * u, padY: 12 * u, radius: 14 * u,
        fill: CGColor(srgbRed: 10 / 255, green: 10 / 255, blue: 14 / 255, alpha: 0.78), maxWidth: W * 0.8 - 52 * u)
    }

    guard let cg = ctx.makeImage() else { return nil }
    return CIImage(cgImage: cg)
  }

  enum Weight { case semibold, bold }

  static func text(_ str: String, size: Double, weight: Weight, alpha: Double = 1, kern: Double = 0) -> NSAttributedString {
    let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
    let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
    let w: Double = weight == .bold ? 0.4 : 0.3
    let desc = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: [kCTFontWeightTrait: w]] as CFDictionary)
    let weighted = CTFontCreateCopyWithAttributes(font, size, nil, desc)
    var align = CTTextAlignment.center
    let para = withUnsafePointer(to: &align) {
      CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: $0)], 1)
    }
    var attrs: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): weighted,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha),
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

  static func color(_ hex: String) -> CGColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    return CGColor(
      srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, alpha: 1)
  }
}
