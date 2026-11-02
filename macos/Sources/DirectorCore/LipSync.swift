import AVFoundation
import Foundation
import Vision

/// Measures the camera offset from the footage itself: how far the lips are open on camera
/// against how loud the voice is in the recording's audio. The recorder's offset comes from the
/// first timestamps of each stream, which is off by however long the camera (or mic) holds a
/// frame before the Mac stamps it, a third of a second on some webcams.
public enum LipSync {
  public struct Result: Equatable {
    /// The measured `camera.offset` (camera time = screen time + offset).
    public var offset: Double
    /// Mean correlation at the best offset, about 0.1 to 0.3 when it's clear.
    public var strength: Double
    /// Windows whose own best offset is within 60 ms of the combined one.
    public var agreeing: Int
    public var windows: Int

    /// Clear enough to apply without asking: a real peak that at least two windows agree on.
    public var confident: Bool { strength >= 0.08 && agreeing >= 2 }
  }

  static let step = 0.02
  static let windowCount = 4
  static let windowLength = 30.0

  /// Searches `camera.offset` ± `search` seconds. Speech has a rhythm of a few syllables a second,
  /// so the correlation repeats about every 0.7 s; a wider search can lock onto the wrong beat.
  public static func measure(project: Project, camera: Plan.Camera, search: Double = 0.5) async throws -> Result? {
    let screen = AVURLAsset(url: project.dir.appendingPathComponent(project.source.video))
    let cam = AVURLAsset(url: project.dir.appendingPathComponent(camera.video))
    guard let audioTrack = try await screen.loadTracks(withMediaType: .audio).first,
      let camTrack = try await cam.loadTracks(withMediaType: .video).first
    else { return nil }
    let camDuration = try await cam.load(.duration).seconds
    let windows = speechWindows(words: project.words, duration: min(project.source.duration, camDuration - camera.offset))
    var mouth: [(Double, Double)] = []
    var voice: [(Double, Double)] = []
    for w in windows {
      try Task.checkCancellation()
      let lo = max(0, w.lowerBound + camera.offset - search - 0.6)
      let hi = min(camDuration, w.upperBound + camera.offset + search + 0.6)
      mouth += try mouthOpening(cam, track: camTrack, from: lo, to: hi)
      voice += try voiceLevel(screen, track: audioTrack, from: w.lowerBound, to: w.upperBound)
    }
    return bestOffset(mouth: mouth, voice: voice, windows: windows, around: camera.offset, search: search)
  }

  /// Up to four 30 s stretches with the most words, one from each quarter of the recording.
  static func speechWindows(words: [Word], duration: Double) -> [ClosedRange<Double>] {
    guard duration > 2 else { return [] }
    let part = duration / Double(windowCount)
    let length = min(windowLength, part)
    return (0..<windowCount).map { i in
      let a = Double(i) * part
      var best = a, bestCount = -1
      var s = a
      while s + length <= a + part + 1e-9 {
        let n = words.filter { $0.start >= s && $0.end <= s + length }.count
        if n > bestCount { (best, bestCount) = (s, n) }
        s += 5
      }
      return best...(best + length)
    }
  }

  /// Lip opening (inner lip height times face height, so it doesn't change with distance) about
  /// 30 times a second, on the camera file's clock. Frames without a face are left out.
  static func mouthOpening(_ asset: AVURLAsset, track: AVAssetTrack, from: Double, to: Double) throws -> [(Double, Double)] {
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
    let output = AVAssetReaderTrackOutput(
      track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    var out: [(Double, Double)] = []
    var next = from
    while let buf = output.copyNextSampleBuffer() {
      let t = CMSampleBufferGetPresentationTimeStamp(buf).seconds
      guard t >= next - 0.002, let px = CMSampleBufferGetImageBuffer(buf) else { continue }
      next = t + 1.0 / 30
      let request = VNDetectFaceLandmarksRequest()
      try? VNImageRequestHandler(cvPixelBuffer: px).perform([request])
      // The biggest face is the speaker.
      guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
        let lips = face.landmarks?.innerLips, lips.pointCount > 2
      else { continue }
      let ys = lips.normalizedPoints.map { Double($0.y) }
      out.append((t, (ys.max()! - ys.min()!) * Double(face.boundingBox.height)))
    }
    if reader.status == .failed, let err = reader.error { throw err }
    return out
  }

  /// Voice level (log RMS) in 20 ms bins starting at `from`, on the screen file's clock. Uses each
  /// buffer's timestamp, since the audio track can start a little after the video.
  static func voiceLevel(_ asset: AVURLAsset, track: AVAssetTrack, from: Double, to: Double) throws -> [(Double, Double)] {
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: max(0, from - 0.2), preferredTimescale: 600), end: CMTime(seconds: to + 0.2, preferredTimescale: 600))
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(output)
    reader.startReading()
    let bins = Int(((to - from) / step).rounded())
    var sums = [Double](repeating: 0, count: bins), counts = [Int](repeating: 0, count: bins)
    while let buf = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
      let start = CMSampleBufferGetPresentationTimeStamp(buf).seconds
      var length = 0
      var ptr: UnsafeMutablePointer<CChar>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
      guard let ptr else { continue }
      let samples = UnsafeRawPointer(ptr).assumingMemoryBound(to: Int16.self)
      for i in 0..<(length / 2) {
        let bin = Int(((start + Double(i) / 16000 - from) / step).rounded(.down))
        guard bin >= 0, bin < bins else { continue }
        let v = Double(samples[i]) / 32768
        sums[bin] += v * v
        counts[bin] += 1
      }
    }
    if reader.status == .failed, let err = reader.error { throw err }
    return (0..<bins).compactMap { i in
      counts[i] > 0 ? (from + Double(i) * step, log((sums[i] / Double(counts[i])).squareRoot() + 0.001)) : nil
    }
  }

  /// The offset where lip opening best follows voice level, searched in 20 ms steps around
  /// `around`. Each window is scored on its own, so one off window shows up as disagreement.
  public static func bestOffset(
    mouth: [(Double, Double)], voice: [(Double, Double)], windows: [ClosedRange<Double>], around: Double, search: Double
  ) -> Result? {
    let k = Int((search / step).rounded())
    var curves: [[Double]] = []
    for w in windows {
      let v = voice.filter { w.contains($0.0) }
      guard v.count > 100 else { continue }
      let t0 = v[0].0
      // Mouth samples on a grid that lines up with the voice grid at every lag.
      let m = mouth.filter { $0.0 >= t0 + around - search - 0.6 && $0.0 <= v.last!.0 + around + search + 0.6 }
      // Too few faces (looking away, off camera) to trust this window.
      guard Double(m.count) >= 0.6 * 30 * (v.last!.0 - t0 + 2 * search) else { continue }
      let grid = (0..<(v.count + 2 * k)).map { t0 + around - search + Double($0) * step }
      let mz = standardized(interpolate(m, at: grid))
      let vz = standardized(v.map(\.1))
      curves.append(
        (-k...k).map { lag in
          var sum = 0.0
          for i in vz.indices { sum += vz[i] * mz[i + lag + k] }
          return sum / Double(vz.count)
        })
    }
    guard !curves.isEmpty else { return nil }
    let mean = (0...(2 * k)).map { i in curves.map { $0[i] }.reduce(0, +) / Double(curves.count) }
    let peak = mean.indices.max { mean[$0] < mean[$1] }!
    // Parabolic fit through the peak and its neighbors for a finer offset than the 20 ms grid.
    var shift = 0.0
    if peak > 0, peak < mean.count - 1 {
      let (a, b, c) = (mean[peak - 1], mean[peak], mean[peak + 1])
      let denom = a - 2 * b + c
      if denom < 0 { shift = 0.5 * (a - c) / denom }
    }
    let agreeing = curves.filter { curve in abs(curve.indices.max { curve[$0] < curve[$1] }! - peak) <= 3 }.count
    // A peak at the edge of the search means the real one is outside it.
    let atEdge = peak == 0 || peak == mean.count - 1
    let offset = ((around + (Double(peak - k) + shift) * step) * 1000).rounded() / 1000
    return Result(offset: offset, strength: atEdge ? 0 : mean[peak], agreeing: agreeing, windows: curves.count)
  }

  /// Linear interpolation of time-sorted samples at `times` (held flat past the ends).
  static func interpolate(_ samples: [(Double, Double)], at times: [Double]) -> [Double] {
    guard let first = samples.first, let last = samples.last else { return times.map { _ in 0 } }
    var j = 0
    return times.map { t in
      if t <= first.0 { return first.1 }
      if t >= last.0 { return last.1 }
      while samples[j + 1].0 < t { j += 1 }
      let (a, b) = (samples[j], samples[j + 1])
      return a.1 + (b.1 - a.1) * (t - a.0) / max(b.0 - a.0, 1e-9)
    }
  }

  /// Takes out the slow drift (a 1 s moving average), then scales to mean 0 and spread 1.
  static func standardized(_ x: [Double]) -> [Double] {
    let half = 25
    var prefix = [0.0]
    for v in x { prefix.append(prefix.last! + v) }
    let detrended = x.indices.map { i -> Double in
      let a = max(0, i - half), b = min(x.count, i + half)
      return x[i] - (prefix[b] - prefix[a]) / Double(b - a)
    }
    let mean = detrended.reduce(0, +) / Double(max(detrended.count, 1))
    let sd = (detrended.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(detrended.count, 1))).squareRoot()
    return detrended.map { sd > 0 ? ($0 - mean) / sd : 0 }
  }
}
