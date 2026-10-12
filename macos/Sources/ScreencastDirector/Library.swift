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

  let settings: AppSettings

  init(settings: AppSettings) {
    self.settings = settings
    refresh()
  }

  func refresh() {
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
    current?.close()
    current = url.map { ProjectModel(dir: $0) }
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

/// One open project: its plan, a live preview, and the pipeline actions.
final class ProjectModel: ObservableObject {
  let dir: URL
  @Published private(set) var player = AVPlayer()
  @Published private(set) var timeline = ""
  @Published private(set) var status = ""
  @Published private(set) var busy = false
  @Published private(set) var previewReady = false
  @Published private(set) var hasPlan = false
  @Published var instruction = ""
  @Published private(set) var claudeLog = ""

  private var watcher: Timer?
  private var lastPlanMtime: Date?
  private var lastPlanData: Data?
  private var itemObserver: NSKeyValueObservation?

  init(dir: URL) {
    self.dir = dir
    reload()
    watchFolder()
  }

  var name: String { dir.lastPathComponent }
  var planURL: URL { dir.appendingPathComponent("plan.json") }
  var outURL: URL { dir.appendingPathComponent("out.mp4") }

  func close() {
    watcher?.invalidate()
    player.pause()
  }

  /// Rebuilds the preview from plan.json, keeping the playhead where it was.
  func reload() {
    hasPlan = FileManager.default.fileExists(atPath: planURL.path)
    guard hasPlan else {
      status = "Not analyzed yet."
      timeline = ""
      // Show the raw recording until there's a plan.
      if let src = try? JSONDecoder().decode(Project.Source.self, from: Data(contentsOf: dir.appendingPathComponent("source.json"))) {
        player.replaceCurrentItem(with: AVPlayerItem(url: dir.appendingPathComponent(src.video)))
      }
      return
    }
    lastPlanData = try? Data(contentsOf: planURL)
    Task { @MainActor in
      do {
        let project = try Project.load(dir)
        let plan = try Plan.load(planURL)
        let built = try await buildComposition(project: project, plan: plan)
        let time = player.currentTime()
        let item = built.playerItem()
        itemObserver = item.observe(\.status) { [weak self] item, _ in
          switch item.status {
          case .failed:
            Task { @MainActor in self?.status = "Preview failed: \(item.error?.localizedDescription ?? "unknown error")" }
          case .readyToPlay:
            Task { @MainActor in self?.previewReady = true }
          default: break
          }
        }
        player.replaceCurrentItem(with: item)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        timeline = describe(project, plan)
        let out = Double(built.scene.frameCount) / Double(plan.output.fps)
        status = "\(fmtTime(plan.source.duration)) recorded → \(fmtTime(out)) edited"
      } catch {
        status = "Couldn't load the plan: \(error.localizedDescription)"
      }
    }
  }

  /// Edits arrive both as atomic replaces and as in-place writes (Claude's Edit tool), and a
  /// folder watch misses the latter, so poll plan.json's modification date once a second.
  private func watchFolder() {
    watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      let mtime = (try? FileManager.default.attributesOfItem(atPath: self.planURL.path))?[.modificationDate] as? Date
      guard mtime != self.lastPlanMtime else { return }
      self.lastPlanMtime = mtime
      if (try? Data(contentsOf: self.planURL)) != self.lastPlanData { self.reload() }
    }
  }

  private func run(_ label: String, _ work: @escaping () async throws -> Void) {
    guard !busy else { return }
    busy = true
    status = label
    Task { @MainActor in
      do {
        try await work()
      } catch {
        status = "\(label.replacingOccurrences(of: "…", with: "")) failed: \(error.localizedDescription)"
      }
      busy = false
    }
  }

  /// Transcribe, measure motion, and write a first-draft plan (keeps an existing plan unless `force`).
  func analyzeAndPlan(force: Bool = false) {
    run("Analyzing…") { [self] in
      try await analyze(dir) { msg in Task { @MainActor in self.status = msg } }
      if force || !FileManager.default.fileExists(atPath: planURL.path) {
        try buildPlan(try Project.load(dir)).write(to: planURL)
      }
      reload()
    }
  }

  func export() {
    run("Exporting…") { [self] in
      let built = try await buildComposition(project: try Project.load(dir), plan: try Plan.load(planURL))
      try await DirectorCore.export(built, to: outURL) { p in
        Task { @MainActor in self.status = "Exporting… \(Int(p * 100))%" }
      }
      status = "Exported out.mp4"
      NSWorkspace.shared.activateFileViewerSelecting([outURL])
    }
  }

  func askClaude() {
    let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    claudeLog = ""
    run("Claude is editing…") { [self] in
      let code = try await Claude.edit(project: dir, instruction: text) { chunk in
        Task { @MainActor in self.claudeLog += chunk }
      }
      instruction = ""
      status = code == 0 ? "Claude finished." : "Claude exited with status \(code)."
      reload()
    }
  }
}
