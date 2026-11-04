import AppKit
import DirectorCore

/// The animation templates and logos a video can use: its own `animations/` folder, the personal
/// library, then the ones built into the app (see AnimationSources).
enum AnimationLibrary {
  /// The built-in set: in the app bundle, or the source tree for a `swift build` run.
  static let builtIn: URL = {
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("animations"),
      FileManager.default.fileExists(atPath: bundled.appendingPathComponent("animation.html").path)
    {
      return bundled
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/animations").standardizedFileURL
  }()

  static func sources(_ project: URL) -> AnimationSources { AnimationSources(project: project, builtIn: builtIn) }

  static func templates(_ project: URL) -> [(template: AnimationTemplate, origin: AnimationSources.Origin)] { sources(project).templates() }

  static func template(_ name: String, _ project: URL) -> AnimationTemplate? { sources(project).template(name)?.template }

  /// Logo names, alphabetically. Aliases of one file (ChatGPT and OpenAI) both stay, so a plan that
  /// names either one finds its entry in the pickers.
  /// A broken logos.json lists no logos here; rendering the animation reports what's wrong with it.
  static func logoNames(_ project: URL) -> [String] { ((try? sources(project).logos()) ?? [:]).keys.sorted() }

  private static var images: [URL: NSImage] = [:]

  static func image(_ name: String, _ project: URL) -> NSImage? {
    guard let url = (try? sources(project).logos())?[name] else { return nil }
    if let cached = images[url] { return cached }
    guard let img = NSImage(contentsOf: url) else { return nil }
    images[url] = img
    return img
  }
}
