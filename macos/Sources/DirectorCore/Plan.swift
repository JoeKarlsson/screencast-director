import Foundation

// The edit plan (plan.json). All times are SOURCE seconds
// (positions in the raw screen recording).

public struct Segment: Codable, Equatable {
  public var start: Double
  public var end: Double
  /// 1 = real time. Segments faster than 1 are muted.
  public var speed: Double
  public var note: String?
  /// How the cut into this segment looks: one of `Segment.transitions` (nil is a plain cut).
  public var transition: String?

  public init(start: Double, end: Double, speed: Double, note: String? = nil, transition: String? = nil) {
    self.start = start
    self.end = end
    self.speed = speed
    self.note = note
    self.transition = transition
  }

  public static let transitions: [(name: String, label: String)] = [
    ("crossfade", "Crossfade"), ("blur", "Blur"), ("dip", "Dip"), ("flash", "Flash"), ("punch", "Punch In"), ("whip", "Whip"),
  ]
}

public struct Zoom: Codable, Equatable {
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
/// camera's framing zoom (2 is twice as tight) around the framing point.
public struct PunchIn: Codable, Equatable {
  public var start: Double
  public var end: Double
  public var scale: Double
  public var note: String?
  public init(start: Double, end: Double, scale: Double, note: String? = nil) {
    self.start = start
    self.end = end
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

/// Text on screen: a title, lower third, full-screen slate or chapter card.
public struct Callout: Codable, Equatable {
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
public struct Insert: Codable, Equatable {
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
}

/// A named point on the timeline (source seconds): a note to yourself or the AI ("intro ends").
public struct Marker: Codable, Equatable {
  public var t: Double
  public var label: String?
  public init(t: Double, label: String? = nil) {
    self.t = t
    self.label = label
  }
}

/// A mark on the recorded screen that moves with zooms: a spotlight, box, arrow, highlight or
/// privacy blur. The rectangle is in 0...1 fractions of the recording, top-left origin.
public struct Annotation: Codable, Equatable {
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
    /// The picture-in-picture bubble. Size is a fraction of the frame's short side (nil is 0.24).
    /// `bubbleX`/`bubbleY` place its center as fractions of the output frame (nil is the bottom-right
    /// corner; landscape only, since vertical formats stack the camera under the screen).
    public var bubbleSize: Double?
    public var bubbleX: Double?
    public var bubbleY: Double?
    /// One of `Plan.Camera.shapes` (nil is "circle").
    public var bubbleShape: String?
    /// The white outline and the drop shadow (nil is on).
    public var bubbleBorder: Bool?
    public var bubbleShadow: Bool?
    /// Cut the person out of the camera's background instead of showing the camera in a shape.
    public var cutout: Bool?
    /// Punch-ins: the camera snaps tighter on the framing point for a beat, then snaps back.
    public var punchIns: [PunchIn]?

    public static let defaultBubbleSize = 0.24
    public static let shapes: [(name: String, label: String)] = [("circle", "Circle"), ("rounded", "Rounded"), ("square", "Square")]
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
    /// The house motion style: one of `MotionStyle.all` (nil is "smooth").
    public var motion: String?
    /// Width/height of the screen card. nil shows the whole screen; vertical and square formats
    /// crop (e.g. 0.8 is 4:5) and pan to follow zooms and clicks.
    public var screenAspect: Double?
  }
  public struct Captions: Codable, Equatable {
    public var enabled: Bool
    public var maxWords: Int
    /// One of `Plan.Captions.styles` (nil is "pill").
    public var style: String?

    public static let styles: [(name: String, label: String)] = [
      ("pill", "Pill"), ("karaoke", "Karaoke"), ("pop", "Word Pop"), ("bold", "Bold"),
    ]
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
  /// Spotlights, boxes, arrows, highlights and blurs on the screen.
  public var annotations: [Annotation]?
  /// Named points on the timeline.
  public var markers: [Marker]?
  /// B-roll clips and pictures.
  public var inserts: [Insert]?
  /// Motion-graphics explainers rendered from templates (see Animation).
  public var animations: [Animation]?
  /// Branded fonts, colors, frame and logo, from a profile. nil is the built-in look.
  public var look: Look?
  /// How hard silences were cut (nil: the planner's normal level).
  public var pauses: PauseLevel?
  /// Voice level: normalize to a standard loudness, plus a manual trim.
  public var audio: AudioSettings?
  /// Background music, ducked under the voice.
  public var music: Music?
  /// One-shot sound effects (whoosh, pop, ding) at source times. Not ducked.
  public var sfx: [SoundEffect]?
  /// The drawn cursor (only for recordings made with the real cursor hidden).
  public var cursor: CursorSettings?
  /// Full-frame cards before and after the video (shown when enabled is true). A nil logo falls
  /// back to the look's card, then the look's watermark.
  public var intro: Card?
  public var outro: Card?

  public static func load(_ url: URL) throws -> Plan {
    try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url))
  }

  /// Writes the plan, first saving the version it replaces to .history/ (see PlanHistory).
  public func write(to url: URL) throws {
    let enc = JSONEncoder()
    // Sorted keys, so an unchanged plan writes the same bytes and isn't saved to history again.
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try enc.encode(self)
    data.append(0x0A)
    if let old = try? Data(contentsOf: url), old != data { PlanHistory.snapshot(old, planURL: url) }
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
  case move, click, scroll, key, retake
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

public struct AudioSettings: Codable, Equatable {
  /// Bring the voice to a standard level (about -20 dBFS RMS while speaking).
  public var normalize: Bool?
  /// Extra gain in dB, -12...12.
  public var gainDB: Double?
  /// Remove room noise and echo from the voice (Apple's voice isolation, cached as voice-clean.m4a).
  public var cleanup: Bool?
  /// Warm the voice: chest EQ, less boxiness, gentle compression and light saturation (`WarmVoice`).
  public var warm: Bool?
  public init(normalize: Bool? = nil, gainDB: Double? = nil, cleanup: Bool? = nil, warm: Bool? = nil) {
    self.normalize = normalize
    self.gainDB = gainDB
    self.cleanup = cleanup
    self.warm = warm
  }
}

/// A background music track, looped to the video's length and ducked under the voice.
public struct Music: Codable, Equatable {
  /// A file in the project folder, or an absolute path.
  public var file: String
  /// Music level when nobody's talking, in dB (0 = as recorded). Default -14.
  public var volumeDB: Double?
  /// How far the music drops while the voice is talking, in dB. Default -18.
  public var duckDB: Double?
  public init(file: String, volumeDB: Double? = nil, duckDB: Double? = nil) {
    self.file = file
    self.volumeDB = volumeDB
    self.duckDB = duckDB
  }
}

extension AudioSettings {
  /// `settings` with Normalize voice and Warm voice on, for new recordings when Settings asks.
  public static func polished(_ settings: AudioSettings?) -> AudioSettings {
    var a = settings ?? AudioSettings()
    a.normalize = true
    a.warm = true
    return a
  }
}

/// A sound attached to something on screen (a title, an annotation, an animation's beat). It plays
/// when that thing appears, so it moves when the thing moves and is cut only when the thing is.
public struct Sound: Codable, Equatable {
  /// A file in the project folder, or an absolute path.
  public var file: String
  /// Level in dB (0 = as recorded).
  public var gainDB: Double?
  public init(file: String, gainDB: Double? = nil) {
    self.file = file
    self.gainDB = gainDB
  }
}

extension Plan {
  /// Every sound effect that plays: the free-standing `sfx`, plus the sounds attached to titles,
  /// annotations and animation beats at the moment each appears. Sorted by time.
  public var soundEffects: [SoundEffect] {
    var all = sfxList
    for c in callouts {
      if let s = c.sound { all.append(SoundEffect(t: c.start, file: s.file, gainDB: s.gainDB, note: "title \"\(c.text)\"")) }
    }
    for a in annotationList {
      if let s = a.sound { all.append(SoundEffect(t: a.start, file: s.file, gainDB: s.gainDB, note: "\(a.kind) \(a.text ?? a.note ?? "")")) }
    }
    for an in animationList {
      for (cue, s) in an.sounds ?? [:] {
        let t = cue == "start" ? an.start : an.cues?[cue] ?? an.start
        all.append(SoundEffect(t: t, file: s.file, gainDB: s.gainDB, note: "\(an.note ?? an.template): \(cue)"))
      }
    }
    return all.sorted { $0.t < $1.t }
  }
}

/// A one-shot sound effect. `t` is source seconds; an effect whose time is cut is dropped, and one
/// in a sped-up stretch still plays at normal speed from the mapped output time.
public struct SoundEffect: Codable, Equatable {
  public var t: Double
  /// A file in the project folder, or an absolute path.
  public var file: String
  /// Level in dB (0 = as recorded).
  public var gainDB: Double?
  public var note: String?
  public init(t: Double, file: String, gainDB: Double? = nil, note: String? = nil) {
    self.t = t
    self.file = file
    self.gainDB = gainDB
    self.note = note
  }
}

public struct CursorSettings: Codable, Equatable {
  /// Arrow height in pixels at 1080p (it grows with zooms). Default 32.
  public var size: Double?
  /// Seconds of smoothing on the pointer path, 0 (raw) to 0.4. Default 0.12.
  public var smoothing: Double?
  /// Hide the drawn cursor entirely.
  public var hidden: Bool?
  public init(size: Double? = nil, smoothing: Double? = nil, hidden: Bool? = nil) {
    self.size = size
    self.smoothing = smoothing
    self.hidden = hidden
  }
}
