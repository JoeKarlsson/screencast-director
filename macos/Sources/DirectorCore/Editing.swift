import Foundation

// Manual edit operations on a plan, used by the app's timeline. Pure functions over source times,
// so they're checked in Tests/Checks.swift.

public struct Gap: Equatable {
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

  public func segmentIndex(at t: Double) -> Int? {
    segments.firstIndex { t >= $0.start && t < $0.end }
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
    segments.append(Segment(start: gap.start, end: gap.end, speed: 1, note: "restored"))
    normalize()
  }

  /// Sorts everything, clips overlaps, clamps to the recording and drops slivers.
  public mutating func normalize() {
    let dur = source.duration
    var segs: [Segment] = []
    for var s in segments.sorted(by: { $0.start < $1.start }) {
      s.start = max(0, s.start)
      s.end = min(dur, s.end)
      if let last = segs.last, s.start < last.end { s.start = last.end }
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
  }

  /// Moves one edge of segment `i`, keeping it inside its neighbors.
  public mutating func trimSegment(_ i: Int, start: Double? = nil, end: Double? = nil) {
    guard segments.indices.contains(i) else { return }
    let lo = i > 0 ? segments[i - 1].end : 0
    let hi = i + 1 < segments.count ? segments[i + 1].start : source.duration
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
