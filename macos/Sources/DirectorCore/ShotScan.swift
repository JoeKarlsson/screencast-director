import AVFoundation
import Foundation

// Short shots in a finished video: anything on screen for under a second between two other shots,
// found from the pixels rather than the plan, so it catches what `flashes()` can't see (a punch-in
// sliver, a frame of B-roll left over). Frames are decoded small, consecutive frames compared, and a
// hard cut is a jump in difference that stands out from both neighbors.

public enum ShotScan {
  public struct ShortShot: Equatable {
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
    let (times, diffs) = try await frameDifferences(url)
    let cuts = cutTimes(times: times, diffs: diffs)
    return shortShots(cuts: cuts)
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

  /// Each frame's presentation time and its mean absolute difference from the frame before
  /// (0-1, over the BGR channels of the frame decoded `scanWidth` wide).
  static func frameDifferences(_ url: URL) async throws -> (times: [Double], diffs: [Double]) {
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
      swap(&prev, &cur)
    }
    if reader.status == .failed, let err = reader.error { throw err }
    return (times, diffs)
  }

  /// "short shot at 0:17.4 for 0.27 s"
  public static func describe(_ s: ShortShot) -> String {
    String(format: "short shot at %@ for %.2f s", fmtTime(s.start), s.length)
  }
}
