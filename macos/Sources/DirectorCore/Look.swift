import CoreText
import Foundation

/// The branded look of a video: fonts, colors, frame and logo. Comes from a profile; nil fields
/// fall back to the built-in look.
public struct Look: Codable, Equatable {
  public struct Watermark: Codable, Equatable {
    /// Absolute path to a PNG (resolved from the profile folder when the profile is applied).
    public var image: String
    /// topLeft | topRight | bottomLeft | bottomRight
    public var corner: String?
    /// Height as a fraction of the output's short side.
    public var height: Double?
    public var opacity: Double?
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
  public var titleText: String?
  public var titleBackground: String?
  public var chipText: String?
  public var chipBackground: String?
  /// Click ripples and the bracket frame.
  public var accent: String?
  public var cameraBorder: String?
  /// "none" or "brackets" (corner brackets around the screen).
  public var frame: String?
  public var watermark: Watermark?
  /// Intro and outro cards for videos made with this look. The title may hold "{title}" (the
  /// recording's name); applying the profile writes the resolved text into the plan.
  public var intro: Card?
  public var outro: Card?

  public init() {}
}

/// A full-frame title card before or after the video, in the look's fonts and colors.
public struct Card: Codable, Equatable {
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
public struct Profile: Codable, Equatable {
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

  public struct CameraDefaults: Codable, Equatable {
    /// The whole grade; a `lut` path is relative to the profile folder.
    public var grade: Grade?
    public var bubbleSize: Double?
    public var bubbleShape: String?
    public var bubbleBorder: Bool?
    public var bubbleShadow: Bool?
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

  /// Loads profile.json from a folder and makes asset paths absolute.
  public static func load(_ dir: URL) throws -> Profile {
    var p = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: dir.appendingPathComponent("profile.json")))
    func abs(_ path: String) -> String { path.hasPrefix("/") ? path : dir.appendingPathComponent(path).path }
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
    if let motion = style.motion { plan.style.motion = motion }
    var look = self.look
    look.name = name
    plan.look = look
    if let captions {
      plan.captions.maxWords = captions.maxWords
      if let style = captions.style { plan.captions.style = style }
    }
    if let music { plan.music = music }
    if let audio {
      var a = plan.audio ?? AudioSettings()
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
    }
    if let defaultLayout { plan.defaultLayout = defaultLayout }
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

public enum Fonts {
  /// Each font file tried so far, and why it couldn't be registered (nil when it was).
  nonisolated(unsafe) private static var tried: [String: String?] = [:]

  /// Registers font files for this process (once each). A file that can't be registered is skipped
  /// here, so the frame still renders; `problems` says why, and `describe` warns about it.
  public static func register(_ paths: [String]?) {
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
      if case .some(.some(let why)) = tried[path] { out.append("font file \(path) isn't used: \(why)") }
    }
    for (field, name) in [("titleFont", look.titleFont), ("captionFont", look.captionFont), ("chipFont", look.chipFont)] {
      guard let name, !isAvailable(name) else { continue }
      out.append("\(field) \"\(name)\" isn't installed or in fontFiles, so another font is drawn instead")
    }
    return out
  }

  /// Whether CoreText finds this font by PostScript, full or family name rather than substituting one.
  static func isAvailable(_ name: String) -> Bool {
    let font = CTFontCreateWithName(name as CFString, 12, nil)
    let names = [CTFontCopyPostScriptName(font), CTFontCopyFullName(font), CTFontCopyFamilyName(font)].map { ($0 as String).lowercased() }
    return names.contains(name.lowercased())
  }
}
