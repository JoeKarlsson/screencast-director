import AppKit
import DirectorCore

/// The bundled animation templates and logo library (Resources/animations), for the editor.
enum AnimationLibrary {
  /// In the app bundle, or the source tree for a `swift build` run.
  static let dir: URL = {
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("animations"),
      FileManager.default.fileExists(atPath: bundled.appendingPathComponent("animation.html").path)
    {
      return bundled
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/animations").standardizedFileURL
  }()

  static let templates: [AnimationTemplate] = AnimationTemplate.all(in: dir.appendingPathComponent("templates"))

  static func template(_ name: String) -> AnimationTemplate? { templates.first { $0.name == name } }

  /// Logo names to file names, from logos/logos.json.
  static let logoFiles: [String: String] = {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("logos/logos.json")),
      let map = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return map
  }()

  /// Logo names, alphabetically. Aliases of one file (ChatGPT and OpenAI) both stay, so a plan that
  /// names either one finds its entry in the pickers.
  static let logoNames: [String] = logoFiles.keys.sorted()

  private static var images: [String: NSImage] = [:]

  static func image(_ name: String) -> NSImage? {
    if let cached = images[name] { return cached }
    guard let file = logoFiles[name], let img = NSImage(contentsOf: dir.appendingPathComponent("logos/\(file)")) else { return nil }
    images[name] = img
    return img
  }
}
