import CryptoKit
import Foundation

/// A pack: a folder (or a `.sdpack` zip of one) laid out like the support folder, so installing it
/// is copying it in. It carries profiles with their fonts, LUTs and logos, animation themes,
/// templates, logos and Lotties, effects, sounds and music, and a work library:
///
///     pack.json                {"name": "My Look", "version": "1.0", "about": "…"}
///     Profiles/<name>/…        Animations/{themes,templates,logos,lottie}/…
///     Effects/<name>/…         Sounds/…   Music/…   Work/{Sounds,Music}/…
///
/// Files at the top (pack.json, a README, a LICENSE, a script that zips it) are never copied, nor is
/// anything starting with a dot (a pack kept in git); a folder at the top must be one of `roots`. Nothing in a pack runs at install: its files only do what the same files do
/// in the support folder (a theme's scripts run in the offline animation page, an effect on the GPU).
public enum Packs {
  public struct Manifest: Codable, Equatable, Sendable {
    public var name: String
    public var version: String?
    public var about: String?
    public init(name: String, version: String? = nil, about: String? = nil) {
      self.name = name
      self.version = version
      self.about = about
    }
  }

  /// What installing a pack would do, by path relative to the support folder.
  public struct Plan: Equatable, Sendable {
    /// Files the support folder doesn't have yet.
    public var new: [String] = []
    /// Files it already has, byte for byte.
    public var same: [String] = []
    /// Files it has with different contents, which installing replaces only when asked.
    public var conflicts: [String] = []
  }

  /// An installed pack's record (<support>/Packs/<name>.json): each file it put there and its hash,
  /// so removing it leaves alone what was changed since.
  public struct Record: Codable, Equatable, Sendable {
    public var name: String
    public var version: String?
    public var files: [String: String]
  }

  /// The folders a pack may fill.
  public static let roots = ["Profiles", "Animations", "Effects", "Sounds", "Music", "Work"]
  /// A zip may unpack to at most this much.
  public static let maxBytes: Int64 = 4 << 30

  static func recordsFolder(_ support: URL) -> URL { support.appendingPathComponent("Packs") }

  // MARK: Opening

  /// The pack's folder: `url` itself, or a `.sdpack`/`.zip` unpacked into a temp folder (the second
  /// value, to delete afterwards). A zip with paths that leave it, symlinks or more than `maxBytes`
  /// is refused before anything is unpacked.
  public static func open(_ url: URL) throws -> (folder: URL, temp: URL?) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw DirectorError("no pack at \(url.path)") }
    if isDir.boolValue { return (url, nil) }
    guard ["sdpack", "zip"].contains(url.pathExtension.lowercased()) else {
      throw DirectorError("\(url.lastPathComponent) isn't a pack: give a pack folder or a .sdpack file")
    }
    try checkZip(url)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sdpack-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    do {
      try run("/usr/bin/ditto", ["-x", "-k", url.path, temp.path])
      // `ditto -c -k --keepParent` puts everything in one folder named after the pack.
      let top = try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
      if top.count == 1, !FileManager.default.fileExists(atPath: temp.appendingPathComponent("pack.json").path) {
        return (temp.appendingPathComponent(top[0]), temp)
      }
      return (temp, temp)
    } catch {
      try? FileManager.default.removeItem(at: temp)
      throw error
    }
  }

  /// Refuses a zip whose listing has an absolute path, a "..", a backslash or a symlink, or that
  /// unpacks to more than `maxBytes`.
  static func checkZip(_ url: URL) throws {
    let listing = try run("/usr/bin/zipinfo", ["-l", url.path])
    var total: Int64 = 0
    for line in listing.split(separator: "\n").map(String.init) {
      let cols = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true).map(String.init)
      // "-rw-r--r--  3.0 unx  1234 tx  567 defN 24-Nov-12 12:00 path": entries start with a mode.
      guard cols.count == 10, let mode = cols.first, mode.count == 10, "-dl".contains(mode.first!) else { continue }
      let path = cols[9]
      if mode.first == "l" { throw DirectorError("\(url.lastPathComponent) has a symlink (\(path)); packs can't") }
      if path.hasPrefix("/") || path.contains("\\") || path.split(separator: "/").contains("..") {
        throw DirectorError("\(url.lastPathComponent) has a path that leaves the pack (\(path))")
      }
      total += Int64(cols[3]) ?? 0
    }
    if total > maxBytes { throw DirectorError("\(url.lastPathComponent) unpacks to \(total >> 20) MB, more than a pack may") }
  }

  public static func manifest(_ folder: URL) throws -> Manifest {
    let file = folder.appendingPathComponent("pack.json")
    guard FileManager.default.fileExists(atPath: file.path) else { throw DirectorError("\(folder.path) isn't a pack: it has no pack.json") }
    let m: Manifest
    do {
      m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
    } catch {
      throw DirectorError("\(file.path) isn't a pack manifest ({\"name\": …}): \(error.localizedDescription)")
    }
    let name = m.name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw DirectorError("\(m.name.debugDescription) can't be a pack's name") }
    return m
  }

  // MARK: Installing

  /// Each file the pack would copy, by relative path. Throws on a symlink anywhere, an entry that's
  /// neither a file nor a folder, or a folder at the top that isn't one of `roots`.
  public static func files(_ folder: URL) throws -> [String] {
    var out: [String] = []
    let fm = FileManager.default
    func walk(_ dir: URL, _ rel: [String]) throws {
      for name in try fm.contentsOfDirectory(atPath: dir.path).sorted() where !name.hasPrefix(".") {
        let url = dir.appendingPathComponent(name), path = rel + [name]
        let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        if type == .typeSymbolicLink { throw DirectorError("the pack has a symlink at \(path.joined(separator: "/")); packs can't") }
        if rel.isEmpty {
          if type == .typeRegular { continue }
          guard roots.contains(name), type == .typeDirectory else {
            throw DirectorError("the pack has a \(name) folder at its top; a pack's folders are \(roots.joined(separator: ", "))")
          }
        }
        switch type {
        case .typeDirectory?: try walk(url, path)
        case .typeRegular?: out.append(path.joined(separator: "/"))
        default: throw DirectorError("the pack's \(path.joined(separator: "/")) isn't a file or a folder")
        }
      }
    }
    try walk(folder, [])
    return out
  }

  /// What installing the pack folder into `support` would copy, skip and replace.
  public static func plan(_ folder: URL, into support: URL) throws -> Plan {
    var plan = Plan()
    for rel in try files(folder) {
      let dst = support.appendingPathComponent(rel)
      if !FileManager.default.fileExists(atPath: dst.path) {
        plan.new.append(rel)
      } else if (try? Data(contentsOf: dst)) == (try? Data(contentsOf: folder.appendingPathComponent(rel))) {
        plan.same.append(rel)
      } else {
        plan.conflicts.append(rel)
      }
    }
    return plan
  }

  /// Installs a pack (folder or .sdpack) into `support`. Files already there unchanged are skipped;
  /// different ones stop the install, listed, unless `replace`. Nothing is copied until the whole pack
  /// checks out. Returns the pack's manifest and what it did.
  @discardableResult
  public static func install(_ url: URL, into support: URL = AppPreferences.supportFolder, replace: Bool = false) throws -> (Manifest, Plan) {
    let (folder, temp) = try open(url)
    defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
    let manifest = try manifest(folder)
    let plan = try plan(folder, into: support)
    if !plan.conflicts.isEmpty && !replace {
      let shown = plan.conflicts.prefix(20).map { "  \($0)" }.joined(separator: "\n")
      throw DirectorError("""
        \(plan.conflicts.count) file(s) in "\(manifest.name)" differ from the ones you have; install again with --replace (in the app, Replace) to overwrite them:
        \(shown)\(plan.conflicts.count > 20 ? "\n  …" : "")
        """)
    }
    let fm = FileManager.default
    var record = (try? loadRecord(manifest.name, in: support))?.files ?? [:]
    for rel in plan.new + plan.conflicts + plan.same {
      let src = folder.appendingPathComponent(rel), dst = support.appendingPathComponent(rel)
      if !plan.same.contains(rel) {
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
      }
      record[rel] = try hash(dst)
    }
    try fm.createDirectory(at: recordsFolder(support), withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(Record(name: manifest.name, version: manifest.version, files: record))
      .write(to: recordsFolder(support).appendingPathComponent("\(manifest.name).json"))
    return (manifest, plan)
  }

  static func loadRecord(_ name: String, in support: URL) throws -> Record {
    let file = recordsFolder(support).appendingPathComponent("\(name).json")
    guard !name.contains("/"), FileManager.default.fileExists(atPath: file.path) else {
      throw DirectorError("no pack named \"\(name)\" is installed (there are: \(installed(in: support).map(\.name).joined(separator: ", ")))")
    }
    return try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
  }

  /// The installed packs, by name.
  public static func installed(in support: URL = AppPreferences.supportFolder) -> [Record] {
    let dir = recordsFolder(support)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted()
      .compactMap { try? JSONDecoder().decode(Record.self, from: Data(contentsOf: dir.appendingPathComponent($0))) }
  }

  /// Removes an installed pack's files, except ones changed since it put them there (returned), and
  /// folders it leaves empty.
  @discardableResult
  public static func remove(_ name: String, from support: URL = AppPreferences.supportFolder) throws -> [String] {
    let record = try loadRecord(name, in: support)
    let fm = FileManager.default
    var kept: [String] = []
    for (rel, sha) in record.files.sorted(by: { $0.key < $1.key }) {
      guard roots.contains(String(rel.split(separator: "/").first ?? "")), !rel.split(separator: "/").contains("..") else { continue }
      let file = support.appendingPathComponent(rel)
      guard fm.fileExists(atPath: file.path) else { continue }
      guard (try? hash(file)) == sha else { kept.append(rel); continue }
      try fm.removeItem(at: file)
      // Empty folders it leaves, up to (not including) the root folder.
      var dir = file.deletingLastPathComponent()
      func removable(_ d: URL) -> Bool {
        d.path.count > support.path.count + 1 && !roots.contains { support.appendingPathComponent($0).path == d.path }
          && (try? fm.contentsOfDirectory(atPath: d.path).filter { $0 != ".DS_Store" }.isEmpty) == true
      }
      while removable(dir) {
        try? fm.removeItem(at: dir)
        dir.deleteLastPathComponent()
      }
    }
    try fm.removeItem(at: recordsFolder(support).appendingPathComponent("\(name).json"))
    return kept
  }

  // MARK: Exporting

  /// Writes the named profiles into a pack at `out` (a folder, or a `.sdpack` file), each with every
  /// file it uses copied beside it, plus the effects and animation theme they use and, with `work`,
  /// the work library. The pack is named after `out`.
  public static func export(profiles names: [String], work: Bool, to out: URL, from support: URL = AppPreferences.supportFolder) throws {
    guard !names.isEmpty else { throw DirectorError("name at least one profile to put in the pack") }
    let fm = FileManager.default
    let zip = out.pathExtension.lowercased() == "sdpack"
    let name = out.deletingPathExtension().lastPathComponent
    guard !fm.fileExists(atPath: out.path) else { throw DirectorError("\(out.path) is already there; pick a new name") }
    let staging = zip ? fm.temporaryDirectory.appendingPathComponent("sdpack-\(UUID().uuidString)/\(name)") : out
    defer { if zip { try? fm.removeItem(at: staging.deletingLastPathComponent()) } }
    let library = ProfileLibrary(root: support.appendingPathComponent("Profiles"))
    var effects = Set<String>(), themes = Set<String>()
    for profileName in names {
      let src = library.folder(profileName)
      guard fm.fileExists(atPath: src.appendingPathComponent("profile.json").path) else {
        throw DirectorError("no profile named \"\(profileName)\" (there are: \(library.names().joined(separator: ", ")))")
      }
      let raw = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: src.appendingPathComponent("profile.json")))
      let dst = staging.appendingPathComponent("Profiles/\(profileName)")
      try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: src, to: dst)
      // Relative paths now resolve in the copy; only files from elsewhere get copied in, and only
      // then is profile.json rewritten (the same bytes install over the original as "already here").
      let portable = try Profile.portable(raw, from: dst, into: dst)
      if portable != raw { try portable.write(to: dst) }
      raw.effects?.forEach { effects.insert($0.name) }
      if let t = raw.look.animationTheme, !ThemeSources.isBuiltIn(t) { themes.insert(t) }
    }
    func copyFolder(_ rel: String) throws {
      let src = support.appendingPathComponent(rel)
      guard fm.fileExists(atPath: src.path) else { throw DirectorError("the profiles use \(rel), which isn't in \(support.path)") }
      try fm.createDirectory(at: staging.appendingPathComponent(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.copyItem(at: src, to: staging.appendingPathComponent(rel))
    }
    for e in effects.sorted() { try copyFolder("Effects/\(e)") }
    for t in themes.sorted() { try copyFolder("Animations/themes/\(t)") }
    if work { try copyFolder("Work") }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(Manifest(name: name, version: "1.0")).write(to: staging.appendingPathComponent("pack.json"))
    _ = try files(staging)  // the pack it made installs
    if zip { try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", staging.path, out.path]) }
  }

  static func hash(_ file: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
  }

  @discardableResult
  static func run(_ tool: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      throw DirectorError("\((tool as NSString).lastPathComponent) failed: \(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return String(decoding: data, as: UTF8.self)
  }
}

extension Profile {
  /// A copy of `profile` whose files all sit in `folder`: each path (relative to `base`, or absolute)
  /// that isn't already inside `folder` is copied in under fonts/, luts/, logos/ or music/ and
  /// written relative, so the folder works on another Mac.
  public static func portable(_ profile: Profile, from base: URL, into folder: URL) throws -> Profile {
    var p = profile
    let fm = FileManager.default
    func bring(_ path: String, _ sub: String) throws -> String {
      let src = resolvePath(path, in: base)
      if PathSafety.url(src, isInside: folder), let rel = PathSafety.resolved(src)?.dropFirst((PathSafety.resolved(folder) ?? "").count + 1) {
        return String(rel)
      }
      guard fm.fileExists(atPath: src.path) else { throw DirectorError("the profile \"\(profile.name)\" uses \(path), which isn't there") }
      let dst = folder.appendingPathComponent("\(sub)/\(src.lastPathComponent)")
      try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !fm.fileExists(atPath: dst.path) { try fm.copyItem(at: src, to: dst) }
      return "\(sub)/\(src.lastPathComponent)"
    }
    p.look.fontFiles = try p.look.fontFiles?.map { try bring($0, "fonts") }
    if let w = p.look.watermark { p.look.watermark?.image = try bring(w.image, "logos") }
    if let l = p.look.intro?.logo { p.look.intro?.logo = try bring(l, "logos") }
    if let l = p.look.outro?.logo { p.look.outro?.logo = try bring(l, "logos") }
    if let m = p.music { p.music?.file = try bring(m.file, "music") }
    if let lut = p.camera?.grade?.lut { p.camera?.grade?.lut = try bring(lut, "luts") }
    return p
  }

  /// Writes profile.json into `folder`.
  public func write(to folder: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(self).write(to: folder.appendingPathComponent("profile.json"))
  }
}
