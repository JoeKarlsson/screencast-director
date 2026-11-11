import CoreText
import Foundation

/// The branded look of a video: fonts, colors, frame and logo. Comes from a profile; nil fields
/// fall back to the built-in look.
public struct Look: Codable, Equatable, Sendable {
  public struct Watermark: Codable, Equatable, Sendable {
    /// A PNG: absolute, or relative to the project (a profile's relative path resolves from its folder when applied).
    public var image: String
    /// topLeft | topRight | bottomLeft | bottomRight | top | bottom (centered; full bleed only)
    public var corner: String?
    /// Height as a fraction of the output's short side.
    public var height: Double?
    public var opacity: Double?

    public init(image: String, corner: String? = nil, height: Double? = nil, opacity: Double? = nil) {
      self.image = image
      self.corner = corner
      self.height = height
      self.opacity = opacity
    }
  }

  public var name: String?
  /// Absolute paths of font files to load before rendering.
  public var fontFiles: [String]?
  /// PostScript names (e.g. "DMSans-Medium").
  public var captionFont: String?
  public var titleFont: String?
  public var chipFont: String?
  public var captionText: String?
  /// Color of the word being spoken; nil means captionText.
  public var captionHighlight: String?
  public var captionBackground: String?
  public var captionBackgroundOpacity: Double?
  /// Color of the caption words in `captions.emphasis`; nil is the accent.
  public var captionEmphasis: String?
  /// Vertical chapter chips list the earlier chapters under them, ticked, like a checklist.
  public var chapterChecklist: Bool?
  /// How chapters show: nil is the chip (vertical) or the card; "big" is joekarlsson.com's hero, a
  /// black block rising under the picture with the chapter in huge type and crayon marks drawing in.
  public var chapterStyle: String?
  public var titleText: String?
  public var titleBackground: String?
  public var chipText: String?
  public var chipBackground: String?
  /// Click ripples and the bracket frame.
  public var accent: String?
  public var cameraBorder: String?
  /// "none", "brackets" (corner brackets around the screen) or "window" (a title bar with three
  /// dots over the screen card and a square or rectangular camera, when padded).
  public var frame: String?
  public var watermark: Watermark?
  /// Intro and outro cards for videos made with this look. The title may hold "{title}" (the
  /// recording's name); applying the profile writes the resolved text into the plan.
  public var intro: Card?
  public var outro: Card?
  /// How animations look: nil is the paper collage; "terminal" is dark, with thin outlined cards and
  /// no drop shadows; "zine" is black and hot pink, drawn in crayon.
  public var animationTheme: String?

  public init() {}

  /// Colors that aren't #rrggbb hex: the renderer would draw them black.
  public var badColors: [String] {
    let fields: [(String, String?)] = [
      ("captionText", captionText), ("captionHighlight", captionHighlight), ("captionBackground", captionBackground),
      ("captionEmphasis", captionEmphasis), ("titleText", titleText), ("titleBackground", titleBackground), ("chipText", chipText),
      ("chipBackground", chipBackground), ("accent", accent), ("cameraBorder", cameraBorder),
    ]
    return fields.compactMap { name, value in
      guard let value, !Look.isHexColor(value) else { return nil }
      return "look.\(name) \"\(value)\" isn't a #rrggbb color, so it draws black"
    }
  }

  /// "#1d2b64" or "1d2b64".
  public static func isHexColor(_ s: String) -> Bool {
    let hex = s.hasPrefix("#") ? s.dropFirst() : Substring(s)
    return hex.count == 6 && hex.allSatisfy(\.isHexDigit)
  }
}

/// A full-frame title card before or after the video, in the look's fonts and colors.
public struct Card: Codable, Equatable, Sendable {
  public var enabled: Bool?
  /// Seconds on screen. Default 2.5.
  public var duration: Double?
  public var title: String?
  public var subtitle: String?
  /// Absolute path to a PNG; nil uses the look's watermark logo.
  public var logo: String?

  public static let defaultDuration = 2.5

  public init(enabled: Bool? = true, duration: Double? = nil, title: String? = nil, subtitle: String? = nil, logo: String? = nil) {
    self.enabled = enabled
    self.duration = duration
    self.title = title
    self.subtitle = subtitle
    self.logo = logo
  }

  /// A card is shown unless it says "enabled": false, so one written into plan.json or a profile by hand shows up.
  public var isOn: Bool { enabled ?? true }
  public var seconds: Double { max(0.5, duration ?? Card.defaultDuration) }

  /// Replaces "{title}" with the recording's name.
  public func resolved(name: String) -> Card {
    var c = self
    c.title = (title ?? "{title}").replacingOccurrences(of: "{title}", with: name)
    c.subtitle = subtitle?.replacingOccurrences(of: "{title}", with: name)
    return c
  }
}

/// A named profile: a look plus the style it pairs with. Lives in a folder with profile.json and
/// its assets (fonts, logos); relative paths in profile.json resolve against that folder.
public struct Profile: Codable, Equatable, Sendable {
  public var name: String
  public var style: Plan.Style
  public var look: Look
  public var captions: Plan.Captions?
  /// A default background track for videos with this profile (path relative to the profile folder).
  public var music: Music?
  /// Voice settings; only the fields set here change a video's.
  public var audio: AudioSettings?
  /// Camera color and bubble; only the fields set here change a video's (and only if it has a camera).
  public var camera: CameraDefaults?
  public var defaultLayout: LayoutMode?
  /// Effects every video with this profile uses (names from the personal Effects folder).
  public var effects: [EffectUse]?
  /// A work profile: its videos can use the sounds and music licensed for work only (Work/Sounds,
  /// Work/Music in the support folder), and no other video can.
  public var work: Bool?

  public struct CameraDefaults: Codable, Equatable, Sendable {
    /// The whole grade; a `lut` path is relative to the profile folder.
    public var grade: Grade?
    public var bubbleSize: Double?
    public var bubbleShape: String?
    public var bubbleBorder: Bool?
    public var bubbleShadow: Bool?
    public var room: String?
    public var outline: Bool?
    public init(grade: Grade? = nil, bubbleSize: Double? = nil, bubbleShape: String? = nil, bubbleBorder: Bool? = nil, bubbleShadow: Bool? = nil) {
      self.grade = grade
      self.bubbleSize = bubbleSize
      self.bubbleShape = bubbleShape
      self.bubbleBorder = bubbleBorder
      self.bubbleShadow = bubbleShadow
    }
  }

  public init(
    name: String, style: Plan.Style, look: Look, captions: Plan.Captions? = nil, music: Music? = nil,
    audio: AudioSettings? = nil, camera: CameraDefaults? = nil, defaultLayout: LayoutMode? = nil
  ) {
    self.name = name
    self.style = style
    self.look = look
    self.captions = captions
    self.music = music
    self.audio = audio
    self.camera = camera
    self.defaultLayout = defaultLayout
  }

  /// What Save as Profile can carry besides the look, style, captions, layout and effects.
  public enum Extra: CaseIterable, Sendable {
    case music, voice, camera
  }

  /// A profile made from a video: its look (the intro's title back to the "{title}" template), style,
  /// captions, default layout and always-on effects, plus the `extras` asked for.
  public static func saved(from plan: Plan, name: String, extras: Set<Extra>) -> Profile {
    var look = plan.look ?? Look()
    look.name = nil
    look.intro = plan.intro.map { var c = $0; c.title = "{title}"; return c } ?? look.intro
    look.outro = plan.outro ?? look.outro
    var p = Profile(name: name, style: plan.style, look: look, captions: plan.captions,
      // A screen-only video's layout says nothing about where a camera should go.
      defaultLayout: plan.camera != nil ? plan.defaultLayout : nil)
    p.effects = plan.effects
    if extras.contains(.music) { p.music = plan.music; p.music?.off = nil }  // off ranges belong to one video
    if extras.contains(.voice) { p.audio = plan.audio }
    if extras.contains(.camera), let cam = plan.camera {
      p.camera = CameraDefaults(grade: cam.grade, bubbleSize: cam.bubbleSize, bubbleShape: cam.bubbleShape, bubbleBorder: cam.bubbleBorder, bubbleShadow: cam.bubbleShadow)
      p.camera?.room = cam.room
      p.camera?.outline = cam.outline
    }
    return p
  }

  /// Loads profile.json from a folder and makes asset paths absolute.
  public static func load(_ dir: URL) throws -> Profile {
    var p = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: dir.appendingPathComponent("profile.json")))
    func abs(_ path: String) -> String { resolvePath(path, in: dir).path }
    p.look.fontFiles = p.look.fontFiles?.map(abs)
    if let w = p.look.watermark { p.look.watermark?.image = abs(w.image) }
    if let m = p.music { p.music?.file = abs(m.file) }
    if let lut = p.camera?.grade?.lut { p.camera?.grade?.lut = abs(lut) }
    if let l = p.look.intro?.logo { p.look.intro?.logo = abs(l) }
    if let l = p.look.outro?.logo { p.look.outro?.logo = abs(l) }
    return p
  }

  /// `name` is the recording's name, for "{title}" in the intro and outro.
  public func apply(to plan: inout Plan, name: String? = nil) {
    plan.style.background = style.background
    plan.style.padding = style.padding
    plan.style.radius = style.radius
    plan.style.transition = style.transition
    plan.style.joinSide = style.joinSide
    plan.style.fill = style.fill
    if let motion = style.motion { plan.style.motion = motion }
    if let broll = style.brollMotion { plan.style.brollMotion = broll }
    var look = self.look
    look.name = name
    plan.look = look
    plan.profile = self.name
    if let captions {
      plan.captions.maxWords = captions.maxWords
      if let style = captions.style { plan.captions.style = style }
    }
    if let music { plan.music = Music(file: music.file, volumeDB: music.volumeDB, duckDB: music.duckDB, off: plan.music?.off) }
    if let audio {
      var a = plan.audioSettings
      if let v = audio.normalize { a.normalize = v }
      if let v = audio.gainDB { a.gainDB = v }
      if let v = audio.cleanup { a.cleanup = v }
      if let v = audio.warm { a.warm = v }
      plan.audio = a
    }
    if let camera, plan.camera != nil {
      if let v = camera.grade { plan.camera?.grade = v }
      if let v = camera.bubbleSize { plan.camera?.bubbleSize = v }
      if let v = camera.bubbleShape { plan.camera?.bubbleShape = v }
      if let v = camera.bubbleBorder { plan.camera?.bubbleBorder = v }
      if let v = camera.bubbleShadow { plan.camera?.bubbleShadow = v }
      if let v = camera.room { plan.camera?.room = v }
      if let v = camera.outline { plan.camera?.outline = v }
    }
    if let defaultLayout { plan.defaultLayout = defaultLayout }
    if let effects { plan.effects = effects }
    // Cards the profile switches on. Text already in the plan (typed by hand) is kept.
    func card(_ c: Card?, _ old: Card?) -> Card? {
      guard let c, c.isOn else { return old }
      var card = c.resolved(name: name ?? "")
      card.title = old?.title ?? card.title
      card.subtitle = old?.subtitle ?? card.subtitle
      return card
    }
    plan.intro = card(look.intro, plan.intro)
    plan.outro = card(look.outro, plan.outro)
  }
}

public enum Fonts: Sendable {
  /// Each font file tried so far, and why it couldn't be registered (nil when it was). The preview and
  /// an export register fonts from different threads, so every access holds `lock`.
  nonisolated(unsafe) private static var tried: [String: String?] = [:]
  private static let lock = NSLock()

  /// Registers font files for this process (once each). A file that can't be registered is skipped
  /// here, so the frame still renders; `problems` says why, and `describe` warns about it.
  public static func register(_ paths: [String]?) {
    lock.lock()
    defer { lock.unlock() }
    for path in paths ?? [] where tried[path] == nil {
      var error: Unmanaged<CFError>?
      let ok = CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, &error)
      let why = error.map { ($0.takeRetainedValue() as Error).localizedDescription }
      // Already registered (by this process or the system) is fine.
      let alreadyThere = why?.contains("already") == true
      tried[path] = ok || alreadyThere ? .some(nil) : .some(why ?? "it isn't a font CoreText can read")
    }
  }

  /// Why the look's fonts won't all be used: font files that can't be registered, and named fonts
  /// that are neither installed nor in `fontFiles` (CoreText would silently draw another font).
  public static func problems(_ look: Look) -> [String] {
    register(look.fontFiles)
    var out: [String] = []
    for path in look.fontFiles ?? [] {
      if case .some(.some(let why)) = lock.withLock({ tried[path] }) { out.append("font file \(path) isn't used: \(why)") }
    }
    for (field, name) in [("titleFont", look.titleFont), ("captionFont", look.captionFont), ("chipFont", look.chipFont)] {
      guard let name, !isAvailable(name) else { continue }
      out.append("\(field) \"\(name)\" isn't installed or in fontFiles, so another font is drawn instead")
    }
    return out
  }

  /// The fonts a caption or title can use: the PostScript names in the look's font files, then the
  /// named font if it's somewhere else (installed), deduplicated in that order.
  public static func choices(_ look: Look?) -> [String] {
    var out: [String] = []
    for path in look?.fontFiles ?? [] {
      let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor] ?? []
      for d in descriptors {
        if let name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String, !out.contains(name) { out.append(name) }
      }
    }
    for name in [look?.captionFont, look?.titleFont].compactMap({ $0 }) where !out.contains(name) { out.append(name) }
    return out
  }

  /// Whether CoreText finds this font by PostScript, full or family name rather than substituting one.
  static func isAvailable(_ name: String) -> Bool {
    let font = CTFontCreateWithName(name as CFString, 12, nil)
    let names = [CTFontCopyPostScriptName(font), CTFontCopyFullName(font), CTFontCopyFamilyName(font)].map { ($0 as String).lowercased() }
    return names.contains(name.lowercased())
  }
}
