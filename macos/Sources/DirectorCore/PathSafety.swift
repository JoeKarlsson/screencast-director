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
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : project.appendingPathComponent(path)
    return Self.url(url, isInside: project)
  }

  /// `new` with every file path that changed from `previous` and leaves the project put back to
  /// the previous value (or dropped when there was none). Returns the plan and the fields reverted.
  public static func sanitize(_ new: Plan, previous: Plan, project: URL) -> (Plan, [String]) {
    var plan = new
    var reverted: [String] = []
    func safe(_ value: String?, _ old: String?, _ field: String) -> Bool {
      guard let value, value != old, !path(value, isInside: project) else { return true }
      reverted.append(field)
      return false
    }
    if !safe(plan.source.video, previous.source.video, "source.video") { plan.source.video = previous.source.video }
    if !safe(plan.camera?.video, previous.camera?.video, "camera.video") {
      if let old = previous.camera?.video { plan.camera?.video = old } else { plan.camera = nil }
    }
    if !safe(plan.music?.file, previous.music?.file, "music.file") { plan.music = previous.music }
    if !safe(plan.intro?.logo, previous.intro?.logo, "intro.logo") { plan.intro?.logo = previous.intro?.logo }
    if !safe(plan.outro?.logo, previous.outro?.logo, "outro.logo") { plan.outro?.logo = previous.outro?.logo }
    if plan.look != nil {
      let old = previous.look
      if !safe(plan.look?.watermark?.image, old?.watermark?.image, "look.watermark.image") { plan.look?.watermark = old?.watermark }
      if !safe(plan.look?.intro?.logo, old?.intro?.logo, "look.intro.logo") { plan.look?.intro?.logo = old?.intro?.logo }
      if !safe(plan.look?.outro?.logo, old?.outro?.logo, "look.outro.logo") { plan.look?.outro?.logo = old?.outro?.logo }
      if let fonts = plan.look?.fontFiles {
        let known = Set(old?.fontFiles ?? [])
        let kept = fonts.filter { known.contains($0) || path($0, isInside: project) }
        if kept.count != fonts.count {
          reverted.append("look.fontFiles")
          plan.look?.fontFiles = kept
        }
      }
    }
    return (plan, reverted)
  }
}
