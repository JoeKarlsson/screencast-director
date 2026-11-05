import Foundation

/// A sound effect or music track in a library: the built-in ones listed in the bundle's manifest
/// (`Resources/sounds/sounds.json`, `Resources/music/music.json`), or an audio file in the personal
/// folder (its file name is its name).
public struct LibraryItem: Codable, Equatable, Sendable {
  public var name: String
  /// File name inside its library folder (and inside the project once used).
  public var file: String
  public var category: String
  /// When to use it ("an answer or result appears").
  public var use: String?
  public var length: Double?
  public var author: String?
  public var source: String?
  public var license: String?
}

/// Sound effects or music a plan can use before the file is in the project: the personal folder
/// (~/Library/Application Support/Screencast Director/Sounds or Music, any audio file) over the ones
/// built into the app. A plan names one as `sfx/<file>` or `music/<file>`; building the video copies
/// it into that project folder, so a file changed later in the library never changes a finished video.
public struct AudioLibrary: Sendable {
  public enum Kind: Sendable {
    case sounds, music

    /// The bundle folder and its manifest's name.
    var resource: String { self == .sounds ? "sounds" : "music" }
    /// The project folder plan paths point into.
    public var planFolder: String { self == .sounds ? "sfx" : "music" }
    public var personalCategory: String { self == .sounds ? "My Sounds" : "My Music" }
    var personalName: String { self == .sounds ? "Sounds" : "Music" }
  }

  static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"]

  public let kind: Kind
  public let builtIn: URL
  public let personal: URL

  public static func personalFolder(_ kind: Kind) -> URL {
    AppPreferences.supportFolder.appendingPathComponent(kind.personalName)
  }

  /// The app bundle's copy (for the app and the bundled `director`), else this repo's (builds run
  /// from macos/.build).
  public static func builtInFolder(_ kind: Kind) -> URL {
    let manifest = "\(kind.resource)/\(kind.resource).json"
    let bundled = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("../Resources").standardizedFileURL
    if FileManager.default.fileExists(atPath: bundled.appendingPathComponent(manifest).path) {
      return bundled.appendingPathComponent(kind.resource)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../Resources/\(kind.resource)").standardizedFileURL
  }

  public init(_ kind: Kind, builtIn: URL? = nil, personal: URL? = nil) {
    self.kind = kind
    self.builtIn = builtIn ?? AudioLibrary.builtInFolder(kind)
    self.personal = personal ?? AudioLibrary.personalFolder(kind)
  }

  public struct Entry: Equatable, Sendable {
    public var item: LibraryItem
    public var url: URL
    public var isPersonal: Bool
  }

  /// Every item: personal ones first (loose files as My Sounds/My Music, then each subfolder as a
  /// category named after it, all by name), then the built-in ones in manifest order. A personal
  /// file with a built-in item's file name replaces it. Plans name a sound by file name alone
  /// (`sfx/<file>`), so two personal files with the same name in different folders are an error.
  public func items() throws -> [Entry] {
    let fm = FileManager.default
    func audioFiles(in folder: URL, category: String) -> [Entry] {
      let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
      return names.sorted().filter { AudioLibrary.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.map { name in
        Entry(item: LibraryItem(name: (name as NSString).deletingPathExtension, file: name, category: category), url: folder.appendingPathComponent(name), isPersonal: true)
      }
    }
    var mine = audioFiles(in: personal, category: kind.personalCategory)
    let subfolders = ((try? fm.contentsOfDirectory(atPath: personal.path)) ?? []).sorted().filter { name in
      var isDir: ObjCBool = false
      return !name.hasPrefix(".") && fm.fileExists(atPath: personal.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
    }
    for folder in subfolders { mine += audioFiles(in: personal.appendingPathComponent(folder), category: folder) }
    var seen: [String: URL] = [:]
    for e in mine {
      if let other = seen[e.item.file] {
        throw DirectorError("Two files in your \(kind.personalName) folder are both named \"\(e.item.file)\" (\(other.path) and \(e.url.path)). Rename one: a video names its sounds by file name alone.")
      }
      seen[e.item.file] = e.url
    }
    let taken = Set(seen.keys)
    let data = try Data(contentsOf: builtIn.appendingPathComponent("\(kind.resource).json"))
    let builtIns = try JSONDecoder().decode([LibraryItem].self, from: data)
      .filter { !taken.contains($0.file) }
      .map { Entry(item: $0, url: builtIn.appendingPathComponent($0.file), isPersonal: false) }
    return mine + builtIns
  }

  /// The library item a plan path (`sfx/<file>` or `music/<file>`) names, if any.
  public func entry(forPlanPath path: String) throws -> Entry? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == kind.planFolder else { return nil }
    return try items().first { $0.item.file == parts[1] }
  }

  /// Copies a library item into the project's folder for this kind unless the project already has
  /// that file, and returns its plan path.
  @discardableResult
  public func freeze(_ entry: Entry, project: URL) throws -> String {
    let path = "\(kind.planFolder)/\(entry.item.file)"
    let target = project.appendingPathComponent(path)
    let fm = FileManager.default
    if !fm.fileExists(atPath: target.path) {
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: entry.url, to: target)
    }
    return path
  }

  /// Copies each library item named by these plan paths that the project doesn't have yet into
  /// it. Returns the plan paths it copied.
  @discardableResult
  public func freezeMissing(_ paths: [String], project: URL) throws -> [String] {
    var copied: [String] = []
    for path in Set(paths).sorted() {
      guard !FileManager.default.fileExists(atPath: project.appendingPathComponent(path).path),
        let entry = try entry(forPlanPath: path)
      else { continue }
      copied.append(try freeze(entry, project: project))
    }
    return copied
  }
}
