import Foundation

/// Whisper's word timings stretch across pauses: a word often "starts" in the silence before it
/// and "ends" in the silence after it. These helpers pull each word's edges in to where the
/// audio is actually loud, using the 50 ms loudness levels from `Analyzer.loudness`.
public enum WordTiming {
  /// The level below which a 50 ms sample counts as silence (same rule as `Analyzer.silences`).
  public static func silenceThreshold(_ levels: [(Double, Double)]) -> Double? {
    guard !levels.isEmpty else { return nil }
    let sorted = levels.map(\.1).sorted()
    return min(sorted[sorted.count / 10] + 12, -30)
  }

  /// Moves each word's start forward and end backward over silent samples, never past the
  /// word's midpoint, so the gaps between words match the real pauses.
  public static func refine(_ words: [Word], levels: [(Double, Double)]) -> [Word] {
    guard let threshold = silenceThreshold(levels), levels.count > 1 else { return words }
    let step = levels[1].0 - levels[0].0
    guard step > 0 else { return words }
    func db(at t: Double) -> Double {
      let i = Int((t - levels[0].0) / step)
      return i >= 0 && i < levels.count ? levels[i].1 : 0
    }
    return words.map { w in
      let mid = (w.start + w.end) / 2
      var s = w.start
      while s + step <= mid, db(at: s) < threshold { s += step }
      var e = w.end
      while e - step >= mid, db(at: e - step) < threshold { e -= step }
      return Word(text: w.text, start: (s * 1000).rounded() / 1000, end: (max(e, s + 0.01) * 1000).rounded() / 1000)
    }
  }

  /// Cached loudness levels for a project, if `loudness.json` exists.
  static func cachedLevels(_ dir: URL) -> [(Double, Double)]? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("loudness.json")),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
    else { return nil }
    return arr.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
  }
}
