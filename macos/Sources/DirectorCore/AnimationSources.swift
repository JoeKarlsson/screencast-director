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
    guard PathSafety.isPlainName(name) else { return nil }
    return folders.map { $0.1.appendingPathComponent("templates/\(name).js") }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// A Lottie file an animation's data names (`data.lottie`), from the first folder whose `lottie/` has it.
  public func lottie(_ name: String) -> URL? {
    guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
    return folders.map { $0.1.appendingPathComponent("lottie/\(name)") }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// A Lottie file on offer: its name (what `data.lottie` takes), where it comes from, and what it's
  /// for (`meta.d`, else its own name), length and whether it plays once (a top-level `"loop": false`).
  public struct Lottie: Equatable, Sendable {
    public var name: String
    public var origin: Origin
    public var about: String
    public var seconds: Double
    public var loops: Bool

    /// Reads a Lottie, throwing when the file isn't one (no frame rate, frames, size or layers).
    public init(_ url: URL, origin: Origin) throws {
      let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
      guard let json, let fr = json["fr"] as? Double, fr > 0, let op = json["op"] as? Double, json["w"] is Double,
        json["h"] is Double, json["layers"] is [Any]
      else { throw DirectorError("\(url.lastPathComponent) isn't a Lottie animation (a Bodymovin .json with fr, op, w, h and layers)") }
      name = url.lastPathComponent
      self.origin = origin
      about = (json["meta"] as? [String: Any])?["d"] as? String ?? (json["nm"] as? String ?? name)
      seconds = (op - (json["ip"] as? Double ?? 0)) / fr
      loops = json["loop"] as? Bool ?? true
    }
  }

  /// Every Lottie file, by name, each from the first folder that has it; files that aren't Lotties are left out.
  public func lotties() -> [Lottie] {
    var seen = Set<String>()
    var out: [Lottie] = []
    for (origin, folder) in folders {
      let dir = folder.appendingPathComponent("lottie")
      let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
      for file in files where file.pathExtension == "json" && !seen.contains(file.lastPathComponent) {
        if let lottie = try? Lottie(file, origin: origin) {
          seen.insert(lottie.name)
          out.append(lottie)
        }
      }
    }
    return out.sorted { $0.name < $1.name }
  }

  /// Copies a Lottie file from anywhere into the video's `animations/lottie/` (or the personal library's),
  /// after checking it is one. Refuses to replace a different file of the same name, which a finished video may play.
  @discardableResult
  public func addLottie(_ file: URL, toLibrary: Bool = false) throws -> Lottie {
    guard let folder = toLibrary ? personal : project.map(AnimationSources.videoFolder) else { throw DirectorError("no video to add the Lottie to") }
    let lottie = try Lottie(file, origin: toLibrary ? .personal : .video)
    let dst = toLibrary
      ? folder.appendingPathComponent("lottie/\(lottie.name)")
      : try PathSafety.ownedFolder("animations/lottie", in: folder.deletingLastPathComponent()).appendingPathComponent(lottie.name)
    let fm = FileManager.default
    if fm.fileExists(atPath: dst.path) {
      guard try Data(contentsOf: dst) == Data(contentsOf: file) else {
        throw DirectorError("there's already a different \(lottie.name) in \(dst.deletingLastPathComponent().path); rename the new one")
      }
      return lottie
    }
    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: file, to: dst)
    return lottie
  }

  /// Copies a Lottie file into the video's folder unless it's already there, like a template, so the
  /// clip's name follows the video's copy. Returns whether it copied.
  @discardableResult
  public func freezeLottie(_ name: String) throws -> Bool {
    guard let project, let source = lottie(name) else { return false }
    let dst = AnimationSources.videoFolder(project).appendingPathComponent("lottie/\(name)")
    guard source != dst else { return false }
    try PathSafety.ownedFolder("animations/lottie", in: project)
    try FileManager.default.copyItem(at: source, to: try PathSafety.ownedFile(dst))
    return true
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
      for (name, file) in map {
        // A project someone sent could map a name to "../../Pictures/x.jpg"; logos stay in their folder.
        let logo = dir.appendingPathComponent(file)
        guard PathSafety.url(logo, isInside: dir) else { throw DirectorError("\(file.debugDescription) in \(dir.path)/logos.json isn't a file in that folder") }
        out[name] = logo
      }
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
    guard PathSafety.isPlainName(name) else { return nil }
    return [personal, builtIn].first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("templates/\(name).js").path) }
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
    // The name becomes a path: "../" in it once let `template update` delete any .js file.
    guard PathSafety.isPlainName(name) else { throw DirectorError("a template name can only use letters, digits, - and _, not \(name.debugDescription)") }
    let fm = FileManager.default
    if let project, to == AnimationSources.videoFolder(project) {
      try PathSafety.ownedFolder("animations/templates", in: project)
    } else {
      try fm.createDirectory(at: to.appendingPathComponent("templates"), withIntermediateDirectories: true)
    }
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

  /// A hash of a file's contents ("" when it isn't there).
  public static func digest(of file: URL) -> String {
    guard let data = try? Data(contentsOf: file) else { return "" }
    return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
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
