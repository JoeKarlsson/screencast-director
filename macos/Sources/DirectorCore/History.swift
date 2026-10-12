import Foundation

/// Earlier versions of a project's plan.json, kept in <project>/.history/plan-<timestamp>.json.
/// `Plan.write(to:)` saves the version it replaces; the app also saves the version an outside
/// edit (Claude Code, a text editor) replaced. The newest `keep` versions survive.
public enum PlanHistory {
  public static let keep = 30

  public struct Entry: Equatable {
    public let url: URL
    public let date: Date
  }

  public static func directory(for planURL: URL) -> URL {
    planURL.deletingLastPathComponent().appendingPathComponent(".history")
  }

  static let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss-SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Saves `data` (a plan.json's bytes) as a version, unless it matches the newest one.
  public static func snapshot(_ data: Data, planURL: URL, keep: Int = keep, now: Date = Date()) {
    let dir = directory(for: planURL)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let newest = list(planURL: planURL).first, (try? Data(contentsOf: newest.url)) == data { return }
    var name = "plan-\(stamp.string(from: now)).json"
    var n = 1
    while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
      name = "plan-\(stamp.string(from: now))-\(n).json"
      n += 1
    }
    try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    prune(planURL: planURL, keep: keep)
  }

  /// Versions, newest first.
  public static func list(planURL: URL) -> [Entry] {
    let dir = directory(for: planURL)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.compactMap { url -> Entry? in
      let name = url.deletingPathExtension().lastPathComponent
      guard name.hasPrefix("plan-"), url.pathExtension == "json" else { return nil }
      let key = String(name.dropFirst(5).prefix(19))
      guard let date = stamp.date(from: key) else { return nil }
      return Entry(url: url, date: date)
    }
    .sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
  }

  public static func prune(planURL: URL, keep: Int = keep) {
    for old in list(planURL: planURL).dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
  }

  /// What differs between two plans, in a few words ("3 clips, 1 zoom, style"), or "same".
  public static func summary(from a: Plan, to b: Plan) -> String {
    func count<T: Equatable>(_ x: [T], _ y: [T]) -> Int {
      max(y.filter { !x.contains($0) }.count, x.filter { !y.contains($0) }.count)
    }
    func plural(_ n: Int, _ word: String) -> String? { n == 0 ? nil : "\(n) \(word)\(n == 1 ? "" : "s")" }
    var parts = [
      plural(count(a.segments, b.segments), "clip"), plural(count(a.zooms, b.zooms), "zoom"),
      plural(count(a.layouts, b.layouts), "layout"), plural(count(a.callouts, b.callouts), "title"),
    ].compactMap { $0 }
    if a.style != b.style || a.look != b.look { parts.append("style") }
    if a.output != b.output { parts.append("format") }
    if a.camera != b.camera { parts.append("camera") }
    if a.audio != b.audio || a.captions != b.captions { parts.append("sound or captions") }
    return parts.isEmpty ? "same" : parts.joined(separator: ", ")
  }
}
