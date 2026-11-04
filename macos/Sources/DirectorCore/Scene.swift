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
  let punchIns: [(s: Double, e: Double, scale: Double, x: Double?, y: Double?)]
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
  /// Compiled effects, drawn in plan order on their layer.
  let effects: [LoadedEffect]
  /// The camera's tracked points, when an effect asks for them.
  let tracking: Tracking?
  /// Output frames where the picture visibly changes (cuts, B-roll, layouts, punch-ins), for the effects' `toCut`.
  let cutFrames: [Double]
  /// What kind of change each of `cutFrames` is (`EffectSignals.cutKind`).
  let cutKinds: [Float]
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
    plan: Plan, words: [Word], clicks: [InputEvent], shortcuts: [InputEvent], cursorPath: [InputEvent] = [], dir: URL? = nil,
    effects: [LoadedEffect] = [], tracking: Tracking? = nil
  ) {
    self.plan = plan
    self.effects = effects
    self.tracking = tracking
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
    watermark = look.watermark.flatMap { w in Scene.loadImage(w.image, dir: dir) }
    let lk = look
    introLogo = (plan.intro?.logo ?? lk.intro?.logo).flatMap { Scene.loadImage($0, dir: dir) } ?? watermark
    outroLogo = (plan.outro?.logo ?? lk.outro?.logo).flatMap { Scene.loadImage($0, dir: dir) } ?? watermark
    let m = mapped
    // Sorted by output frame: with clips moved out of recording order, source order isn't play order.
    focusClicks = clicks.compactMap { c in
      guard (0...1).contains(c.x), (0...1).contains(c.y) else { return nil }
      return srcToOut(m, c.t, fps: fps).map { ($0, c.x, c.y) }
    }.sorted { $0.0 < $1.0 }
    self.clicks =
      plan.clickRipples ? clicks.compactMap { c in srcToOut(m, c.t, fps: fps).map { ($0, c.x, c.y) } }.sorted { $0.0 < $1.0 } : []
    chips =
      plan.shortcutChips
      ? shortcuts.compactMap { k in srcToOut(m, k.t, fps: fps).map { ($0, k.label ?? "") } }.sorted { $0.0 < $1.0 } : []
    // Each item plays where its source range plays: one piece per stretch that plays back to back.
    // A title shows from its first word, through the stretch it opens.
    callouts = plan.callouts.compactMap { c in
      guard let s = srcToOut(m, c.start, fps: fps), let run = srcRangeToOut(m, c.start, c.end, fps: fps).first(where: { abs($0.startF - s) < 0.5 })
      else { return nil }
      return (s, run.endF, c)
    }
    annotations = (plan.annotations ?? []).flatMap { a in srcRangeToOut(m, a.start, a.end, fps: fps).map { ($0.startF, $0.endF, a) } }
    // A punch-in within a second of its clip's cut runs to the cut: otherwise the wide shot shows for
    // a sliver between the punch and the cut, which pops.
    punchIns = (plan.camera?.punchIns ?? []).flatMap { p in
      srcRangeToOut(m, p.start, p.end, fps: fps).map { r -> (s: Double, e: Double, scale: Double, x: Double?, y: Double?) in
        var (s, e) = (r.startF, r.endF)
        if let clip = m.first(where: { s >= Double($0.outStart) && s < Double($0.outStart + $0.frames) }), s - Double(clip.outStart) < Double(fps) {
          s = Double(clip.outStart)
        }
        if let clip = m.first(where: { e - 1 >= Double($0.outStart) && e - 1 < Double($0.outStart + $0.frames) }) {
          let clipEnd = Double(clip.outStart + clip.frames)
          if clipEnd - e < Double(fps) { e = clipEnd }
        }
        return (s, e, p.scale, p.x, p.y)
      }
    }
    // A clip split by a move picks up where its previous piece left off.
    inserts = (plan.insertList + plan.animationInserts(dir: dir)).enumerated().flatMap { i, a in
      var played = 0.0
      return srcRangeToOut(m, a.start, a.end, fps: fps).map { r -> (s: Double, e: Double, a: Insert, index: Int) in
        var piece = a
        if played > 0 { piece.from = (a.from ?? 0) + played }
        played += (r.endF - r.startF) / Double(fps)
        return (r.startF, r.endF, piece, i)
      }
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
    // Every moment the picture visibly changes, and what kind of change it is. When several land on
    // the same frame, the one that matters most to the viewer names it.
    var kinds: [Double: EffectSignals.CutKind] = [:]
    func note(_ f: Double, _ kind: EffectSignals.CutKind) {
      if let old = kinds[f], old.rank >= kind.rank { return }
      kinds[f] = kind
    }
    for (prev, next) in zip(m, m.dropFirst()) {
      // Playing an earlier moment than the clip before (back from a cold open) is a jump back.
      note(Double(next.outStart), next.repeats != true && next.start < prev.start - 0.05 ? .jumpBack : .cut)
    }
    for ins in inserts { [ins.s, ins.e].forEach { note($0, .broll) } }
    for l in layouts { [l.startF, l.endF].forEach { note($0, .layout) } }
    for p in punchIns { [p.s, p.e].forEach { note($0, .punchIn) } }
    for c in callouts where ["chapter", "slate"].contains(c.c.style ?? "") { note(c.s, .section) }
    let total = Double(frameCount)
    cutFrames = kinds.keys.filter { $0 > 0 && $0 < total }.sorted()
    cutKinds = cutFrames.map { kinds[$0]!.rawValue }
    let maxWords = ["bold", "social"].contains(plan.captions.style ?? "") ? min(plan.captions.maxWords, 3) : plan.captions.maxWords
    pages = plan.captions.enabled ? Scene.captionPages(words, m, fps: fps, maxWords: maxWords) : []
    motion = MotionStyle.named(plan.style.motion)
    if motion.name == "classic" {
      camSteps = nil
      layoutSteps = nil
    } else {
      camSteps = cameraSteps(
        zooms: zooms, fps: fps, transition: plan.style.transition, style: motion, lead: Scene.zoomLead,
        restClicks: cropsScreen(plan) ? focusClicks : nil)
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
    var lastClip = -1
    for w in words {
      // The clip the word is heard in: the one holding most of it. Word timings are a little off, so
      // a word can straddle a cut, starting in the clip before it (with clips moved, a clip that
      // plays somewhere else entirely). Under 40% kept, it was cut on purpose.
      // Repeats get their own pages below; here each word is placed at its first showing.
      let overlaps = mapped.indices.map { mapped[$0].repeats ? 0 : max(0, min(w.end, mapped[$0].end) - max(w.start, mapped[$0].start)) }
      guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }),
        overlaps[best] >= 0.4 * max(0.001, w.end - w.start) || (w.start >= mapped[best].start && w.start < mapped[best].end)
      else { continue }
      let clip = best
      // Sped-up segments play muted (Composition), so their words are never heard.
      guard mapped[clip].speed <= 1.01 else { continue }
      let startsInClip = w.start >= mapped[clip].start && w.start < mapped[clip].end
      let startF = startsInClip ? (srcToOut(mapped, w.start, fps: fps) ?? Double(mapped[clip].outStart)) : Double(mapped[clip].outStart)
      // A word ends inside its own clip: one running past a cut ends with the clip, not wherever the
      // rest of it plays (with clips moved, that can be far later).
      let clipEnd = Double(mapped[clip].outStart + mapped[clip].frames)
      let endF = w.end <= mapped[clip].end ? (srcToOut(mapped, max(w.start, w.end - 0.001), fps: fps) ?? startF + 3) : clipEnd
      let pause = w.start - lastEnd > 0.8
      // A word in a clip that doesn't play right after the last word's (a moved clip) starts a page.
      let jump = lastClip >= 0 && clip != lastClip && clip != lastClip + 1
      lastClip = clip
      if pages.isEmpty || pause || jump || pages[pages.count - 1].words.count >= maxWords {
        pages.append(Page(words: [], startF: startF, endF: endF))
      }
      pages[pages.count - 1].words.append((w.text, startF))
      pages[pages.count - 1].endF = endF
      lastEnd = w.end
    }
    // A repeat captions its words again where it plays.
    for r in mapped where r.repeats {
      var single = r
      single.repeats = false
      pages += captionPages(words.filter { $0.end > r.start && $0.start < r.end }, [single], fps: fps, maxWords: maxWords)
    }
    return pages.sorted { $0.startF < $1.startF }
  }

  // MARK: Rendering

  static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

  /// Composes one output frame. `screen`/`camera` are the decoded source frames (camera may be absent).
  /// A plan path: absolute, or relative to the project folder (nil for a relative path when there's
  /// no project folder).
  public static func fileURL(_ path: String, dir: URL?) -> URL? {
    if let dir { return resolvePath(path, in: dir) }
    return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
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
    // Cards take the frame's effects too, so they look like the rest of the video.
    if f < introFrames, let c = plan.intro {
      return withEffects(card(c, look.intro, logo: introLogo, frame: f, length: introFrames, intro: true), layer: "frame", frame: f)
    }
    if f >= outroStart, outroStart < frameCount, let c = plan.outro {
      return withEffects(
        card(c, look.outro, logo: outroLogo, frame: f - outroStart, length: frameCount - outroStart, intro: false), layer: "frame", frame: f)
    }
    // A cropped screen (vertical, square) rests on the last click instead of the center.
    let clicks = focusClicks
    let base: ((Int) -> (Double, Double))? =
      !cropsScreen(plan)
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
    let cb = boxes.cam
    let hasCamera = camera != nil && plan.camera != nil && cb.opacity > 0.01
    let camShadow = plan.camera?.cutout != true && plan.camera?.bubbleShadow != false
    let camChrome = hasCamera ? windowChromeOpacity(cb) : 0
    // Joined side by side: the camera's shadow goes under the screen, not across it.
    let joined = plan.style.joinSide == true && abs(cb.x - (b.x + b.w)) < 1
    if hasCamera, camShadow, joined {
      image = shadow(withWindowBar(cb, camChrome), opacity: 0.5 * cb.opacity, blur: 30 * u, drop: 20 * u).composited(over: image)
    }
    if let screen, b.opacity > 0.01 {
      image = shadow(withWindowBar(b, 1), opacity: 0.45, blur: 40 * u, drop: 30 * u).composited(over: image)
      if let chrome = windowChrome(b, opacity: b.opacity) { image = chrome.composited(over: image) }
      let blur = cameraMotion(f, box: b, cam: cam, base: base)
      image = screenCard(withEffects(screen, layer: "screen", frame: f), box: b, cam: cam, blur: blur).composited(over: image)
      image = privacyBlurs(image, frame: Double(f), screen: b, cam: cam)
      image = broll(image, frame: Double(f), full: false, box: b, frames: insertFrames)
    }
    if let camera, hasCamera {
      // A cutout has no shape to cast a shadow from.
      if camShadow, !joined {
        image = shadow(withWindowBar(cb, camChrome), opacity: 0.5 * cb.opacity, blur: 30 * u, drop: 20 * u).composited(over: image)
      }
      if let chrome = windowChrome(cb, opacity: cb.opacity * camChrome) { image = chrome.composited(over: image) }
      image = cameraCard(camera, box: cb, frame: Double(f)).composited(over: image)
      // Portrait split: an accent seam where the screen's square meets the camera.
      if socialTop(plan) != nil, cb.y > 1 {
        let seam = (0.011 * W).rounded()
        let color = CIColor(cgColor: Scene.color(look.accent ?? "#FFE500").copy(alpha: cb.opacity)!)
        image = CIImage(color: color).cropped(to: CGRect(x: 0, y: H - cb.y - seam / 2, width: W, height: seam)).composited(over: image)
      }
    }
    image = broll(image, frame: Double(f), full: true, box: b, frames: insertFrames)
    image = withEffects(image.cropped(to: CGRect(x: 0, y: 0, width: W, height: H)), layer: "frame", frame: f)
    if let overlay = overlays(frame: Double(f), screen: b, cam: cam, camBox: camera != nil && plan.camera != nil ? cb : nil) {
      image = overlay.composited(over: image)
    }
    image = cutTransition(image, frame: Double(f))
    return image.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
  }

  /// How much of a window frame's title bar the camera gets: all of it on a square or rectangular
  /// card, none on a round bubble or a cutout, easing between them as a layout change reshapes it.
  func windowChromeOpacity(_ b: Box) -> Double {
    guard plan.camera?.cutout != true else { return 0 }
    let roundness = b.r / max(1, min(b.w, b.h) / 2)
    return min(1, max(0, (0.5 - roundness) / 0.3))
  }

  /// The box with a window frame's title bar on top, for its shadow (unchanged without one).
  func withWindowBar(_ b: Box, _ amount: Double) -> Box {
    let bar = windowBarHeight(plan) * amount
    return Box(x: b.x, y: b.y - bar, w: b.w, h: b.h + bar, r: b.r, opacity: b.opacity)
  }

  /// A window frame's title bar over a card: dark, with three dots, its top corners rounded like
  /// the card's. It reaches under the card's top corners so they read as the window's inner corners.
  func windowChrome(_ b: Box, opacity: Double) -> CIImage? {
    let bar = windowBarHeight(plan)
    guard bar > 0, opacity > 0.01 else { return nil }
    let r = min(b.r, b.w / 2, bar)
    let w = Int(b.w.rounded(.up)), h = Int((bar + r + 1).rounded(.up))
    guard
      w > 0,
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.setAlpha(opacity)
    // Core Graphics is bottom-up: the bar's top edge is at y = top.
    let width = Double(w), top = Double(h)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: top - r))
    path.addArc(tangent1End: CGPoint(x: 0, y: top), tangent2End: CGPoint(x: r, y: top), radius: r)
    path.addLine(to: CGPoint(x: width - r, y: top))
    path.addArc(tangent1End: CGPoint(x: width, y: top), tangent2End: CGPoint(x: width, y: top - r), radius: r)
    path.addLine(to: CGPoint(x: width, y: 0))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(Scene.color("#1a1d24"))
    ctx.fillPath()
    // A hairline where the bar meets the card.
    ctx.setFillColor(Scene.color("#2a2d34"))
    ctx.fill(CGRect(x: 0, y: top - bar, width: width, height: max(1, bar / 36)))
    let d = bar * 0.3, step = bar * 0.5, cy = top - bar / 2
    ctx.setFillColor(Scene.color("#4a4d54"))
    for i in 0..<3 {
      ctx.fillEllipse(in: CGRect(x: bar * 0.45 + Double(i) * step, y: cy - d / 2, width: d, height: d))
    }
    guard let cg = ctx.makeImage() else { return nil }
    return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: b.x, y: H - (b.y - bar) - top))
  }

  /// A box (top-left coordinates) as a Core Image rect (bottom-left origin).
  func ciRect(_ b: Box) -> CGRect { CGRect(x: b.x, y: H - b.y - b.h, width: b.w, height: b.h) }

  func background() -> CIImage {
    // Portrait sets the screen card on ink, like a phone's dark stage.
    if socialTop(plan) != nil { return CIImage(color: CIColor(cgColor: Scene.color("#15151C"))).cropped(to: CGRect(x: 0, y: 0, width: W, height: H)) }
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
    // Lanczos both ways: shrinking a 4K capture into a 1080p card, and enlarging a 1080p camera to
    // fill a 4K frame, where the plain affine scale is soft and blocky.
    if abs(k - 1) > 0.01 {
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

extension Scene {
  /// What the effects know about output frame `f`.
  func effectSignals(_ f: Int) -> EffectSignals {
    var s = EffectSignals()
    let fd = Double(f), rate = Double(fps)
    s.time = Float(fd / rate)
    s.frame = Float(f)
    if let c = focusClicks.last(where: { $0.f <= fd }) {
      s.sinceClick = Float((fd - c.f) / rate)
      s.clickX = Float(c.x)
      s.clickY = Float(c.y)
    }
    if let i = cutFrames.indices.min(by: { abs(cutFrames[$0] - fd) < abs(cutFrames[$1] - fd) }) {
      s.toCut = Float(abs(cutFrames[i] - fd) / rate)
      s.cutTime = Float(cutFrames[i] / rate)
      s.cutIndex = Float(i)
      s.cutKind = cutKinds[i]
    }
    if let clip = mapped.first(where: { f >= $0.outStart && f < $0.outStart + $0.frames }) { s.speed = Float(clip.speed) }
    return s
  }

  /// The image with each effect for this layer drawn on it, in plan order.
  func withEffects(_ image: CIImage, layer: String, frame f: Int) -> CIImage {
    let these = effects.filter { $0.layer == layer }
    guard !these.isEmpty else { return image }
    let signals = effectSignals(f)
    let blobs = these.contains(where: \.tracking) ? effectBlobs(layer: layer, frame: f, size: image.extent.size) : []
    return these.reduce(image) { $1.apply($0, signals: signals, blobs: blobs) }
  }

  /// The points followed on a layer at output frame `f`, in that layer's pixels (y down): body joints
  /// and fingertips on the camera, the pointer and clicks from the last 1.5 s on the screen. None on
  /// the frame layer, where the camera and screen can be anywhere.
  func effectBlobs(layer: String, frame f: Int, size: CGSize) -> [EffectBlob] {
    let w = Double(size.width), h = Double(size.height)
    switch layer {
    case "camera":
      guard let tracking, let camera = plan.camera, let t = outToSrc(mapped, Double(f), fps: plan.output.fps) else { return [] }
      return tracking.points(at: t + camera.offset).map {
        EffectBlob(x: Float((camera.mirror == true ? 1 - $0.x : $0.x) * w), y: Float($0.y * h), size: Float($0.size * h), id: Float($0.id))
      }
    case "screen":
      var out: [EffectBlob] = []
      if let p = cursorPosition(frame: Double(f)) {
        out.append(EffectBlob(x: Float(p.x * w), y: Float(p.y * h), size: Float(0.05 * h), id: 100))
      }
      let recent = focusClicks.filter { $0.f <= Double(f) && Double(f) - $0.f < 1.5 * Double(fps) }
      for (i, c) in recent.suffix(Effects.maxBlobs - 1).enumerated() {
        out.append(EffectBlob(x: Float(c.x * w), y: Float(c.y * h), size: Float(0.08 * h), id: Float(101 + i)))
      }
      return out
    default:
      return []
    }
  }
}
