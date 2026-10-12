import Foundation

// The edit plan, same JSON as src/types.ts. All times are SOURCE seconds
// (positions in the raw screen recording).

public struct Segment: Codable, Equatable {
  public var start: Double
  public var end: Double
  /// 1 = real time. Segments faster than 1 are muted.
  public var speed: Double
  public var note: String?

  public init(start: Double, end: Double, speed: Double, note: String? = nil) {
    self.start = start
    self.end = end
    self.speed = speed
    self.note = note
  }
}

public struct Zoom: Codable, Equatable {
  public var start: Double
  public var end: Double
  /// Focus point, 0...1 across the recorded screen (y down).
  public var x: Double
  public var y: Double
  public var scale: Double
  public var note: String?

  public init(start: Double, end: Double, x: Double, y: Double, scale: Double, note: String? = nil) {
    self.start = start
    self.end = end
    self.x = x
    self.y = y
    self.scale = scale
    self.note = note
  }
}

public enum LayoutMode: String, Codable, CaseIterable {
  case screen, pip, side, camera
}

public struct LayoutRange: Codable, Equatable {
  public var start: Double
  public var end: Double
  public var mode: LayoutMode
  public var note: String?
  public init(start: Double, end: Double, mode: LayoutMode, note: String? = nil) {
    self.start = start
    self.end = end
    self.mode = mode
    self.note = note
  }
}

public struct Callout: Codable, Equatable {
  public var start: Double
  public var end: Double
  public var text: String
  public init(start: Double, end: Double, text: String) {
    self.start = start
    self.end = end
    self.text = text
  }
}

public struct Plan: Codable, Equatable {
  public struct Source: Codable, Equatable {
    public var video: String
    public var width: Double
    public var height: Double
    public var duration: Double
  }
  public struct Camera: Codable, Equatable {
    public var video: String
    /// Seconds to add to a screen time to get the same moment in the camera file.
    public var offset: Double
    /// Framing: the point of the camera image to keep centered (0..1, y down) and how far to zoom
    /// in (1 = fill the box). Set by "Center on my face" or by hand; nil centers the image.
    public var x: Double?
    public var y: Double?
    public var zoom: Double?
    /// Color grading for the camera.
    public var grade: Grade?
    public init(video: String, offset: Double) {
      self.video = video
      self.offset = offset
    }
  }
  public struct Output: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
  }
  public struct Style: Codable, Equatable {
    public var background: [String]
    public var padding: Double
    public var radius: Double
    public var transition: Double
    /// Width/height of the screen card. nil shows the whole screen; vertical and square formats
    /// crop (e.g. 0.8 is 4:5) and pan to follow zooms and clicks.
    public var screenAspect: Double?
  }
  public struct Captions: Codable, Equatable {
    public var enabled: Bool
    public var maxWords: Int
  }

  public var version: Int = 1
  public var source: Source
  public var camera: Camera?
  public var output: Output
  public var style: Style
  public var segments: [Segment]
  public var zooms: [Zoom]
  public var defaultLayout: LayoutMode
  public var layouts: [LayoutRange]
  public var captions: Captions
  public var clickRipples: Bool
  public var shortcutChips: Bool
  public var callouts: [Callout]
  /// Branded fonts, colors, frame and logo, from a profile. nil is the built-in look.
  public var look: Look?
  /// How hard silences were cut (nil: the planner's normal level).
  public var pauses: PauseLevel?
  /// Voice level: normalize to a standard loudness, plus a manual trim.
  public var audio: AudioSettings?

  public static func load(_ url: URL) throws -> Plan {
    try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url))
  }

  public func write(to url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    var data = try enc.encode(self)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
  }
}

public struct Word: Codable, Equatable {
  public var text: String
  public var start: Double
  public var end: Double
  public init(text: String, start: Double, end: Double) {
    self.text = text
    self.start = start
    self.end = end
  }
}

public enum InputKind: String, Codable {
  case move, click, scroll, key
}

public struct InputEvent: Equatable {
  public var t: Double
  public var type: InputKind
  public var x: Double
  public var y: Double
  public var label: String?
  public init(t: Double, type: InputKind, x: Double, y: Double, label: String? = nil) {
    self.t = t
    self.type = type
    self.x = x
    self.y = y
    self.label = label
  }
}

public struct Grade: Codable, Equatable {
  /// Stops of exposure, -1...1.
  public var exposure: Double?
  /// 1 = unchanged.
  public var contrast: Double?
  /// 1 = unchanged, 0 = black and white.
  public var saturation: Double?
  /// -1 (cool) ... 1 (warm).
  public var warmth: Double?
  public init(exposure: Double? = nil, contrast: Double? = nil, saturation: Double? = nil, warmth: Double? = nil) {
    self.exposure = exposure
    self.contrast = contrast
    self.saturation = saturation
    self.warmth = warmth
  }
  public static let presets: [(name: String, grade: Grade)] = [
    ("Natural", Grade()),
    ("Warm", Grade(exposure: 0.05, contrast: 1.05, saturation: 1.05, warmth: 0.35)),
    ("Punchy", Grade(exposure: 0.1, contrast: 1.15, saturation: 1.2, warmth: 0.1)),
    ("Cool", Grade(contrast: 1.05, saturation: 0.95, warmth: -0.3)),
    ("Bright", Grade(exposure: 0.35, contrast: 0.95, saturation: 1.05)),
  ]
}

public struct AudioSettings: Codable, Equatable {
  /// Bring the voice to a standard level (about -20 dBFS RMS while speaking).
  public var normalize: Bool?
  /// Extra gain in dB, -12...12.
  public var gainDB: Double?
  public init(normalize: Bool? = nil, gainDB: Double? = nil) {
    self.normalize = normalize
    self.gainDB = gainDB
  }
}
