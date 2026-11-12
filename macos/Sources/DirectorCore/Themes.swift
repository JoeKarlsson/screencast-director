import CryptoKit
import Foundation

/// An animation theme's `theme.json`: what its folder holds besides it. Every file is a plain name in
/// the theme's own folder.
public struct ThemeManifest: Codable, Equatable, Sendable {
  public var title: String?
  /// A stylesheet added after the page's own.
  public var css: String?
  /// Scripts run in order after engine.js and the template; one registers `THEMES[name]`.
  public var scripts: [String]?
  /// A marks.json replacing the app's marks by name, for the animations and the native drawing.
  public var marks: String?
  /// Covers get the theme's marks drawn on them.
  public var coverMarks: Bool?
}

/// A theme loaded for a render: its stylesheet and scripts as text, its marks over the app's.
public struct Theme: Sendable {
  public var name: String
  public var manifest: ThemeManifest
  public var css: String
  public var scripts: [(file: String, source: String)]
  public var marks: MarkSet
}

/// Where animation themes come from: the video's `animations/themes/<name>/` (its frozen copy), then
/// the personal library's `Animations/themes/<name>/`, where packs install them. Paper (no theme) and
/// "terminal" are built into the page and have no folder. A theme can come with a video someone sent:
/// its CSS and scripts only run in the offline animation page, and its marks are only drawn.
public struct ThemeSources: Sendable {
  public let project: URL?
  public let personal: URL

  /// The themes the page draws itself.
  public static let builtIn: [(name: String, title: String)] = [("", "Paper"), ("terminal", "Terminal")]

  public static var personalFolder: URL {
    AnimationSources.personalFolder.appendingPathComponent("themes")
  }

  public init(project: URL?, personal: URL = ThemeSources.personalFolder) {
    self.project = project
    self.personal = personal
  }

  public static func videoFolder(_ project: URL) -> URL { AnimationSources.videoFolder(project).appendingPathComponent("themes") }

  /// Whether `name` is drawn by the page itself (nil and "" are paper).
  public static func isBuiltIn(_ name: String?) -> Bool { ThemeSources.builtIn.contains { $0.name == (name ?? "") } }

  /// The folder a theme loads from, or nil when no folder has it.
  public func folder(_ name: String) -> URL? {
    guard PathSafety.isPlainName(name) else { return nil }
    let candidates = (project.map { [ThemeSources.videoFolder($0)] } ?? []) + [personal]
    return candidates.map { $0.appendingPathComponent(name) }.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("theme.json").path)
    }
  }

  /// Every theme to pick from: the built-in ones, then the installed and frozen ones by title.
  public func available() -> [(name: String, title: String)] {
    let candidates = (project.map { [ThemeSources.videoFolder($0)] } ?? []) + [personal]
    let names = Set(candidates.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] })
    let installed = names.filter { folder($0) != nil && !ThemeSources.isBuiltIn($0) }
      .map { ($0, (try? manifest($0))?.title ?? $0) }.sorted { $0.1 < $1.1 }
    return ThemeSources.builtIn + installed
  }

  public func manifest(_ name: String) throws -> ThemeManifest {
    guard let dir = folder(name) else { throw ThemeSources.missing(name) }
    let file = dir.appendingPathComponent("theme.json")
    do {
      return try JSONDecoder().decode(ThemeManifest.self, from: Data(contentsOf: file))
    } catch {
      throw DirectorError("\(file.path) isn't a theme manifest: \(error.localizedDescription)")
    }
  }

  static func missing(_ name: String) -> DirectorError {
    DirectorError("the \"\(name)\" animation theme isn't installed: install the pack that has it (File > Install Pack…, or `director pack install`), or pick another theme")
  }

  /// The theme for a look's `animationTheme`: nil for a built-in one. Throws when it isn't installed
  /// or a file it names is missing or not a plain file in its folder.
  public func load(_ name: String?) throws -> Theme? {
    guard let name, !ThemeSources.isBuiltIn(name) else { return nil }
    let m = try manifest(name)
    let dir = folder(name)!
    func text(_ file: String) throws -> String {
      try String(contentsOf: try ThemeSources.file(file, in: dir, theme: name), encoding: .utf8)
    }
    return Theme(
      name: name, manifest: m, css: try m.css.map(text) ?? "",
      scripts: try (m.scripts ?? []).map { ($0, try text($0)) },
      marks: try m.marks.map { try MarkSet.load(ThemeSources.file($0, in: dir, theme: name)) } ?? MarkSet([:]))
  }

  /// A file a theme names: a plain file name in its folder, not a symlink.
  static func file(_ name: String, in dir: URL, theme: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    guard !name.contains("/"), !name.hasPrefix("."), !PathSafety.isSymlink(url.path), FileManager.default.fileExists(atPath: url.path) else {
      throw DirectorError("the \"\(theme)\" theme names \(name.debugDescription), which isn't a file in \(dir.path)")
    }
    return url
  }

  /// The theme a video's native drawing uses, frozen into the video first: nil for a built-in theme,
  /// or one that isn't installed (its marks fall back to the app's; validate and describe say so).
  public func forVideo(_ name: String?) throws -> Theme? {
    try freeze(name)
    guard let name, !ThemeSources.isBuiltIn(name), folder(name) != nil else { return nil }
    return try load(name)
  }

  /// The marks native drawing uses for a look: the theme's over the app's. A theme that isn't
  /// installed draws the app's marks (describe warns about it); a broken one throws.
  public func marks(for name: String?) throws -> MarkSet {
    guard let name, !ThemeSources.isBuiltIn(name), folder(name) != nil else { return .builtIn }
    return try load(name)?.marks ?? .builtIn
  }

  /// The theme's files (theme.json and the regular files beside it), sorted by name.
  private static func files(in dir: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.sorted().map { dir.appendingPathComponent($0) }.filter { url in
      var isDir: ObjCBool = false
      return !url.lastPathComponent.hasPrefix(".") && !PathSafety.isSymlink(url.path)
        && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }
  }

  /// Copies the library's theme into the video unless it's already there, so changing the library
  /// later never changes a finished video. Returns whether it copied.
  @discardableResult
  public func freeze(_ name: String?) throws -> Bool {
    guard let project, let name, !ThemeSources.isBuiltIn(name), PathSafety.isPlainName(name) else { return false }
    let src = personal.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: ThemeSources.videoFolder(project).appendingPathComponent("\(name)/theme.json").path),
      FileManager.default.fileExists(atPath: src.appendingPathComponent("theme.json").path)
    else { return false }
    let dst = try PathSafety.ownedFolder("animations/themes/\(name)", in: project)
    for file in ThemeSources.files(in: src) {
      let to = try PathSafety.ownedFile(dst.appendingPathComponent(file.lastPathComponent))
      try? FileManager.default.removeItem(at: to)
      try FileManager.default.copyItem(at: file, to: to)
    }
    return true
  }

  /// A hash of the theme's files where it loads from ("" for a built-in or missing theme), for the
  /// clip's name: the same before and after it's frozen, different when the video's copy changes.
  public func digest(_ name: String?) -> String {
    guard let name, !ThemeSources.isBuiltIn(name), let dir = folder(name) else { return "" }
    var h = SHA256()
    for file in ThemeSources.files(in: dir) {
      h.update(data: Data(file.lastPathComponent.utf8))
      if let d = try? Data(contentsOf: file) { h.update(data: d) }
    }
    return h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
  }
}
