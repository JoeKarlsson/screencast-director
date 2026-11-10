import Foundation

/// Readability of an animation's text: the color of each piece of text against what's behind it in
/// the rendered frame, as WCAG contrast. `director animate` warns about text that stays hard to read.
public enum TextContrast {
  /// WCAG AA: 4.5:1 for body text, 3:1 for large text (24 px, or 19 px bold, at 1080p).
  public static func needed(large: Bool) -> Double { large ? 3 : 4.5 }

  /// WCAG relative luminance of an sRGB color (components 0-1).
  public static func luminance(_ c: [Double]) -> Double {
    let lin = c.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
  }

  public static func ratio(_ a: [Double], _ b: [Double]) -> Double {
    let (la, lb) = (luminance(a), luminance(b))
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }

  /// What's behind a piece of text: the most common color in its box of a premultiplied BGRA frame
  /// (glyphs cover less of their box than the card or paper behind them), as straight [r, g, b, alpha].
  public static func backdrop(bgra p: [UInt8], width: Int, height: Int, x: Int, y: Int, w: Int, h: Int) -> [Double]? {
    let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
    guard x1 > x0, y1 > y0 else { return nil }
    var counts: [Int: Int] = [:], sums: [Int: [Int]] = [:]
    // Every other pixel each way: a box's backdrop is most of it, so a quarter of its pixels find it.
    for yy in stride(from: y0, to: y1, by: 2) {
      for xx in stride(from: x0, to: x1, by: 2) {
        let i = (yy * width + xx) * 4
        let (b, g, r, a) = (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]), Int(p[i + 3]))
        let key = (r >> 4) << 12 | (g >> 4) << 8 | (b >> 4) << 4 | (a >> 4)
        counts[key, default: 0] += 1
        let s = sums[key] ?? [0, 0, 0, 0]
        sums[key] = [s[0] + r, s[1] + g, s[2] + b, s[3] + a]
      }
    }
    guard let (key, n) = counts.max(by: { $0.value < $1.value }), let s = sums[key] else { return nil }
    let a = Double(s[3]) / Double(n) / 255
    guard a > 0.01 else { return [0, 0, 0, 0] }
    return [Double(s[0]), Double(s[1]), Double(s[2])].map { min(1, $0 / Double(n) / 255 / a) } + [a]
  }

  /// `director animate`'s textProbe rows of one frame as overlapWarnings rows: ["contrast", text, needed ratio, how
  /// many times short of it] for text too faint against what's behind it, ["bare", text, "", 0] for
  /// text with nothing behind it (an overlay's, straight on the video).
  public static func rows(_ rows: [[Any]], bgra pixels: [UInt8], width: Int, height: Int) -> [[Any]] {
    rows.compactMap { row -> [Any]? in
      guard row.count == 9, let name = row[0] as? String else { return nil }
      let n = row.dropFirst().map { ($0 as? Double) ?? 0 }
      guard let back = backdrop(bgra: pixels, width: width, height: height, x: Int(n[0]), y: Int(n[1]), w: Int(n[2]), h: Int(n[3]))
      else { return nil }
      if back[3] < 0.5 { return ["bare", name, "", 0.0] }
      let needed = needed(large: n[7] > 0), ratio = ratio(Array(n[4...6]), back)
      return ratio < needed ? ["contrast", name, String(format: "%g", needed), needed / ratio] : nil
    }
  }

}
