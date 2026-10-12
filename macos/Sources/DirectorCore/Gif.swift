import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Animated GIFs of the edited video, for docs and READMEs: frames come from the same
/// compositor as preview and export, scaled down and encoded with ImageIO.
public enum GIF {
  public struct Options {
    /// Output seconds; nil means the start or end of the video.
    public var from: Double?
    public var to: Double?
    /// Pixel width, capped at the video's own width (height follows the aspect).
    public var width: Int
    public var fps: Int
    public init(from: Double? = nil, to: Double? = nil, width: Int = 720, fps: Int = 12) {
      self.from = from
      self.to = to
      self.width = width
      self.fps = fps
    }
  }

  /// Writes the GIF and returns how many frames it has. `progress` gets 0...1.
  @discardableResult
  public static func export(
    _ built: BuiltComposition, to url: URL, options o: Options = Options(), progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> Int {
    let scene = built.scene
    let length = Double(scene.frameCount) / Double(scene.fps)
    let a = max(0, min(o.from ?? 0, length)), b = max(a, min(o.to ?? length, length))
    let fps = max(1, min(o.fps, 30))
    let count = max(1, Int(((b - a) * Double(fps)).rounded()))
    let w = Double(min(o.width, scene.plan.output.width))
    let h = (w * Double(scene.plan.output.height) / Double(scene.plan.output.width) / 2).rounded() * 2

    let gen = AVAssetImageGenerator(asset: built.asset)
    gen.videoComposition = built.videoComposition
    gen.maximumSize = CGSize(width: w, height: h)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    // Snap each GIF frame to a video frame so the compositor renders exactly that frame.
    let times = (0..<count).map { i -> CMTime in
      let frame = Int(((a + Double(i) / Double(fps)) * Double(scene.fps)).rounded())
      return CMTime(value: CMTimeValue(min(frame, scene.frameCount - 1)), timescale: CMTimeScale(scene.fps))
    }

    try? FileManager.default.removeItem(at: url)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
      throw NSError(domain: "GIF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't write \(url.path)"])
    }
    CGImageDestinationSetProperties(
      dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false]] as CFDictionary)
    // GIF delays are whole hundredths of a second, so 1/12 s can't be stored. Alternate 8 and 9
    // hundredths (and so on) so the running time stays exact.
    func frameProps(_ i: Int) -> CFDictionary {
      let cs = (Double(i + 1) * 100 / Double(fps)).rounded() - (Double(i) * 100 / Double(fps)).rounded()
      return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: cs / 100, kCGImagePropertyGIFUnclampedDelayTime: cs / 100]]
        as CFDictionary
    }
    var done = 0
    for await result in gen.images(for: times) {
      try Task.checkCancellation()
      // The generator delivers in request order; a gap would mean a dropped frame.
      guard result.requestedTime == times[done] else {
        throw NSError(domain: "GIF", code: 3, userInfo: [NSLocalizedDescriptionKey: "Frames arrived out of order"])
      }
      CGImageDestinationAddImage(dest, try result.image, frameProps(done))
      done += 1
      progress?(Double(done) / Double(count))
    }
    guard CGImageDestinationFinalize(dest) else {
      throw NSError(domain: "GIF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't finish \(url.lastPathComponent)"])
    }
    return done
  }
}
