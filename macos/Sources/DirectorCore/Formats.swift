import Foundation

/// Output shapes and sizes. Resolution names the short side (1080p vertical is 1080x1920).
public enum Aspect: String, CaseIterable, Codable {
  case landscape = "16:9", vertical = "9:16", square = "1:1", feed = "4:5"

  public var ratio: (w: Int, h: Int) {
    switch self {
    case .landscape: return (16, 9)
    case .vertical: return (9, 16)
    case .square: return (1, 1)
    case .feed: return (4, 5)
    }
  }

  public var label: String {
    switch self {
    case .landscape: return "16:9 Landscape"
    case .vertical: return "9:16 Vertical"
    case .square: return "1:1 Square"
    case .feed: return "4:5 Feed"
    }
  }

  public static func of(_ output: Plan.Output) -> Aspect {
    let r = Double(output.width) / Double(output.height)
    return allCases.min { abs(Double($0.ratio.w) / Double($0.ratio.h) - r) < abs(Double($1.ratio.w) / Double($1.ratio.h) - r) }!
  }
}

public enum Resolution: Int, CaseIterable {
  case p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160

  public var label: String { self == .p2160 ? "4K" : "\(rawValue)p" }

  public static func of(_ output: Plan.Output) -> Resolution {
    let short = min(output.width, output.height)
    return allCases.min { abs($0.rawValue - short) < abs($1.rawValue - short) }!
  }
}

/// Even pixel sizes for an aspect at a short-side resolution.
public func outputSize(_ aspect: Aspect, _ res: Resolution) -> (width: Int, height: Int) {
  let (rw, rh) = aspect.ratio
  let short = Double(res.rawValue)
  func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
  return rw >= rh ? (even(short * Double(rw) / Double(rh)), Int(short)) : (Int(short), even(short * Double(rh) / Double(rw)))
}

public struct ExportPreset: Equatable {
  public let id: String
  public let name: String
  public let aspect: Aspect
  public let resolution: Resolution
  /// Screen crop for non-landscape shapes (width/height of the screen card); nil shows the whole screen.
  public let screenAspect: Double?

  public static let all: [ExportPreset] = [
    .init(id: "youtube-4k", name: "YouTube 4K (16:9)", aspect: .landscape, resolution: .p2160, screenAspect: nil),
    .init(id: "youtube-1080", name: "YouTube 1080p (16:9)", aspect: .landscape, resolution: .p1080, screenAspect: nil),
    .init(id: "vertical", name: "Shorts, Reels, TikTok (9:16)", aspect: .vertical, resolution: .p1080, screenAspect: 0.8),
    .init(id: "square", name: "Square (1:1)", aspect: .square, resolution: .p1080, screenAspect: 1.25),
    .init(id: "feed", name: "LinkedIn and Instagram feed (4:5)", aspect: .feed, resolution: .p1080, screenAspect: 1.0),
  ]

  /// The plan reshaped for this preset (the saved plan is left alone).
  public func applied(to plan: Plan) -> Plan {
    var p = plan
    let size = outputSize(aspect, resolution)
    p.output.width = size.width
    p.output.height = size.height
    p.style.screenAspect = screenAspect
    return p
  }
}
