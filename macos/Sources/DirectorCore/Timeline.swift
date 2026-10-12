import Foundation

// Port of src/timeline.ts: segment mapping and Hann-window smoothing. Keep the two in step.

public struct MappedSegment: Equatable {
  public var start: Double
  public var end: Double
  public var speed: Double
  public var note: String?
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
    out.append(MappedSegment(start: s.start, end: s.end, speed: s.speed, note: s.note, outStart: outStart, frames: frames))
    outStart += frames
  }
  return out
}

public func totalFrames(_ mapped: [MappedSegment]) -> Int {
  guard let last = mapped.last else { return 1 }
  return last.outStart + last.frames
}

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
    return 0
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
}

public func zoomsToOut(_ zooms: [Zoom], _ mapped: [MappedSegment], fps: Int) -> [OutZoom] {
  zooms
    .map {
      OutZoom(
        startF: srcToOutClamped(mapped, $0.start, fps: fps),
        endF: srcToOutClamped(mapped, $0.end, fps: fps, before: true),
        x: $0.x, y: $0.y, scale: $0.scale)
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
/// side of the window. With the defaults the move is symmetric around the zoom's start, like
/// `cameraAt` in src/timeline.ts.
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

public func layoutBoxes(_ mode: LayoutMode, plan: Plan) -> LayoutBoxes {
  let W = Double(plan.output.width), H = Double(plan.output.height)
  let pad = plan.style.padding * min(W, H)
  let aspect = plan.style.screenAspect ?? plan.source.width / plan.source.height
  let ins = insets(plan)
  // Full bleed has square edges; the radius only applies to padded cards.
  let r = ins.fullBleed ? 0 : plan.style.radius * min(W, H) / 1080
  let edge = ins.fullBleed ? ins.safe : pad
  let full = (x: pad, y: pad, w: W - 2 * pad, h: H - 2 * pad)
  func box(_ f: (x: Double, y: Double, w: Double, h: Double), r: Double, opacity: Double = 1) -> Box {
    Box(x: f.x, y: f.y, w: f.w, h: f.h, r: r, opacity: opacity)
  }

  if H > W * 1.05 {
    // Portrait: screen on top, camera stacked under it, captions below that.
    let captionSpace = H * 0.16
    let bubble = (W * 0.34).rounded()
    let screenArea = (x: pad, y: pad, w: W - 2 * pad, h: H - 2 * pad - captionSpace)
    let s = fit(screenArea, aspect: aspect)
    let screenTop = box((s.x, pad + (screenArea.h - s.h) * 0.3, s.w, s.h), r: r)
    let withBubbleArea = (x: pad, y: pad, w: W - 2 * pad, h: screenArea.h - bubble - pad)
    let s2 = fit(withBubbleArea, aspect: aspect)
    let screenPip = box((s2.x, pad + (withBubbleArea.h - s2.h) * 0.3, s2.w, s2.h), r: r)
    let pipCam = Box(x: (W - bubble) / 2, y: screenPip.y + screenPip.h + pad, w: bubble, h: bubble, r: bubble / 2, opacity: 1)
    switch mode {
    case .screen:
      let b = bubble * 0.6
      return LayoutBoxes(
        screen: screenTop, cam: Box(x: (W - b) / 2, y: screenTop.y + screenTop.h + pad, w: b, h: b, r: b / 2, opacity: 0))
    case .pip:
      return LayoutBoxes(screen: screenPip, cam: pipCam)
    case .side:
      let half = (x: pad, y: pad, w: W - 2 * pad, h: (screenArea.h - pad) * 0.55)
      let s3 = fit(half, aspect: aspect)
      let top = box((s3.x, pad, s3.w, s3.h), r: r)
      let camY = top.y + top.h + pad
      return LayoutBoxes(screen: top, cam: Box(x: pad, y: camY, w: W - 2 * pad, h: max(1, pad + screenArea.h - camY), r: r, opacity: 1))
    case .camera:
      return LayoutBoxes(screen: box((s.x, s.y, s.w, s.h), r: r, opacity: 0), cam: box((full.x, full.y, full.w, full.h - captionSpace), r: r))
    }
  }

  let s = fit(full, aspect: aspect)
  let screenFull = Box(x: s.x, y: s.y, w: s.w, h: s.h, r: r, opacity: 1)
  let bubble = (min(W, H) * 0.24).rounded()
  let pipCam = Box(x: W - edge - bubble, y: H - edge - bubble, w: bubble, h: bubble, r: bubble / 2, opacity: 1)

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
      let s = fit((0, 0, W - camW, H), aspect: aspect)
      return LayoutBoxes(
        screen: Box(x: s.x, y: s.y, w: s.w, h: s.h, r: 0, opacity: 1),
        cam: Box(x: W - camW, y: 0, w: camW, h: H, r: 0, opacity: 1))
    }
    let camW = (W - 3 * pad) * 0.3
    let s = fit((pad, pad, W - 3 * pad - camW, H - 2 * pad), aspect: aspect)
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
  return plan.layouts
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
