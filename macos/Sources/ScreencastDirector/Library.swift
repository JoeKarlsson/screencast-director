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

  /// How the sidebar orders recordings. `projects` itself stays newest first (Recent and Join use it).
  enum Sort: String, CaseIterable, Identifiable {
    case recentlyAdded, oldestFirst, recentlyEdited, name, longest
    var id: String { rawValue }
    var label: String {
      switch self {
      case .recentlyAdded: return "Recently Added"
      case .oldestFirst: return "Oldest First"
      case .recentlyEdited: return "Recently Edited"
      case .name: return "Name"
      case .longest: return "Longest First"
      }
    }
  }
  @Published var sort = Sort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .recentlyAdded {
    didSet { UserDefaults.standard.set(sort.rawValue, forKey: "librarySort") }
  }

  /// Recordings matching the search box (by name, or by anything said in them), in the chosen order.
  var filtered: [URL] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    let matches = q.isEmpty ? projects : projects.filter(matching(q))
    switch sort {
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
    let dest = url.deletingLastPathComponent().appendingPathComponent(clean)
    guard !FileManager.default.fileExists(atPath: dest.path) else {
      throw NSError(domain: "Library", code: 1, userInfo: [NSLocalizedDescriptionKey: "There's already a recording called \(clean)."])
    }
    let wasSelected = selection == url
    if wasSelected { selection = nil }
    try FileManager.default.moveItem(at: url, to: dest)
    transcripts[url] = nil
    refresh()
    if wasSelected { selection = dest }
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
      files.contains { $0.hasPrefix("out") && $0.hasSuffix(".mp4") } ? .exported : files.contains("plan.json") ? .edited : .new
    let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    let edited = (try? fm.attributesOfItem(atPath: url.appendingPathComponent("plan.json").path))?[.modificationDate] as? Date
    let i = Info(duration: source?.duration ?? 0, date: date, edited: edited ?? date, stage: stage)
    infos[url] = i
    return i
  }

  /// Asks the AI for a short descriptive name from what was said, keeping the date in front.
  func suggestName(_ url: URL, autoApply: Bool = false) {
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
        status = "Couldn't suggest a name: \(error.localizedDescription)"
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

  private func open(_ url: URL?) {
    // Leaving a project: its edit date and export badge may have changed.
    if let old = current?.dir { infos[old] = nil }
    current?.close()
    current = url.map { ProjectModel(dir: $0) }
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
  func importVideo(_ video: URL) async throws -> URL {
    let dir = settings.projectsURL.appendingPathComponent(video.deletingPathExtension().lastPathComponent)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = "screen." + video.pathExtension.lowercased()
    try FileManager.default.copyItem(at: video, to: dir.appendingPathComponent(name))
    let asset = AVURLAsset(url: dir.appendingPathComponent(name))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CompositionError.noVideo(name) }
    let size = try await track.load(.naturalSize)
    let source = Project.Source(
      video: name, width: size.width, height: size.height, duration: try await asset.load(.duration).seconds, captureStart: nil, camera: nil)
    try JSONEncoder().encode(source).write(to: dir.appendingPathComponent("source.json"))
    return dir
  }
}
