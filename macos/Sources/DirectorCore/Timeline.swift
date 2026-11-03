import Foundation

// Segment mapping and Hann-window smoothing.

public struct MappedSegment: Equatable {
  public var start: Double
  public var end: Double
  public var speed: Double
  public var note: String?
  public var transition: String? = nil
  /// First output frame of this segment.
  public var outStart: Int
  public var frames: Int
}

public func mapSegments(_ segments: [Segment], fps: Int) -> [MappedSegment] {
  var out: [MappedSegment] = []
  var outStart = 0
  for s in segments.sorted(by: { $0.start < $1.start }) {
    let frames = Int(((s.end - s.start) / s.speed * Double(fps)).rounded())
    if frames < 1 { continue }
    out.append(
      MappedSegment(start: s.start, end: s.end, speed: s.speed, note: s.note, transition: s.transition, outStart: outStart, frames: frames))
    outStart += frames
  }
  return out
}

public func totalFrames(_ mapped: [MappedSegment]) -> Int {
  guard let last = mapped.last else { return 1 }
  return last.outStart + last.frames
}

/// Output frames held by the intro and outro cards (0 when a card is off).
public func cardFrames(_ plan: Plan) -> (intro: Int, outro: Int) {
  func frames(_ c: Card?) -> Int {
    guard let c, c.isOn else { return 0 }
    return Int((c.seconds * Double(plan.output.fps)).rounded())
  }
  return (frames(plan.intro), frames(plan.outro))
}

/// The plan's segments in output frames, after the intro card. Use this (not mapSegments) for
/// anything placed in the final video, so captions, zooms and chapters move with the intro.
public func mapPlan(_ plan: Plan) -> [MappedSegment] {
  let intro = cardFrames(plan).intro
  return mapSegments(plan.segments, fps: plan.output.fps).map {
    var s = $0
    s.outStart += intro
    return s
  }
}

/// Length of the final video in frames: intro, kept segments, outro.
public func planFrames(_ plan: Plan) -> Int {
  let cards = cardFrames(plan)
  let mapped = mapPlan(plan)
  return (mapped.last.map { $0.outStart + $0.frames } ?? max(1, cards.intro)) + cards.outro
}

/// Length of the final video in seconds.
public func planSeconds(_ plan: Plan) -> Double { Double(planFrames(plan)) / Double(plan.output.fps) }

/// Output frame (fractional) for a source time, or nil if that moment is cut.
public func srcToOut(_ mapped: [MappedSegment], _ t: Double, fps: Int) -> Double? {
  for s in mapped where t >= s.start && t < s.end {
    return Double(s.outStart) + (t - s.start) * Double(fps) / s.speed
  }
  return nil
}

/// Like srcToOut, but a cut moment snaps to the next kept frame (or the previous one if `before`).
public func srcToOutClamped(_ mapped: [MappedSegment], _ t: Double, fps: Int, before: Bool = false) -> Double {
  if let exact = srcToOut(mapped, t, fps: fps) { return exact }
  if before {
    for s in mapped.reversed() where s.end <= t { return Double(s.outStart + s.frames) }
    return Double(mapped.first?.outStart ?? 0)
  }
  for s in mapped where s.start >= t { return Double(s.outStart) }
  return Double(totalFrames(mapped))
}

public func outToSrc(_ mapped: [MappedSegment], _ f: Double, fps: Int) -> Double? {
  for s in mapped where f >= Double(s.outStart) && f < Double(s.outStart + s.frames) {
    return s.start + (f - Double(s.outStart)) / Double(fps) * s.speed
  }
  return nil
}

/// A crossfade at a cut: for `half` frames on each side of output frame `f`, the screen dissolves
/// between the two clips. The other clip's frames there are "handles": the next clip's source just
/// before it starts (before the cut), and the previous clip's source just after it ends (after).
public struct Crossfade: Equatable {
  public var f: Int
  public var half: Int
  public var prev: MappedSegment
  public var next: MappedSegment
}

/// Crossfades for the plan's cuts that ask for one, a quarter second each side (less for short clips).
public func crossfades(_ mapped: [MappedSegment], fps: Int) -> [Crossfade] {
  zip(mapped, mapped.dropFirst()).compactMap { prev, next in
    guard next.transition == "crossfade" else { return nil }
    let half = min(Int((0.25 * Double(fps)).rounded()), prev.frames / 2, next.frames / 2)
    return half >= 2 ? Crossfade(f: next.outStart, half: half, prev: prev, next: next) : nil
  }
}

/// How much of the handle shows at output frame `f` (0 is none), for the dissolve.
public func crossfadeMix(_ fades: [Crossfade], frame f: Int) -> Double? {
  guard let c = fades.first(where: { f >= $0.f - $0.half && f < $0.f + $0.half }) else { return nil }
  // 0 to 0.5 approaching the cut (the next clip fades in), 0.5 back to 0 after it (the previous fades out).
  let x = f < c.f ? Double(f - (c.f - c.half)) / Double(c.half) : 1 - Double(f - c.f) / Double(c.half)
  let eased = x * x * (3 - 2 * x)
  return 0.5 * eased
}

/// Averages a step function under a Hann window, turning steps into eased transitions
/// and back-to-back zooms into pans.
public func smooth(_ f: Int, halfWidth: Int, _ sample: (Int) -> [Double]) -> [Double] {
  if halfWidth < 1 { return sample(f) }
  var acc: [Double] = []
  var total = 0.0
  for d in -halfWidth...halfWidth {
    let w = 0.5 + 0.5 * cos(Double.pi * Double(d) / Double(halfWidth + 1))
    let v = sample(f + d)
    if acc.isEmpty { acc = Array(repeating: 0, count: v.count) }
    for i in v.indices { acc[i] += v[i] * w }
    total += w
  }
  return acc.map { $0 / total }
}

public struct OutZoom: Equatable {
  public var startF: Double
  public var endF: Double
  public var x: Double
  public var y: Double
  public var scale: Double
  public var ease: String? = nil
  public var seconds: Double? = nil
}

public func zoomsToOut(_ zooms: [Zoom], _ mapped: [MappedSegment], fps: Int) -> [OutZoom] {
  zooms
    .map {
      OutZoom(
        startF: srcToOutClamped(mapped, $0.start, fps: fps),
        endF: srcToOutClamped(mapped, $0.end, fps: fps, before: true),
        x: $0.x, y: $0.y, scale: $0.scale, ease: $0.ease, seconds: $0.seconds)
    }
    .filter { $0.endF > $0.startF }
    .sorted { $0.startF < $1.startF }
}

public struct CameraState: Equatable {
  public var scale: Double
  public var x: Double
  public var y: Double
}

/// `base` is where the camera rests outside zooms (the center, or the last click when a cropped
/// vertical frame should follow the action).
/// Like `smooth`, but the window looks `ahead` frames forward and `behind` frames back. A move
/// starts `ahead` frames before its step and settles `behind` frames after it, so a longer
/// `behind` gives a quick start and a long, soft ease-out.
public func smooth(_ f: Int, ahead: Int, behind: Int, _ sample: (Int) -> [Double]) -> [Double] {
  if ahead == behind { return smooth(f, halfWidth: ahead, sample) }
  var acc: [Double] = []
  var total = 0.0
  for d in -max(behind, 0)...max(ahead, 0) {
    let side = d < 0 ? behind : ahead
    let w = 0.5 + 0.5 * cos(Double.pi * Double(d) / Double(side + 1))
    let v = sample(f + d)
    if acc.isEmpty { acc = Array(repeating: 0, count: v.count) }
    for i in v.indices { acc[i] += v[i] * w }
    total += w
  }
  return acc.map { $0 / total }
}

/// The smoothed camera at output frame `f`. `lead` pulls each zoom's start that many frames
/// earlier (the camera is already moving when the click lands) and `tail` stretches the ease-out
/// side of the window. With the defaults the move is symmetric around the zoom's start.
public func cameraAt(
  _ f: Int, zooms: [OutZoom], halfWidth: Int, base: ((Int) -> (Double, Double))? = nil, lead: Int = 0, tail: Double = 1
) -> CameraState {
  let behind = max(halfWidth, Int((Double(halfWidth) * tail).rounded()))
  let v = smooth(f, ahead: halfWidth, behind: behind) { frame in
    var hit: OutZoom?
    for z in zooms where Double(frame) >= z.startF - Double(lead) && Double(frame) < z.endF { hit = z }
    if let hit { return [hit.scale, hit.x, hit.y] }
    let b = base?(frame) ?? (0.5, 0.5)
    return [1, b.0, b.1]
  }
  let half = 0.5 / max(v[0], 1)
  return CameraState(scale: v[0], x: min(max(v[1], half), 1 - half), y: min(max(v[2], half), 1 - half))
}

// MARK: Layouts

/// A box in output pixels, top-left origin (like CSS), with corner radius and opacity.
public struct Box: Equatable {
  public var x, y, w, h, r, opacity: Double
  var vec: [Double] { [x, y, w, h, r, opacity] }
  init(_ v: ArraySlice<Double>) {
    let a = Array(v)
    (x, y, w, h, r, opacity) = (a[0], a[1], a[2], a[3], a[4], a[5])
  }
  public init(x: Double, y: Double, w: Double, h: Double, r: Double, opacity: Double) {
    (self.x, self.y, self.w, self.h, self.r, self.opacity) = (x, y, w, h, r, opacity)
  }
}

public struct LayoutBoxes: Equatable {
  public var screen: Box
  public var cam: Box
}

func fit(_ area: (x: Double, y: Double, w: Double, h: Double), aspect: Double) -> (x: Double, y: Double, w: Double, h: Double) {
  var w = area.w
  var h = w / aspect
  if h > area.h {
    h = area.h
    w = h * aspect
  }
  return (area.x + (area.w - w) / 2, area.y + (area.h - h) / 2, w, h)
}

/// One margin for everything that sits near the frame's edge, so every corner matches.
public struct Insets {
  /// Distance from the frame edge (4% of the short side).
  public let margin: Double
  /// Bracket stroke width.
  public let bracket: Double
  /// Where overlays sit: the margin, or just inside the brackets when there are brackets.
  public let safe: Double
  /// Padding 0: screen and camera fill the frame edge to edge.
  public let fullBleed: Bool
}

public func insets(_ plan: Plan) -> Insets {
  let short = Double(min(plan.output.width, plan.output.height))
  let m = (0.04 * short).rounded()
  let t = 12 * short / 1080
  let full = plan.style.padding * short < 1
  let brackets = plan.look?.frame == "brackets"
  return Insets(margin: m, bracket: t, safe: full && brackets ? m + t + m * 0.6 : m, fullBleed: full)
}

/// The bubble's corner radius for its shape (a cutout has no shape).
func bubbleRadius(_ plan: Plan, size: Double) -> Double {
  if plan.camera?.cutout == true { return 0 }
  switch plan.camera?.bubbleShape {
  case "square": return 0
  case "rounded": return size * 0.18
  default: return size / 2
  }
}

/// Where the landscape bubble's center sits, as fractions of the output frame: the plan's position,
/// or the bottom-right corner inset by the padding.
public func bubblePlacement(_ plan: Plan) -> (x: Double, y: Double) {
  if let x = plan.camera?.bubbleX, let y = plan.camera?.bubbleY { return (x, y) }
  return bubbleCorner("bottomRight", plan: plan)
}

/// The center of a bubble tucked into a corner ("topLeft" ... "bottomRight"): inset by the
/// padding, except a cutout in a bottom corner, which stands on the frame's bottom edge.
public func bubbleCorner(_ corner: String, plan: Plan) -> (x: Double, y: Double) {
  let W = Double(plan.output.width), H = Double(plan.output.height)
  let ins = insets(plan)
  let edge = ins.fullBleed ? ins.safe : plan.style.padding * min(W, H)
  let bubble = (min(W, H) * (plan.camera?.bubbleSize ?? Plan.Camera.defaultBubbleSize)).rounded()
  let x = corner.hasSuffix("Left") ? edge + bubble / 2 : W - edge - bubble / 2
  let bottom = plan.camera?.cutout == true ? H - bubble / 2 : H - edge - bubble / 2
  let y = corner.hasPrefix("top") ? edge + bubble / 2 : bottom
  return (x / W, y / H)
}

/// In a portrait frame, where the top square (the screen card's area) ends and the camera begins;
/// nil for landscape and square frames.
public func socialTop(_ plan: Plan) -> Double? {
  let W = Double(plan.output.width), H = Double(plan.output.height)
  return H > W * 1.05 ? min(W, H * 0.5625).rounded() : nil
}

/// The title bar a "window" frame draws over each card, in output pixels: 0 without that frame,
/// at full bleed and in portrait.
public func windowBarHeight(_ plan: Plan) -> Double {
  guard plan.look?.frame == "window", !insets(plan).fullBleed, socialTop(plan) == nil else { return 0 }
  return (0.034 * Double(min(plan.output.width, plan.output.height))).rounded()
}

/// True when the screen is cropped to fill a full-bleed frame (`style.fill`); not in portrait,
/// which has its own split.
public func fillsFrame(_ plan: Plan) -> Bool {
  plan.style.fill == true && insets(plan).fullBleed && socialTop(plan) == nil
}

/// True when the screen card shows a crop of the screen that pans to follow the action.
public func cropsScreen(_ plan: Plan) -> Bool { plan.style.screenAspect != nil || fillsFrame(plan) }

public func layoutBoxes(_ mode: LayoutMode, plan: Plan) -> LayoutBoxes {
  let W = Double(plan.output.width), H = Double(plan.output.height)
  let pad = plan.style.padding * min(W, H)
  let aspect = plan.style.screenAspect ?? plan.source.width / plan.source.height
  let ins = insets(plan)
  // Full bleed has square edges; the radius only applies to padded cards.
  let r = ins.fullBleed ? 0 : plan.style.radius * min(W, H) / 1080
  let edge = ins.fullBleed ? ins.safe : pad
  // A window frame's title bars sit above the cards, so the cards start lower.
  let bar = windowBarHeight(plan)
  let full = (x: pad, y: pad + bar, w: W - 2 * pad, h: H - 2 * pad - bar)
  func box(_ f: (x: Double, y: Double, w: Double, h: Double), r: Double, opacity: Double = 1) -> Box {
    Box(x: f.x, y: f.y, w: f.w, h: f.h, r: r, opacity: opacity)
  }

  if let top = socialTop(plan) {
    // Portrait (social): the screen in a card on the top square, the camera full width under it.
    // Talking to the lens fills the whole frame with the camera.
    let m = (0.037 * W).rounded()
    let cardR = (0.033 * W).rounded()
    let card = fit((m, m, W - 2 * m, top - 2 * m), aspect: aspect)
    let split = Box(x: 0, y: top, w: W, h: H - top, r: 0, opacity: 1)
    let hasCamera = plan.camera != nil
    switch mode {
    case .pip, .side:
      return LayoutBoxes(screen: box(card, r: cardR), cam: hasCamera ? split : Box(x: 0, y: top, w: W, h: H - top, r: 0, opacity: 0))
    case .screen:
      // The screen alone: a bigger card, leaving the bottom for captions.
      let big = fit((m, m, W - 2 * m, H * 0.78 - m), aspect: aspect)
      return LayoutBoxes(screen: box(big, r: cardR), cam: Box(x: 0, y: top, w: W, h: H - top, r: 0, opacity: 0))
    case .camera:
      return LayoutBoxes(screen: box(card, r: cardR, opacity: 0), cam: Box(x: 0, y: 0, w: W, h: H, r: 0, opacity: 1))
    }
  }

  let fill = fillsFrame(plan)
  let s = fill ? full : fit(full, aspect: aspect)
  let screenFull = Box(x: s.x, y: s.y, w: s.w, h: s.h, r: r, opacity: 1)
  let bubble = (min(W, H) * (plan.camera?.bubbleSize ?? Plan.Camera.defaultBubbleSize)).rounded()
  let place = bubblePlacement(plan)
  let pipCam = Box(
    x: min(max(0, place.x * W - bubble / 2), W - bubble), y: min(max(0, place.y * H - bubble / 2), H - bubble),
    w: bubble, h: bubble, r: bubbleRadius(plan, size: bubble), opacity: 1)

  switch mode {
  case .screen:
    let b = bubble * 0.6
    return LayoutBoxes(
      screen: screenFull, cam: Box(x: pipCam.x + bubble * 0.2, y: pipCam.y + bubble * 0.2, w: b, h: b, r: b / 2, opacity: 0))
  case .pip:
    return LayoutBoxes(screen: screenFull, cam: pipCam)
  case .side:
    if ins.fullBleed {
      // Screen on the left, camera filling a full-height column on the right.
      let camW = (W * 0.3).rounded()
      let s = fill ? (x: 0, y: 0, w: W - camW, h: H) : fit((0, 0, W - camW, H), aspect: aspect)
      return LayoutBoxes(
        screen: Box(x: s.x, y: s.y, w: s.w, h: s.h, r: 0, opacity: 1),
        cam: Box(x: W - camW, y: 0, w: camW, h: H, r: 0, opacity: 1))
    }
    if plan.style.joinSide == true {
      // One card: the screen, then a camera column 0.3 of the width at the screen's height.
      let total = min(full.w, full.h * aspect / 0.7)
      let sw = total * 0.7, h = sw / aspect
      let x = full.x + (full.w - total) / 2, y = full.y + (full.h - h) / 2
      return LayoutBoxes(
        screen: Box(x: x, y: y, w: sw, h: h, r: r, opacity: 1),
        cam: Box(x: x + sw, y: y, w: total - sw, h: h, r: r, opacity: 1))
    }
    let camW = (W - 3 * pad) * 0.3
    let s = fit((pad, full.y, W - 3 * pad - camW, full.h), aspect: aspect)
    let camH = min(s.h, camW * 16 / 9)
    return LayoutBoxes(
      screen: Box(x: s.x, y: s.y, w: s.w, h: s.h, r: r, opacity: 1),
      cam: Box(x: W - pad - camW, y: s.y + (s.h - camH) / 2, w: camW, h: camH, r: r, opacity: 1))
  case .camera:
    var hidden = screenFull
    hidden.opacity = 0
    return LayoutBoxes(screen: hidden, cam: Box(x: full.x, y: full.y, w: full.w, h: full.h, r: r, opacity: 1))
  }
}

public struct OutLayout: Equatable {
  public var startF: Double
  public var endF: Double
  public var mode: LayoutMode
}

public func layoutsToOut(_ plan: Plan, _ mapped: [MappedSegment]) -> [OutLayout] {
  let fps = plan.output.fps
  // In portrait an animation plays in the screen card, so the split shows while it does (last range wins).
  let animated = socialTop(plan) == nil ? [] : plan.animationList.map { LayoutRange(start: $0.start, end: $0.end, mode: .pip) }
  return (plan.layouts + animated)
    .map {
      OutLayout(
        startF: srcToOutClamped(mapped, $0.start, fps: fps),
        endF: srcToOutClamped(mapped, $0.end, fps: fps, before: true), mode: $0.mode)
    }
    .filter { $0.endF > $0.startF }
}

public func layoutAt(_ f: Int, plan: Plan, ranges: [OutLayout], halfWidth: Int) -> LayoutBoxes {
  var boxes: [LayoutMode: LayoutBoxes] = [:]
  for m in LayoutMode.allCases { boxes[m] = layoutBoxes(m, plan: plan) }
  let v = smooth(f, halfWidth: halfWidth) { frame in
    var mode = plan.defaultLayout
    for l in ranges where Double(frame) >= l.startF && Double(frame) < l.endF { mode = l.mode }
    let b = boxes[mode]!
    return b.screen.vec + b.cam.vec
  }
  return LayoutBoxes(screen: Box(v[0..<6]), cam: Box(v[6..<12]))
}
