import AVFoundation
import Foundation

/// Background music levels: steady at `volumeDB`, dropping by `duckDB` while the voice is talking
/// (0.3 s down, 0.6 s back up), silent through `music.off` (the same ramps, down to nothing), starting
/// and stopping with the video (a 0.15 s ramp, no long fades).
public enum MusicDuck: Sendable {
  public static let defaultVolumeDB = -14.0
  public static let defaultDuckDB = -18.0
  static let attack = 0.3
  static let release = 0.6
  // Just enough to start and stop without a pop: a long fade at the end reads as the video trailing off.
  static let fadeIn = 0.15
  static let fadeOut = 0.15

  /// Output-time spans where the voice is above the silence threshold. Sped-up clips are muted, so
  /// they don't count as talking.
  public static func speech(levels: [(Double, Double)], mapped: [MappedSegment], fps: Int) -> [(Double, Double)] {
    guard levels.count > 1 else { return [] }
    let threshold = Analyzer.silenceThreshold(levels)
    let step = levels[1].0 - levels[0].0
    var source: [(Double, Double)] = []
    for (t, db) in levels where db > threshold {
      if let last = source.last, t - last.1 < 0.25 {
        source[source.count - 1].1 = t + step
      } else {
        source.append((t, t + step))
      }
    }
    let fps = Double(fps)
    var out: [(Double, Double)] = []
    for s in mapped where s.speed <= 1.01 {
      for (a, b) in source where b > s.start && a < s.end {
        let o = Double(s.outStart) / fps
        out.append((o + (max(a, s.start) - s.start) / s.speed, o + (min(b, s.end) - s.start) / s.speed))
      }
    }
    out.sort { $0.0 < $1.0 }
    // Gaps shorter than a full down-and-up would only make the music bob; stay ducked through them.
    var merged: [(Double, Double)] = []
    for span in out {
      if let last = merged.last, span.0 - last.1 < attack + release {
        merged[merged.count - 1].1 = max(last.1, span.1)
      } else {
        merged.append(span)
      }
    }
    return merged
  }

  static func gain(_ db: Double) -> Float { Float(pow(10, db / 20)) }

  /// Output-time spans with the music off: `music.off` (source seconds) mapped through the edit, cut
  /// parts dropped. Spans closer than a fade out and back in join, so the music doesn't blip between.
  public static func offSpans(_ music: Music, mapped: [MappedSegment], fps: Int) -> [(Double, Double)] {
    let f = Double(fps)
    let pieces = (music.off ?? []).flatMap { r in srcRangeToOut(mapped, r.start, r.end, fps: fps).map { ($0.startF / f, $0.endF / f) } }
    var merged: [(Double, Double)] = []
    for span in pieces.sorted(by: { $0.0 < $1.0 }) {
      if let last = merged.last, span.0 - last.1 < attack + release {
        merged[merged.count - 1].1 = max(last.1, span.1)
      } else {
        merged.append(span)
      }
    }
    return merged
  }

  /// `points` (volume over output time, linear between) silenced inside each `off` span: down over
  /// the `attack` before it and back up over the `release` after, like ducking all the way.
  static func silenced(_ points: [(Double, Float)], off: [(Double, Double)], total: Double) -> [(Double, Float)] {
    func level(_ t: Double) -> Float {
      guard let i = points.lastIndex(where: { $0.0 <= t }) else { return points.first?.1 ?? 0 }
      guard i + 1 < points.count else { return points[i].1 }
      let (a, b) = (points[i], points[i + 1])
      return a.1 + (b.1 - a.1) * Float((t - a.0) / (b.0 - a.0))
    }
    func open(_ t: Double) -> Float {
      let shares = off.map { a, b in t <= a - attack ? 1 : t < a ? (a - t) / attack : t <= b ? 0 : t < b + release ? (t - b) / release : 1 }
      return Float(shares.min() ?? 1)
    }
    let knots = Set(points.map(\.0) + off.flatMap { [$0.0 - attack, $0.0, $0.1, $0.1 + release] }).filter { (0...total).contains($0) }
    return knots.sorted().map { ($0, level($0) * open($0)) }
  }

  /// Sets the music's volume ramps: ducked under `speech`, silent in `off` (output seconds, `offSpans`).
  public static func apply(
    _ music: Music, to p: AVMutableAudioMixInputParameters, speech: [(Double, Double)], off: [(Double, Double)] = [], total: Double
  ) {
    let up = gain(music.volumeDB ?? defaultVolumeDB)
    let down = gain((music.volumeDB ?? defaultVolumeDB) + (music.duckDB ?? defaultDuckDB))
    func t(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 60000) }
    // The ducked level as points; a ramp runs between each pair that differ.
    var points: [(Double, Float)] = []
    func ramp(_ from: Float, _ to: Float, _ a: Double, _ b: Double) {
      guard b > a else { return }
      points += [(a, from), (b, to)]
    }
    let fadeStart = max(0, total - fadeOut)
    // Talking right at the start: fade in to the ducked level instead.
    let startsDucked = speech.first.map { $0.0 < fadeIn + attack } ?? false
    var level = startsDucked ? down : up
    var cursor = min(fadeIn, fadeStart)
    ramp(0, level, 0, cursor)
    for (a, b) in speech {
      if b <= cursor { continue }
      if level == up {
        let start = max(cursor, a - attack)
        if start >= fadeStart { break }
        ramp(up, down, start, min(a, fadeStart))
        cursor = min(a, fadeStart)
        level = down
      }
      if b + release > fadeStart {
        // Still talking when the music fades out: fade from the ducked level.
        break
      }
      ramp(down, up, b, b + release)
      cursor = b + release
      level = up
    }
    ramp(level, 0, fadeStart, total)
    if !off.isEmpty { points = silenced(points, off: off, total: total) }
    for (a, b) in zip(points, points.dropFirst()) where b.0 > a.0 && a.1 != b.1 {
      p.setVolumeRamp(fromStartVolume: a.1, toEndVolume: b.1, timeRange: CMTimeRange(start: t(a.0), end: t(b.0)))
    }
  }
}
