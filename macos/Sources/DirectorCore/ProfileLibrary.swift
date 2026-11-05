import Foundation

/// The saved profiles: <support folder>/Profiles/<name>/profile.json with their fonts and logos.
/// New recordings get the default one (the `defaultProfile` setting); any video can switch.
/// The app's Profiles menu and `director profiles`/`profile`/`profile-save` share this.
public struct ProfileLibrary: Sendable {
  public let root: URL

  public init(root: URL = AppPreferences.supportFolder.appendingPathComponent("Profiles")) {
    self.root = root
  }

  /// Profile names, sorted. Seeds a Personal profile with the built-in look the first time.
  public func names() -> [String] {
    seedPersonal()
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("profile.json").path) }
      .map(\.lastPathComponent).sorted()
  }

  private func seedPersonal() {
    let personal = root.appendingPathComponent("Personal/profile.json")
    guard !FileManager.default.fileExists(atPath: personal.path) else { return }
    try? FileManager.default.createDirectory(at: personal.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(
      ##"{"name": "Personal", "style": {"background": ["#1d2b64", "#f8cdda"], "padding": 0, "radius": 14, "transition": 0.8}, "look": {}}"##.utf8
    ).write(to: personal)
  }

  public func folder(_ name: String) -> URL { root.appendingPathComponent(name) }

  public func load(_ name: String) throws -> Profile {
    guard FileManager.default.fileExists(atPath: folder(name).appendingPathComponent("profile.json").path) else {
      throw DirectorError("no profile named \"\(name)\" (there are: \(names().joined(separator: ", ")))")
    }
    return try Profile.load(folder(name))
  }

  public static var defaultName: String {
    get { AppPreferences.defaults.string(forKey: "defaultProfile") ?? "Personal" }
    set { AppPreferences.defaults.set(newValue, forKey: "defaultProfile") }
  }

  /// The default profile, or nil when there's no profile by that name. One that's there but can't
  /// be read throws, so a broken profile.json isn't silently skipped.
  public func defaultProfile() throws -> Profile? {
    let name = ProfileLibrary.defaultName
    seedPersonal()
    let file = folder(name).appendingPathComponent("profile.json")
    return FileManager.default.fileExists(atPath: file.path) ? try Profile.load(folder(name)) : nil
  }

  /// Saves a video's current look and style as a profile (asset paths stay absolute).
  public func save(from plan: Plan, as name: String, extras: Set<Profile.Extra>) throws {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else { throw DirectorError("\"\(name)\" can't be a profile name") }
    let dir = folder(trimmed)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(Profile.saved(from: plan, name: trimmed, extras: extras)).write(to: dir.appendingPathComponent("profile.json"))
  }
}

/// The first draft a new recording gets, as the app makes it after recording, importing or Start
/// Over: the planner's draft, then the default profile, the pause setting, voice polish, the camera
/// centered on the face and lined up with the voice. `director draft` runs the same steps.
public enum FreshDraft: Sendable {
  public struct Result: Sendable {
    public var plan: Plan
    /// Set when the camera couldn't be checked against the voice (the offset stays the recorder's).
    public var lipSyncUnchecked: Bool
  }

  public static func make(
    dir: URL, name: String, profile: Profile?, pauseLevel: PauseLevel, polishVoice: Bool, status: (String) -> Void = { _ in }
  ) async throws -> Result {
    let project = try Project.load(dir)
    var draft = buildPlan(project)
    profile?.apply(to: &draft, name: name)
    let silences = Analyzer.silences(try await Analyzer.loudness(project, video: draft.source.video), minLength: 0.2)
    draft.retrimPauses(words: project.words, level: pauseLevel, silences: silences, paused: project.paused)
    draft.pauses = pauseLevel
    if polishVoice { draft.audio = AudioSettings.polished(draft.audio) }
    if draft.camera != nil, let face = try await Publish.faceCenter(project: project, plan: draft) {
      draft.camera?.x = face.x
      draft.camera?.y = face.y
      draft.camera?.zoom = Publish.centeringZoom(x: face.x, y: face.y)
    }
    // The recorder's offset comes from stream timestamps, which some webcams stamp late.
    var unchecked = false
    if let camera = draft.camera {
      status("Matching your lips to your voice…")
      if let sync = try await LipSync.measure(project: project, camera: camera), sync.confident {
        draft.camera?.offset = sync.offset
      } else {
        unchecked = true
      }
    }
    return Result(plan: draft, lipSyncUnchecked: unchecked)
  }

  /// `make` with the app's settings: its default profile, pause level and voice polish.
  public static func withAppSettings(dir: URL, name: String, status: (String) -> Void = { _ in }) async throws -> Result {
    let d = AppPreferences.defaults
    return try await make(
      dir: dir, name: name, profile: try ProfileLibrary().defaultProfile(),
      pauseLevel: PauseLevel(rawValue: d.string(forKey: "pauseLevel") ?? "") ?? .normal,
      polishVoice: d.bool(forKey: "polishVoice"), status: status)
  }
}
