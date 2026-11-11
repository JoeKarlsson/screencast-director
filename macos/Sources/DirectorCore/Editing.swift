import Foundation

// Manual edit operations on a plan, used by the app's timeline. Pure functions over source times,
// so they're checked in Tests/Checks.swift.

public struct Gap: Equatable, Sendable {
  public var start: Double
  public var end: Double
}

extension Plan {
  /// Cut ranges: everything in the recording not covered by a segment.
  public var gaps: [Gap] {
    var out: [Gap] = []
    var cursor = 0.0
    for s in segments.sorted(by: { $0.start < $1.start }) {
      if s.start - cursor > 0.01 { out.append(Gap(start: cursor, end: s.start)) }
      cursor = max(cursor, s.end)
    }
    if source.duration - cursor > 0.01 { out.append(Gap(start: cursor, end: source.duration)) }
    return out
  }

  /// The clip playing source time `t` (the original, not a repeat of it).
  public func segmentIndex(at t: Double) -> Int? {
    segments.firstIndex { t >= $0.start && t < $0.end && $0.repeats != true } ?? segments.firstIndex { t >= $0.start && t < $0.end }
  }

  /// Splits the segment under `t` in two. Returns false if `t` is in a cut or too near an edge.
  @discardableResult
  public mutating func split(at t: Double) -> Bool {
    guard let i = segmentIndex(at: t), t - segments[i].start > 0.05, segments[i].end - t > 0.05 else { return false }
    var right = segments[i]
    right.start = t
    segments[i].end = t
    segments.insert(right, at: i + 1)
    return true
  }

  /// Puts a cut range back at real-time speed.
  public mutating func restore(_ gap: Gap) {
    insertInRecordingOrder(Segment(start: gap.start, end: gap.end, speed: 1, note: "restored"))
    normalize()
  }

  /// Adds a clip where it falls in the recording: right after the clip that ends before it, so a
  /// restored piece plays next to its neighbors even when clips have been moved.
  mutating func insertInRecordingOrder(_ s: Segment) {
    if let i = segments.indices.filter({ segments[$0].end <= s.start + 1e-6 }).max(by: { segments[$0].end < segments[$1].end }) {
      segments.insert(s, at: i + 1)
    } else if let j = segments.indices.filter({ segments[$0].start >= s.end - 1e-6 }).min(by: { segments[$0].start < segments[$1].start }) {
      segments.insert(s, at: j)
    } else {
      segments.append(s)
    }
  }

  /// Keeps the clips in play order (a plan from before reordering is put in recording order once),
  /// clips overlaps so each moment plays once, clamps to the recording, sorts everything else and
  /// drops slivers.
  public mutating func normalize() {
    let dur = source.duration
    if version < 2 {
      segments.sort { $0.start < $1.start }
      version = 2
    }
    var segs: [Segment] = []
    for var s in segments {
      s.start = max(0, s.start)
      s.end = min(dur, s.end)
      // Repeats may overlap; everything else plays each moment once.
      for o in segs where s.repeats != true && o.repeats != true && s.start < o.end && s.end > o.start {
        if s.start >= o.start { s.start = o.end } else { s.end = min(s.end, o.start) }
      }
      if s.end - s.start >= 0.04 { segs.append(s) }
    }
    segments = segs
    zooms = zooms.map { z in
      var z = z
      z.start = max(0, z.start)
      z.end = min(dur, z.end)
      z.x = min(max(z.x, 0), 1)
      z.y = min(max(z.y, 0), 1)
      z.scale = min(max(z.scale, 1), 4)
      return z
    }.filter { $0.end - $0.start >= 0.2 }.sorted { $0.start < $1.start }
    layouts = layouts.filter { $0.end - $0.start >= 0.2 }.sorted { $0.start < $1.start }
    callouts = callouts.filter { $0.end - $0.start >= 0.2 }.sorted { $0.start < $1.start }
    if let marks = annotations {
      let kinds = Set(Annotation.kinds.map(\.name))
      let kept: [Annotation] = marks.map { a in
        var a = a
        a.start = max(0, a.start)
        a.end = min(dur, a.end)
        a.x = min(max(a.x, 0), 1)
        a.y = min(max(a.y, 0), 1)
        a.w = min(max(a.w, 0.005), 1 - a.x)
        a.h = min(max(a.h, 0.005), 1 - a.y)
        return a
      }.filter { $0.end - $0.start >= 0.2 && kinds.contains($0.kind) }.sorted { $0.start < $1.start }
      annotations = kept.isEmpty ? nil : kept
    }
    if let list = inserts {
      let kept: [Insert] = list.map { a in
        var a = a
        a.start = max(0, a.start)
        a.end = min(dur, a.end)
        if let f = a.from { a.from = max(0, f) }
        return a
      }.filter { $0.end - $0.start >= 0.2 && !$0.file.isEmpty }.sorted { $0.start < $1.start }
      inserts = kept.isEmpty ? nil : kept
    }
    if let list = camera?.punchIns {
      let kept: [PunchIn] = list.map { p in
        var p = p
        p.start = max(0, p.start)
        p.end = min(dur, p.end)
        return p
      }.filter { $0.end - $0.start >= 0.2 && $0.scale > 0 }.sorted { $0.start < $1.start }
      camera?.punchIns = kept.isEmpty ? nil : kept
    }
    if let list = effectRanges {
      let kept: [EffectRange] = list.map { r in
        var r = r
        r.start = max(0, r.start)
        r.end = min(dur, r.end)
        return r
      }.filter { $0.end - $0.start >= 0.2 && !$0.name.isEmpty }.sorted { $0.start < $1.start }
      effectRanges = kept.isEmpty ? nil : kept
    }
    if let list = sfx {
      let kept: [SoundEffect] = list.map { e in
        var e = e
        e.t = min(max(e.t, 0), dur)
        return e
      }.filter { !$0.file.isEmpty }.sorted { $0.t < $1.t }
      sfx = kept.isEmpty ? nil : kept
    }
    if let m = markers {
      let kept: [Marker] = m.map { k in
        var k = k
        k.t = min(max(k.t, 0), dur)
        return k
      }.sorted { $0.t < $1.t }
      markers = kept.isEmpty ? nil : kept
    }
  }

  /// Moves one edge of segment `i`, keeping it inside its neighbors.
  public mutating func trimSegment(_ i: Int, start: Double? = nil, end: Double? = nil) {
    guard segments.indices.contains(i) else { return }
    // Its neighbors in the recording, wherever they play.
    let me = segments[i]
    let others = me.repeats == true ? [] : segments.filter { $0.repeats != true }
    let lo = others.filter { $0.end <= me.start + 1e-6 }.map(\.end).max() ?? 0
    let hi = others.filter { $0.start >= me.end - 1e-6 }.map(\.start).min() ?? source.duration
    if let start { segments[i].start = min(max(start, lo), segments[i].end - 0.05) }
    if let end { segments[i].end = max(min(end, hi), segments[i].start + 0.05) }
  }
}

/// Where a new zoom should look: the last click in the 10 s before `t`, else the center.
public func zoomFocus(at t: Double, clicks: [InputEvent]) -> (x: Double, y: Double) {
  if let c = clicks.last(where: { $0.t <= t && t - $0.t < 10 && (0...1).contains($0.x) && (0...1).contains($0.y) }) {
    return (c.x, c.y)
  }
  return (0.5, 0.5)
}

extension Plan {
  /// Cuts a source time range out of the edit, splitting clips as needed. A piece of a clip under
  /// two frames left beside the cut goes too, since it would only flash by.
  public mutating func cut(range: Range<Double>) {
    guard range.upperBound > range.lowerBound else { return }
    let sliver = 2 / Double(output.fps)
    segments = segments.flatMap { s -> [Segment] in
      if range.upperBound <= s.start || range.lowerBound >= s.end { return [s] }
      var parts: [Segment] = []
      if range.lowerBound - s.start >= sliver {
        var left = s
        left.end = range.lowerBound
        parts.append(left)
      }
      if s.end - range.upperBound >= sliver {
        var right = s
        right.start = range.upperBound
        parts.append(right)
      }
      return parts
    }
    normalize()
  }

  /// Puts back the cut parts of a source time range at real-time speed. Parts already in the edit
  /// (at any speed) stay as they are.
  /// Plays a source range at `speed`, splitting clips at its edges. Cut parts stay cut.
  public mutating func setSpeed(range: Range<Double>, speed: Double) {
    _ = split(at: range.lowerBound)
    _ = split(at: range.upperBound)
    for i in segments.indices where segments[i].start >= range.lowerBound - 1e-6 && segments[i].end <= range.upperBound + 1e-6 {
      segments[i].speed = speed
    }
  }

  public mutating func restore(range: Range<Double>) {
    for g in gaps where g.end > range.lowerBound && g.start < range.upperBound {
      insertInRecordingOrder(Segment(start: max(g.start, range.lowerBound), end: min(g.end, range.upperBound), speed: 1, note: "restored"))
    }
    normalize()
  }

  /// Moves the clips in a source range (split at its edges) to play just before the moment at source
  /// time `before` (the next kept moment if that's cut), or first when `before` is nil: a cold open.
  /// Returns false when nothing in the range is kept, or `before` is inside it.
  @discardableResult
  public mutating func move(range: Range<Double>, before: Double?) -> Bool {
    if let before, range.contains(before) { return false }
    if version < 2 { normalize() }
    _ = split(at: range.lowerBound)
    _ = split(at: range.upperBound)
    if let before { _ = split(at: before) }
    let inRange = { (s: Segment) in s.repeats != true && s.start >= range.lowerBound - 1e-6 && s.end <= range.upperBound + 1e-6 }
    let moving = segments.filter(inRange)
    guard !moving.isEmpty else { return false }
    segments.removeAll(where: inRange)
    var at = 0
    if let before {
      at = segments.firstIndex { before >= $0.start - 1e-6 && before < $0.end }
        ?? segments.indices.filter { segments[$0].start >= before }.min { segments[$0].start < segments[$1].start }
        ?? segments.count
    }
    segments.insert(contentsOf: moving, at: at)
    return true
  }

  /// Plays a source range a second time, just before the moment at `before` (the next kept moment if
  /// that's cut) or first when nil, leaving it where it already plays too: a cold open that stays
  /// in its sentence. Returns false when none of the range is in the edit.
  @discardableResult
  public mutating func repeatRange(_ range: Range<Double>, before: Double?) -> Bool {
    if let before, range.contains(before) { return false }
    if version < 2 { normalize() }
    guard segments.contains(where: { $0.repeats != true && $0.start < range.upperBound && $0.end > range.lowerBound }) else { return false }
    if let before { _ = split(at: before) }
    var at = 0
    if let before {
      at = segments.firstIndex { before >= $0.start - 1e-6 && before < $0.end && $0.repeats != true }
        ?? segments.indices.filter { segments[$0].start >= before && segments[$0].repeats != true }.min { segments[$0].start < segments[$1].start }
        ?? segments.count
    }
    segments.insert(Segment(start: range.lowerBound, end: range.upperBound, speed: 1, note: "repeat", repeats: true), at: at)
    return true
  }

  /// Moves clip `i` to play at position `to` (0 is first), keeping the rest in order.
  public mutating func moveSegment(_ i: Int, to: Int) {
    if version < 2 { normalize() }
    guard segments.indices.contains(i) else { return }
    let s = segments.remove(at: i)
    segments.insert(s, at: min(max(0, to), segments.count))
  }

  /// The speed a source moment plays at, or nil if it's cut.
  public func speed(at t: Double) -> Double? {
    segments.first { t >= $0.start && t < $0.end }?.speed
  }

  /// Whether two plans differ in cuts, speeds or zooms (what a second look checks).
  public func changesCutsOrZooms(from old: Plan) -> Bool {
    segments != old.segments || zooms != old.zooms
  }
}
