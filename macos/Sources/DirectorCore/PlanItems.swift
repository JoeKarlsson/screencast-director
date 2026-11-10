import Foundation

// The plan's timed items besides clips: zooms, camera punch-ins, layouts, titles, B-roll, markers and annotations.

public struct Zoom: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  /// Focus point, 0...1 across the recorded screen (y down).
  public var x: Double
  public var y: Double
  public var scale: Double
  public var note: String?
  /// An `Ease` name for this zoom's moves (nil: the motion style's).
  public var ease: String?
  /// Length of this zoom's moves in seconds (nil: style.transition).
  public var seconds: Double?

  public init(
    start: Double, end: Double, x: Double, y: Double, scale: Double, note: String? = nil, ease: String? = nil, seconds: Double? = nil
  ) {
    self.start = start
    self.end = end
    self.x = x
    self.y = y
    self.scale = scale
    self.note = note
    self.ease = ease
    self.seconds = seconds
  }
}

/// A hard-cut zoom on the camera for punctuation. Times are source seconds; `scale` multiplies the
/// camera's framing zoom (2 is twice as tight, below 1 wider, never past the whole camera) around
/// the framing point. `x`/`y` move the framing point for the punch (camera-file fractions, like
/// `camera.x`/`y`), for a cut to something held up beside the face.
public struct PunchIn: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  public var scale: Double
  public var x: Double?
  public var y: Double?
  public var note: String?
  public init(start: Double, end: Double, scale: Double, x: Double? = nil, y: Double? = nil, note: String? = nil) {
    self.start = start
    self.end = end
    self.scale = scale
    self.x = x
    self.y = y
    self.note = note
  }
}

public enum LayoutMode: String, Codable, CaseIterable, Sendable {
  case screen, pip, side, camera
}

public struct LayoutRange: Codable, Equatable, Sendable {
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

/// Text on screen: a title, lower third, full-screen slate or chapter card.
public struct Callout: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  public var text: String
  /// One of `Callout.styles` (nil is "title").
  public var style: String?
  /// A second line (lower thirds, slates and chapters).
  public var subtitle: String?
  /// How it comes and goes (nil: the motion style's).
  public var enter: Motion?
  public var exit: Motion?
  /// Plays as it appears, and moves with it.
  public var sound: Sound?
  public init(start: Double, end: Double, text: String, style: String? = nil, subtitle: String? = nil, enter: Motion? = nil, exit: Motion? = nil) {
    self.start = start
    self.end = end
    self.text = text
    self.style = style
    self.subtitle = subtitle
    self.enter = enter
    self.exit = exit
  }

  public static let styles: [(name: String, label: String)] = [
    ("title", "Title"), ("lower-third", "Lower Third"), ("slate", "Slate"), ("chapter", "Chapter"),
  ]
}

/// B-roll: a video clip or picture shown over part of the recording, inside the screen card or
/// over the whole frame. Times are source seconds of the main recording, as everywhere.
public struct Insert: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  /// A file in the project folder (the app copies picked files into broll/).
  public var file: String
  /// Seconds into a video file to start from (default 0). Clips play at real time and muted.
  public var from: Double?
  /// "screen" (in the screen card, the default) or "full" (the whole frame, under captions).
  public var placement: String?
  /// "fill" (crop to fill, the default) or "fit" (show it all).
  public var fit: String?
  public var enter: Motion?
  public var exit: Motion?
  /// "halftone": the background in the accent's halftone dots with the subject (Vision's foreground)
  /// in color, and the camera's crayon outline around it when that's on. "none": as shot. Unset,
  /// video B-roll follows the camera's room and images stay as they are.
  public var room: String?
  /// A sticker's center (fractions of the frame from its top left; default upper right) and width
  /// (a fraction of the frame's width, default 0.32). Its height follows the clip's shape.
  public var x: Double?
  public var y: Double?
  public var w: Double?
  /// Meme text on a sticker, in white capitals with a black outline, along its top and bottom.
  public var topText: String?
  public var bottomText: String?
  /// A sticker's tilt in degrees, clockwise (default `stickerTilt`, counterclockwise); 0 sits square.
  public var rotation: Double?
  public var note: String?
  public init(
    start: Double, end: Double, file: String, from: Double? = nil, placement: String? = nil, fit: String? = nil, enter: Motion? = nil,
    exit: Motion? = nil, note: String? = nil
  ) {
    self.start = start
    self.end = end
    self.file = file
    self.from = from
    self.placement = placement
    self.fit = fit
    self.enter = enter
    self.exit = exit
    self.note = note
  }

  public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "tif", "bmp"]
  public var isImage: Bool { Insert.imageExtensions.contains((file as NSString).pathExtension.lowercased()) }
  public var isFull: Bool { placement == "full" }
  /// Floats over the whole finished frame (screen, camera and all) and covers nothing: a clip or
  /// picture with alpha, like an overlay animation's, or a sticker.
  public var isOverlay: Bool { placement == "overlay" || isSticker }
  /// A small clip or picture (a reaction GIF) in a white sticker border over the video, at `x`, `y`.
  public var isSticker: Bool { placement == "sticker" }
  public static let stickerTilt = -4.0
}

/// A named point on the timeline (source seconds): a note to yourself or the AI ("intro ends").
public struct Marker: Codable, Equatable, Sendable {
  public var t: Double
  public var label: String?
  public init(t: Double, label: String? = nil) {
    self.t = t
    self.label = label
  }
}

/// A mark on the recorded screen that moves with zooms: a spotlight, box, arrow, highlight or
/// privacy blur. The rectangle is in 0...1 fractions of the recording, top-left origin.
public struct Annotation: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  /// One of `Annotation.kinds`.
  public var kind: String
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double
  /// A label next to boxes and arrows.
  public var text: String?
  public var enter: Motion?
  public var exit: Motion?
  public var note: String?
  /// Plays as it appears, and moves with it.
  public var sound: Sound?
  public init(
    start: Double, end: Double, kind: String, x: Double, y: Double, w: Double, h: Double, text: String? = nil, enter: Motion? = nil,
    exit: Motion? = nil, note: String? = nil
  ) {
    self.start = start
    self.end = end
    self.kind = kind
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.text = text
    self.enter = enter
    self.exit = exit
    self.note = note
  }

  public static let kinds: [(name: String, label: String)] = [
    ("spotlight", "Spotlight"), ("box", "Box"), ("arrow", "Arrow"), ("highlight", "Highlight"), ("blur", "Blur"),
  ]
}
