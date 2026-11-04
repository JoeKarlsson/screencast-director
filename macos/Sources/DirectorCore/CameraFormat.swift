import Foundation

/// Which of a camera's capture formats to record in, and at what bitrate. Kept apart from
/// AVFoundation so test.sh can check the choice.
public enum CameraFormat {
  public struct Option: Equatable {
    public var width: Int
    public var height: Int
    public var maxFPS: Double
    public init(width: Int, height: Int, maxFPS: Double) {
      self.width = width
      self.height = height
      self.maxFPS = maxFPS
    }
    var pixels: Int { width * height }
  }

  /// Largest size recorded: 4K UHD. Bigger formats (6K, 8K) cost far more to decode for no gain in a
  /// 4K export.
  public static let maxPixels = 3840 * 2160

  /// The index of the format to record in: the most pixels up to 4K that still runs at 30 fps,
  /// then the higher frame rate. nil when no format runs at 30 fps (the caller keeps the default).
  public static func best(_ options: [Option]) -> Int? {
    options.indices
      .filter { options[$0].maxFPS >= 29.9 && options[$0].pixels <= maxPixels }
      .max { a, b in
        let (x, y) = (options[a], options[b])
        return x.pixels != y.pixels ? x.pixels < y.pixels : x.maxFPS < y.maxFPS
      }
  }

  /// H.264 bitrate for a camera recording this size: 12 Mbps at 1080p, rising with the pixel count
  /// to 40 Mbps at 4K, so a sharper camera isn't squeezed back down by the encoder.
  public static func bitrate(width: Int, height: Int) -> Int {
    max(12_000_000, Int(Double(width * height) / Double(1920 * 1080) * 10_000_000))
  }
}
