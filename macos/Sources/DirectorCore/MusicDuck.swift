import AVFoundation
import Foundation

/// Background music levels: steady at `volumeDB`, dropping by `duckDB` while the voice is talking
/// (0.3 s down, 0.6 s back up), fading in over the first second and out over the last two.
public enum MusicDuck {
  public static let defaultVolumeDB = -14.0
  public static let defaultDuckDB = -18.0
  static let attack = 0.3
  static let release = 0.6
  static let fadeIn = 1.0
  static let fadeOut = 2.0

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

  public static func apply(_ music: Music, to p: AVMutableAudioMixInputParameters, speech: [(Double, Double)], total: Double) {
    let up = gain(music.volumeDB ?? defaultVolumeDB)
    let down = gain((music.volumeDB ?? defaultVolumeDB) + (music.duckDB ?? defaultDuckDB))
    func t(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 60000) }
    func ramp(_ from: Float, _ to: Float, _ a: Double, _ b: Double) {
      guard b > a else { return }
      p.setVolumeRamp(fromStartVolume: from, toEndVolume: to, timeRange: CMTimeRange(start: t(a), end: t(b)))
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
  }
}
