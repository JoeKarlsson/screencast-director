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
      for o in segs where s.start < o.end && s.end > o.start {
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
    let lo = segments.filter { $0.end <= me.start + 1e-6 }.map(\.end).max() ?? 0
    let hi = segments.filter { $0.start >= me.end - 1e-6 }.map(\.start).min() ?? source.duration
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

/// How hard to cut silence. Gentle keeps natural pauses; tight leaves almost none.
public enum PauseLevel: String, CaseIterable, Codable {
  case gentle, normal, tight

  /// Longest pause kept whole, and how much silence to leave on each side of a cut.
  public var maxPause: Double { [.gentle: 1.2, .normal: 0.6, .tight: 0.35][self]! }
  public var keep: Double { [.gentle: 0.25, .normal: 0.12, .tight: 0.06][self]! }
  public var label: String { rawValue.capitalized }
}

extension Plan {
  /// Re-cuts the silences at a new level, in either direction. Only "pause cuts" (gaps with no
  /// spoken words) are rewritten; cuts that removed words (retakes, fumbles) stay cut, and
  /// sped-up segments are left alone. `paused` stretches (recorded while paused) stay cut too.
  public mutating func retrimPauses(
    words: [Word], level: PauseLevel, silences: [(Double, Double)]? = nil, paused: [(Double, Double)] = []
  ) {
    func hasWords(_ a: Double, _ b: Double) -> Bool { words.contains { $0.start < b - 0.02 && $0.end > a + 0.02 } }
    // A cut was a pause if it was mostly silent (measured), else if it held no transcript words.
    // Whisper stretches word timings across pauses, so the audio is the better judge.
    func wasPause(_ a: Double, _ b: Double) -> Bool {
      guard let silences else { return !hasWords(a, b) }
      let quiet = silences.reduce(0.0) { $0 + max(0, min($1.1, b) - max($1.0, a)) }
      return quiet >= 0.8 * (b - a)
    }

    // 1. Undo pause cuts: join clips that play back to back across gaps that were silence (a clip
    // moved out of recording order has no gap to its neighbor to join).
    var joined: [Segment] = []
    for s in playSegments {
      if var last = joined.last, s.start >= last.end - 1e-6, s.start - last.end < 6, wasPause(last.end, s.start), last.speed == 1, s.speed == 1,
        !paused.contains(where: { $0.0 < s.start && $0.1 > last.end })
      {
        last.end = s.end
        joined[joined.count - 1] = last
      } else {
        joined.append(s)
      }
    }

    // 2. Cut long silences inside real-time segments, leaving `keep` on each side.
    var out: [Segment] = []
    for s in joined {
      guard s.speed == 1 else {
        out.append(s)
        continue
      }
      var cursor = s.start
      var marks: [(Double, Double)] = []
      if let silences {
        // Measured silences (from the audio) inside this segment.
        for (a, b) in silences where b > s.start && a < s.end {
          let a2 = max(a, s.start), b2 = min(b, s.end)
          if b2 - a2 > level.maxPause { marks.append((a2 + level.keep, b2 - level.keep)) }
        }
      } else {
        // No audio levels: fall back to gaps between transcript words.
        let inside = words.filter { $0.end > s.start && $0.start < s.end }.sorted { $0.start < $1.start }
        var prevEnd = s.start
        for w in inside {
          if w.start - prevEnd > level.maxPause { marks.append((prevEnd + level.keep, w.start - level.keep)) }
          prevEnd = max(prevEnd, w.end)
        }
        if s.end - prevEnd > level.maxPause, !inside.isEmpty { marks.append((prevEnd + level.keep, s.end - level.keep)) }
      }
      for (a, b) in marks where b - a > 0.05 {
        if a - cursor > 0.04 { out.append(Segment(start: cursor, end: a, speed: 1, note: s.note)) }
        cursor = b
      }
      if s.end - cursor > 0.04 { out.append(Segment(start: cursor, end: s.end, speed: 1, note: s.note)) }
    }
    segments = out
    dropSlivers(silences: silences ?? [])
    normalize()
  }

  /// Drops clips left stranded between cuts: under `Rules.minClip` seconds of output, or under
  /// `Rules.minQuietClip` and mostly silence. They play as a jarring flicker, so the cut runs on to
  /// where speech resumes. Clips that play back to back count as one.
  public mutating func dropSlivers(silences: [(Double, Double)]) {
    var islands: [[Segment]] = []
    for s in playSegments {
      if let last = islands.last?.last, s.start - last.end < 0.01 { islands[islands.count - 1].append(s) } else { islands.append([s]) }
    }
    guard islands.count > 1 else { return }
    func isSliver(_ island: [Segment]) -> Bool {
      let output = island.reduce(0.0) { $0 + ($1.end - $1.start) / $1.speed }
      if output < Rules.minClip { return true }
      guard output < Rules.minQuietClip else { return false }
      let a = island[0].start, b = island[island.count - 1].end
      let quiet = silences.reduce(0.0) { $0 + max(0, min($1.1, b) - max($1.0, a)) }
      return quiet >= 0.7 * (b - a)
    }
    segments = islands.filter { !isSliver($0) }.flatMap { $0 }
  }
}

extension Plan {
  /// Cuts a source time range out of the edit, splitting clips as needed.
  public mutating func cut(range: Range<Double>) {
    guard range.upperBound > range.lowerBound else { return }
    segments = segments.flatMap { s -> [Segment] in
      if range.upperBound <= s.start || range.lowerBound >= s.end { return [s] }
      var parts: [Segment] = []
      if range.lowerBound > s.start {
        var left = s
        left.end = range.lowerBound
        parts.append(left)
      }
      if range.upperBound < s.end {
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
    let inRange = { (s: Segment) in s.start >= range.lowerBound - 1e-6 && s.end <= range.upperBound + 1e-6 }
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

/// What an AI's second look at its own edit needs: for each zoom, what was said and clicked while
/// it's on screen, and every cut edge that lands inside a word.
public func editReview(_ project: Project, _ plan: Plan) -> String {
  var lines: [String] = []
  let fps = plan.output.fps
  let mapped = mapPlan(plan)
  for (i, z) in plan.zooms.enumerated() {
    let said = project.words.filter { $0.end > z.start && $0.start < z.end }.map(\.text).joined(separator: " ")
    let clicks = project.events.filter { $0.type == .click && $0.t >= z.start && $0.t < z.end }
      .map { String(format: "(%.2f, %.2f)", $0.x, $0.y) }
    let mid = Int(srcToOutClamped(mapped, (z.start + z.end) / 2, fps: fps))
    lines.append(
      "zoom #\(i) src \(fmtTime(z.start))-\(fmtTime(z.end)) at " + String(format: "(%.2f, %.2f) x%.1f", z.x, z.y, z.scale)
        + ": said \"\(said)\"" + (clicks.isEmpty ? ", no clicks" : ", clicks at " + clicks.joined(separator: " "))
        + "; middle is output frame \(mid)")
  }
  // Each place the video jumps over a cut, and the frame 0.5 s after it.
  for (i, m) in mapped.enumerated() where i > 0 ? abs(mapped[i - 1].end - m.start) > 0.001 : m.start > 0.001 {
    lines.append("cut before src \(fmtTime(m.start)): 0.5 s after it is output frame \(m.outStart + fps / 2)")
  }
  for s in plan.segments {
    for edge in [s.start, s.end] {
      if let w = project.words.first(where: { $0.start + 0.05 < edge && edge < $0.end - 0.05 }) {
        lines.append("cut edge at src \(fmtTime(edge)) splits the word \"\(w.text)\" (\(fmtTime(w.start))-\(fmtTime(w.end)))")
      }
    }
  }
  for f in flashes(plan, dir: project.dir) { lines.append("WARNING: \(describeFlash(f, plan))") }
  return lines.isEmpty ? "No zooms and no cuts inside words." : lines.joined(separator: "\n")
}

/// Source-time ranges an edit touched: clips and timed items (zooms, layouts, titles, annotations,
/// B-roll, animations, sound effects) that were added, removed or changed between two plans, merged
/// where they overlap. The timeline flashes these after an AI edit.
public func changedRanges(from old: Plan, to new: Plan) -> [(Double, Double)] {
  func diff<T: Equatable>(_ a: [T], _ b: [T], _ range: (T) -> (Double, Double)) -> [(Double, Double)] {
    a.filter { !b.contains($0) }.map(range) + b.filter { !a.contains($0) }.map(range)
  }
  let all =
    diff(old.segments, new.segments) { ($0.start, $0.end) } + diff(old.zooms, new.zooms) { ($0.start, $0.end) }
    + diff(old.layouts, new.layouts) { ($0.start, $0.end) } + diff(old.callouts, new.callouts) { ($0.start, $0.end) }
    + diff(old.annotations ?? [], new.annotations ?? []) { ($0.start, $0.end) }
    + diff(old.insertList, new.insertList) { ($0.start, $0.end) }
    + diff(old.animationList, new.animationList) { ($0.start, $0.end) } + diff(old.sfxList, new.sfxList) { ($0.t, $0.t) }
  var merged: [(Double, Double)] = []
  for r in all.sorted(by: { $0.0 < $1.0 }) {
    if let last = merged.last, r.0 <= last.1 {
      merged[merged.count - 1].1 = max(last.1, r.1)
    } else {
      merged.append(r)
    }
  }
  return merged
}
