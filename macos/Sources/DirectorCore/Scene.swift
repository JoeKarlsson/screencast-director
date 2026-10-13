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
  let callouts: [(s: Double, e: Double, c: Callout)]
  let annotations: [(s: Double, e: Double, a: Annotation)]
  /// B-roll in output frames, with its index in plan.inserts (the compositor's key for its frames).
  public let inserts: [(s: Double, e: Double, a: Insert, index: Int)]
  /// Pictures for picture inserts, loaded once.
  let insertImages: [Int: CIImage]
  /// The project folder, for files the plan names relative to it.
  public let dir: URL?
  /// Styled cuts: the output frame of each cut and how it looks.
  let cuts: [(f: Double, kind: String)]
  /// Cuts that dissolve between clips (a second screen track carries the other clip's frames).
  public let fades: [Crossfade]
  let motion: MotionStyle
  /// The eased camera and layouts (nil in the classic style, which smooths with a window instead).
  let camSteps: EasedSteps?
  let layoutSteps: EasedSteps?
  let half: Int
  let W: Double
  let H: Double
  /// Size scale relative to 1080p (by the short side, so vertical video isn't oversized).
  let u: Double
  let look: Look
  let watermark: CGImage?
  let introLogo: CGImage?
  let outroLogo: CGImage?
  /// Clicks in output frames, for cropped formats whose camera rests on the last click.
  let focusClicks: [(f: Double, x: Double, y: Double)]

  struct Page {
    var words: [(text: String, startF: Double)]
    var startF: Double
    var endF: Double
  }

  public var fps: Int { plan.output.fps }
  public let frameCount: Int
  /// Output frames of the intro card, and the first frame of the outro card.
  public let introFrames: Int
  public let outroStart: Int

  /// Transcript words (source times), for captions and SRT export.
  public let words: [Word]
  /// Pointer samples (source time, x, y), sorted, when the renderer draws the cursor.
  let pointer: [(t: Double, x: Double, y: Double)]
  /// Click times (source), for the cursor's press pulse.
  let clickTimes: [Double]

  public init(
    plan: Plan, words: [Word], clicks: [InputEvent], shortcuts: [InputEvent], cursorPath: [InputEvent] = [], dir: URL? = nil
  ) {
    self.plan = plan
    self.dir = dir
    self.words = words
    pointer =
      plan.cursor?.hidden == true
      ? [] : cursorPath.filter { (-0.05...1.05).contains($0.x) && (-0.05...1.05).contains($0.y) }.map { ($0.t, $0.x, $0.y) }.sorted { $0.t < $1.t }
    clickTimes = clicks.map(\.t).sorted()
    let fps = plan.output.fps
    mapped = mapPlan(plan)
    frameCount = planFrames(plan)
    introFrames = cardFrames(plan).intro
    outroStart = frameCount - cardFrames(plan).outro
    zooms = zoomsToOut(plan.zooms, mapped, fps: fps)
    layouts = layoutsToOut(plan, mapped)
    half = max(1, Int((plan.style.transition * Double(fps) / 2).rounded()))
    W = Double(plan.output.width)
    H = Double(plan.output.height)
    u = min(W, H) / 1080
    look = plan.look ?? Look()
    Fonts.register(look.fontFiles)
    watermark = look.watermark.flatMap { w in Scene.loadImage(w.image) }
    let lk = look
    introLogo = (plan.intro?.logo ?? lk.intro?.logo).flatMap(Scene.loadImage) ?? watermark
    outroLogo = (plan.outro?.logo ?? lk.outro?.logo).flatMap(Scene.loadImage) ?? watermark
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
      return (s, srcToOut(m, c.end, fps: fps) ?? srcToOutClamped(m, c.end, fps: fps, before: true), c)
    }
    annotations = (plan.annotations ?? []).compactMap { a in
      let s = srcToOutClamped(m, a.start, fps: fps), e = srcToOutClamped(m, a.end, fps: fps, before: true)
      return e > s ? (s, e, a) : nil
    }
    inserts = plan.insertList.enumerated().compactMap { i, a in
      let s = srcToOutClamped(m, a.start, fps: fps), e = srcToOutClamped(m, a.end, fps: fps, before: true)
      return e > s ? (s, e, a, i) : nil
    }
    var images: [Int: CIImage] = [:]
    for ins in inserts where ins.a.isImage {
      if let url = Scene.fileURL(ins.a.file, dir: dir), let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
        images[ins.index] = img
      }
    }
    insertImages = images
    cuts = m.dropFirst().compactMap { seg in seg.transition.map { (Double(seg.outStart), $0) } }
    fades = crossfades(m, fps: fps)
    let maxWords = plan.captions.style == "bold" ? min(plan.captions.maxWords, 3) : plan.captions.maxWords
    pages = plan.captions.enabled ? Scene.captionPages(words, m, fps: fps, maxWords: maxWords) : []
    motion = MotionStyle.named(plan.style.motion)
    if motion.name == "classic" {
      camSteps = nil
      layoutSteps = nil
    } else {
      camSteps = cameraSteps(
        zooms: zooms, fps: fps, transition: plan.style.transition, style: motion, lead: Scene.zoomLead,
        restClicks: plan.style.screenAspect == nil ? nil : focusClicks)
      layoutSteps = Scene.layoutSteps(plan, layouts, frames: frameCount, style: motion)
    }
  }

  /// Layout changes as eased moves between each mode's boxes, centered on the change.
  static func layoutSteps(_ plan: Plan, _ ranges: [OutLayout], frames: Int, style: MotionStyle) -> EasedSteps {
    var boxes: [LayoutMode: [Double]] = [:]
    for m in LayoutMode.allCases {
      let b = layoutBoxes(m, plan: plan)
      boxes[m] = b.screen.vec + b.cam.vec
    }
    func mode(_ f: Double) -> LayoutMode {
      var mode = plan.defaultLayout
      for l in ranges where f >= l.startF && f < l.endF { mode = l.mode }
      return mode
    }
    let dur = max(1, plan.style.transition * Double(plan.output.fps))
    var edges = Set<Double>()
    for l in ranges {
      edges.insert(l.startF)
      edges.insert(l.endF)
    }
    var changes: [EasedSteps.Change] = []
    var current = mode(-1)
    for f in edges.sorted() {
      let m = mode(f)
      guard m != current else { continue }
      current = m
      changes.append(.init(at: f - dur / 2, to: boxes[m]!, frames: dur, ease: style.ease))
    }
    return EasedSteps(initial: boxes[mode(-1)]!, changes: changes)
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
  /// A plan path: absolute, or relative to the project folder.
  public static func fileURL(_ path: String, dir: URL?) -> URL? {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
    return dir?.appendingPathComponent(path)
  }

  public func render(
    frame f: Int, screen screenA: CIImage?, camera: CIImage?, handle: CIImage? = nil, insertFrames: [Int: CIImage] = [:]
  ) -> CIImage {
    // Inside a crossfade, dissolve the screen toward the other clip before laying out the frame.
    var screen = screenA
    if let a = screenA, let b = handle, let mix = crossfadeMix(fades, frame: f), mix > 0.001 {
      let target = b.transformed(by: CGAffineTransform(scaleX: a.extent.width / max(1, b.extent.width), y: a.extent.height / max(1, b.extent.height)))
      screen = a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: target, kCIInputTimeKey: mix]).cropped(to: a.extent)
    }
    if f < introFrames, let c = plan.intro {
      return card(c, look.intro, logo: introLogo, frame: f, length: introFrames, intro: true)
    }
    if f >= outroStart, outroStart < frameCount, let c = plan.outro {
      return card(c, look.outro, logo: outroLogo, frame: f - outroStart, length: frameCount - outroStart, intro: false)
    }
    // A cropped screen (vertical, square) rests on the last click instead of the center.
    let clicks = focusClicks
    let base: ((Int) -> (Double, Double))? =
      plan.style.screenAspect == nil
      ? nil
      : { frame in clicks.last(where: { $0.f <= Double(frame) }).map { ($0.x, $0.y) } ?? (0.5, 0.5) }
    let cam = cameraState(f, base: base)
    let boxes: LayoutBoxes
    if let layoutSteps {
      let v = layoutSteps.at(Double(f))
      boxes = LayoutBoxes(screen: Box(v[0..<6]), cam: Box(v[6..<12]))
    } else {
      boxes = layoutAt(f, plan: plan, ranges: layouts, halfWidth: half)
    }
    var image = background()

    let b = boxes.screen
    if let screen, b.opacity > 0.01 {
      image = shadow(b, opacity: 0.45, blur: 40 * u, drop: 30 * u).composited(over: image)
      let blur = cameraMotion(f, box: b, cam: cam, base: base)
      image = screenCard(screen, box: b, cam: cam, blur: blur).composited(over: image)
      image = privacyBlurs(image, frame: Double(f), screen: b, cam: cam)
      image = broll(image, frame: Double(f), full: false, box: b, frames: insertFrames)
    }
    let cb = boxes.cam
    if let camera, plan.camera != nil, cb.opacity > 0.01 {
      image = shadow(cb, opacity: 0.5 * cb.opacity, blur: 30 * u, drop: 20 * u).composited(over: image)
      image = cameraCard(camera, box: cb).composited(over: image)
    }
    image = broll(image, frame: Double(f), full: true, box: b, frames: insertFrames)
    if let overlay = overlays(frame: Double(f), screen: b, cam: cam, camBox: camera != nil && plan.camera != nil ? cb : nil) {
      image = overlay.composited(over: image)
    }
    image = cutTransition(image, frame: Double(f))
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

  /// Zoom-ins start this much output time before the zoom does, and settle on a tail this many
  /// times the transition's half-width (see `cameraAt`).
  static let zoomLead = 0.3
  static let easeTail = 1.6
  /// Motion blur: the share of a frame's movement smeared (a 180 degree shutter is 0.5), and its cap.
  static let shutter = 0.5
  static let maxBlur = 28.0

  func cameraState(_ f: Int, base: ((Int) -> (Double, Double))?) -> CameraState {
    if let camSteps {
      let v = camSteps.at(Double(f))
      let half = 0.5 / max(v[0], 1)
      return CameraState(scale: max(v[0], 1), x: min(max(v[1], half), 1 - half), y: min(max(v[2], half), 1 - half))
    }
    return cameraAt(
      f, zooms: zooms, halfWidth: half, base: base, lead: Int((Scene.zoomLead * Double(fps)).rounded()), tail: Scene.easeTail)
  }

  /// How far (output pixels, top-left coordinates) the screen content under the card's center
  /// moved since the previous frame. Zero while the camera holds still.
  public func cameraMotion(_ f: Int, box b: Box, cam: CameraState, base: ((Int) -> (Double, Double))? = nil) -> (dx: Double, dy: Double) {
    guard f > 0 else { return (0, 0) }
    let prev = cameraState(f - 1, base: base)
    if prev == cam { return (0, 0) }
    let (k, tx, ty) = screenMap(b, cam)
    let (pk, ptx, pty) = screenMap(b, prev)
    let cx = b.x + b.w / 2, cy = b.y + b.h / 2
    // The source point now at the center, and where the previous frame drew it.
    let sx = (cx - tx) / k, sy = (cy - ty) / k
    return (cx - (ptx + pk * sx), cy - (pty + pk * sy))
  }

  func screenCard(_ src: CIImage, box b: Box, cam: CameraState, blur: (dx: Double, dy: Double) = (0, 0)) -> CIImage {
    let (k0, tx, ty) = screenMap(b, cam)
    // The decoded frame may differ from source.json's size; scale relative to it.
    let k = k0 * plan.source.width / src.extent.width
    let moved = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
    var placed = moved.transformed(by: CGAffineTransform(translationX: tx, y: H - ty - src.extent.height * k))
    // Smear along the pan while the camera moves; the card's edges stay sharp because the mask
    // is applied afterwards.
    let radius = min(hypot(blur.dx, blur.dy) * Scene.shutter, Scene.maxBlur * u)
    if radius > 1 {
      let extent = placed.extent
      placed = placed.clampedToExtent()
        .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(-blur.dy, blur.dx)])
        .cropped(to: extent)
    }
    return masked(placed, ciRect(b), radius: b.r, opacity: b.opacity)
  }

  static func graded(_ img: CIImage, _ g: Grade?) -> CIImage {
    guard let g else { return img }
    var out = img
    if let e = g.exposure, e != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": e]) }
    if g.contrast != nil || g.saturation != nil {
      out = out.applyingFilter(
        "CIColorControls", parameters: ["inputContrast": g.contrast ?? 1, "inputSaturation": g.saturation ?? 1, "inputBrightness": 0])
    }
    if let w = g.warmth, w != 0 {
      // Telling Core Image the light was cooler than it was warms the picture, and the reverse.
      out = out.applyingFilter(
        "CITemperatureAndTint",
        parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + w * 2500, y: 0)])
    }
    return out.cropped(to: img.extent)
  }

  func cameraCard(_ src0: CIImage, box b: Box) -> CIImage {
    let src = Scene.graded(src0, plan.camera?.grade)
    let cw = src.extent.width, ch = src.extent.height
    let cam = plan.camera
    let k = max(b.w / cw, b.h / ch) * max(1, cam?.zoom ?? 1)
    let moved = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
    let r = ciRect(b)
    // Keep the framing point centered, clamped so the camera image always covers the box.
    let fx = cam?.x ?? 0.5, fy = cam?.y ?? 0.5
    var tx = r.midX - fx * cw * k
    var ty = r.midY - (1 - fy) * ch * k
    tx = min(r.minX, max(tx, r.maxX - cw * k))
    ty = min(r.minY, max(ty, r.maxY - ch * k))
    let placed = moved.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    return masked(placed, r, radius: b.r, opacity: b.opacity)
  }

  // MARK: Overlays (CoreGraphics + CoreText, drawn in top-left coordinates)

  func overlays(frame f: Double, screen b: Box, cam: CameraState, camBox: Box?) -> CIImage? {
    let fps = Double(plan.output.fps)
    let page = pages.first { f >= $0.startF && f < $0.endF + fps * 0.4 }
    let chip = chips.last { f >= $0.f && f < $0.f + fps * 1.2 }
    let shownCallouts = callouts.filter { f >= $0.s && f < $0.e }
    let shownMarks = b.opacity > 0.01 ? annotations.filter { f >= $0.s && f < $0.e && $0.a.kind != "blur" } : []
    let ripples = clicks.filter { f >= $0.f && f <= $0.f + fps * 0.5 }
    let border = camBox.map { $0.opacity > 0.01 } ?? false
    let ins = insets(plan)
    let brackets = look.frame == "brackets" && (ins.fullBleed || b.opacity > 0.01)
    let pointerAt = b.opacity > 0.01 ? cursorPosition(frame: f) : nil
    if page == nil && chip == nil && shownCallouts.isEmpty && shownMarks.isEmpty && ripples.isEmpty && !border && !brackets
      && watermark == nil && pointerAt == nil
    {
      return nil
    }

    guard let ctx = Scene.context(Int(W), Int(H)) else { return nil }
    // Flip to top-left coordinates like the CSS version; text is unflipped per draw.
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    /// Overlays mid-blur are drawn on their own and blurred with Core Image, above the rest.
    var blurred: [CIImage] = []

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

    if !shownMarks.isEmpty {
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), cornerWidth: b.r, cornerHeight: b.r, transform: nil))
      ctx.clip()
      for m in shownMarks { drawAnnotation(ctx, m.a, frame: f, start: m.s, end: m.e, screen: b, cam: cam, blurred: &blurred) }
      ctx.restoreGState()
    }

    if let p = pointerAt {
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), cornerWidth: b.r, cornerHeight: b.r, transform: nil))
      ctx.clip()
      let (k, tx, ty) = screenMap(b, cam)
      drawCursor(ctx, at: CGPoint(x: tx + k * p.x * plan.source.width, y: ty + k * p.y * plan.source.height),
        height: (plan.cursor?.size ?? 32) * u * cam.scale * p.pulse)
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

    for c in shownCallouts {
      let pose = Motion.pose(frame: f, start: c.s, end: c.e, fps: Int(fps), enter: c.c.enter, exit: c.c.exit, style: motion)
      drawCallout(ctx, c.c, pose: pose, insets: ins, blurred: &blurred)
    }
    if let chip {
      let pose = Motion.pose(
        frame: f, start: chip.f, end: chip.f + fps * 1.2, fps: Int(fps),
        enter: motion.name == "classic" ? Motion(preset: "none") : Motion(preset: "pop", seconds: 0.25, ease: "spring"),
        exit: motion.name == "classic" ? Motion(preset: "none") : Motion(preset: "fade", seconds: 0.2, ease: "ease-in"), style: motion)
      let s = Scene.text(chip.label, size: 44 * u, weight: .semibold, kern: 4 * u, font: look.chipFont, color: look.chipText ?? "#ffffff")
      let size = Scene.measure(s, maxWidth: W)
      let padX = 22 * u, padY = 10 * u
      let top = H - H * 0.2 - size.height - 20 * u
      let rect = CGRect(x: W / 2 - size.width / 2 - padX, y: top, width: size.width + 2 * padX, height: size.height + 2 * padY)
      animated(ctx, rect, pose, blurred: &blurred) { c in
        self.pill(
          c, s, centerX: self.W / 2, top: top, padX: padX, padY: padY, radius: 12 * self.u,
          fill: Scene.color(self.look.chipBackground ?? "#0f0f14").copy(alpha: 0.88)!)
      }
    }
    if let page { drawCaptions(ctx, page, frame: f, insets: ins, blurred: &blurred) }
    if brackets {
      // Full bleed: the brackets frame the whole picture at the margin. Padded: they hug the screen card.
      if ins.fullBleed {
        let m = ins.margin, t = ins.bracket
        drawBrackets(ctx, Box(x: m + t + 10 * u, y: m + t + 10 * u, w: W - 2 * (m + t + 10 * u), h: H - 2 * (m + t + 10 * u), r: 24 * u, opacity: 1))
      } else {
        drawBrackets(ctx, b)
      }
    }
    if let watermark, let w = look.watermark { drawWatermark(ctx, watermark, w) }

    guard let cg = ctx.makeImage() else { return nil }
    return blurred.reduce(CIImage(cgImage: cg)) { $1.composited(over: $0) }
  }

  static func context(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(
      data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  }

  // MARK: Animated overlays

  /// Draws `draw` (top-left frame coordinates) posed: faded, moved, scaled about `rect`'s center
  /// and wiped. Mid-blur, it's drawn into its own layer and blurred into `blurred` instead.
  func animated(_ ctx: CGContext, _ rect: CGRect, _ pose: OverlayPose, blurred: inout [CIImage], _ draw: (CGContext) -> Void) {
    guard pose.visible else { return }
    func apply(_ c: CGContext) {
      c.setAlpha(min(1, pose.opacity))
      c.translateBy(x: rect.midX + pose.dx * rect.width, y: rect.midY + pose.dy * rect.height)
      c.scaleBy(x: pose.scale, y: pose.scale)
      c.translateBy(x: -rect.midX, y: -rect.midY)
      if pose.reveal < 0.999 { c.clip(to: CGRect(x: rect.minX, y: rect.minY - 4 * u, width: rect.width * pose.reveal, height: rect.height + 8 * u)) }
    }
    if pose.blur * u < 0.5 {
      ctx.saveGState()
      apply(ctx)
      draw(ctx)
      ctx.restoreGState()
      return
    }
    // A layer just big enough for the posed overlay and its blur.
    let pad = pose.blur * u * 3 + 8 * u
    let grown = rect.applying(
      CGAffineTransform(translationX: -rect.midX, y: -rect.midY).scaledBy(x: pose.scale, y: pose.scale)
        .translatedBy(x: rect.midX / pose.scale + pose.dx * rect.width / pose.scale, y: rect.midY / pose.scale + pose.dy * rect.height / pose.scale)
    ).union(rect).insetBy(dx: -pad, dy: -pad).integral
    guard let layer = Scene.context(Int(grown.width), Int(grown.height)) else { return }
    layer.translateBy(x: 0, y: grown.height)
    layer.scaleBy(x: 1, y: -1)
    layer.translateBy(x: -grown.minX, y: -grown.minY)
    apply(layer)
    draw(layer)
    guard let cg = layer.makeImage() else { return }
    let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: grown.minX, y: H - grown.maxY))
    blurred.append(img.applyingGaussianBlur(sigma: pose.blur * u / 2).cropped(to: img.extent.insetBy(dx: -pad, dy: -pad)))
  }

  /// Text with only the first `share` of it shown (by word or by character); the hidden part keeps
  /// its space so the layout doesn't move as it types.
  static func revealed(_ s: NSAttributedString, share: Double, byWord: Bool) -> NSAttributedString {
    guard share < 0.999 else { return s }
    let str = s.string as NSString
    var cut = Int((Double(str.length) * share).rounded(.down))
    if byWord {
      let words = s.string.split(separator: " ", omittingEmptySubsequences: false)
      let shown = Int((Double(words.count) * share).rounded(.up))
      cut = min(str.length, words.prefix(shown).map { ($0 as Substring).utf16.count + 1 }.reduce(0, +))
    }
    let out = NSMutableAttributedString(attributedString: s)
    if cut < str.length {
      let key = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
      out.addAttribute(key, value: CGColor(gray: 0, alpha: 0), range: NSRange(location: cut, length: str.length - cut))
    }
    return out
  }

  func drawCallout(_ ctx: CGContext, _ c: Callout, pose: OverlayPose, insets ins: Insets, blurred: inout [CIImage]) {
    let preset = c.enter?.preset ?? motion.enter.preset
    let byWord = preset == "words"
    let typing = byWord || preset == "typewriter"
    func reveal(_ s: NSAttributedString) -> NSAttributedString { typing ? Scene.revealed(s, share: pose.text, byWord: byWord) : s }
    let accent = look.accent ?? "#78a0ff"
    let panel = Scene.color(look.titleBackground ?? "#0f0f14").copy(alpha: look.titleBackground == nil ? 0.88 : 1)!
    let titleColor = look.titleText ?? "#ffffff"
    switch c.style ?? "title" {
    case "lower-third":
      let title = Scene.text(c.text, size: 46 * u, weight: .bold, font: look.titleFont, color: titleColor, align: .left)
      let sub = c.subtitle.map { Scene.text($0, size: 30 * u, weight: .semibold, alpha: 0.8, font: look.captionFont, color: titleColor, align: .left) }
      let maxW = W * 0.6
      let ts = Scene.measure(title, maxWidth: maxW)
      let ss = sub.map { Scene.measure($0, maxWidth: maxW) } ?? .zero
      let bar = 8 * u, padX = 28 * u, padY = 18 * u, gap = sub == nil ? 0 : 6 * u
      let w = max(ts.width, ss.width) + 2 * padX + bar
      let h = ts.height + ss.height + gap + 2 * padY
      let x = ins.fullBleed ? ins.safe : max(ins.safe, plan.style.padding * min(W, H) + 24 * u)
      let rect = CGRect(x: x, y: H * 0.74 - h, width: w, height: h)
      animated(ctx, rect, pose, blurred: &blurred) { g in
        g.setFillColor(panel)
        g.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * self.u, cornerHeight: 12 * self.u, transform: nil))
        g.fillPath()
        g.setFillColor(Scene.color(accent))
        g.fill(CGRect(x: rect.minX, y: rect.minY + 10 * self.u, width: bar, height: rect.height - 20 * self.u))
        self.drawText(g, reveal(title), at: CGPoint(x: rect.minX + bar + padX, y: rect.minY + padY), size: ts)
        if let sub { self.drawText(g, reveal(sub), at: CGPoint(x: rect.minX + bar + padX, y: rect.minY + padY + ts.height + gap), size: ss) }
      }
    case "slate", "chapter":
      let chapter = c.style == "chapter"
      // The scrim only fades; the text does the moving.
      ctx.setFillColor(CGColor(gray: 0, alpha: (chapter ? 0.45 : 0.62) * min(1, pose.opacity)))
      ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
      let title = Scene.text(c.text, size: (chapter ? 76 : 92) * u, weight: .bold, font: look.titleFont, color: "#ffffff")
      let label = c.subtitle.map {
        Scene.text(chapter ? $0.uppercased() : $0, size: (chapter ? 28 : 38) * u, weight: .semibold, kern: chapter ? 5 * u : 0,
          font: look.captionFont, color: chapter ? accent : "#ffffff")
      }
      let maxW = W * 0.8
      let ts = Scene.measure(title, maxWidth: maxW)
      let ls = label.map { Scene.measure($0, maxWidth: maxW) } ?? .zero
      let gap = 22 * u, barH = 7 * u
      let total = ts.height + (label == nil ? 0 : ls.height + gap) + (chapter ? gap + barH : 0)
      let top = (H - total) / 2
      let rect = CGRect(x: (W - max(ts.width, ls.width)) / 2, y: top, width: max(ts.width, ls.width), height: total)
      animated(ctx, rect, pose, blurred: &blurred) { g in
        var y = top
        if chapter, let label {
          self.drawText(g, label, at: CGPoint(x: (self.W - ls.width) / 2, y: y), size: ls)
          y += ls.height + gap
        }
        self.drawText(g, reveal(title), at: CGPoint(x: (self.W - ts.width) / 2, y: y), size: ts)
        y += ts.height + gap
        if chapter {
          g.setFillColor(Scene.color(accent))
          g.fill(CGRect(x: (self.W - 96 * self.u) / 2, y: y, width: 96 * self.u, height: barH))
        } else if let label {
          self.drawText(g, reveal(label), at: CGPoint(x: (self.W - ls.width) / 2, y: y), size: ls)
        }
      }
    default:
      let s = Scene.text(c.text, size: (look.titleFont == nil ? 40 : 46) * u, weight: .bold, font: look.titleFont, color: titleColor)
      let size = Scene.measure(s, maxWidth: W)
      let padX = 28 * u, padY = 14 * u
      let top = ins.fullBleed ? ins.safe : H * 0.06
      let rect = CGRect(x: W / 2 - size.width / 2 - padX, y: top, width: size.width + 2 * padX, height: size.height + 2 * padY)
      animated(ctx, rect, pose, blurred: &blurred) { g in
        self.pill(g, reveal(s), centerX: self.W / 2, top: top, padX: padX, padY: padY, radius: 14 * self.u, fill: panel)
      }
    }
  }

  /// Draws text with its top-left corner at `at` (top-left coordinates).
  func drawText(_ ctx: CGContext, _ s: NSAttributedString, at p: CGPoint, size: CGSize) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: p.y + size.height)
    ctx.scaleBy(x: 1, y: -1)
    let path = CGPath(rect: CGRect(x: p.x, y: 0, width: size.width + 1, height: size.height), transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0), path, nil), ctx)
    ctx.restoreGState()
  }

  func drawCaptions(_ ctx: CGContext, _ page: Page, frame f: Double, insets ins: Insets, blurred: inout [CIImage]) {
    let fps = Double(plan.output.fps)
    let style = plan.captions.style ?? "pill"
    let bold = style == "bold"
    let s = NSMutableAttributedString()
    var current: NSRange?
    let highlight = look.captionHighlight ?? (style == "pill" ? nil : look.accent ?? "#ffe500")
    for (i, w) in page.words.enumerated() {
      let spoken = f >= w.startF
      let isCurrent = spoken && (i + 1 == page.words.count || f < page.words[i + 1].startF)
      let text = (bold ? w.text.uppercased() : w.text) + (i < page.words.count - 1 ? " " : "")
      var alpha = spoken ? 1.0 : 0.5
      if style == "pop" || bold {
        // Each word appears as it's said, fading in over a few frames.
        alpha = spoken ? min(1, (f - w.startF) / max(1, fps * 0.08)) : 0
      }
      var color = look.captionText ?? "#ffffff"
      if isCurrent, let highlight { color = style == "karaoke" ? Scene.readableOn(highlight) : highlight }
      if isCurrent { current = NSRange(location: s.length, length: (text as NSString).length - (i < page.words.count - 1 ? 1 : 0)) }
      s.append(
        Scene.text(
          text, size: (bold ? 64 : 42) * u, weight: bold ? .bold : .semibold, alpha: alpha, font: look.captionFont, color: color,
          stroke: bold ? 7 : 0))
    }
    let maxW = W * 0.8 - 52 * u
    let size = Scene.measure(s, maxWidth: maxW)
    let padX = bold ? 0 : 26 * u, padY = bold ? 0 : 12 * u
    let top = H - (ins.fullBleed ? ins.safe : H * 0.07) - size.height - (bold ? 40 : 24) * u
    let rect = CGRect(x: W / 2 - size.width / 2 - padX, y: top, width: size.width + 2 * padX, height: size.height + 2 * padY)
    let pose =
      motion.name == "classic"
      ? .full
      : Motion.pose(
        frame: f, start: page.startF, end: page.endF + fps * 0.4, fps: Int(fps), enter: Motion(preset: bold ? "pop" : "fade-up", seconds: 0.16, ease: "smooth"),
        exit: Motion(preset: "fade", seconds: 0.12, ease: "ease-in"), style: motion)
    let fill =
      bold ? CGColor(gray: 0, alpha: 0) : Scene.color(look.captionBackground ?? "#0a0a0e").copy(alpha: look.captionBackgroundOpacity ?? 0.78)!
    let mark = style == "karaoke" ? current.map { ($0, Scene.color(highlight ?? "#ffe500")) } : nil
    animated(ctx, rect, pose, blurred: &blurred) { g in
      self.pill(g, s, centerX: self.W / 2, top: top, padX: padX, padY: padY, radius: 14 * self.u, fill: fill, maxWidth: maxW, mark: mark)
    }
  }

  /// A spotlight, box, arrow or highlight on the screen, placed through the camera so it moves
  /// with zooms. Drawn inside the screen card's clip.
  func drawAnnotation(
    _ ctx: CGContext, _ a: Annotation, frame f: Double, start s: Double, end e: Double, screen b: Box, cam: CameraState, blurred: inout [CIImage]
  ) {
    let (k, tx, ty) = screenMap(b, cam)
    let rect = CGRect(
      x: tx + k * a.x * plan.source.width, y: ty + k * a.y * plan.source.height, width: k * a.w * plan.source.width,
      height: k * a.h * plan.source.height)
    let defaultEnter: Motion? =
      switch a.kind {
      case "spotlight": Motion(preset: "fade", seconds: 0.35, ease: "smooth")
      case "highlight": Motion(preset: "wipe", seconds: 0.4, ease: "smooth")
      default: nil
      }
    let pose = Motion.pose(frame: f, start: s, end: e, fps: plan.output.fps, enter: a.enter ?? defaultEnter, exit: a.exit, style: motion)
    let accent = Scene.color(look.accent ?? "#ffcc00")
    let r = 10 * u * cam.scale
    switch a.kind {
    case "spotlight":
      // Dim everything but the rectangle; the hole closes in from a little larger as it fades in.
      let grow = (1 - min(1, pose.opacity)) * 40 * u
      let hole = rect.insetBy(dx: -6 * u - grow, dy: -6 * u - grow)
      ctx.saveGState()
      ctx.addRect(CGRect(x: b.x, y: b.y, width: b.w, height: b.h))
      ctx.addPath(CGPath(roundedRect: hole, cornerWidth: r, cornerHeight: r, transform: nil))
      ctx.setFillColor(CGColor(gray: 0, alpha: 0.6 * min(1, pose.opacity)))
      ctx.fillPath(using: .evenOdd)
      ctx.restoreGState()
    case "highlight":
      animated(ctx, rect, pose, blurred: &blurred) { g in
        g.setFillColor(accent.copy(alpha: 0.32)!)
        g.addPath(CGPath(roundedRect: rect.insetBy(dx: -4 * self.u, dy: -2 * self.u), cornerWidth: 4 * self.u, cornerHeight: 4 * self.u, transform: nil))
        g.fillPath()
      }
    case "arrow":
      // Points at the rectangle's center from below and to the right (or the left near the edge).
      let tip = CGPoint(x: rect.midX, y: rect.maxY + 4 * u)
      let fromLeft = tip.x > b.x + b.w * 0.75
      let tail = CGPoint(x: tip.x + (fromLeft ? -1 : 1) * 110 * u, y: tip.y + 130 * u)
      let box = CGRect(x: min(tip.x, tail.x), y: tip.y, width: abs(tail.x - tip.x), height: tail.y - tip.y)
      animated(ctx, box, pose, blurred: &blurred) { g in
        self.drawArrow(g, from: tail, to: tip, color: accent)
        if let text = a.text, !text.isEmpty {
          let str = Scene.text(text, size: 30 * self.u, weight: .bold, color: "#ffffff")
          let size = Scene.measure(str, maxWidth: self.W * 0.4)
          self.pill(
            g, str, centerX: tail.x, top: tail.y + 8 * self.u, padX: 16 * self.u, padY: 8 * self.u, radius: 10 * self.u,
            fill: Scene.color(self.look.titleBackground ?? "#0f0f14").copy(alpha: 0.9)!, maxWidth: size.width)
        }
      }
    default:  // box
      animated(ctx, rect, pose, blurred: &blurred) { g in
        g.setStrokeColor(accent)
        g.setLineWidth(5 * self.u)
        g.setShadow(offset: .zero, blur: 12 * self.u, color: CGColor(gray: 0, alpha: 0.35))
        g.addPath(CGPath(roundedRect: rect.insetBy(dx: -6 * self.u, dy: -6 * self.u), cornerWidth: r, cornerHeight: r, transform: nil))
        g.strokePath()
        g.setShadow(offset: .zero, blur: 0, color: nil)
        if let text = a.text, !text.isEmpty {
          let str = Scene.text(text, size: 28 * self.u, weight: .bold, color: "#111111")
          let size = Scene.measure(str, maxWidth: self.W * 0.4)
          let top = rect.minY - 6 * self.u - size.height - 18 * self.u
          self.pill(
            g, str, centerX: rect.minX - 6 * self.u + size.width / 2 + 14 * self.u, top: max(self.u * 4, top), padX: 14 * self.u, padY: 6 * self.u,
            radius: 8 * self.u, fill: accent, maxWidth: size.width)
        }
      }
    }
  }

  func drawArrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, color: CGColor) {
    let angle = atan2(b.y - a.y, b.x - a.x)
    let head = 34 * u
    let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
    let path = CGMutablePath()
    path.move(to: a)
    path.addLine(to: base)
    let tri = CGMutablePath()
    tri.move(to: b)
    tri.addLine(to: CGPoint(x: b.x - cos(angle - 0.45) * head, y: b.y - sin(angle - 0.45) * head))
    tri.addLine(to: CGPoint(x: b.x - cos(angle + 0.45) * head, y: b.y - sin(angle + 0.45) * head))
    tri.closeSubpath()
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // A white outline keeps it readable on any screen.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    ctx.setLineWidth(14 * u)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.addPath(tri)
    ctx.setLineWidth(6 * u)
    ctx.strokePath()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(8 * u)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.setFillColor(color)
    ctx.addPath(tri)
    ctx.fillPath()
    ctx.restoreGState()
  }

  /// B-roll showing at this frame: in the screen card (`full` false) or over the whole frame.
  func broll(_ image: CIImage, frame f: Double, full: Bool, box b: Box, frames: [Int: CIImage]) -> CIImage {
    var out = image
    for ins in inserts where ins.a.isFull == full && f >= ins.s && f < ins.e {
      guard let src = insertImages[ins.index] ?? frames[ins.index] else { continue }
      let pose = Motion.pose(
        frame: f, start: ins.s, end: ins.e, fps: plan.output.fps, enter: ins.a.enter ?? Motion(preset: "fade", seconds: 0.3, ease: "smooth"),
        exit: ins.a.exit ?? Motion(preset: "fade", seconds: 0.25, ease: "ease-in"), style: motion)
      guard pose.visible else { continue }
      let rect = full ? CGRect(x: 0, y: 0, width: W, height: H) : ciRect(b)
      let radius = full ? 0 : b.r
      let fill = ins.a.fit != "fit"
      let iw = src.extent.width, ih = src.extent.height
      guard iw > 0, ih > 0 else { continue }
      let k = fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
      var placed = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
      placed = placed.transformed(by: CGAffineTransform(translationX: rect.midX - iw * k / 2, y: rect.midY - ih * k / 2))
      if !fill {
        // Letterbox on black so the screen doesn't show around a fitted picture.
        placed = placed.composited(over: CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05)).cropped(to: rect))
      }
      if abs(pose.scale - 1) > 0.001 || abs(pose.dx) + abs(pose.dy) > 0.001 {
        let t = CGAffineTransform(translationX: -rect.midX, y: -rect.midY).concatenating(CGAffineTransform(scaleX: pose.scale, y: pose.scale))
          .concatenating(CGAffineTransform(translationX: rect.midX + pose.dx * rect.width, y: rect.midY - pose.dy * rect.height))
        placed = placed.transformed(by: t)
      }
      out = masked(placed, rect, radius: radius, opacity: min(1, pose.opacity)).composited(over: out)
    }
    return out
  }

  /// Blurs the parts of the screen covered by blur annotations (passwords, emails), following zooms.
  func privacyBlurs(_ image: CIImage, frame f: Double, screen b: Box, cam: CameraState) -> CIImage {
    let shown = annotations.filter { f >= $0.s && f < $0.e && $0.a.kind == "blur" }
    guard !shown.isEmpty else { return image }
    let (k, tx, ty) = screenMap(b, cam)
    var out = image
    let soft = out.clampedToExtent().applyingGaussianBlur(sigma: 22 * u * cam.scale)
    for m in shown {
      let a = m.a
      let pose = Motion.pose(frame: f, start: m.s, end: m.e, fps: plan.output.fps, enter: a.enter ?? Motion(preset: "fade", seconds: 0.2),
        exit: a.exit ?? Motion(preset: "fade", seconds: 0.2), style: motion)
      let rect = ciRect(
        Box(x: tx + k * a.x * plan.source.width, y: ty + k * a.y * plan.source.height, w: k * a.w * plan.source.width,
          h: k * a.h * plan.source.height, r: 0, opacity: 1)
      ).intersection(ciRect(b))
      guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }
      out = masked(soft, rect, radius: 8 * u * cam.scale, opacity: min(1, pose.opacity)).composited(over: out)
    }
    return out
  }

  /// Styled cuts: blur, dip to the background, flash, punch in or whip pan, peaking on the cut.
  func cutTransition(_ image: CIImage, frame f: Double) -> CIImage {
    let half = Double(plan.output.fps) * 0.22
    guard let cut = cuts.first(where: { abs(f - $0.f) < half }) else { return image }
    let d = (f - cut.f) / half
    // 1 on the cut, easing to 0 at either end.
    let x = 1 - abs(d)
    let peak = x * x * (3 - 2 * x)
    let frame = CGRect(x: 0, y: 0, width: W, height: H)
    switch cut.kind {
    case "blur":
      return image.clampedToExtent().applyingGaussianBlur(sigma: 30 * u * peak).cropped(to: frame)
    case "dip":
      return background().applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: peak)])
        .composited(over: image)
    case "flash":
      return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85 * peak)).cropped(to: frame).composited(over: image)
    case "punch":
      let k = 1 + 0.07 * peak
      return image.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2).concatenating(CGAffineTransform(scaleX: k, y: k))
        .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))).cropped(to: frame)
    case "whip":
      // Out to the left before the cut, in from the right after it.
      let shift = (d < 0 ? -1.0 : 1.0) * W * 0.18 * peak
      return image.clampedToExtent().transformed(by: CGAffineTransform(translationX: shift, y: 0))
        .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 70 * u * peak, kCIInputAngleKey: 0]).cropped(to: frame)
    default:
      return image
    }
  }

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
