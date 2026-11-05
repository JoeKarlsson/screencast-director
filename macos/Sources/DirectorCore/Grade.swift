import Foundation

public struct Grade: Codable, Equatable, Sendable {
  /// Stops of exposure, -1...1.
  public var exposure: Double?
  /// 1 = unchanged.
  public var contrast: Double?
  /// 1 = unchanged, 0 = black and white.
  public var saturation: Double?
  /// -1 (cool) ... 1 (warm).
  public var warmth: Double?
  /// -1...0: pulls the bright parts down (a hot-lit face) without darkening the rest. 0 = unchanged.
  public var highlights: Double?
  /// -1...1: positive lifts the dark parts, negative deepens them. 0 = unchanged.
  public var shadows: Double?
  /// -1...1: like saturation, but boosts muted colors more than strong ones, so skin stays put. 0 = unchanged.
  public var vibrance: Double?
  /// A 3D `.cube` LUT (relative to the project, usually `luts/`), applied after the other controls.
  public var lut: String?
  public init(
    exposure: Double? = nil, contrast: Double? = nil, saturation: Double? = nil, warmth: Double? = nil,
    highlights: Double? = nil, shadows: Double? = nil, vibrance: Double? = nil, lut: String? = nil
  ) {
    self.exposure = exposure
    self.contrast = contrast
    self.saturation = saturation
    self.warmth = warmth
    self.highlights = highlights
    self.shadows = shadows
    self.vibrance = vibrance
    self.lut = lut
  }
  public static let presets: [(name: String, grade: Grade)] = [
    ("Natural", Grade()),
    ("Warm", Grade(exposure: 0.05, contrast: 1.05, saturation: 1.05, warmth: 0.35)),
    ("Punchy", Grade(exposure: 0.1, contrast: 1.15, saturation: 1.2, warmth: 0.1)),
    ("Cool", Grade(contrast: 1.05, saturation: 0.95, warmth: -0.3)),
    ("Bright", Grade(exposure: 0.35, contrast: 0.95, saturation: 1.05)),
  ]
}
