import Foundation

// The first-draft edit.
//   speech            -> 1x (filler words cut)
//   typing, no speech -> 3x
//   mouse, no speech  -> 1.5x
//   screen changing   -> 4x
//   nothing happening -> cut
// Zooms follow clusters of clicks and typing.

public enum Rules {
  static let speechMergeGap = 0.7
  static let speechPadBefore = 0.2
  static let speechPadAfter = 0.35
  static let bucket = 0.25
  static let minIdleCut = 0.6
  static let idleKeep = 0.1
  static let typingSpeed = 3.0
  static let mouseSpeed = 1.5
  static let screenSpeed = 4.0
  static let minSpedUp = 1.5
  public static let motionThreshold = 0.25
  static let zoomGap = 2.5
  static let zoomDistance = 0.2
  static let zoomLeadIn = 0.6
  static let zoomHold = 1.5
  static let minZoom = 1.5

  static func isFiller(_ text: String) -> Bool {
    text.range(of: #"^(um+|uh+|erm+|uhm+|ah+|hmm+)[.,!?]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
  }
}

private struct Interval {
  var start: Double
  var end: Double
}

private func merge(_ list: [Interval], gap: Double) -> [Interval] {
  var out: [Interval] = []
  for i in list.sorted(by: { $0.start < $1.start }) {
    if var last = out.last, i.start - last.end <= gap {
      last.end = max(last.end, i.end)
      out[out.count - 1] = last
    } else {
      out.append(i)
    }
  }
  return out
}

private enum Label: String { case speech, typing, mouse, screen, idle }

private func roundTo(_ v: Double, _ places: Int) -> Double {
  let p = pow(10.0, Double(places))
  return (v * p).rounded() / p
}

public func buildSegments(_ p: Project) -> [Segment] {
  // Cut filler words, phrases marked as retakes (⌃⌥⌘M), and earlier takes of script lines.
  var fillers = p.words.filter { Rules.isFiller($0.text) }.map { Interval(start: $0.start - 0.05, end: $0.end + 0.05) }
  fillers += retakeCuts(words: p.words, marks: p.retakes).map { Interval(start: $0.0, end: $0.1) }
  fillers += earlierTakeCuts(words: p.words, script: p.script).map { Interval(start: $0.0, end: $0.1) }
  let speech = merge(
    p.words.filter { !Rules.isFiller($0.text) }.map {
      Interval(start: $0.start - Rules.speechPadBefore, end: $0.end + Rules.speechPadAfter)
    }, gap: Rules.speechMergeGap)
  let dur = p.source.duration
  let b = Rules.bucket

  func label(_ t: Double) -> Label {
    if speech.contains(where: { t + b > $0.start && t < $0.end }) { return .speech }
    let near = p.events.filter { $0.type != .retake && $0.t >= t - 0.5 && $0.t < t + b + 0.5 }
    if near.contains(where: { $0.type == .key }) { return .typing }
    if !near.isEmpty { return .mouse }
    let changing = p.motion.contains { $0.0 >= t && $0.0 < t + b && $0.1 > Rules.motionThreshold }
    return changing ? .screen : .idle
  }

  var runs: [(label: Label, start: Double, end: Double)] = []
  var t = 0.0
  while t < dur {
    let l = label(t)
    let end = min(dur, t + b)
    if let last = runs.last, last.label == l { runs[runs.count - 1].end = end } else { runs.append((l, t, end)) }
    t += b
  }

  var segments: [Segment] = []
  for r in runs {
    let len = r.end - r.start
    var speed = 1.0
    switch r.label {
    case .idle where len >= Rules.minIdleCut:
      // Keep a sliver on each side so cuts don't feel clipped.
      if r.start > 0 { segments.append(Segment(start: r.start, end: r.start + Rules.idleKeep, speed: 1, note: "idle")) }
      if r.end < dur { segments.append(Segment(start: r.end - Rules.idleKeep, end: r.end, speed: 1, note: "idle")) }
      continue
    case .typing where len >= Rules.minSpedUp: speed = Rules.typingSpeed
    case .mouse where len >= Rules.minSpedUp: speed = Rules.mouseSpeed
    case .screen where len >= Rules.minSpedUp: speed = Rules.screenSpeed
    default: break
    }
    segments.append(Segment(start: r.start, end: r.end, speed: speed, note: r.label.rawValue))
  }

  for f in fillers {
    segments = segments.flatMap { s -> [Segment] in
      if f.end <= s.start || f.start >= s.end { return [s] }
      var parts: [Segment] = []
      if f.start > s.start { var a = s; a.end = f.start; parts.append(a) }
      if f.end < s.end { var c = s; c.start = f.end; parts.append(c) }
      return parts
    }
  }

  var merged: [Segment] = []
  for s in segments {
    if var last = merged.last, abs(last.end - s.start) < 1e-6, last.speed == s.speed {
      last.end = s.end
      if let n = s.note, let ln = last.note, !ln.split(separator: "+").contains(Substring(n)) { last.note = ln + "+" + n }
      merged[merged.count - 1] = last
    } else {
      merged.append(s)
    }
  }
  // A joined recording's takes meet with a hard cut: no segment runs across a join.
  for j in p.source.joins ?? [] {
    merged = merged.flatMap { s -> [Segment] in
      guard s.start < j - 0.01, s.end > j + 0.01 else { return [s] }
      var a = s, b = s
      a.end = j
      b.start = j
      return [a, b]
    }
  }
  return merged.filter { $0.end - $0.start > 0.04 }.map {
    var s = $0
    s.start = roundTo(s.start, 3)
    s.end = roundTo(s.end, 3)
    return s
  }
}

public func buildZooms(_ p: Project) -> [Zoom] {
  struct Focus { var e: InputEvent; var fx: Double; var fy: Double }
  var lastClick: InputEvent?
  var focus: [Focus] = []
  for e in p.events {
    if e.type == .click {
      lastClick = e
      focus.append(Focus(e: e, fx: e.x, fy: e.y))
    } else if e.type == .key {
      // Typing has no caret position, so it borrows the last click before it.
      let anchor = (lastClick.map { e.t - $0.t < 20 } ?? false) ? lastClick! : e
      focus.append(Focus(e: e, fx: anchor.x, fy: anchor.y))
    }
  }

  var clusters: [[Focus]] = []
  for f in focus {
    if f.fx < 0 || f.fx > 1 || f.fy < 0 || f.fy > 1 { continue }  // another display
    if let prev = clusters.last?.last, f.e.t - prev.e.t <= Rules.zoomGap,
      hypot(f.fx - prev.fx, f.fy - prev.fy) <= Rules.zoomDistance
    {
      clusters[clusters.count - 1].append(f)
    } else {
      clusters.append([f])
    }
  }

  var zooms = clusters.map { c -> Zoom in
    let keys = c.filter { $0.e.type == .key }.count
    let typing = Double(keys) > Double(c.count) / 2
    let start = max(0, c[0].e.t - Rules.zoomLeadIn)
    let end = max(c[c.count - 1].e.t + Rules.zoomHold, start + Rules.minZoom)
    return Zoom(
      start: roundTo(start, 2), end: roundTo(min(end, p.source.duration), 2),
      x: roundTo(c.map(\.fx).reduce(0, +) / Double(c.count), 3),
      y: roundTo(c.map(\.fy).reduce(0, +) / Double(c.count), 3),
      scale: typing ? 2 : 1.6, note: typing ? "typing (\(c.count) keys)" : "\(c.count) click(s)")
  }
  // Overlapping zooms hand off: the earlier one ends where the next begins (renders as a pan).
  if zooms.count > 1 {
    for i in 0..<(zooms.count - 1) where zooms[i].end > zooms[i + 1].start { zooms[i].end = zooms[i + 1].start }
  }
  // Nor does a zoom: it ends where the next take starts.
  for j in p.source.joins ?? [] {
    for i in zooms.indices where zooms[i].start < j && zooms[i].end > j { zooms[i].end = j }
  }
  return zooms.filter { $0.end - $0.start > 0.3 }
}

public func buildPlan(_ p: Project) -> Plan {
  Plan(
    source: .init(video: p.source.video, width: p.source.width, height: p.source.height, duration: p.source.duration),
    camera: p.source.camera,
    output: .init(width: 1920, height: 1080, fps: 30),
    style: .init(background: ["#1d2b64", "#f8cdda"], padding: 0.06, radius: 14, transition: 0.8),
    segments: buildSegments(p), zooms: buildZooms(p),
    defaultLayout: p.source.camera != nil ? .pip : .screen, layouts: [],
    captions: .init(enabled: !p.words.isEmpty, maxWords: 7),
    clickRipples: true, shortcutChips: true, callouts: [])
}
