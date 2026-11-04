import AVFoundation
import AppKit
import DirectorCore
import Foundation

/// The projects folder: one subfolder per recording.
final class Library: ObservableObject {
  @Published private(set) var projects: [URL] = []
  @Published var selection: URL? {
    didSet { if selection != oldValue { open(selection) } }
  }
  @Published private(set) var current: ProjectModel?
  @Published var search = ""
  @Published var status = ""
  /// Transcript text per recording, for search (loaded lazily).
  private var transcripts: [URL: String] = [:]

  /// When each recording was last opened (standardized path → seconds since 1970), for Recently Opened.
  @Published private(set) var lastOpened: [String: Double] = UserDefaults.standard.dictionary(forKey: "lastOpened") as? [String: Double] ?? [:] {
    didSet { UserDefaults.standard.set(lastOpened, forKey: "lastOpened") }
  }
  /// Recordings, the most recently opened first (the menu bar's Recent list).
  var recentlyOpened: [URL] { byLastOpened(projects, opened: lastOpened) }

  /// How the sidebar orders recordings. `projects` itself stays newest first (Join uses it).
  enum Sort: String, CaseIterable, Identifiable {
    case recentlyOpened, recentlyAdded, oldestFirst, recentlyEdited, name, longest
    var id: String { rawValue }
    var label: String {
      switch self {
      case .recentlyOpened: return "Recently Opened"
      case .recentlyAdded: return "Recently Added"
      case .oldestFirst: return "Oldest First"
      case .recentlyEdited: return "Recently Edited"
      case .name: return "Name"
      case .longest: return "Longest First"
      }
    }
  }
  @Published var sort = Sort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .recentlyOpened {
    didSet { UserDefaults.standard.set(sort.rawValue, forKey: "librarySort") }
  }

  /// Recordings matching the search box (by name, or by anything said in them), in the chosen order.
  var filtered: [URL] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    let matches = q.isEmpty ? projects : projects.filter(matching(q))
    switch sort {
    case .recentlyOpened: return byLastOpened(matches, opened: lastOpened)
    case .recentlyAdded: return matches
    case .oldestFirst: return matches.reversed()
    case .recentlyEdited: return matches.sorted { info($0).edited > info($1).edited }
    case .name: return matches.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    case .longest: return matches.sorted { info($0).duration > info($1).duration }
    }
  }

  private func matching(_ q: String) -> (URL) -> Bool {
    { url in
      if url.lastPathComponent.lowercased().contains(q) { return true }
      if self.transcripts[url] == nil {
        let obj = (try? Data(contentsOf: url.appendingPathComponent("transcript.json")))
          .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        self.transcripts[url] = ((obj?["text"] as? String) ?? "").lowercased()
      }
      return self.transcripts[url]!.contains(q)
    }
  }

  /// Renames a recording's folder, keeping it selected if it was.
  func rename(_ url: URL, to name: String) throws {
    let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != url.lastPathComponent else { return }
    if isWorking(url) {
      pendingRenames[url] = clean
      Notices.shared.show("\(url.lastPathComponent) is still working. It'll be renamed to \(clean) when it's done.")
      return
    }
    let dest = url.deletingLastPathComponent().appendingPathComponent(clean)
    guard !FileManager.default.fileExists(atPath: dest.path) else {
      throw DirectorError("There's already a recording called \(clean).")
    }
    let wasSelected = selection == url
    if wasSelected { selection = nil }
    try FileManager.default.moveItem(at: url, to: dest)
    transcripts[url] = nil
    if let at = lastOpened.removeValue(forKey: url.standardizedFileURL.path) { lastOpened[dest.standardizedFileURL.path] = at }
    refresh()
    if wasSelected { selection = dest }
  }

  /// Asks, then moves a recording's folder to the Trash (so Finder's Put Back can restore it).
  func promptDelete(_ url: URL) {
    if isWorking(url) {
      Notices.shared.show("\(url.lastPathComponent) is still working. Wait for it to finish, or stop it, before deleting.")
      return
    }
    let alert = NSAlert()
    alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
    alert.informativeText = "The recording, its edit and its exports go to the Trash. You can put it back from there."
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    presentAlert(alert) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      if self.selection == url { self.selection = nil }
      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
      } catch {
        Notices.shared.show(error, "Couldn't move \(url.lastPathComponent) to the Trash")
      }
      self.transcripts[url] = nil
      self.refresh()
    }
  }

  /// Inline rename in the sidebar: the row turns into a text field.
  @Published var renaming: URL?
  @Published var renameText = ""

  func beginRename(_ url: URL) {
    renameText = url.lastPathComponent
    renaming = url
  }

  func commitRename() {
    guard let url = renaming else { return }
    renaming = nil
    do { try rename(url, to: renameText) } catch { Notices.shared.show(error) }
  }

  /// Duration, date and how far along a recording is, for the sidebar. Cached until refresh().
  enum Stage { case new, edited, exported }
  struct Info {
    let duration: Double
    let date: Date
    /// When the edit last changed (the recording's date if it was never edited).
    let edited: Date
    let stage: Stage
  }
  private var infos: [URL: Info] = [:]

  func info(_ url: URL) -> Info {
    if let i = infos[url] { return i }
    let fm = FileManager.default
    let source = (try? Data(contentsOf: url.appendingPathComponent("source.json"))).flatMap { try? JSONDecoder().decode(Project.Source.self, from: $0) }
    let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
    let stage: Stage =
      files.contains { isExportFile($0, project: url.lastPathComponent) } ? .exported : files.contains("plan.json") ? .edited : .new
    let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    let edited = (try? fm.attributesOfItem(atPath: url.appendingPathComponent("plan.json").path))?[.modificationDate] as? Date
    let i = Info(duration: source?.duration ?? 0, date: date, edited: edited ?? date, stage: stage)
    infos[url] = i
    return i
  }

  /// Asks the AI for a short descriptive name from what was said, keeping the date in front.
  func suggestName(_ url: URL, autoApply: Bool = false) {
    // A rename the user queued wins over the automatic name.
    if autoApply, pendingRenames[url] != nil { return }
    let obj = (try? Data(contentsOf: url.appendingPathComponent("transcript.json")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let text = String(((obj?["text"] as? String) ?? "").prefix(6000))
    guard !text.isEmpty else {
      status = "No transcript yet to name it from."
      return
    }
    status = "Thinking of a name…"
    Task { @MainActor in
      do {
        let raw = try await AIText.generate(
          system: "You name screen recordings so they're easy to find later. Reply with only the name: 3 to 7 words, Title Case, plain words, no quotes, no punctuation, no dates.",
          user: "Transcript:\n\(text)", settings: AISettings.shared)
        let name = raw.split(separator: "\n").first.map(String.init)?
          .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.*#")) ?? ""
        guard !name.isEmpty else { return }
        let date = Library.datePrefix(for: url)
        let full = "\(date) \(name)"
        if autoApply {
          try rename(url, to: full)
          status = "Named it \(full)"
        } else {
          status = ""
          Notices.shared.show("Suggested name: \(full)", action: "Rename") { [weak self] in
            do { try self?.rename(url, to: full) } catch { Notices.shared.show(error) }
          }
        }
      } catch {
        status = ""
        Notices.shared.show(error, "Couldn't suggest a name")
      }
    }
  }

  static func datePrefix(for url: URL) -> String {
    let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: created)
  }

  let settings: AppSettings

  init(settings: AppSettings) {
    self.settings = settings
    refresh()
  }

  func refresh() {
    infos = [:]
    let root = settings.projectsURL
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
    projects =
      dirs
      .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("source.json").path) }
      .sorted {
        let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return a > b
      }
  }

  /// Projects left while still analyzing or exporting; their work keeps running after `close()`.
  private var leftWorking: [ProjectModel] = []
  /// Renames asked for while a recording was working, applied when its work finishes.
  private var pendingRenames: [URL: String] = [:]

  private func applyPendingRename(_ url: URL) {
    guard let name = pendingRenames.removeValue(forKey: url) else { return }
    do { try rename(url, to: name) } catch { Notices.shared.show(error, "Couldn't rename \(url.lastPathComponent)") }
  }

  /// Whether a recording's folder is being written by analysis or an export, open or not.
  /// Moving the folder then would fail the write.
  func isWorking(_ url: URL) -> Bool {
    leftWorking.removeAll { !$0.busy }
    return ([current].compactMap { $0 } + leftWorking).contains { $0.dir == url && $0.busy }
  }

  private func open(_ url: URL?) {
    // Leaving a project: its edit date and export badge may have changed.
    if let old = current?.dir { infos[old] = nil }
    if let old = current, old.busy { leftWorking.append(old) }
    current?.close()
    current = url.map { ProjectModel(dir: $0) }
    if let url { lastOpened[url.standardizedFileURL.path] = Date().timeIntervalSince1970 }
    current?.onFinishedWork = { [weak self] dir in self?.applyPendingRename(dir) }
  }

  /// Asks which recordings to join (oldest first), then makes a new project from them and drafts
  /// its edit. The originals aren't touched.
  func promptJoin() {
    let alert = NSAlert()
    alert.messageText = "Join Recordings"
    alert.informativeText = "Pick two or more recordings of the same screen size. They're joined oldest first into a new recording; the originals stay as they are."
    let candidates = Array(projects.reversed())
    let rows = candidates.map { url -> NSButton in
      let b = NSButton(checkboxWithTitle: url.lastPathComponent, target: nil, action: nil)
      b.state = url == selection ? .on : .off
      return b
    }
    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: min(300, CGFloat(rows.count) * 24 + 8)))
    scroll.hasVerticalScroller = true
    stack.frame = NSRect(x: 0, y: 0, width: 380, height: stack.fittingSize.height)
    scroll.documentView = stack
    alert.accessoryView = scroll
    alert.addButton(withTitle: "Join")
    alert.addButton(withTitle: "Cancel")
    presentAlert(alert) { [weak self] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      self.join(zip(candidates, rows).filter { $0.1.state == .on }.map(\.0))
    }
  }

  private func join(_ takes: [URL]) {
    guard takes.count >= 2 else {
      Notices.shared.show("Pick at least two recordings to join.")
      return
    }
    let base = "\(takes[0].lastPathComponent) (joined)"
    var out = settings.projectsURL.appendingPathComponent(base)
    var n = 2
    while FileManager.default.fileExists(atPath: out.path) {
      out = settings.projectsURL.appendingPathComponent("\(base) \(n)")
      n += 1
    }
    status = "Joining \(takes.count) recordings…"
    let dest = out
    Task { @MainActor in
      do {
        _ = try await Join.run(takes, into: dest)
        status = ""
        refresh()
        selection = dest
        let analyzed = ["motion.json", "loudness.json"].allSatisfy {
          FileManager.default.fileExists(atPath: dest.appendingPathComponent($0).path)
        }
        current?.analyzeAndPlan(analyzeFirst: !analyzed)
      } catch {
        status = ""
        Notices.shared.show(error, "Couldn't join the recordings")
      }
    }
  }

  /// Copies a video in as a new project (no input log, so zooms come from Claude, not clicks).
  /// Copies a screen recording (and optionally a camera video of the same take) into a new project.
  /// The camera starts at offset 0; analysis then lines it up with the voice (LipSync).
  func importVideo(_ video: URL, camera: URL? = nil) async throws -> URL {
    let dir = settings.projectsURL.appendingPathComponent(video.deletingPathExtension().lastPathComponent)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = "screen." + video.pathExtension.lowercased()
    try FileManager.default.copyItem(at: video, to: dir.appendingPathComponent(name))
    let asset = AVURLAsset(url: dir.appendingPathComponent(name))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CompositionError.noVideo(name) }
    let size = try await track.load(.naturalSize)
    let source = Project.Source(
      video: name, width: size.width, height: size.height, duration: try await asset.load(.duration).seconds, captureStart: nil,
      camera: try camera.map { cam in
        let camName = "camera." + cam.pathExtension.lowercased()
        try FileManager.default.copyItem(at: cam, to: dir.appendingPathComponent(camName))
        return Plan.Camera(video: camName, offset: 0)
      })
    try JSONEncoder().encode(source).write(to: dir.appendingPathComponent("source.json"))
    return dir
  }
}
