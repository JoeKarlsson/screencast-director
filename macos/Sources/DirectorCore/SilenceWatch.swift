import Foundation

/// New Recording's mic check: whether the mic has gone quiet long enough to say so. A muted or
/// dead mic reads near -120 dBFS; a working one hears at least room noise, but a quiet room can
/// sit under the threshold too, so the message asks for speech rather than calling the mic broken.
public struct SilenceWatch: Sendable {
  /// Peaks under this count as silence.
  public static let quietDB = -55.0
  /// How long silence lasts before it's flagged.
  public static let seconds = 3.0

  private var lastHeard: Double

  /// `start`: when listening began, so a fresh mic gets the full grace period.
  public init(start: Double) { lastHeard = start }

  public mutating func hear(peakDB: Double, at t: Double) {
    if peakDB >= SilenceWatch.quietDB { lastHeard = t }
  }

  public func isSilent(at t: Double) -> Bool { t - lastHeard >= SilenceWatch.seconds }
}
