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

  public init() {}
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

  public init(name: String, style: Plan.Style, look: Look, captions: Plan.Captions? = nil, music: Music? = nil) {
    self.name = name
    self.style = style
    self.look = look
    self.captions = captions
    self.music = music
  }

  /// Loads profile.json from a folder and makes asset paths absolute.
  public static func load(_ dir: URL) throws -> Profile {
    var p = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: dir.appendingPathComponent("profile.json")))
    func abs(_ path: String) -> String { path.hasPrefix("/") ? path : dir.appendingPathComponent(path).path }
    p.look.fontFiles = p.look.fontFiles?.map(abs)
    if let w = p.look.watermark { p.look.watermark?.image = abs(w.image) }
    if let m = p.music { p.music?.file = abs(m.file) }
    return p
  }

  public func apply(to plan: inout Plan) {
    plan.style.background = style.background
    plan.style.padding = style.padding
    plan.style.radius = style.radius
    plan.style.transition = style.transition
    var look = self.look
    look.name = name
    plan.look = look
    if let captions { plan.captions.maxWords = captions.maxWords }
    if let music { plan.music = music }
  }
}

public enum Fonts {
  nonisolated(unsafe) private static var registered = Set<String>()

  /// Registers font files for this process (once each).
  public static func register(_ paths: [String]?) {
    for path in paths ?? [] where !registered.contains(path) {
      registered.insert(path)
      CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, nil)
    }
  }
}
