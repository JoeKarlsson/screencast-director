import CoreGraphics
import Foundation

/// A hand-drawn mark (`MarkSet`), drawn natively: it draws in stroke by stroke, holds and can erase,
/// boils (wobbles a little, redrawn six times a second) and has the grainy, broken edge of crayon.
public struct Scribble: Sendable {
  /// The mark's design box (the SVG viewBox) and its strokes as polylines in that box.
  public let size: CGSize
  public let strokes: [[CGPoint]]

  public init(size: CGSize, path: String) {
    self.size = size
    strokes = Scribble.parse(path)
  }

  /// An SVG path with absolute M, L, Q and C commands (what marks use), one polyline per
  /// M. Curves are flattened into 12 segments each.
  public static func parse(_ d: String) -> [[CGPoint]] {
    var strokes: [[CGPoint]] = []
    var numbers: [Double] = []
    var command: Character = "M"
    var token = ""
    func flushToken() { if let v = Double(token) { numbers.append(v) }; token = "" }
    func run() {
      var i = 0
      func point() -> CGPoint? {
        guard i + 1 < numbers.count else { return nil }
        defer { i += 2 }
        return CGPoint(x: numbers[i], y: numbers[i + 1])
      }
      while i < numbers.count {
        let from = strokes.last?.last ?? .zero
        switch command {
        case "M":
          guard let p = point() else { return }
          strokes.append([p])
          command = "L"  // Further pairs after an M are lines, as in SVG.
        case "L":
          guard let p = point() else { return }
          strokes[strokes.count - 1].append(p)
        case "Q":
          guard let c = point(), let p = point() else { return }
          for k in 1...12 {
            let t = Double(k) / 12, u = 1 - t
            strokes[strokes.count - 1].append(CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * p.x, y: u * u * from.y + 2 * u * t * c.y + t * t * p.y))
          }
        case "C":
          guard let c1 = point(), let c2 = point(), let p = point() else { return }
          for k in 1...12 {
            let t = Double(k) / 12, u = 1 - t
            let x = u * u * u * from.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x
            let y = u * u * u * from.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y
            strokes[strokes.count - 1].append(CGPoint(x: x, y: y))
          }
        default: return
        }
      }
    }
    for ch in d {
      if "MLQC".contains(ch) {
        flushToken(); run(); numbers = []; command = ch
      } else if ch == "," || ch == " " {
        flushToken()
      } else if ch == "-" && !token.isEmpty && token.last != "e" {
        flushToken(); token = "-"
      } else {
        token.append(ch)
      }
    }
    flushToken(); run()
    return strokes.filter { $0.count > 1 }
  }

  /// The stretch of a polyline from `from` to `to` (fractions of its length): drawing in grows `to`
  /// from 0, erasing grows `from` to 1, like a stroke's dash offset.
  public static func trimmed(_ pts: [CGPoint], from: Double, to: Double) -> [CGPoint] {
    let a = min(max(from, 0), 1), b = min(max(to, 0), 1)
    guard pts.count > 1, b > a else { return [] }
    var lengths = [0.0]
    for i in 1..<pts.count { lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
    let total = lengths.last ?? 0
    guard total > 0 else { return [] }
    func at(_ d: Double) -> CGPoint {
      let i = max(1, lengths.firstIndex { $0 >= d } ?? lengths.count - 1)
      let span = lengths[i] - lengths[i - 1], k = span > 0 ? (d - lengths[i - 1]) / span : 0
      return CGPoint(x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * k, y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * k)
    }
    let start = a * total, end = b * total
    return [at(start)] + pts.indices.filter { lengths[$0] > start && lengths[$0] < end }.map { pts[$0] } + [at(end)]
  }

  /// How much of each stroke shows at `progress` (0 nothing, 1 all drawn): the strokes draw one
  /// after another like one pen, each taking an equal share.
  public func shares(_ progress: Double) -> [(from: Double, to: Double)] {
    let n = Double(strokes.count)
    return strokes.indices.map { i in (0, min(1, max(0, progress * n - Double(i)))) }
  }

  /// Draws the mark into `rect` (top-left coordinates, stretched to fit) on a layer of its own, so
  /// the crayon's grain only takes from the mark: `shares` per stroke (from `shares(_:)`), `boil`
  /// picks one of three wobble frames. Points move a little with the boil, smoothly along the line.
  public func draw(
    _ ctx: CGContext, in rect: CGRect, color: CGColor, lineWidth: Double, shares: [(from: Double, to: Double)], boil: Int
  ) {
    let pad = lineWidth * 2
    let box = rect.insetBy(dx: -pad, dy: -pad).integral
    guard box.width >= 1, box.height >= 1,
      let layer = CGContext(
        data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    // The layer is y-up; flip so it's drawn in the same top-left coordinates as the frame.
    layer.translateBy(x: 0, y: box.height)
    layer.scaleBy(x: 1, y: -1)
    let sx = rect.width / size.width, sy = rect.height / size.height
    let wobble = lineWidth * 0.45, phase = Double(boil % 3) * 2.1
    layer.setStrokeColor(color)
    layer.setLineWidth(lineWidth)
    layer.setLineCap(.round)
    layer.setLineJoin(.round)
    for (stroke, share) in zip(strokes, shares) {
      let pts = Scribble.trimmed(stroke, from: share.from, to: share.to)
      guard pts.count > 1 else { continue }
      let moved = pts.map { p -> CGPoint in
        let x = (p.x * sx) + rect.minX - box.minX, y = (p.y * sy) + rect.minY - box.minY
        return CGPoint(x: x + wobble * sin(y * 0.031 + phase) * cos(x * 0.017 + phase * 1.3), y: y + wobble * sin(x * 0.029 + phase * 0.7))
      }
      layer.addLines(between: moved)
      layer.strokePath()
    }
    // The grain: specks of the layer taken out, as crayon skips over paper.
    layer.setBlendMode(.destinationOut)
    if let grain = Scribble.grain {
      let tile = 128 * max(1, lineWidth / 8)
      layer.draw(grain, in: CGRect(x: 0, y: 0, width: tile, height: tile), byTiling: true)
    }
    guard let image = layer.makeImage() else { return }
    ctx.saveGState()
    // Back to y-up for CGImage drawing at the box.
    ctx.translateBy(x: box.minX, y: box.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: box.width, height: box.height))
    ctx.restoreGState()
  }

  /// Specks of alpha: about a quarter of a 128 px tile, the same every run.
  static let grain: CGImage? = {
    let n = 128
    var bytes = [UInt8](repeating: 0, count: n * n * 4)
    var s: UInt32 = 12345
    for i in 0..<(n * n) {
      s = s &* 1_103_515_245 &+ 12345
      if (s >> 16) % 100 < 24 { bytes[i * 4 + 3] = 255 }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)
  }()
}
