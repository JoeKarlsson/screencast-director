import Foundation

/// Keeps file paths inside a project folder. A plan names files it reads (the recording, music,
/// logos, fonts) and an AI edit rewrites the whole plan, so a prompt-injected transcript could
/// point those at any file on disk; `sanitize` undoes such changes.
public enum PathSafety {
  /// The real path (symlinks resolved) of a file that may not exist yet: the nearest existing
  /// ancestor goes through realpath and the rest is appended. nil when the missing part has "..".
  public static func resolved(_ url: URL) -> String? {
    func real(_ path: String) -> String? {
      guard let c = realpath(path, nil) else { return nil }
      defer { free(c) }
      return String(cString: c)
    }
    var existing = url.standardizedFileURL
    var rest: [String] = []
    while true {
      if let base = real(existing.path) {
        return ([base] + rest).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
      }
      let name = existing.lastPathComponent
      guard name != "/", name != "..", !name.isEmpty else { return nil }
      rest.insert(name, at: 0)
      existing.deleteLastPathComponent()
    }
  }

  /// True when `url` resolves to `dir` itself or somewhere under it.
  public static func url(_ url: URL, isInside dir: URL) -> Bool {
    guard let p = resolved(url), let d = resolved(dir) else { return false }
    return p == d || p.hasPrefix(d.hasSuffix("/") ? d : d + "/")
  }

  /// True when a plan path (relative to the project, or absolute) stays inside the project.
  public static func path(_ path: String, isInside project: URL) -> Bool {
    Self.url(resolvePath(path, in: project), isInside: project)
  }

  /// `new` with every file path that changed from `previous` and leaves the project put back to
  /// the previous value (or dropped when there was none). Returns the plan and the fields reverted.
  /// Paths into `library` (the user's own support folder: profiles' fonts and logos, sounds, music)
  /// are allowed too, so applying a saved profile keeps its assets.
  public static func sanitize(_ new: Plan, previous: Plan, project: URL, library: URL = AppPreferences.supportFolder) -> (Plan, [String]) {
    var plan = new
    var reverted: [String] = []
    func allowed(_ p: String) -> Bool { path(p, isInside: project) || url(resolvePath(p, in: project), isInside: library) }
    func safe(_ value: String?, _ old: String?, _ field: String) -> Bool {
      guard let value, value != old, !allowed(value) else { return true }
      reverted.append(field)
      return false
    }
    if !safe(plan.source.video, previous.source.video, "source.video") { plan.source.video = previous.source.video }
    if !safe(plan.camera?.video, previous.camera?.video, "camera.video") {
      if let old = previous.camera?.video { plan.camera?.video = old } else { plan.camera = nil }
    }
    if !safe(plan.camera?.grade?.lut, previous.camera?.grade?.lut, "camera.grade.lut") {
      plan.camera?.grade?.lut = previous.camera?.grade?.lut
    }
    if !safe(plan.music?.file, previous.music?.file, "music.file") { plan.music = previous.music }
    if let list = plan.inserts {
      let known = Set((previous.inserts ?? []).map(\.file))
      let kept = list.filter { known.contains($0.file) || allowed($0.file) }
      if kept.count != list.count {
        reverted.append("inserts.file")
        plan.inserts = kept.isEmpty ? nil : kept
      }
    }
    if let list = plan.sfx {
      let known = Set(previous.sfxList.map(\.file))
      let kept = list.filter { known.contains($0.file) || allowed($0.file) }
      if kept.count != list.count {
        reverted.append("sfx.file")
        plan.sfx = kept.isEmpty ? nil : kept
      }
    }
    // Attached sounds: one pointing outside the project (and not already there before) is removed.
    let knownSounds = Set(previous.soundEffects.map(\.file))
    func keep(_ s: Sound?) -> Bool { s.map { knownSounds.contains($0.file) || allowed($0.file) } ?? true }
    var droppedSound = false
    for i in plan.callouts.indices where !keep(plan.callouts[i].sound) {
      plan.callouts[i].sound = nil
      droppedSound = true
    }
    var marks = plan.annotationList
    for i in marks.indices where !keep(marks[i].sound) {
      marks[i].sound = nil
      droppedSound = true
    }
    if droppedSound { plan.annotationList = marks }
    var anims = plan.animationList
    for i in anims.indices {
      guard let sounds = anims[i].sounds else { continue }
      let kept = sounds.filter { keep($0.value) }
      if kept.count != sounds.count {
        anims[i].sounds = kept.isEmpty ? nil : kept
        droppedSound = true
        plan.animationList = anims
      }
    }
    if droppedSound { reverted.append("sound.file") }
    if !safe(plan.intro?.logo, previous.intro?.logo, "intro.logo") { plan.intro?.logo = previous.intro?.logo }
    if !safe(plan.outro?.logo, previous.outro?.logo, "outro.logo") { plan.outro?.logo = previous.outro?.logo }
    if plan.look != nil {
      let old = previous.look
      if !safe(plan.look?.watermark?.image, old?.watermark?.image, "look.watermark.image") { plan.look?.watermark = old?.watermark }
      if !safe(plan.look?.intro?.logo, old?.intro?.logo, "look.intro.logo") { plan.look?.intro?.logo = old?.intro?.logo }
      if !safe(plan.look?.outro?.logo, old?.outro?.logo, "look.outro.logo") { plan.look?.outro?.logo = old?.outro?.logo }
      if let fonts = plan.look?.fontFiles {
        let known = Set(old?.fontFiles ?? [])
        let kept = fonts.filter { known.contains($0) || allowed($0) }
        if kept.count != fonts.count {
          reverted.append("look.fontFiles")
          plan.look?.fontFiles = kept
        }
      }
    }
    return (plan, reverted)
  }
}
