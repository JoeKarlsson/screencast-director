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
}

public struct Callout: Codable, Equatable {
  public var start: Double
  public var end: Double
  public var text: String
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
