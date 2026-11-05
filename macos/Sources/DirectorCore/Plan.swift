import Foundation

// The edit plan (plan.json). All times are SOURCE seconds
// (positions in the raw screen recording).

public struct Segment: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  /// 1 = real time. Segments faster than 1 are muted.
  public var speed: Double
  public var note: String?
  /// How the cut into this segment looks: one of `Segment.transitions` (nil is a plain cut).
  public var transition: String?
  /// A second showing of a moment that also plays in another clip, like a cold open that stays in
  /// its sentence too. It may overlap other clips. Zooms, punch-ins, B-roll and captions play again
  /// with it; titles and sound effects only at the first showing.
  public var repeats: Bool?

  public init(start: Double, end: Double, speed: Double, note: String? = nil, transition: String? = nil, repeats: Bool? = nil) {
    self.start = start
    self.end = end
    self.speed = speed
    self.note = note
    self.transition = transition
    self.repeats = repeats
  }

  public static let transitions: [(name: String, label: String)] = [
    ("crossfade", "Crossfade"), ("blur", "Blur"), ("dip", "Dip"), ("flash", "Flash"), ("punch", "Punch In"), ("whip", "Whip"),
  ]
}

public struct Plan: Codable, Equatable, Sendable {
  public struct Source: Codable, Equatable, Sendable {
    public var video: String
    public var width: Double
    public var height: Double
    public var duration: Double
  }
  public struct Camera: Codable, Equatable, Sendable {
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
    /// Flip the camera left to right, for a camera that records mirrored (text it shows reads
    /// backwards). `x`/`y` stay in the file's own coordinates.
    public var mirror: Bool?
    /// Punch-ins: the camera snaps tighter on the framing point for a beat, then snaps back.
    public var punchIns: [PunchIn]?

    public static let defaultBubbleSize = 0.24
    public static let shapes: [(name: String, label: String)] = [("circle", "Circle"), ("rounded", "Rounded"), ("square", "Square")]
    public init(video: String, offset: Double) {
      self.video = video
      self.offset = offset
    }
  }
  public struct Output: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
  }
  public struct Style: Codable, Equatable, Sendable {
    public var background: [String]
    public var padding: Double
    public var radius: Double
    public var transition: Double
    /// The house motion style: one of `MotionStyle.all` (nil is "smooth").
    public var motion: String?
    /// Width/height of the screen card. nil shows the whole screen; vertical and square formats
    /// crop (e.g. 0.8 is 4:5) and pan to follow zooms and clicks.
    public var screenAspect: Double?
    /// Side by side: the screen and camera touch at the same height, like one card, instead of
    /// sitting apart. Padded layouts only.
    public var joinSide: Bool?
    /// With no padding, crop the screen to fill the frame (and pan to follow zooms and clicks)
    /// instead of showing the whole screen with background around it. Landscape, square and feed.
    public var fill: Bool?
    /// How B-roll and animations come and go when they don't set their own `enter`/`exit` (nil cuts).
    public var brollMotion: Motion?

    /// The built-in look a new plan starts with.
    public static let standard = Style(background: ["#1d2b64", "#f8cdda"], padding: 0.06, radius: 14, transition: 0.8)
  }
  public struct Captions: Codable, Equatable, Sendable {
    @Defaulted<Fallback.False> public var enabled: Bool
    @Defaulted<Fallback.CaptionWords> public var maxWords: Int
    /// One of `Plan.Captions.styles` (nil is "pill").
    public var style: String?
    /// Where the captions sit: the center of the caption block as fractions of the output frame.
    /// nil keeps the style's place (the bottom, or the seam for social).
    public var x: Double?
    public var y: Double?
    /// A box behind bold and social captions, in the look's caption background color and opacity.
    /// The pill styles always have one.
    public var box: Bool?
    /// Text size relative to the style's (1 is the style's own; nil is 1).
    public var size: Double?
    /// Words or phrases ("home lab") drawn bigger in the look's `captionEmphasis` color wherever
    /// they're said. Case and punctuation don't matter.
    public var emphasis: [String]?

    /// Bold and social captions: big words, a few at a time, with an optional box behind them.
    public var isBold: Bool { style == "bold" || style == "social" }

    public static let styles: [(name: String, label: String)] = [
      ("pill", "Pill"), ("karaoke", "Karaoke"), ("pop", "Word Pop"), ("bold", "Bold"), ("social", "Social (big, for vertical)"),
    ]
  }

  /// 2: `segments` play in the order they're listed, so a clip can move ahead of earlier moments
  /// (a cold open). 1 (plans saved before that): they play in recording order.
  @Defaulted<Fallback.FirstVersion> public var version: Int = 2
  public var source: Source
  public var camera: Camera?
  public var output: Output
  @Defaulted<Fallback.StandardStyle> public var style: Style
  public var segments: [Segment]
  @Defaulted<Fallback.NoZooms> public var zooms: [Zoom]
  @Defaulted<Fallback.ScreenLayout> public var defaultLayout: LayoutMode
  @Defaulted<Fallback.NoLayouts> public var layouts: [LayoutRange]
  @Defaulted<Fallback.NoCaptions> public var captions: Captions
  @Defaulted<Fallback.True> public var clickRipples: Bool
  @Defaulted<Fallback.True> public var shortcutChips: Bool
  @Defaulted<Fallback.NoCallouts> public var callouts: [Callout]
  /// Spotlights, boxes, arrows, highlights and blurs on the screen.
  public var annotations: [Annotation]?
  /// Named points on the timeline.
  public var markers: [Marker]?
  /// B-roll clips and pictures.
  public var inserts: [Insert]?
  /// Motion-graphics explainers rendered from templates (see Animation).
  public var animations: [Animation]?
  /// Pieces of the edit exported on their own, like vertical social clips (see Clip).
  public var clips: [Clip]?
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
  /// Shaders from effect folders drawn on the screen, the camera or the whole frame (see Effects).
  public var effects: [EffectUse]?
  /// Effects that draw only from `start` to `end`, each with its own settings, like blob tracking
  /// for one stretch. They draw before the always-on `effects` on the same layer.
  public var effectRanges: [EffectRange]?
  /// Source seconds the publish covers are made from (up to three, oldest dropped first); nil
  /// picks the clearest camera frames.
  public var coverAt: [Double]?

  /// Adds a moment to make a cover from, replacing one within a second of it and keeping the
  /// three most recent.
  public mutating func addCover(at t: Double) {
    var list = (coverAt ?? []).filter { abs($0 - t) >= 1 }
    list.append((t * 100).rounded() / 100)
    coverAt = Array(list.suffix(3))
  }

  /// The segments in the order they play.
  public var playSegments: [Segment] { version >= 2 ? segments : segments.sorted { $0.start < $1.start } }

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
    if let old = try? Data(contentsOf: url), old != data { try PlanHistory.snapshot(old, planURL: url) }
    try data.write(to: url, options: .atomic)
  }
}

public struct CursorSettings: Codable, Equatable, Sendable {
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

extension Plan {
  /// How B-roll without its own `enter`/`exit` comes and goes: the style's `brollMotion`, else a hard cut.
  public var brollDefaultMotion: Motion { style.brollMotion ?? Motion(preset: "none") }
}
