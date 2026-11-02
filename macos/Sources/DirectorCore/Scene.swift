import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Vision

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
  /// Camera punch-ins in output frames.
  let punchIns: [(s: Double, e: Double, scale: Double)]
  /// B-roll in output frames, with its index in plan.inserts and then the rendered animations (the
  /// compositor's key for its frames).
  public let inserts: [(s: Double, e: Double, a: Insert, index: Int)]
  /// Pictures for picture inserts, loaded once.
  let insertImages: [Int: CIImage]
  /// The project folder, for files the plan names relative to it.
  public let dir: URL?
  /// The camera grade's LUT, read once here rather than on every frame. A LUT that can't be read
  /// is skipped (`describe` warns about it, and the app checks it when it's chosen).
  let cameraLUT: CubeLUT?
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
    cameraLUT = plan.camera?.grade?.lut.flatMap { Scene.fileURL($0, dir: dir) }.flatMap { try? CubeLUT.load($0) }
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
    punchIns = (plan.camera?.punchIns ?? []).compactMap { p in
      let s = srcToOutClamped(m, p.start, fps: fps), e = srcToOutClamped(m, p.end, fps: fps, before: true)
      return e > s ? (s, e, p.scale) : nil
    }
    inserts = (plan.insertList + plan.animationInserts(dir: dir)).enumerated().compactMap { i, a in
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
    // The video opens in whatever layout covers its first frame, and a range running to the last
    // frame stays put: no layout change eases in at frame 0 or out at the end.
    var changes: [EasedSteps.Change] = []
    var current = mode(0)
    for f in edges.sorted() where f > 0 && f < Double(frames) {
      let m = mode(f)
      guard m != current else { continue }
      current = m
      changes.append(.init(at: f - dur / 2, to: boxes[m]!, frames: dur, ease: style.ease))
    }
    return EasedSteps(initial: boxes[mode(0)]!, changes: changes)
  }

  static func captionPages(_ words: [Word], _ mapped: [MappedSegment], fps: Int, maxWords: Int) -> [Page] {
    var pages: [Page] = []
    var lastEnd = -Double.infinity
    for w in words {
      // Sped-up segments play muted (Composition), so their words are never heard.
      guard let startF = srcToOut(mapped, w.start, fps: fps),
        mapped.first(where: { w.start >= $0.start && w.start < $0.end }).map({ $0.speed <= 1.01 }) ?? true
      else { continue }
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
      // A cutout has no shape to cast a shadow from.
      if plan.camera?.cutout != true, plan.camera?.bubbleShadow != false {
        image = shadow(cb, opacity: 0.5 * cb.opacity, blur: 30 * u, drop: 20 * u).composited(over: image)
      }
      image = cameraCard(camera, box: cb, frame: Double(f)).composited(over: image)
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
}
