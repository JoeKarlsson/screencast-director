import Foundation

// Pause levels, and re-cutting a plan's silences at another level without bringing back cut words.

/// How hard to cut silence. Gentle keeps natural pauses; tight leaves almost none.
public enum PauseLevel: String, CaseIterable, Codable, Sendable {
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
      if var last = joined.last, s.repeats != true, last.repeats != true, s.start >= last.end - 1e-6, s.start - last.end < 6, wasPause(last.end, s.start), last.speed == 1,
        s.speed == 1,
        !paused.contains(where: { $0.0 < s.start && $0.1 > last.end }) {
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
