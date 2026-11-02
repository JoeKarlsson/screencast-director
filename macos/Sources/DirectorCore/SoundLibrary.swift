import Foundation

/// A sound effect in a library: the built-in ones listed in `Resources/sounds/sounds.json`, or an
/// audio file in the personal folder (its file name is its name).
public struct LibrarySound: Codable, Equatable {
  public var name: String
  /// File name inside its library folder (and inside a project's `sfx/` once used).
  public var file: String
  public var category: String
  /// When to use it ("an answer or result appears").
  public var use: String?
  public var length: Double?
  public var author: String?
  public var source: String?
  public var license: String?
}

/// Sound effects a plan can use before the file is in the project: the personal folder
/// (~/Library/Application Support/Screencast Director/Sounds, any audio file) over the ones built
/// into the app. A plan names one as `sfx/<file>`; building the video copies it into the project's
/// `sfx/` folder, so a sound changed later in the library never changes a finished video.
public struct SoundLibrary {
  public static let personalCategory = "My Sounds"
  static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "aac"]

  public let builtIn: URL
  public let personal: URL

  public static var personalFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Screencast Director/Sounds")
  }

  /// The app bundle's sounds (for the app and the bundled `director`), else this repo's copy (builds
  /// run from macos/.build).
  public static var builtInFolder: URL {
    let bundled = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("../Resources/sounds").standardizedFileURL
    if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("sounds.json").path) { return bundled }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/sounds").standardizedFileURL
  }

  public init(builtIn: URL = SoundLibrary.builtInFolder, personal: URL = SoundLibrary.personalFolder) {
    self.builtIn = builtIn
    self.personal = personal
  }

  public struct Entry: Equatable {
    public var sound: LibrarySound
    public var url: URL
    public var isPersonal: Bool
  }

  /// Every sound: personal ones first (by name), then the built-in ones in manifest order. A
  /// personal file with a built-in sound's file name replaces it.
  public func sounds() throws -> [Entry] {
    var mine: [Entry] = []
    if let names = try? FileManager.default.contentsOfDirectory(atPath: personal.path) {
      for name in names.sorted() where SoundLibrary.audioExtensions.contains((name as NSString).pathExtension.lowercased()) {
        let sound = LibrarySound(name: (name as NSString).deletingPathExtension, file: name, category: SoundLibrary.personalCategory)
        mine.append(Entry(sound: sound, url: personal.appendingPathComponent(name), isPersonal: true))
      }
    }
    let taken = Set(mine.map(\.sound.file))
    let data = try Data(contentsOf: builtIn.appendingPathComponent("sounds.json"))
    let builtIns = try JSONDecoder().decode([LibrarySound].self, from: data)
      .filter { !taken.contains($0.file) }
      .map { Entry(sound: $0, url: builtIn.appendingPathComponent($0.file), isPersonal: false) }
    return mine + builtIns
  }

  /// The library sound a plan path (`sfx/<file>`) names, if any.
  public func entry(forPlanPath path: String) throws -> Entry? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == "sfx" else { return nil }
    return try sounds().first { $0.sound.file == parts[1] }
  }

  /// Copies a library sound into the project's `sfx/` folder unless the project already has that
  /// file, and returns its plan path (`sfx/<file>`).
  @discardableResult
  public static func freeze(_ entry: Entry, project: URL) throws -> String {
    let path = "sfx/\(entry.sound.file)"
    let target = project.appendingPathComponent(path)
    let fm = FileManager.default
    if !fm.fileExists(atPath: target.path) {
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: entry.url, to: target)
    }
    return path
  }

  /// Copies each library sound the plan names but the project doesn't have yet into its `sfx/`
  /// folder. Returns the plan paths it copied.
  @discardableResult
  public func freezeMissing(_ plan: Plan, project: URL) throws -> [String] {
    var copied: [String] = []
    for path in Set(plan.soundEffects.map(\.file)).sorted() {
      guard !FileManager.default.fileExists(atPath: project.appendingPathComponent(path).path),
        let entry = try entry(forPlanPath: path)
      else { continue }
      copied.append(try SoundLibrary.freeze(entry, project: project))
    }
    return copied
  }
}
