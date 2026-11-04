import CoreGraphics
import Foundation

/// The part of a vertical video that TikTok, Instagram Reels and YouTube Shorts leave uncovered. Their
/// tabs and search sit over the top, the caption, sound and progress bar over the bottom, the like,
/// comment and share buttons down the right. Fractions of the frame, the union of all three apps, so
/// one export works everywhere. Every title, chip, caption and logo in a vertical video is kept inside
/// it (`Scene.animated`, the watermark), and animations start their content below its top.
public enum SafeArea {
  public static let top = 0.12
  public static let bottom = 0.22
  public static let left = 0.06
  public static let right = 0.12

  /// The uncovered area of a vertical video's frame (top-left coordinates, output pixels), or nil
  /// for landscape and square videos, which the apps don't cover.
  public static func rect(_ plan: Plan) -> CGRect? {
    guard socialTop(plan) != nil else { return nil }
    let W = Double(plan.output.width), H = Double(plan.output.height)
    return CGRect(x: W * left, y: H * top, width: W * (1 - left - right), height: H * (1 - top - bottom))
  }

  /// How far to move `r` (top-left coordinates) so it sits inside the safe area: zero when it
  /// already does or the video isn't vertical. Something bigger than the area is lined up with
  /// its top or left edge.
  public static func shift(_ r: CGRect, plan: Plan) -> CGSize {
    guard let safe = rect(plan) else { return .zero }
    func axis(_ lo: Double, _ hi: Double, _ safeLo: Double, _ safeHi: Double) -> Double {
      if hi - lo > safeHi - safeLo { return safeLo - lo }
      if lo < safeLo { return safeLo - lo }
      if hi > safeHi { return safeHi - hi }
      return 0
    }
    return CGSize(width: axis(r.minX, r.maxX, safe.minX, safe.maxX), height: axis(r.minY, r.maxY, safe.minY, safe.maxY))
  }
}
