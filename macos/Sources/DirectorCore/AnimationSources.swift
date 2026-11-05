import CryptoKit
import Foundation

/// Where animation templates and logos come from, first match wins: the video's own `animations/`
/// folder, then the personal library (~/Library/Application Support/Screencast Director/Animations),
/// then the ones built into the app. Each folder holds `templates/<name>.js` + `<name>.json` and
/// `logos/` with a `logos.json` (logo name → file in that folder).
///
/// A video freezes each template it uses by copying it into its own folder, so a template changed
/// later in the library never changes a finished video; the cached clip's name includes the frozen
/// copy's contents, so editing that copy re-renders it.
public struct AnimationSources: Sendable {
  public enum Origin: String, Sendable { case video, personal, builtIn }

  public let project: URL?
  public let personal: URL
  public let builtIn: URL

  public static var personalFolder: URL {
    AppPreferences.supportFolder.appendingPathComponent("Animations")
  }

  public init(project: URL?, builtIn: URL, personal: URL = AnimationSources.personalFolder) {
    self.project = project
    self.personal = personal
    self.builtIn = builtIn
  }

  /// A video's own animation folder.
  public static func videoFolder(_ project: URL) -> URL { project.appendingPathComponent("animations") }

  private var folders: [(Origin, URL)] {
    (project.map { [(Origin.video, AnimationSources.videoFolder($0))] } ?? []) + [(.personal, personal), (.builtIn, builtIn)]
  }

  /// Every template, by title, each from the first folder that has it.
  public func templates() -> [(template: AnimationTemplate, origin: Origin)] {
    var seen = Set<String>()
    var out: [(AnimationTemplate, Origin)] = []
    for (origin, folder) in folders {
      for t in AnimationTemplate.all(in: folder.appendingPathComponent("templates")) where seen.insert(t.name).inserted {
        out.append((t, origin))
      }
    }
    return out.sorted { $0.0.title < $1.0.title }
  }

  /// Template manifests that couldn't be read, with why, so a broken one doesn't just vanish.
  public func templateProblems() -> [String] {
    folders.flatMap { AnimationTemplate.load(in: $0.1.appendingPathComponent("templates")).problems }
  }

  public func template(_ name: String) -> (template: AnimationTemplate, origin: Origin)? {
    templates().first { $0.template.name == name }
  }

  /// The template's script, from the first folder that has it.
  public func script(_ name: String) -> URL? {
    folders.map { $0.1.appendingPathComponent("templates/\(name).js") }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Logo names to files, the video's overriding the personal library's overriding the app's.
  /// Throws, naming the file, when a logos.json is there but isn't a name-to-file map.
  public func logos() throws -> [String: URL] {
    var out: [String: URL] = [:]
    for (_, folder) in folders.reversed() {
      let dir = folder.appendingPathComponent("logos")
      let file = dir.appendingPathComponent("logos.json")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      let map: [String: String]
      do {
        map = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
      } catch {
        throw DirectorError("\(file.path) isn't a map of logo names to files: \(error.localizedDescription)")
      }
      for (name, file) in map { out[name] = dir.appendingPathComponent(file) }
    }
    return out
  }

  // MARK: Freezing

  /// The script and manifest files of a template in a folder.
  private static func files(_ name: String, in folder: URL) -> [URL] {
    ["js", "json"].map { folder.appendingPathComponent("templates/\(name).\($0)") }
  }

  /// The library version (personal, else built in) a video's copy came from or can update to.
  public func libraryFolder(for name: String) -> URL? {
    [personal, builtIn].first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("templates/\(name).js").path) }
  }

  /// Copies the template into the video's folder unless it's already there. Returns whether it copied.
  @discardableResult
  public func freeze(_ name: String) throws -> Bool {
    guard let project else { return false }
    let video = AnimationSources.videoFolder(project)
    guard !FileManager.default.fileExists(atPath: video.appendingPathComponent("templates/\(name).js").path) else { return false }
    guard let source = libraryFolder(for: name) else { return false }
    try copy(name, from: source, to: video)
    return true
  }

  /// Replaces the video's copy with the library's latest version.
  public func updateFromLibrary(_ name: String) throws {
    guard let project, let source = libraryFolder(for: name) else { return }
    try copy(name, from: source, to: AnimationSources.videoFolder(project))
  }

  /// Saves the video's copy into the personal library, for other videos to use.
  public func saveToPersonal(_ name: String) throws {
    guard let project else { return }
    try copy(name, from: AnimationSources.videoFolder(project), to: personal)
  }

  private func copy(_ name: String, from: URL, to: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: to.appendingPathComponent("templates"), withIntermediateDirectories: true)
    for (src, dst) in zip(AnimationSources.files(name, in: from), AnimationSources.files(name, in: to)) where fm.fileExists(atPath: src.path) {
      try? fm.removeItem(at: dst)
      try fm.copyItem(at: src, to: dst)
    }
  }

  /// Whether the video's copy differs from the library's current version (an update is available,
  /// or the video's copy was edited).
  public func differsFromLibrary(_ name: String) -> Bool {
    guard let project, let lib = libraryFolder(for: name) else { return false }
    return AnimationSources.digest(name, in: AnimationSources.videoFolder(project)) != AnimationSources.digest(name, in: lib)
  }

  /// A hash of a template's script and manifest in a folder ("" when it isn't there).
  public static func digest(_ name: String, in folder: URL) -> String {
    let data = files(name, in: folder).compactMap { try? Data(contentsOf: $0) }
    guard !data.isEmpty else { return "" }
    var h = SHA256()
    for d in data { h.update(data: d) }
    return h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
  }
}
