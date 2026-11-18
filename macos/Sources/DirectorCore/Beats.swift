import Foundation

/// Beats and tempo of a music track from signal processing alone (ported from HyperFrames, Apache 2.0):
/// a log-band spectral-flux onset curve, an autocorrelation tempo with a log-normal prior around
/// 120 BPM, and Ellis's (2007) dynamic-programming beat placement.
public enum Beats: Sendable {
  public struct Result: Equatable, Sendable {
    /// Seconds into the signal; empty when there's no steady beat, with `reason` saying why.
    public var times: [Double]
    /// 0-1: how clearly the onsets repeat at the beat period, scaled by how much stronger they are on the beats.
    public var confidence: Double
    public var reason: String?
    /// Beats per minute from the steady gap between beats; nil without beats.
    public var bpm: Double? {
      let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
      guard !gaps.isEmpty else { return nil }
      let median = gaps[gaps.count / 2]
      let near = gaps.filter { abs($0 - median) <= 0.1 * median }
      return (600 / (near.reduce(0, +) / Double(near.count))).rounded() / 10
    }
  }

  static let fps = 100.0
  static let frameSize = 1024
  static let slowestBPM = 40.0, fastestBPM = 240.0
  static let tightness = 100.0
  /// The onset curve peaks this much ahead of where listeners place the beat.
  static let onsetLag = 0.015
  /// Two bars of 4/4 at 80 BPM: anything shorter has too few beats to call steady.
  static let shortestSeconds = 6.0
  /// Below this the beats are more likely the tracker's own grid than the music's.
  static let steadyConfidence = 0.15

  /// Beats of `samples` (mono at `rate` Hz).
  public static func track(_ samples: [Float], rate: Double) throws -> Result {
    let curve = try onsets(samples, rate: rate)
    let (period, clarity) = beatPeriod(curve, range: lagRange)
    guard Double(curve.count) >= shortestSeconds * fps else { return Result(times: [], confidence: 0, reason: "too short for a steady beat") }
    guard curve.contains(where: { $0 > 0 }), Double(curve.count) >= 2 * period else { return Result(times: [], confidence: 0, reason: "no steady beat") }
    let local = smoothed(curve, period: period)
    let beats = trimmed(placeBeats(local, periodAt: localPeriods(curve, period: period)), local)
    let overall = local.reduce(0, +) / Double(max(1, local.count))
    let onBeats = beats.reduce(0) { $0 + local[$1] } / Double(max(1, beats.count))
    let lift = overall > 0 ? onBeats / overall - 1 : 0
    let confidence = (max(0, min(1, clarity)) * max(0, min(1, lift / 3)) * 1000).rounded() / 1000
    guard beats.count >= 4, confidence >= steadyConfidence else { return Result(times: [], confidence: confidence, reason: "no steady beat") }
    return Result(times: beats.map { ((Double($0) / fps + onsetLag) * 1000).rounded() / 1000 }, confidence: confidence)
  }

  /// The rectified rise in log power summed over fifth-octave bands, 100 times a second, minus its
  /// local mean (±0.4 s) and scaled to unit spread.
  static func onsets(_ samples: [Float], rate: Double) throws -> [Double] {
    let spectrum = try AudioSpectrum(size: frameSize)
    let binHz = rate / Double(frameSize), nyquistBin = frameSize / 2
    var edges: [Int] = []
    var hz = 30.0
    while hz < 9000 {
      edges.append(min(nyquistBin, max(1, Int((hz / binHz).rounded()))))
      hz *= pow(2, 1.0 / 5)
    }
    let hop = rate / fps
    var bands: [[Double]] = []
    var f = 0
    while Int((Double(f) * hop).rounded()) < samples.count {
      let power = spectrum.power(samples, start: Int((Double(f) * hop).rounded()) - frameSize / 2)
      bands.append(zip(edges, edges.dropFirst()).map { a, b in
        let end = max(a + 1, b)
        let p = (a..<end).reduce(0.0) { $0 + Double(power[$1]) } / Double(frameSize * frameSize * (end - a))
        return log1p(1e9 * p)
      })
      f += 1
    }
    var broad = [Double](repeating: 0, count: bands.count)
    for i in bands.indices.dropFirst() {
      broad[i] = zip(bands[i], bands[i - 1]).reduce(0) { $0 + max(0, $1.0 - $1.1) }
    }
    // Keep only what rises above the surrounding mean.
    let radius = Int((0.4 * fps).rounded())
    var sums = [Double](repeating: 0, count: broad.count + 1)
    for i in broad.indices { sums[i + 1] = sums[i] + broad[i] }
    let above = broad.indices.map { i -> Double in
      let a = max(0, i - radius), b = min(broad.count, i + radius + 1)
      return max(0, broad[i] - (sums[b] - sums[a]) / Double(b - a))
    }
    let mean = above.reduce(0, +) / Double(max(1, above.count))
    let spread = (above.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, above.count))).squareRoot()
    return above.map { spread > 0 ? $0 / spread : 0 }
  }

  static var lagRange: ClosedRange<Int> { max(1, Int(60 / fastestBPM * fps))...Int((60 / slowestBPM * fps).rounded(.up)) }

  /// The beat period in frames: prior-weighted autocorrelation plus half its value at twice the lag,
  /// refined between lags; `clarity` is the autocorrelation there.
  static func beatPeriod<C: RandomAccessCollection>(_ curve: C, range: ClosedRange<Int>) -> (period: Double, clarity: Double)
  where C.Element == Double, C.Index == Int {
    let values = Array(curve)
    let maxLag = 2 * range.upperBound + 1
    let mean = values.reduce(0, +) / Double(max(1, values.count))
    let centred = values.map { $0 - mean }
    var ac = [Double](repeating: 0, count: maxLag + 1)
    for lag in 0...maxLag where lag < centred.count {
      var sum = 0.0
      for i in lag..<centred.count { sum += centred[i] * centred[i - lag] }
      ac[lag] = sum
    }
    let zero = ac[0] == 0 ? 1 : ac[0]
    ac = ac.map { $0 / zero }
    func at(_ lag: Int) -> Double { ac[min(ac.count - 1, max(0, lag))] }
    func prior(_ lag: Int) -> Double { exp(-0.5 * pow(log2(60 / (Double(lag) / fps) / 120) / 0.8, 2)) }
    func score(_ lag: Int) -> Double { prior(lag) * (at(lag) + 0.5 * at(2 * lag) + 0.25 * (at(2 * lag - 1) + at(2 * lag + 1))) }
    let best = range.max { score($0) < score($1) } ?? range.lowerBound
    let (a, b, c) = (score(best - 1), score(best), score(best + 1))
    let curvature = a - 2 * b + c
    let shift = curvature != 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / curvature)) : 0
    return (Double(best) + shift, max(0, min(1, at(best))))
  }

  /// The onset curve smoothed by a Gaussian a thirty-second of a beat wide.
  static func smoothed(_ curve: [Double], period: Double) -> [Double] {
    let half = max(1, Int((period / 8).rounded()))
    let kernel = (0...2 * half).map { exp(-0.5 * pow(Double($0 - half) * 32 / period, 2)) }
    return curve.indices.map { i in
      kernel.indices.reduce(0.0) { sum, j in
        let k = i + j - half
        return sum + (k >= 0 && k < curve.count ? kernel[j] * curve[k] : 0)
      }
    }
  }

  /// The period through the piece: eight-second windows a second apart, held within 10% of the
  /// global period, median-smoothed, interpolated between window centres.
  static func localPeriods(_ curve: [Double], period: Double) -> (Int) -> Double {
    let window = Int(8 * fps), hop = Int(fps)
    let full = lagRange
    let lo = max(full.lowerBound, Int(period * 0.9))
    let range = lo...max(lo, min(full.upperBound, Int((period * 1.1).rounded(.up))))
    var centres: [Double] = [], periods: [Double] = []
    var start = 0
    repeat {
      let end = min(curve.count, start + window)
      periods.append(beatPeriod(curve[start..<end], range: range).period)
      centres.append(Double(start + end) / 2)
      start += hop
    } while start + window <= curve.count
    let medians = periods.indices.map { i -> Double in
      let near = periods[max(0, i - 2)..<min(periods.count, i + 3)].sorted()
      return near[near.count / 2]
    }
    return { frame in
      let x = Double(frame)
      guard x > centres[0] else { return medians[0] }
      for i in 1..<centres.count where x <= centres[i] {
        let u = (x - centres[i - 1]) / (centres[i] - centres[i - 1])
        return medians[i - 1] * (1 - u) + medians[i] * u
      }
      return medians[medians.count - 1]
    }
  }

  /// Ellis's recursion: each frame's best score from a predecessor about one period back, penalized by
  /// log deviation; then back-tracked from the last strong maximum.
  static func placeBeats(_ local: [Double], periodAt: (Int) -> Double) -> [Int] {
    var score = [Double](repeating: 0, count: local.count)
    var back = [Int](repeating: -1, count: local.count)
    for i in local.indices {
      let period = periodAt(i)
      var best = -Double.infinity, from = -1
      let lo = max(0, Int((Double(i) - 2 * period).rounded())), hi = i - Int((period / 2).rounded())
      if lo <= hi {
        for j in lo...hi {
          let candidate = score[j] - tightness * pow(log(Double(i - j) / period), 2)
          if candidate > best { (best, from) = (candidate, j) }
        }
      }
      score[i] = local[i] + max(0, best)
      back[i] = best > 0 ? from : -1
    }
    // The last local maximum reaching half the median maximum.
    let maxima = score.indices.dropFirst().dropLast().filter { score[$0] > score[$0 - 1] && score[$0] >= score[$0 + 1] }
    var last = score.count - 1
    if !maxima.isEmpty {
      let median = maxima.map { score[$0] }.sorted()[maxima.count / 2]
      last = maxima.last { score[$0] >= 0.5 * median } ?? maxima[maxima.count - 1]
    }
    var beats: [Int] = []
    var i = last
    while i >= 0 {
      beats.append(i)
      i = back[i]
    }
    return beats.reversed()
  }

  /// Drops beats at either end whose onset strength is under half the RMS of the beats' strengths.
  static func trimmed(_ beats: [Int], _ local: [Double]) -> [Int] {
    let rms = (beats.reduce(0) { $0 + local[$1] * local[$1] } / Double(max(1, beats.count))).squareRoot()
    var first = 0, end = beats.count
    while first < end && local[beats[first]] < 0.5 * rms { first += 1 }
    while end > first && local[beats[end - 1]] < 0.5 * rms { end -= 1 }
    return Array(beats[first..<end])
  }

  /// The music's beats in output seconds: the track starts with the video and loops (like
  /// `addMusic`), so each pass's beats repeat; beats in `music.off` or past the end are dropped.
  public static func output(_ beats: [Double], trackLength: Double, total: Double, off: [(Double, Double)]) -> [Double] {
    guard trackLength > 0.1 else { return [] }
    var out: [Double] = []
    var pass = 0.0
    while pass < total {
      out += beats.map { $0 + pass }.filter { t in t < total && !off.contains { t >= $0.0 && t <= $0.1 } }
      pass += trackLength
    }
    return out
  }
}
