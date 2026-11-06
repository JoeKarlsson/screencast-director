import CoreGraphics
import Foundation

/// Crayon marks from joekarlsson.com (its src/data/scribbles.ts), drawn natively: a mark draws in
/// stroke by stroke, holds and can erase, boils (wobbles a little, redrawn six times a second) and
/// has the grainy, broken edge of crayon.
public struct Scribble: Sendable {
  /// The mark's design box (the SVG viewBox) and its strokes as polylines in that box.
  public let size: CGSize
  public let strokes: [[CGPoint]]

  public init(size: CGSize, path: String) {
    self.size = size
    strokes = Scribble.parse(path)
  }

  /// A loose coil, 900x300: the one under the name on the homepage.
  public static let coil = Scribble(size: CGSize(width: 900, height: 300), path: "M34.1,95.1 Q39.7,102.8 42.2,106.7 Q44.7,110.5 46.9,114.2 Q49.1,118.0 50.9,121.5 Q52.7,125.0 54.2,128.3 Q55.6,131.5 56.7,134.4 Q57.9,137.2 58.6,139.7 Q59.4,142.1 59.8,144.0 Q60.3,145.9 60.4,147.3 Q60.6,148.6 60.5,149.4 Q60.3,150.1 60.0,150.2 Q59.7,150.3 59.2,149.8 Q58.7,149.3 58.1,148.2 Q57.5,147.0 56.8,145.3 Q56.1,143.5 55.5,141.2 Q54.8,138.9 54.2,136.0 Q53.6,133.2 53.2,129.9 Q52.7,126.6 52.4,123.0 Q52.1,119.3 52.1,115.4 Q52.1,111.4 52.3,107.3 Q52.6,103.2 53.2,99.0 Q53.8,94.8 54.8,90.7 Q55.8,86.5 57.1,82.5 Q58.5,78.5 60.3,74.7 Q62.1,70.9 64.3,67.5 Q66.5,64.1 69.1,61.1 Q71.7,58.2 74.8,55.7 Q77.8,53.3 81.2,51.5 Q84.7,49.7 88.4,48.5 Q92.2,47.4 96.2,46.9 Q100.3,46.5 104.6,46.8 Q108.9,47.1 113.4,48.1 Q118.0,49.2 122.6,51.0 Q127.2,52.7 131.9,55.2 Q136.6,57.7 141.3,60.9 Q145.9,64.0 150.5,67.7 Q155.1,71.5 159.5,75.7 Q164.0,80.0 168.2,84.7 Q172.4,89.3 176.3,94.3 Q180.2,99.3 183.8,104.5 Q187.3,109.6 190.3,114.8 Q193.4,120.1 196.0,125.1 Q198.5,130.2 200.7,135.0 Q202.8,139.9 204.4,144.3 Q206.0,148.8 207.2,152.8 Q208.4,156.8 209.1,160.2 Q209.8,163.6 210.1,166.4 Q210.4,169.2 210.2,171.3 Q210.1,173.3 209.7,174.6 Q209.2,175.9 208.4,176.4 Q207.7,176.9 206.7,176.7 Q205.7,176.4 204.6,175.3 Q203.5,174.2 202.2,172.3 Q201.0,170.5 199.8,167.9 Q198.5,165.4 197.3,162.2 Q196.2,159.0 195.1,155.2 Q194.1,151.4 193.2,147.2 Q192.4,142.9 191.8,138.3 Q191.3,133.7 191.0,128.8 Q190.8,124.0 190.9,119.0 Q191.0,114.0 191.6,109.0 Q192.1,104.0 193.1,99.1 Q194.1,94.2 195.6,89.6 Q197.1,85.0 199.0,80.7 Q201.0,76.4 203.4,72.6 Q205.8,68.8 208.7,65.6 Q211.6,62.4 214.9,59.8 Q218.2,57.2 221.9,55.3 Q225.6,53.4 229.6,52.3 Q233.6,51.1 238.0,50.8 Q242.3,50.4 246.9,50.9 Q251.4,51.3 256.2,52.5 Q260.9,53.8 265.7,55.8 Q270.5,57.8 275.3,60.5 Q280.1,63.1 284.9,66.5 Q289.7,69.8 294.3,73.7 Q298.9,77.6 303.3,82.0 Q307.8,86.4 311.9,91.1 Q316.1,95.8 319.9,100.8 Q323.7,105.7 327.2,110.8 Q330.6,115.9 333.7,121.0 Q336.8,126.1 339.4,131.1 Q342.1,136.1 344.2,140.9 Q346.4,145.7 348.1,150.1 Q349.8,154.5 351.0,158.5 Q352.2,162.5 353.0,165.9 Q353.7,169.3 354.0,172.1 Q354.3,174.9 354.2,176.9 Q354.1,179.0 353.6,180.3 Q353.1,181.6 352.3,182.1 Q351.5,182.6 350.5,182.2 Q349.5,181.9 348.2,180.7 Q347.0,179.6 345.7,177.6 Q344.4,175.7 343.0,173.0 Q341.7,170.3 340.4,166.9 Q339.0,163.5 337.9,159.5 Q336.7,155.4 335.7,150.9 Q334.7,146.4 334.0,141.5 Q333.3,136.5 332.9,131.3 Q332.5,126.1 332.5,120.7 Q332.5,115.3 332.9,109.9 Q333.3,104.5 334.2,99.2 Q335.1,93.8 336.5,88.8 Q337.9,83.7 339.8,78.9 Q341.7,74.2 344.1,70.0 Q346.5,65.7 349.4,62.0 Q352.3,58.4 355.7,55.4 Q359.1,52.4 362.9,50.1 Q366.7,47.9 370.9,46.4 Q375.1,45.0 379.6,44.4 Q384.1,43.8 388.9,44.0 Q393.6,44.3 398.6,45.4 Q403.6,46.6 408.7,48.5 Q413.7,50.5 418.8,53.2 Q423.9,55.9 429.0,59.4 Q434.1,62.9 439.0,67.0 Q443.9,71.1 448.6,75.7 Q453.4,80.3 457.8,85.4 Q462.2,90.5 466.3,95.8 Q470.4,101.2 474.1,106.7 Q477.8,112.2 480.7,117.7 Q483.7,123.2 486.1,128.4 Q488.6,133.6 490.5,138.4 Q492.4,143.3 493.9,147.6 Q495.3,152.0 496.2,155.7 Q497.1,159.5 497.5,162.5 Q498.0,165.6 498.0,167.9 Q498.1,170.3 497.7,171.8 Q497.4,173.3 496.8,174.0 Q496.1,174.8 495.2,174.7 Q494.3,174.6 493.3,173.7 Q492.2,172.8 491.1,171.1 Q490.0,169.5 488.8,167.1 Q487.6,164.7 486.5,161.7 Q485.4,158.7 484.4,155.2 Q483.5,151.6 482.7,147.6 Q481.9,143.6 481.3,139.2 Q480.8,134.9 480.6,130.3 Q480.3,125.7 480.5,121.0 Q480.6,116.3 481.1,111.5 Q481.6,106.8 482.5,102.2 Q483.4,97.6 484.7,93.3 Q486.0,88.9 487.7,84.8 Q489.4,80.8 491.6,77.1 Q493.7,73.5 496.3,70.3 Q498.8,67.1 501.7,64.5 Q504.6,61.9 507.8,59.9 Q511.0,57.8 514.5,56.4 Q518.0,55.0 521.7,54.3 Q525.4,53.5 529.3,53.4 Q533.2,53.3 537.2,53.7 Q541.2,54.2 545.3,55.3 Q549.3,56.4 553.4,58.0 Q557.4,59.6 561.5,61.6 Q565.5,63.7 569.4,66.2 Q573.2,68.7 577.0,71.5 Q580.7,74.2 584.2,77.3 Q587.8,80.3 591.0,83.5 Q594.3,86.7 597.3,89.9 Q600.3,93.2 603.1,96.4 Q605.8,99.6 608.4,102.7 Q611.0,105.9 613.4,108.9 Q615.7,112.0 617.7,114.9 Q619.7,117.9 621.4,120.5 Q623.1,123.2 624.5,125.6 Q625.9,128.0 627.0,130.0 Q628.1,132.0 628.9,133.6 Q629.7,135.1 630.2,136.3 Q630.7,137.4 631.0,138.0 Q631.3,138.6 631.4,138.6 Q631.5,138.7 631.5,138.3 Q631.4,137.8 631.3,136.8 Q631.1,135.8 630.9,134.3 Q630.6,132.8 630.4,130.8 Q630.2,128.8 630.0,126.4 Q629.7,124.0 629.6,121.2 Q629.5,118.4 629.5,115.2 Q629.5,112.1 629.7,108.7 Q629.9,105.3 630.3,101.8 Q630.7,98.2 631.4,94.6 Q632.0,90.9 633.0,87.3 Q633.9,83.6 635.2,80.0 Q636.4,76.4 638.0,73.0 Q639.5,69.6 641.4,66.4 Q643.3,63.2 645.5,60.3 Q647.7,57.4 650.2,54.9 Q652.7,52.4 655.5,50.4 Q658.3,48.3 661.4,46.7 Q664.5,45.1 667.8,44.1 Q671.1,43.0 674.6,42.5 Q678.2,41.9 681.9,41.9 Q685.5,42.0 689.3,42.5 Q693.1,43.1 697.0,44.1 Q700.8,45.2 704.7,46.8 Q708.6,48.3 712.4,50.4 Q716.3,52.4 720.0,54.8 Q723.7,57.2 727.4,59.9 Q731.0,62.6 734.4,65.6 Q737.8,68.6 741.0,71.8 Q744.2,75.0 747.2,78.2 Q750.1,81.5 752.8,84.7 Q755.4,88.0 757.7,91.2 Q760.0,94.3 762.0,97.3 Q764.0,100.3 765.6,103.0 Q767.3,105.7 768.6,108.1 Q770.0,110.5 771.0,112.4 Q772.0,114.4 772.8,116.0 Q773.5,117.5 774.0,118.5 Q774.4,119.6 774.7,120.1 Q774.9,120.6 775.0,120.6 Q775.0,120.6 774.9,120.0 Q774.9,119.5 774.7,118.4 Q774.5,117.3 774.2,115.7 Q774.0,114.1 773.7,112.1 Q773.5,110.0 773.3,107.5 Q773.1,105.0 773.0,102.2 Q772.9,99.3 773.0,96.2 Q773.0,93.0 773.2,89.6 Q773.5,86.2 773.9,82.7 Q774.4,79.2 775.1,75.6 Q775.8,72.0 776.8,68.4 Q777.8,64.8 779.1,61.3 Q780.4,57.8 782.0,54.5 Q783.6,51.2 785.5,48.1 Q787.5,45.1 789.7,42.3 Q791.9,39.6 794.4,37.2 Q797.0,34.9 799.8,32.9 Q802.6,31.0 805.6,29.5 Q808.7,28.1 812.0,27.1 Q815.2,26.2 818.7,25.7 Q822.1,25.3 825.7,25.4 Q829.3,25.5 833.0,26.1 Q836.7,26.6 840.5,27.7 Q844.2,28.8 848.0,30.3 Q851.7,31.9 855.4,33.8 Q859.1,35.7 862.7,38.0 Q866.3,40.3 869.7,42.9 Q873.2,45.5 876.5,48.3 Q879.8,51.1 882.8,54.0 Q885.9,57.0 888.7,60.0")
  /// Three short emphasis ticks fanning out, 160x120.
  public static let rays = Scribble(size: CGSize(width: 160, height: 120), path: "M29.7,85.3 Q20.2,62.8 14.1,51.4 L8.0,40.0 M71.9,74.7 Q72.2,52.3 73.7,43.0 Q75.2,33.7 76.6,22.9 L78.0,12.0 M107.7,87.7 Q120.8,74.6 128.1,68.5 Q135.4,62.5 142.7,56.3 L150.0,50.0")
  /// A dense starburst of short strokes, 200x200.
  public static let burst = Scribble(size: CGSize(width: 200, height: 200), path: "M124.4,99.3 Q142.1,103.6 151.5,102.9 Q161.0,102.2 170.6,103.5 L180.3,104.8 M119.5,109.6 Q136.9,116.2 146.1,120.3 Q155.4,124.4 164.3,128.4 Q173.1,132.5 181.5,136.7 L189.8,140.9 M113.4,120.8 Q126.1,138.9 131.8,148.0 Q137.5,157.1 143.7,166.5 L149.8,175.9 M106.1,122.3 Q113.1,144.7 116.7,156.7 L120.3,168.7 M91.2,121.2 Q86.8,142.3 82.0,152.9 Q77.3,163.6 73.4,174.3 L69.6,184.9 M82.0,119.8 Q70.9,137.2 64.0,144.2 Q57.1,151.2 50.5,159.3 L43.8,167.4 M78.5,107.8 Q63.5,117.4 55.4,122.4 Q47.2,127.4 38.4,130.6 L29.5,133.8 M74.9,100.6 Q51.0,100.4 39.4,98.9 Q27.9,97.4 16.3,97.4 L4.6,97.4 M79.9,91.1 Q57.3,79.5 45.2,73.6 L33.1,67.8 M87.4,77.6 Q74.9,60.5 69.1,51.4 L63.3,42.4 M96.5,81.8 Q94.8,64.5 93.1,55.5 Q91.3,46.5 89.3,36.3 Q87.4,26.2 86.2,17.1 L85.0,8.0 M106.1,77.8 Q113.3,56.9 115.4,45.9 L117.4,34.9 M112.7,84.1 Q130.7,63.9 139.5,54.8 L148.4,45.7 M122.2,91.0 Q144.0,77.9 155.0,73.7 L166.1,69.5")
  /// A hand-drawn asterisk, 100x100.
  public static let asterisk = Scribble(size: CGSize(width: 100, height: 100), path: "M49.4,9.5 Q51.4,27.2 50.7,38.9 Q50.0,50.6 50.3,61.8 Q50.6,73.1 51.3,82.5 L52.0,92.0 M11.1,30.3 Q31.9,38.7 41.8,44.7 Q51.8,50.6 59.8,55.5 Q67.9,60.4 77.9,66.2 L88.0,72.0 M83.4,23.9 Q70.2,37.7 59.9,44.0 Q49.5,50.2 41.2,55.5 Q32.8,60.7 23.4,67.4 L14.0,74.0")

  /// An SVG path with absolute M, L, Q and C commands (all the site's marks use), one polyline per
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
