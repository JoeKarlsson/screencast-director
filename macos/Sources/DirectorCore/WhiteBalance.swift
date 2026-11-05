import CoreImage
import Foundation

/// The pre-recording white balance check: how far a camera frame's neutrals lean warm/cool and
/// green/magenta, and the camera `Grade.warmth` that would neutralize it in the edit.
public enum WhiteBalance: Sendable {
  public struct Reading: Equatable, Sendable {
    /// The `Grade.warmth` that makes the frame's neutrals neutral: negative when the picture runs
    /// warm (it needs cooling), positive when it runs cool.
    public let fixWarmth: Double
    /// Green/magenta lean of the neutrals after that fix: positive = green, negative = magenta.
    public let tint: Double

    /// Within these the picture reads as neutral.
    public static let warmthTolerance = 0.1
    public static let tintTolerance = 0.05

    public var isNeutral: Bool { abs(fixWarmth) <= Reading.warmthTolerance && abs(tint) <= Reading.tintTolerance }

    /// What the reading means and how to get to neutral. A warm or colored look can be on purpose,
    /// so it says what to change for neutral rather than calling it wrong.
    public var advice: String {
      var lines: [String] = []
      if fixWarmth < -Reading.warmthTolerance {
        lines.append("Runs warm (orange). For neutral, set the camera's white balance cooler or use 5600 K light.")
      } else if fixWarmth > Reading.warmthTolerance {
        lines.append("Runs cool (blue). For neutral, set the camera's white balance warmer or use 3200-4000 K light.")
      }
      if tint > Reading.tintTolerance {
        lines.append("Leans green (fluorescent or cheap LED). Add magenta tint in the camera's app.")
      } else if tint < -Reading.tintTolerance {
        lines.append("Leans magenta. Add green tint in the camera's app.")
      }
      guard !lines.isEmpty else { return "Looks neutral." }
      if abs(fixWarmth) >= 1 {
        lines.append("Too strong for Warmth to fully undo in the edit.")
      } else if abs(fixWarmth) > Reading.warmthTolerance {
        lines.append(String(format: "Warmth %+.2f in the edit neutralizes it.", fixWarmth))
      }
      return lines.joined(separator: " ")
    }
  }

  /// Reads a camera frame. Nil when the frame is too dark or blown out to have neutrals to judge.
  public static func measure(_ frame: CIImage) -> Reading? {
    guard let neutral = neutralColor(frame) else { return nil }
    // Search the renderer's own warmth control for the value that balances red against blue, so
    // the suggested fix is exactly what `Scene.graded` will do.
    var best = (w: 0.0, error: Double.infinity, rgb: neutral)
    for step in -50...50 {
      let w = Double(step) / 50
      let rgb = graded(neutral, warmth: w)
      let error = abs(log(rgb[0] / rgb[2]))
      if error < best.error { best = (w, error, rgb) }
    }
    let rgb = best.rgb
    return Reading(fixWarmth: best.w, tint: log(rgb[1] / ((rgb[0] + rgb[2]) / 2)))
  }

  /// The linear RGB average of the frame's least saturated pixels that are neither near black nor
  /// clipped: walls, shirts and desks rather than skin, which is warm under any light.
  static func neutralColor(_ frame: CIImage) -> [Double]? {
    let w = 96, h = 54
    let e = frame.extent
    guard e.width > 0, e.height > 0, !e.isInfinite else { return nil }
    let small = frame.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
      .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
    var px = [Float](repeating: 0, count: w * h * 4)
    context.render(
      small, toBitmap: &px, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
      colorSpace: linear)
    var candidates: [(saturation: Double, rgb: [Double])] = []
    for i in 0..<(w * h) {
      let rgb = [Double(px[i * 4]), Double(px[i * 4 + 1]), Double(px[i * 4 + 2])]
      let hi = rgb.max()!, lo = rgb.min()!
      guard lo > 0.01, hi < 0.92 else { continue }
      candidates.append(((hi - lo) / hi, rgb))
    }
    guard candidates.count >= w * h / 20 else { return nil }
    let neutrals = candidates.sorted { $0.saturation < $1.saturation }.prefix(max(1, candidates.count * 3 / 10))
    let n = Double(neutrals.count)
    return (0..<3).map { c in neutrals.reduce(0) { $0 + $1.rgb[c] } / n }
  }

  private static let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
  private static let context = CIContext(options: [.workingColorSpace: linear])

  private static func graded(_ rgb: [Double], warmth: Double) -> [Double] {
    let color = CIColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1, colorSpace: linear)!
    let pixel = CGRect(x: 0, y: 0, width: 1, height: 1)
    let img = Scene.graded(CIImage(color: color).cropped(to: pixel), Grade(warmth: warmth))
    var out = [Float](repeating: 0, count: 4)
    context.render(img, toBitmap: &out, rowBytes: 16, bounds: pixel, format: .RGBAf, colorSpace: linear)
    return out.prefix(3).map { max(1e-4, Double($0)) }
  }
}
