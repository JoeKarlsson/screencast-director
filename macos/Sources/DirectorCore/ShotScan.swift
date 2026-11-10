import AVFoundation
import Foundation

// Short shots in a finished video: anything on screen for under a second between two other shots,
// found from the pixels rather than the plan, so it catches what `flashes()` can't see (a punch-in
// sliver, a frame of B-roll left over). Frames are decoded small, consecutive frames compared, and a
// hard cut is a jump in difference that stands out from both neighbors.

public enum ShotScan: Sendable {
  public struct ShortShot: Equatable, Sendable {
    /// Output seconds.
    public var start: Double
    public var end: Double
    public var length: Double { end - start }
  }

  /// A cut needs the frame to differ from the one before by `cutThreshold` (mean over pixels and
  /// channels, as a share of full range), and by `cutJump` more than the smaller of its neighbors'
  /// differences. Measured on a real export: cuts between shots of the same face (a punch-in ending,
  /// a jump cut) were 0.12-0.2, while talking and hand moves peaked near 0.1 and change gradually, so
  /// their neighbors differ about as much and don't count.
  public static let cutThreshold = 0.1
  public static let cutJump = 0.07
  /// Shots shorter than this between two others are reported.
  public static let shortShot = 1.0
  /// Frames are decoded this wide (height keeps the aspect), which keeps a 4K scan fast.
  static let scanWidth = 64

  /// Shots under `shortShot` seconds with another shot on both sides, in output seconds.
  public static func shortShots(in url: URL) async throws -> [ShortShot] {
    let (times, diffs, _) = try await frameDifferences(url)
    let cuts = cutTimes(times: times, diffs: diffs)
    return shortShots(cuts: cuts)
  }

  /// Everything `director scan` finds in a finished video.
  public struct Report: Sendable {
    public var shortShots: [ShortShot]
    /// Output seconds of frames that repeat the one before while the picture around them moves:
    /// a hitch in a zoom, pan or animation.
    public var hitches: [Double]
    /// Black stretches (output seconds) after the first second and before the last.
    public var black: [ShortShot]
  }

  public static func scan(_ url: URL) async throws -> Report {
    let (times, diffs, levels) = try await frameDifferences(url)
    return Report(
      shortShots: shortShots(cuts: cutTimes(times: times, diffs: diffs)), hitches: hitches(times: times, diffs: diffs),
      black: blackStretches(times: times, levels: levels))
  }

  /// A frame counts as repeated under `stillDiff`, and the picture as moving when both neighbors
  /// differ by `movingDiff` or more (a slow zoom on a 64-wide frame is about 0.01 a frame).
  public static let stillDiff = 0.0015
  public static let movingDiff = 0.008

  /// Animations step on twos and threes (12 fps in a 30 fps video): when this share of the frames
  /// around a repeat repeat too, it's that look, not a hitch. A 25 fps camera in a 30 fps video
  /// repeats one frame in six, well under it.
  public static let steppedShare = 0.4

  /// Frames that repeat the one before while the frames on both sides of them move, outside
  /// stretches that step on purpose (`steppedShare` of the second around them repeating).
  static func hitches(times: [Double], diffs: [Double]) -> [Double] {
    guard diffs.count > 2, let first = times.first, let last = times.last else { return [] }
    let fps = Double(times.count - 1) / max(last - first, 1e-6)
    let half = max(1, Int((fps / 2).rounded()))
    var out: [Double] = []
    for i in 1..<(diffs.count - 1) where diffs[i] < stillDiff && diffs[i - 1] >= movingDiff && diffs[i + 1] >= movingDiff {
      let window = max(0, i - half)...min(diffs.count - 1, i + half)
      let still = window.filter { diffs[$0] < stillDiff }.count
      if Double(still) < steppedShare * Double(window.count) { out.append(times[i]) }
    }
    return out
  }

  /// A frame darker than this (mean level, 0-1) is black.
  public static let blackLevel = 0.03

  /// Runs of black frames, leaving out the first and last second (a fade from or to black there is a choice).
  static func blackStretches(times: [Double], levels: [Double]) -> [ShortShot] {
    guard let end = times.last else { return [] }
    var out: [ShortShot] = []
    var start: Double?
    for (t, l) in zip(times, levels) {
      let black = l < blackLevel && t >= 1 && t <= end - 1
      if black, start == nil { start = t }
      if !black, let s = start {
        out.append(ShortShot(start: s, end: t))
        start = nil
      }
    }
    if let s = start { out.append(ShortShot(start: s, end: end)) }
    return out
  }

  /// The shots between consecutive cuts that are under `shortShot` (the first shot starts at the
  /// video's start and the last ends at its end, so neither is between two others).
  static func shortShots(cuts: [Double]) -> [ShortShot] {
    guard cuts.count >= 2 else { return [] }
    return zip(cuts, cuts.dropFirst()).compactMap { a, b in b - a < shortShot ? ShortShot(start: a, end: b) : nil }
  }

  /// Times of the frames that start a new shot. `diffs[i]` is frame i's difference from frame i-1
  /// (0 for the first frame), as a share of full range.
  static func cutTimes(times: [Double], diffs: [Double]) -> [Double] {
    var cuts: [Double] = []
    for i in diffs.indices.dropFirst() {
      let d = diffs[i]
      let before = diffs[i - 1]
      let after = i + 1 < diffs.count ? diffs[i + 1] : 0
      // Comparing with the smaller neighbor keeps both edges of a one-frame shot (each edge's other
      // neighbor is still).
      if d >= cutThreshold && d - min(before, after) >= cutJump { cuts.append(times[i]) }
    }
    return cuts
  }

  /// Each frame's presentation time, its mean absolute difference from the frame before and its
  /// mean level (both 0-1, over the BGR channels of the frame decoded `scanWidth` wide).
  static func frameDifferences(_ url: URL) async throws -> (times: [Double], diffs: [Double], levels: [Double]) {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalyzerError.noVideoTrack }
    let size = try await track.load(.naturalSize)
    let w = scanWidth
    let h = max(2, Int((Double(w) * abs(size.height) / max(1, abs(size.width))).rounded()) / 2 * 2)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
        kCVPixelBufferHeightKey as String: h,
      ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? AnalyzerError.noVideoTrack }

    var times: [Double] = []
    var diffs: [Double] = []
    var levels: [Double] = []
    var prev: [UInt8] = []
    var cur: [UInt8] = []
    while let buf = output.copyNextSampleBuffer() {
      guard let px = CMSampleBufferGetImageBuffer(buf) else { continue }
      CVPixelBufferLockBaseAddress(px, .readOnly)
      let pw = CVPixelBufferGetWidth(px), ph = CVPixelBufferGetHeight(px)
      let stride = CVPixelBufferGetBytesPerRow(px)
      let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
      cur.removeAll(keepingCapacity: true)
      for y in 0..<ph {
        let row = base + y * stride
        for x in 0..<pw {
          cur.append(row[x * 4])
          cur.append(row[x * 4 + 1])
          cur.append(row[x * 4 + 2])
        }
      }
      CVPixelBufferUnlockBaseAddress(px, .readOnly)
      var d = 0.0
      if prev.count == cur.count, !cur.isEmpty {
        var sum = 0
        for i in cur.indices { sum += abs(Int(cur[i]) - Int(prev[i])) }
        d = Double(sum) / Double(cur.count) / 255
      }
      times.append(CMSampleBufferGetPresentationTimeStamp(buf).seconds)
      diffs.append(d)
      levels.append(cur.isEmpty ? 0 : Double(cur.reduce(0) { $0 + Int($1) }) / Double(cur.count) / 255)
      swap(&prev, &cur)
    }
    if reader.status == .failed, let err = reader.error { throw err }
    return (times, diffs, levels)
  }

  /// "short shot at 0:17.4 for 0.27 s"
  public static func describe(_ s: ShortShot) -> String {
    String(format: "short shot at %@ for %.2f s", fmtTime(s.start), s.length)
  }
}
