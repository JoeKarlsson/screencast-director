import Foundation

// Easing curves, motion presets, and eased transitions between held states (the camera, layouts).

/// An easing curve: maps a transition's progress 0...1 to how far the value has moved. Springs
/// overshoot past 1 before settling.
public enum Ease: Equatable {
  case linear
  case cubic(Double, Double, Double, Double)
  /// A damped spring that settles by t = 1. Damping below 1 overshoots (0.5 is bouncy).
  case spring(Double)

  /// Names the plan can use for `ease`.
  public static let names = ["smooth", "snappy", "cinematic", "spring", "bouncy", "linear", "ease-in", "ease-out", "ease-in-out"]

  /// Parses a name, `spring(0.7)` or `cubic-bezier(a, b, c, d)`. nil for anything else.
  public static func named(_ s: String?) -> Ease? {
    guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
    switch s {
    case "linear": return .linear
    // Quick start and a long, soft landing: the default camera move.
    case "smooth": return .cubic(0.45, 0, 0.15, 1)
    case "snappy": return .cubic(0.2, 0.9, 0.1, 1)
    case "cinematic": return .cubic(0.65, 0, 0.35, 1)
    case "ease-in": return .cubic(0.42, 0, 1, 1)
    case "ease-out": return .cubic(0, 0, 0.58, 1)
    case "ease-in-out": return .cubic(0.42, 0, 0.58, 1)
    case "spring": return .spring(0.78)
    case "bouncy": return .spring(0.52)
    default: break
    }
    func args(_ prefix: String) -> [Double]? {
      guard s.hasPrefix(prefix + "("), s.hasSuffix(")") else { return nil }
      return s.dropFirst(prefix.count + 1).dropLast().split(separator: ",").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
      }
    }
    if let a = args("spring"), a.count == 1 { return .spring(min(max(a[0], 0.2), 1)) }
    if let a = args("cubic-bezier"), a.count == 4 { return .cubic(min(max(a[0], 0), 1), a[1], min(max(a[2], 0), 1), a[3]) }
    return nil
  }

  public func at(_ t: Double) -> Double {
    if t <= 0 { return 0 }
    if t >= 1 { return 1 }
    switch self {
    case .linear: return t
    case .cubic(let x1, let y1, let x2, let y2): return Ease.bezier(t, x1, y1, x2, y2)
    case .spring(let zeta):
      // Envelope e^(-6t) is about 0.25% at t = 1, where it snaps to 1.
      let decay = 6.0
      if zeta >= 0.999 {
        let w = decay
        return 1 - exp(-w * t) * (1 + w * t)
      }
      let w = decay / zeta
      let wd = w * (1 - zeta * zeta).squareRoot()
      return 1 - exp(-decay * t) * (cos(wd * t) + decay / wd * sin(wd * t))
    }
  }

  /// CSS cubic-bezier: solve x(s) = t for s (Newton, then bisection), return y(s).
  static func bezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
    func coord(_ s: Double, _ a: Double, _ b: Double) -> Double {
      let u = 1 - s
      return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }
    func slope(_ s: Double, _ a: Double, _ b: Double) -> Double {
      let u = 1 - s
      return 3 * u * u * a + 6 * u * s * (b - a) + 3 * s * s * (1 - b)
    }
    var s = t
    for _ in 0..<8 {
      let d = slope(s, x1, x2)
      if abs(d) < 1e-6 { break }
      let next = s - (coord(s, x1, x2) - t) / d
      if next < 0 || next > 1 { break }
      s = next
    }
    if abs(coord(s, x1, x2) - t) > 1e-4 {
      var lo = 0.0, hi = 1.0
      s = t
      for _ in 0..<40 {
        if coord(s, x1, x2) < t { lo = s } else { hi = s }
        s = (lo + hi) / 2
      }
    }
    return coord(s, y1, y2)
  }
}

/// A house style for every move in the video: how the camera eases and how titles and other
/// overlays come and go. `plan.style.motion` names one; overlays and zooms can override it.
public struct MotionStyle: Equatable {
  public var name: String
  public var label: String
  /// The camera's and layouts' easing.
  public var ease: Ease
  /// How overlays enter and leave when they don't say.
  public var enter: Motion
  public var exit: Motion

  public static let all: [MotionStyle] = [
    MotionStyle(
      name: "smooth", label: "Smooth", ease: Ease.named("smooth")!,
      enter: Motion(preset: "fade-up", seconds: 0.4, ease: "smooth"), exit: Motion(preset: "fade", seconds: 0.25, ease: "ease-in")),
    MotionStyle(
      name: "snappy", label: "Snappy", ease: Ease.named("snappy")!,
      enter: Motion(preset: "pop", seconds: 0.3, ease: "spring"), exit: Motion(preset: "fade", seconds: 0.18, ease: "ease-in")),
    MotionStyle(
      name: "cinematic", label: "Cinematic", ease: Ease.named("cinematic")!,
      enter: Motion(preset: "blur", seconds: 0.6, ease: "cinematic"), exit: Motion(preset: "blur", seconds: 0.45, ease: "ease-in")),
    MotionStyle(
      name: "bouncy", label: "Bouncy", ease: Ease.named("spring")!,
      enter: Motion(preset: "pop", seconds: 0.45, ease: "bouncy"), exit: Motion(preset: "pop", seconds: 0.22, ease: "ease-in")),
    // The engine before motion styles: a windowed average, kept so older edits can look the same.
    MotionStyle(
      name: "classic", label: "Classic", ease: Ease.named("smooth")!,
      enter: Motion(preset: "none"), exit: Motion(preset: "none")),
  ]

  public static func named(_ s: String?) -> MotionStyle {
    all.first { $0.name == s } ?? all[0]
  }
}

/// How one overlay enters (or, reversed, leaves).
public struct Motion: Codable, Equatable {
  /// One of `Motion.presets`.
  public var preset: String
  /// Length of the move. Default from the motion style.
  public var seconds: Double?
  /// An `Ease` name. Default from the motion style.
  public var ease: String?
  public init(preset: String, seconds: Double? = nil, ease: String? = nil) {
    self.preset = preset
    self.seconds = seconds
    self.ease = ease
  }

  public static let presets: [(name: String, label: String)] = [
    ("fade", "Fade"), ("fade-up", "Fade Up"), ("slide-up", "Slide Up"), ("slide-down", "Slide Down"),
    ("slide-left", "Slide Left"), ("slide-right", "Slide Right"), ("pop", "Pop"), ("zoom", "Zoom"), ("blur", "Blur"),
    ("wipe", "Wipe"), ("words", "Word by Word"), ("typewriter", "Typewriter"), ("none", "None"),
  ]
}

/// What an entrance or exit does to an overlay at one moment. `amount` 0 is hidden, 1 is fully in.
public struct OverlayPose: Equatable {
  public var opacity = 1.0
  /// Offset as a share of the overlay's own size (dx of 1 is one width to the right).
  public var dx = 0.0
  public var dy = 0.0
  public var scale = 1.0
  /// Gaussian blur, in points at 1080p.
  public var blur = 0.0
  /// Share revealed from the left (wipe).
  public var reveal = 1.0
  /// Share of the text shown (words, typewriter).
  public var text = 1.0
  public var visible: Bool { opacity > 0.003 && reveal > 0.003 }

  public static let full = OverlayPose()

  /// The pose `amount` of the way in (springs can pass 1 and come back).
  public static func of(_ preset: String, _ amount: Double) -> OverlayPose {
    let a = amount
    let clamped = min(max(a, 0), 1)
    var p = OverlayPose()
    switch preset {
    case "none": break
    case "fade": p.opacity = clamped
    case "fade-up":
      p.opacity = clamped
      p.dy = 0.35 * (1 - a)
    case "slide-up":
      p.opacity = min(1, clamped * 3)
      p.dy = 1.2 * (1 - a)
    case "slide-down":
      p.opacity = min(1, clamped * 3)
      p.dy = -1.2 * (1 - a)
    case "slide-left":
      p.opacity = min(1, clamped * 3)
      p.dx = 0.6 * (1 - a)
    case "slide-right":
      p.opacity = min(1, clamped * 3)
      p.dx = -0.6 * (1 - a)
    case "pop":
      p.opacity = min(1, clamped * 2.5)
      p.scale = max(0.05, 0.6 + 0.4 * a)
    case "zoom":
      p.opacity = clamped
      p.scale = 1.18 - 0.18 * a
    case "blur":
      p.opacity = clamped
      p.blur = 24 * (1 - clamped)
      p.scale = 1.04 - 0.04 * a
    case "wipe": p.reveal = clamped
    case "words", "typewriter":
      p.opacity = min(1, clamped * 4)
      p.text = clamped
    default: p.opacity = clamped
    }
    return p
  }
}

extension Motion {
  /// The pose of an overlay shown from output frame `s` to `e`, at frame `f`.
  public static func pose(
    frame f: Double, start s: Double, end e: Double, fps: Int, enter: Motion?, exit: Motion?, style: MotionStyle
  ) -> OverlayPose {
    guard f >= s, f < e else { return OverlayPose(opacity: 0) }
    let inM = enter ?? style.enter
    let outM = exit ?? style.exit
    let length = e - s
    // Long entrances and exits share a short overlay instead of overlapping.
    var inF = (inM.seconds ?? style.enter.seconds ?? 0.35) * Double(fps)
    var outF = (outM.seconds ?? style.exit.seconds ?? 0.25) * Double(fps)
    if inM.preset == "none" { inF = 0 }
    if outM.preset == "none" { outF = 0 }
    if inF + outF > length, inF + outF > 0 {
      let k = length / (inF + outF)
      inF *= k
      outF *= k
    }
    if inF > 0, f < s + inF {
      let ease = Ease.named(inM.ease) ?? Ease.named(style.enter.ease) ?? .linear
      // Text reveals run at an even pace; only the rest of the pose eases.
      var pose = OverlayPose.of(inM.preset, ease.at((f - s) / inF))
      if inM.preset == "words" || inM.preset == "typewriter" { pose.text = min(1, (f - s) / inF) }
      return pose
    }
    if outF > 0, f >= e - outF {
      let ease = Ease.named(outM.ease) ?? Ease.named(style.exit.ease) ?? .linear
      var pose = OverlayPose.of(outM.preset, 1 - ease.at((f - (e - outF)) / outF))
      // A text reveal leaves by fading, not by un-typing.
      if outM.preset == "words" || outM.preset == "typewriter" { pose = OverlayPose.of("fade", pose.opacity) }
      return pose
    }
    return .full
  }
}

// MARK: Eased transitions between held states

/// A value that holds still, then eases to a new value at each change. A change that starts
/// before the last one finished starts from wherever the value was, so nothing ever jumps.
public struct EasedSteps {
  public struct Change {
    /// Output frame the move starts.
    public var at: Double
    public var to: [Double]
    /// Length of the move in frames.
    public var frames: Double
    public var ease: Ease
    public init(at: Double, to: [Double], frames: Double, ease: Ease) {
      self.at = at
      self.to = to
      self.frames = frames
      self.ease = ease
    }
  }

  let initial: [Double]
  let changes: [Change]
  let from: [[Double]]
  let interp: ([Double], [Double], Double) -> [Double]

  public init(initial: [Double], changes: [Change], interp: @escaping ([Double], [Double], Double) -> [Double] = EasedSteps.lerp) {
    self.initial = initial
    self.interp = interp
    let sorted = changes.sorted { $0.at < $1.at }
    self.changes = sorted
    var from: [[Double]] = []
    for (i, c) in sorted.enumerated() {
      if i == 0 {
        from.append(initial)
      } else {
        let p = sorted[i - 1]
        let u = p.frames <= 0 ? 1 : p.ease.at((c.at - p.at) / p.frames)
        from.append(interp(from[i - 1], p.to, u))
      }
    }
    self.from = from
  }

  public func at(_ f: Double) -> [Double] {
    // The last change that has started.
    var lo = 0, hi = changes.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if changes[mid].at <= f { lo = mid + 1 } else { hi = mid }
    }
    guard lo > 0 else { return initial }
    let c = changes[lo - 1]
    let u = c.frames <= 0 ? 1 : c.ease.at((f - c.at) / c.frames)
    return u >= 1 && (f - c.at) >= c.frames ? c.to : interp(from[lo - 1], c.to, u)
  }

  public static func lerp(_ a: [Double], _ b: [Double], _ u: Double) -> [Double] {
    zip(a, b).map { $0 + ($1 - $0) * u }
  }

  /// Camera moves ([scale, x, y]): scale changes evenly in log space, so a 1x to 2x zoom feels as
  /// fast at the end as at the start, and the point that stays put on screen stays put, so a zoom
  /// toward a corner doesn't swing out and back.
  public static func camera(_ a: [Double], _ b: [Double], _ u: Double) -> [Double] {
    let s0 = max(a[0], 0.05), s1 = max(b[0], 0.05)
    let s = exp(log(s0) + (log(s1) - log(s0)) * u)
    let lerped = [s, a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u]
    guard abs(s1 - s0) > 0.05 * max(s0, s1) else { return lerped }
    // The fixed point q: where (q - c0) * s0 == (q - c1) * s1.
    let qx = (b[1] * s1 - a[1] * s0) / (s1 - s0)
    let qy = (b[2] * s1 - a[2] * s0) / (s1 - s0)
    // A fixed point far off screen means it's mostly a pan; zooming about it would swing.
    guard (-0.25...1.25).contains(qx), (-0.25...1.25).contains(qy) else { return lerped }
    return [s, qx - (qx - a[1]) * s0 / s, qy - (qy - a[2]) * s0 / s]
  }
}

/// The camera's moves for a plan: zooms in (arriving just after the click), holds, and out, with a
/// cropped format's resting point following clicks between zooms.
public func cameraSteps(
  zooms: [OutZoom], fps: Int, transition: Double, style: MotionStyle, lead: Double, restClicks: [(f: Double, x: Double, y: Double)]?
) -> EasedSteps {
  let dur = max(1, transition * Double(fps))
  let leadF = lead * Double(fps)
  func rest(_ f: Double) -> [Double] {
    let c = restClicks?.last { $0.f <= f }
    return [1, c?.x ?? 0.5, c?.y ?? 0.5]
  }
  var changes: [EasedSteps.Change] = []
  var holds: [(Double, Double)] = []
  let sorted = zooms.sorted { $0.startF < $1.startF }
  for (i, z) in sorted.enumerated() {
    let ease = Ease.named(z.ease) ?? style.ease
    let d = z.seconds.map { max(1, $0 * Double(fps)) } ?? dur
    var inAt = z.startF - leadF - d / 2
    if let last = changes.last { inAt = max(inAt, last.at + 1) }
    changes.append(.init(at: inAt, to: [z.scale, z.x, z.y], frames: d, ease: ease))
    let outAt = max(inAt + 1, z.endF - d * 0.3)
    let nextIn = i + 1 < sorted.count ? sorted[i + 1].startF - leadF - (sorted[i + 1].seconds.map { $0 * Double(fps) } ?? dur) / 2 : .infinity
    if nextIn > outAt + 1 {
      // The exit is a little slower than the entrance: a long, soft settle.
      changes.append(.init(at: outAt, to: rest(outAt + d), frames: d * 1.3, ease: ease))
      holds.append((inAt, outAt))
    } else {
      holds.append((inAt, nextIn))
    }
  }
  if let clicks = restClicks {
    for c in clicks {
      let at = c.f - dur / 2
      guard !holds.contains(where: { at >= $0.0 - dur && at < $0.1 + dur }) else { continue }
      changes.append(.init(at: at, to: [1, c.x, c.y], frames: dur, ease: style.ease))
    }
  }
  return EasedSteps(initial: rest(-.infinity), changes: changes, interp: EasedSteps.camera)
}
