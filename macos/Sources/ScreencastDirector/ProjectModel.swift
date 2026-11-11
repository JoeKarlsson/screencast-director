import AVFoundation
import AppKit
import Combine
import DirectorCore
import Foundation

/// The playhead, apart from ProjectModel: it ticks 30 times a second while playing, and only the
/// views that draw it (the playhead line, the clock, the current word) should redraw that often.
final class Playhead: ObservableObject {
  /// Output frames.
  @Published var frame = 0.0
  /// The transcript word under the playhead (an index into project.words).
  @Published var word: Int?
}

/// One open project: the plan (with undo), a live preview, a playhead, and the pipeline actions.
/// Every edit, from the timeline, the inspector or Claude, ends up in plan.json.
final class ProjectModel: ObservableObject {
  let dir: URL
  @Published private(set) var plan: Plan? {
    didSet {
      mapped = plan.map(mapPlan) ?? []
      totalOutFrames = plan.map(planFrames) ?? 1
    }
  }
  @Published private(set) var project: Project?
  @Published private(set) var player = AVPlayer()
  let playhead = Playhead()
  /// Playhead in output frames. Not published: observe `playhead` to follow it.
  var outFrame: Double {
    get { playhead.frame }
    set {
      playhead.frame = newValue
      let w = wordIndex(at: playheadSrc)
      if w != playhead.word { playhead.word = w }
    }
  }
  @Published private(set) var isPlaying = false
  @Published var selection: Selection?
  /// More items selected with ⇧/⌘-click or a drag box, besides `selection` (which the inspector shows).
  @Published var multi: [Selection] = []
  /// An in/out range (I and O), in source seconds: cut, zoom, title or ask the AI about a stretch.
  @Published var inPoint: Double?
  @Published var outPoint: Double?
  @Published var status = ""
  @Published var busy = false
  @Published private(set) var previewReady = false
  /// The scene the preview plays, for where its handles go (annotations follow zooms).
  @Published private(set) var previewScene: DirectorCore.Scene?
  @Published var instruction = ""
  /// What you've asked the AI to do in this session, and what it said back.
  @Published var asks: [Ask] = []
  /// What the last AI edit changed, in source seconds; the timeline flashes these ranges. A new
  /// id each time, so the same ranges flash again.
  @Published var aiChange: (id: UUID, ranges: [(Double, Double)])?
  var planBeforeAsk: Plan?
  /// The Claude Code session the last ask ran in, resumed by the next one so a follow-up knows what
  /// it did. Gone when the recording closes, or after an ask that failed.
  var claudeSession: String?
  /// Claude Code is writing plan.json. Edits here would race its writes, so they wait.
  @Published var aiEditing = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published var showPublish = false
  /// Loudness every 50 ms (source time), for the timeline's audio track and normalizing.
  @Published private(set) var levels: [(Double, Double)] = []
  @Published var showHistory = false
  /// Words selected in the Transcript tab (indexes into project.words), first to last.
  @Published var transcriptSel: ClosedRange<Int>?
  @Published var publishTitle = ""
  @Published var publishFiles: [URL] = []
  @Published var descriptionText = ""

  var undoStack: [Plan] = [] { didSet { canUndo = !undoStack.isEmpty } }
  var redoStack: [Plan] = [] { didSet { canRedo = !redoStack.isEmpty } }
  private var watcher: Timer?
  private var lastPlanData: Data?
  private var lastPlanMtime: Date?
  private var itemObserver: NSKeyValueObservation?
  private var timeObserver: Any?
  private var rateObserver: NSKeyValueObservation?
  private var volumeObserver: AnyCancellable?
  private var rebuildWork: DispatchWorkItem?
  var thumbnails: [Int: NSImage] = [:]

  init(dir: URL) {
    self.dir = dir
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
      guard let self, let fps = self.plan?.output.fps else { return }
      self.outFrame = t.seconds * Double(fps)
    }
    rateObserver = player.observe(\.rate) { [weak self] p, _ in
      DispatchQueue.main.async { self?.isPlaying = p.rate != 0 }
    }
    volumeObserver = AppSettings.shared.$previewVolume.combineLatest(AppSettings.shared.$previewMuted).sink { [weak self] volume, muted in
      self?.player.volume = volume
      self?.player.isMuted = muted
    }
    loadFromDisk()
    watchPlan()
    loadAsks()
    quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stopForQuit() }
    }
  }

  private var quitObserver: NSObjectProtocol?

  var name: String { dir.lastPathComponent }
  var planURL: URL { dir.appendingPathComponent("plan.json") }
  var outURL: URL { exportURL(dir: dir, size: plan?.output) }
  var hasPlan: Bool { plan != nil }
  var fps: Int { plan?.output.fps ?? 30 }
  /// The plan's segments in output frames, kept in step with the plan.
  private(set) var mapped: [MappedSegment] = []
  private(set) var totalOutFrames = 1
  /// Playhead in source seconds (what the timeline shows).
  var playheadSrc: Double { outToSrc(mapped, min(outFrame, Double(totalOutFrames - 1)), fps: fps) ?? 0 }

  func close() {
    flushWrite()
    watcher?.invalidate()
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    player.pause()
  }

  // MARK: Loading and the preview

  private func loadFromDisk() {
    do { project = try Project.load(dir) } catch {
      project = nil
      Notices.shared.show(error, "Couldn't read \(dir.lastPathComponent)")
    }
    func showRecordingOnly(_ why: String) {
      plan = nil
      status = why
      if let src = project?.source {
        player.replaceCurrentItem(with: AVPlayerItem(url: dir.appendingPathComponent(src.video)))
      }
    }
    guard FileManager.default.fileExists(atPath: planURL.path) else { return showRecordingOnly("Not analyzed yet.") }
    let data: Data, p: Plan
    do {
      data = try Data(contentsOf: planURL)
      p = try JSONDecoder().decode(Plan.self, from: data)
    } catch {
      // A bad hand or AI edit: say so, rather than looking like a recording that was never analyzed.
      Notices.shared.show(error, "Couldn't read plan.json")
      return showRecordingOnly("plan.json can't be read.")
    }
    lastPlanData = data
    plan = p
    rebuild(now: true)
    if levels.isEmpty, let project {
      Task { @MainActor in self.levels = (try? await Analyzer.loudness(project, video: p.source.video)) ?? [] }
    }
  }

  /// Picks up changes made outside the app (Claude, a text editor). Edits made here are written
  /// with lastPlanData set first, so they don't bounce back. The previous plan goes on the undo
  /// stack, so ⌘Z undoes Claude's edit too.
  private func watchPlan() {
    watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      let mtime = (try? FileManager.default.attributesOfItem(atPath: self.planURL.path))?[.modificationDate] as? Date
      guard mtime != self.lastPlanMtime else { return }
      self.lastPlanMtime = mtime
      guard let data = try? Data(contentsOf: self.planURL), data != self.lastPlanData else { return }
      // An outside edit (Claude Code's Edit tool, a text editor) bypasses Plan.write, so keep the
      // version it replaced in .history here.
      if let previous = self.lastPlanData {
        do {
          try PlanHistory.snapshot(previous, planURL: self.planURL)
        } catch {
          Notices.shared.show(error, "Couldn't keep the replaced plan in .history")
        }
      }
      // While Claude Code edits, its writes become one undo step when it finishes (finishAsk).
      if let old = self.plan, !self.aiEditing {
        self.undoStack.append(old)
        self.redoStack.removeAll()
      }
      self.loadFromDisk()
    }
  }

  func rebuild(now: Bool = false) {
    rebuildWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.rebuildPreview() }
    rebuildWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.25), execute: work)
  }

  /// Counts preview builds. A build that finishes after a newer one started is thrown away, or a
  /// slow build of an older plan would replace the newer preview (and play, say, without leveling).
  private var previewGeneration = 0

  /// Flashes already reported, so each new one shows in the banner once.
  private var reportedFlashes: [Flash] = []

  /// Banners a flash (something on screen for under a second between two others) that an edit just
  /// made, with its time, so it gets fixed before export.
  private func warnAboutNewFlashes(_ plan: Plan) {
    let found = flashes(plan, dir: dir)
    let new = found.filter { f in !reportedFlashes.contains(f) }
    reportedFlashes = found
    guard let first = new.first else { return }
    let more = new.count > 1 ? " (and \(new.count - 1) more; see describe)" : ""
    Notices.shared.show("Flash: " + describeFlash(first, plan) + more, error: true, action: "Show") { [weak self] in
      self?.seek(outFrame: first.startF)
    }
  }

  private func rebuildPreview() {
    guard let plan else { return }
    warnAboutNewFlashes(plan)
    previewReady = false
    previewGeneration += 1
    let generation = previewGeneration
    Task { @MainActor in
      do {
        let project = try Project.load(dir)
        let built = try await buildComposition(project: project, plan: plan)
        guard generation == previewGeneration else { return }
        self.project = project
        previewScene = built.scene
        let time = player.currentTime()
        let item = built.playerItem()
        itemObserver = item.observe(\.status) { [weak self] item, _ in
          Task { @MainActor in
            switch item.status {
            case .failed:
              let msg = "Preview failed: \(item.error?.localizedDescription ?? "unknown error")"
              self?.status = msg
              Notices.shared.show(msg, error: true, action: "Retry") { self?.rebuild(now: true) }
            case .readyToPlay: self?.previewReady = true
            default: break
            }
          }
        }
        let wasPlaying = player.rate != 0
        player.replaceCurrentItem(with: item)
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
        let out = Double(built.scene.frameCount) / Double(plan.output.fps)
        status = "\(fmtTime(plan.source.duration)) recorded → \(fmtTime(out)) edited"
        for warning in built.warnings { Notices.shared.show(warning, error: true) }
        scheduleAnimationRender()
      } catch {
        guard generation == previewGeneration else { return }
        status = "Couldn't load the plan: \(error.localizedDescription)"
        Notices.shared.show(error, "Couldn't load the plan")
      }
    }
  }

  /// Animations whose clip hasn't been rendered yet show nothing in the preview, so render them
  /// with the bundled `director animate` (WebKit lives there, not in the app's process) and rebuild
  /// when it's done. One run at a time; a plan changed meanwhile is checked again by that rebuild.
  @Published private(set) var animating = false

  private var animateWork: DispatchWorkItem?

  /// Renders once editing pauses, so typing in an animation's heading doesn't start a render per key.
  private func scheduleAnimationRender() {
    animateWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, let plan = self.plan else { return }
      self.renderAnimationsIfNeeded(plan)
    }
    animateWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  /// Renders missing animation clips in the background. `target` is the plan as it'll export (another
  /// format's, or one clip's) and `args` tell `director animate` the same (`--preset id`, `--clip name`).
  func renderAnimationsIfNeeded(_ plan: Plan, target: Plan? = nil, args: [String] = []) {
    let missing = (target ?? plan).animationsToRender(dir: dir).count
    guard missing > 0, !animating else { return }
    animating = true
    status = "Rendering \(missing) animation\(missing == 1 ? "" : "s")…"
    let p = Process()
    p.executableURL = Claude.director
    p.arguments = ["animate", dir.path] + args
    let errors = Pipe()
    p.standardError = errors
    p.standardOutput = FileHandle.nullDevice
    p.terminationHandler = { [weak self] proc in
      let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      Task { @MainActor in
        guard let self else { return }
        self.animating = false
        if proc.terminationStatus == 0 {
          self.rebuild(now: true)
        } else {
          self.status = "An animation didn't render."
          Notices.shared.show("An animation didn't render: \(message.isEmpty ? "director animate failed" : message)", error: true)
        }
      }
    }
    do {
      try p.run()
    } catch {
      animating = false
      Notices.shared.show(error, "Couldn't render the animations")
    }
  }

  // MARK: Editing

  private var lastEditKey: String?
  private var lastEditAt = Date.distantPast

  /// Applies an edit, saves plan.json and refreshes the preview. Edits with the same `coalesce`
  /// key in quick succession (a slider drag) share one undo step.
  func apply(coalesce key: String? = nil, _ change: (inout Plan) -> Void) {
    guard !aiEditing else {
      Notices.shared.show("Claude is still editing. Wait for it to finish, or press Stop.")
      return
    }
    // An edit made outside the app (Claude, the CLI, a text editor) may not have been picked up
    // yet. Apply this change on top of the file, not over it.
    // Checking the modification date first keeps a slider drag from reading the file every tick.
    if planMtime() != lastPlanMtime, pendingWrite == nil, let disk = try? Data(contentsOf: planURL), disk != lastPlanData,
      let fresh = try? JSONDecoder().decode(Plan.self, from: disk) {
      if let old = plan { undoStack.append(old) }
      lastPlanData = disk
      lastPlanMtime = planMtime()
      plan = fresh
    }
    guard var p = plan else { return }
    let merge = key != nil && key == lastEditKey && Date().timeIntervalSince(lastEditAt) < 1.5
    lastEditKey = key
    lastEditAt = Date()
    if !merge { undoStack.append(p) }
    redoStack.removeAll()
    change(&p)
    p.normalize()
    commit(p, deferWrite: key != nil)
  }

  private var pendingWrite: DispatchWorkItem?

  private func planMtime() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: planURL.path))?[.modificationDate] as? Date
  }

  /// Writes plan.json now if a coalesced edit (a slider drag) is still waiting to be saved.
  func flushWrite() {
    guard let work = pendingWrite else { return }
    work.cancel()
    pendingWrite = nil
    if let plan { save(plan) }
  }

  private func save(_ p: Plan) {
    do {
      try p.write(to: planURL)
      lastPlanData = try Data(contentsOf: planURL)
      lastPlanMtime = planMtime()
    } catch {
      status = "Couldn't save: \(error.localizedDescription)"
      Notices.shared.show(error, "Couldn't save the edit")
    }
  }

  /// Publishes a plan and saves it. `deferWrite` (slider drags) saves once the drag pauses, so
  /// dragging doesn't write the file and its history snapshot on every tick.
  func commit(_ p: Plan, deferWrite: Bool = false) {
    // Drop a selection the new plan doesn't have before publishing it, so views never see both.
    if let s = selection, !p.has(s) { selection = nil }
    multi = multi.filter { p.has($0) }
    plan = p
    pendingWrite?.cancel()
    pendingWrite = nil
    if deferWrite {
      let work = DispatchWorkItem { [weak self] in
        self?.pendingWrite = nil
        self?.save(p)
      }
      pendingWrite = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    } else {
      save(p)
    }
    rebuild()
  }

  func undo() {
    guard let prev = undoStack.popLast(), let cur = plan else { return }
    redoStack.append(cur)
    commit(prev)
  }

  func redo() {
    guard let next = redoStack.popLast(), let cur = plan else { return }
    undoStack.append(cur)
    commit(next)
  }

  func splitAtPlayhead() {
    let t = playheadSrc
    apply { _ = $0.split(at: t) }
  }

  /// Plays the selected clip at position `to` in the video (0 is first); the selection follows it.
  func moveSelectedClip(to: Int) {
    guard case .segment(let i) = selection, let count = plan?.segments.count, (0..<count).contains(i) else { return }
    let target = min(max(0, to), count - 1)
    guard target != i else { return }
    apply { $0.moveSegment(i, to: target) }
    selection = .segment(target)
  }

  func deleteSelection() {
    if transcriptSel != nil {
      cutTranscriptSelection()
      return
    }
    let items = selectedItems
    guard !items.isEmpty else { return }
    apply { $0.delete(items) }
    selection = nil
    multi = []
  }

  // MARK: Selecting several items

  /// Everything selected on the timeline: the inspector's item first.
  var selectedItems: [Selection] { (selection.map { [$0] } ?? []) + multi }

  func isSelected(_ s: Selection) -> Bool { selection == s || multi.contains(s) }

  /// A click selects one item; ⇧/⌘-click adds it to (or takes it out of) the selection.
  func select(_ s: Selection, adding: Bool) {
    var picked = TimelineSelection(primary: selection, others: multi)
    picked.click(s, adding: adding)
    selection = picked.primary
    multi = picked.others
  }

  /// A drag box selects what it touches (added to the selection with ⇧).
  func select(_ items: [Selection], adding: Bool) {
    var picked = TimelineSelection(primary: selection, others: multi)
    picked.box(items, adding: adding)
    selection = picked.primary
    multi = picked.others
  }

  /// The source range of a selected item (a marker is a point).
  func timeRange(_ s: Selection) -> (Double, Double)? { plan?.timeRange(of: s) }

  /// A timeline bar dragged or trimmed: retimes it and keeps it selected.
  func retime(_ s: Selection, start: Double, end: Double) {
    var moved: Selection?
    apply { moved = $0.retime(s, start: start, end: end) }
    if let moved { select(moved, adding: false) }
  }

  /// Moves every selected zoom, layout, title, annotation and marker by `delta` seconds, as far as
  /// the group can go without leaving the recording, and keeps them selected.
  func moveSelected(by delta: Double, coalesce: String? = nil) {
    let items = selectedItems
    guard let d = plan?.groupShift(items, by: delta) else { return }
    var moved: [Selection] = []
    apply(coalesce: coalesce) { moved = $0.shift(items, by: d) }
    select(moved + items.filter { !$0.movable }, adding: false)
  }

  /// ⌘A: every zoom, layout, title and annotation (the things that move as a group).
  func selectAllItems() {
    guard let p = plan else { return }
    select(p.allItems.filter(\.movable), adding: false)
  }

  // MARK: Pipeline

  /// The running pipeline step, so Stop can cancel it.
  var task: Task<Void, Never>?
  /// Called with `dir` when a step ends (done, failed or stopped); the library applies queued renames.
  var onFinishedWork: ((URL) -> Void)?
}
