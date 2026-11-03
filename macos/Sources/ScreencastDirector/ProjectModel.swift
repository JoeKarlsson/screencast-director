import AVFoundation
import AppKit
import DirectorCore
import Foundation

/// One request to the AI editor and its reply (streamed in while it runs), the steps it took,
/// and what it changed (each can be undone on its own until accepted).
struct Ask: Identifiable {
  let id = UUID()
  let instruction: String
  var reply = ""
  var running = true
  var steps: [String] = []
  var changes: [PlanChange] = []
}

/// What's kept of an ask in .history/asks.json.
private struct SavedAsk: Codable {
  var instruction: String
  var reply: String
  var steps: [String]?
}

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
  private(set) var outFrame: Double {
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
  @Published private(set) var busy = false
  @Published private(set) var previewReady = false
  @Published var instruction = ""
  /// What you've asked the AI to do in this session, and what it said back.
  @Published private(set) var asks: [Ask] = []
  /// What the last AI edit changed, in source seconds; the timeline flashes these ranges. A new
  /// id each time, so the same ranges flash again.
  @Published private(set) var aiChange: (id: UUID, ranges: [(Double, Double)])?
  private var planBeforeAsk: Plan?
  /// Claude Code is writing plan.json. Edits here would race its writes, so they wait.
  @Published private(set) var aiEditing = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published var showPublish = false
  /// Loudness every 50 ms (source time), for the timeline's audio track and normalizing.
  @Published private(set) var levels: [(Double, Double)] = []
  @Published var showHistory = false
  /// Words selected in the Transcript tab (indexes into project.words), first to last.
  @Published var transcriptSel: ClosedRange<Int>?
  @Published var publishTitle = ""
  @Published private(set) var publishFiles: [URL] = []
  @Published private(set) var descriptionText = ""

  private var undoStack: [Plan] = [] { didSet { canUndo = !undoStack.isEmpty } }
  private var redoStack: [Plan] = [] { didSet { canRedo = !redoStack.isEmpty } }
  private var watcher: Timer?
  private var lastPlanData: Data?
  private var lastPlanMtime: Date?
  private var itemObserver: NSKeyValueObservation?
  private var timeObserver: Any?
  private var rateObserver: NSKeyValueObservation?
  private var rebuildWork: DispatchWorkItem?
  private var thumbnails: [Int: NSImage] = [:]

  init(dir: URL) {
    self.dir = dir
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
      guard let self, let fps = self.plan?.output.fps else { return }
      self.outFrame = t.seconds * Double(fps)
    }
    rateObserver = player.observe(\.rate) { [weak self] p, _ in
      DispatchQueue.main.async { self?.isPlaying = p.rate != 0 }
    }
    loadFromDisk()
    watchPlan()
    loadAsks()
    quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
      [weak self] _ in MainActor.assumeIsolated { self?.stopForQuit() }
    }
  }

  private var quitObserver: NSObjectProtocol?

  var name: String { dir.lastPathComponent }
  var planURL: URL { dir.appendingPathComponent("plan.json") }
  var outURL: URL { exportURL(dir: dir) }
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
      if let previous = self.lastPlanData { PlanHistory.snapshot(previous, planURL: self.planURL) }
      // While Claude Code edits, its writes become one undo step when it finishes (finishAsk).
      if let old = self.plan, !self.aiEditing {
        self.undoStack.append(old)
        self.redoStack.removeAll()
      }
      self.loadFromDisk()
    }
  }

  private func rebuild(now: Bool = false) {
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
  private func renderAnimationsIfNeeded(_ plan: Plan, target: Plan? = nil, args: [String] = []) {
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
      let fresh = try? JSONDecoder().decode(Plan.self, from: disk)
    {
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
  private func commit(_ p: Plan, deferWrite: Bool = false) {
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

  // MARK: B-roll

  /// Asks for a picture or video, copies it into the project's broll/ folder, and shows it from the
  /// playhead (3 s for a picture, up to 5 s of a clip).
  func addInsert() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .movie]
    panel.message = "Pick a picture or clip to show over the video"
    let start = playheadSrc
    let done: (NSApplication.ModalResponse) -> Void = { [self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        let file = try Project.importFile(url, into: "broll", dir: dir)
        Task { @MainActor in
          var length = 3.0
          if !Insert(start: 0, end: 1, file: file).isImage, let d = try? await AVURLAsset(url: dir.appendingPathComponent(file)).load(.duration) {
            length = min(5, max(0.5, d.seconds))
          }
          guard let plan else { return }
          let ins = Insert(start: start, end: min(plan.source.duration, start + length), file: file)
          apply { $0.insertList.append(ins) }
          if let i = self.plan?.insertList.firstIndex(of: ins) { select(.insert(i), adding: false) }
        }
      } catch {
        Notices.shared.show(error, "Couldn't add the B-roll")
      }
    }
    presentPanel(panel, then: done)
  }

  /// Asks for a `.cube` LUT, copies it into the project's luts/ folder, and grades the camera with it.
  /// A file that isn't a 3D LUT is refused with the reason, before anything is copied.
  func chooseLUT() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
    panel.message = "Choose a .cube LUT for the camera"
    let done: (NSApplication.ModalResponse) -> Void = { [self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        _ = try CubeLUT.load(url)
        let file = try Project.importFile(url, into: "luts", dir: dir)
        apply { p in
          var g = p.camera?.grade ?? Grade()
          g.lut = file
          p.camera?.grade = g
        }
      } catch {
        Notices.shared.show(error, "Couldn't use that LUT")
      }
    }
    presentPanel(panel, then: done)
  }

  /// A library sound at the playhead. It's copied into the project's sfx/ folder (unless the
  /// project already has that file), so the video keeps it if the library changes.
  func addSound(_ entry: AudioLibrary.Entry) {
    let file: String
    do {
      file = try AudioLibrary(.sounds).freeze(entry, project: dir)
    } catch {
      Notices.shared.show(error, "Couldn't add \(entry.item.name)")
      return
    }
    let e = SoundEffect(t: playheadSrc, file: file, note: entry.item.name)
    apply { p in p.sfxList.append(e) }
    if let i = plan?.sfx?.firstIndex(of: e) { select(.sfx(i), adding: false) }
    status = "\(entry.item.name) at \(fmtTime(e.t))."
  }

  /// A library track as the video's music, copied into the project's music/ folder (unless it's
  /// there already). Keeps the current volume settings when swapping tracks.
  func useMusic(_ entry: AudioLibrary.Entry) {
    let file: String
    do {
      file = try AudioLibrary(.music).freeze(entry, project: dir)
    } catch {
      Notices.shared.show(error, "Couldn't use \(entry.item.name)")
      return
    }
    apply { p in
      var m = p.music ?? Music(file: file)
      m.file = file
      p.music = m
    }
    status = "Music: \(entry.item.name)."
  }

  /// Asks for an audio file, copies it into the project's music/ folder, and uses it as the music.
  /// Keeps the current volume settings.
  func chooseMusicFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
    panel.message = "Choose a background track"
    presentPanel(panel) { [self] response in
      guard response == .OK, let url = panel.url else { return }
      let file: String
      do { file = try Project.importFile(url, into: "music", dir: dir) } catch {
        Notices.shared.show(error, "Couldn't add the music")
        return
      }
      apply { p in
        var m = p.music ?? Music(file: file)
        m.file = file
        p.music = m
      }
      status = "Music: \(url.deletingPathExtension().lastPathComponent)."
    }
  }

  // MARK: Markers

  /// M: a marker at the playhead.
  func addMarker() {
    let t = playheadSrc
    let m = Marker(t: t)
    apply { $0.markerList.append(m) }
    if let i = plan?.markerList.firstIndex(of: m) { select(.marker(i), adding: false) }
    status = "Marker at \(fmtTime(t)). Name it in the inspector."
  }

  /// ; and ': the previous or next marker.
  func jumpMarker(_ step: Int) {
    let t = playheadSrc
    if let target = plan?.marker(from: t, step: step) { seek(src: target.t) }
  }

  // MARK: In and out

  /// The marked range, when both ends are set the right way round.
  var markedRange: Range<Double>? { DirectorCore.markedRange(in: inPoint, out: outPoint) }

  /// I: the range starts at the playhead.
  func markIn() {
    inPoint = playheadSrc
    if let o = outPoint, o <= playheadSrc { outPoint = nil }
  }

  /// O: the range ends at the playhead.
  func markOut() {
    outPoint = playheadSrc
    if let i = inPoint, i >= playheadSrc { inPoint = nil }
  }

  func clearInOut() {
    inPoint = nil
    outPoint = nil
  }

  func cutMarked() {
    guard let r = markedRange else { return }
    apply { $0.cut(range: r) }
    status = "Cut \(fmtTime(r.upperBound - r.lowerBound)). ⌘Z puts it back."
    clearInOut()
  }

  /// Speeds up the marked range (talking stays muted when sped up, so this is for typing and waiting).
  func speedMarked(_ speed: Double) {
    guard let r = markedRange else { return }
    apply { $0.setSpeed(range: r, speed: speed) }
    status = "\(fmtTime(r.upperBound - r.lowerBound)) at \(speed.formatted())×"
    clearInOut()
  }

  func restore(_ gap: Gap) {
    apply { $0.restore(gap) }
    selection = nil
  }

  func addZoom() {
    guard let plan else { return }
    let t = playheadSrc
    let f = zoomFocus(at: t, clicks: project?.clicks ?? [])
    let z = Zoom(start: t, end: min(plan.source.duration, t + 2.5), x: f.x, y: f.y, scale: 1.8, note: "manual")
    apply { $0.zooms.append(z) }
    if let i = self.plan?.zooms.firstIndex(of: z) { selection = .zoom(i) }
  }

  /// A new animation over the in/out range, the selected words, or the template's length from the
  /// playhead, with the template's starting content and its beats spread over that stretch.
  func addAnimation(_ template: AnimationTemplate) {
    guard let plan else { return }
    let span = markedRange ?? transcriptRange ?? playheadSrc..<min(plan.source.duration, playheadSrc + template.length)
    guard span.upperBound - span.lowerBound > 0.5 else {
      Notices.shared.show("There's not enough recording after the playhead for an animation.")
      return
    }
    let a = template.make(start: span.lowerBound, end: span.upperBound)
    freezeTemplate(template.name)
    apply { $0.animationList.append(a) }
    if let i = self.plan?.animationList.firstIndex(of: a) { select(.animation(i), adding: false) }
    status = "Added \(template.title). Fill it in on the right, or let Claude fill it from what you say."
  }

  /// Changes one animation, bounds-checked (an undo can remove it while its editor is open).
  func editAnimation(_ i: Int, coalesce: String? = nil, _ change: (inout Animation) -> Void) {
    apply(coalesce: coalesce) { p in
      guard p.animationList.indices.contains(i) else { return }
      var list = p.animationList
      change(&list[i])
      p.animationList = list
    }
  }

  /// Switches an animation to another template, starting over with that template's content.
  func setAnimationTemplate(_ i: Int, _ template: AnimationTemplate) {
    freezeTemplate(template.name)
    editAnimation(i) { a in
      guard a.template != template.name else { return }
      a = template.make(start: a.start, end: a.end)
    }
  }

  /// Copies a template into this video's animations folder (once), so later changes to the
  /// library never change this video.
  private func freezeTemplate(_ name: String) {
    do {
      try AnimationLibrary.sources(dir).freeze(name)
    } catch {
      Notices.shared.show(error, "Couldn't copy the \(name) template into this video")
    }
  }

  /// Replaces this video's copy of a template with the library's latest; its animations re-render.
  func updateAnimationTemplate(_ name: String) {
    do {
      try AnimationLibrary.sources(dir).updateFromLibrary(name)
      objectWillChange.send()
      rebuild(now: true)
      status = "Updated the \(name) template. Its animations re-render with the new version."
    } catch {
      Notices.shared.show(error, "Couldn't update the \(name) template")
    }
  }

  /// Saves this video's copy of a template to the personal library, for future videos.
  func saveAnimationTemplate(_ name: String) {
    do {
      try AnimationLibrary.sources(dir).saveToPersonal(name)
      objectWillChange.send()
      status = "Saved the \(name) template to your library. New animations in any video can use it."
    } catch {
      Notices.shared.show(error, "Couldn't save the \(name) template to your library")
    }
  }

  /// Shows this video's copy of a template in the Finder, to edit it by hand or with Claude.
  func revealAnimationTemplate(_ name: String) {
    let file = AnimationSources.videoFolder(dir).appendingPathComponent("templates/\(name).js")
    NSWorkspace.shared.activateFileViewerSelecting([file])
  }

  /// Has Claude write the animation's text and time its beats from what's said over it.
  func fillAnimationFromTranscript(_ i: Int) {
    guard let list = plan?.animationList, list.indices.contains(i) else { return }
    let a = list[i]
    instruction =
      "Fill in animation #\(i) (the \"\(a.template)\" template, \(fmtTime(a.start))–\(fmtTime(a.end))) from what I say in that stretch: "
      + "write its heading, labels and apps in my words, and cue each beat to the word that names it. Keep its start and end."
    askClaude()
  }

  func addLayout(_ mode: LayoutMode) {
    guard let plan else { return }
    let t = playheadSrc
    let l = LayoutRange(start: t, end: min(plan.source.duration, t + 4), mode: mode, note: nil)
    apply { $0.layouts.append(l) }
    if let i = self.plan?.layouts.firstIndex(of: l) { selection = .layout(i) }
  }

  func addCallout(style: String = "title") {
    guard let plan else { return }
    let t = playheadSrc
    let text = style == "lower-third" ? "Your Name" : style == "chapter" ? "Section" : "Title"
    let c = Callout(
      start: t, end: min(plan.source.duration, t + (style == "slate" || style == "chapter" ? 2.5 : 3)), text: text,
      style: style == "title" ? nil : style, subtitle: style == "lower-third" ? "Your role" : style == "chapter" ? "Part 1" : nil)
    apply { $0.callouts.append(c) }
    if let i = self.plan?.callouts.firstIndex(of: c) { selection = .callout(i) }
  }

  /// Adds a spotlight, box, arrow, highlight or blur at the playhead, around the last click.
  func addAnnotation(_ kind: String, from start: Double? = nil, to end: Double? = nil) {
    guard let plan else { return }
    let t = start ?? playheadSrc
    let f = zoomFocus(at: end ?? t, clicks: project?.clicks ?? [])
    let w = kind == "highlight" ? 0.2 : 0.16, h = kind == "highlight" ? 0.04 : 0.1
    let a = Annotation(
      start: t, end: min(plan.source.duration, end ?? t + 2.5), kind: kind, x: min(max(f.x - w / 2, 0), 1 - w), y: min(max(f.y - h / 2, 0), 1 - h),
      w: w, h: h)
    apply { $0.annotationList.append(a) }
    if let i = self.plan?.annotationList.firstIndex(of: a) { select(.annotation(i), adding: false) }
  }

  /// ⌥← and ⌥→: moves the selected zoom, layout, title or annotation by whole frames.
  func nudgeSelection(frames n: Double) {
    moveSelected(by: n / Double(fps), coalesce: "nudge")
  }

  // MARK: Transcript editing

  var words: [Word] { project?.words ?? [] }

  /// The word being said at source time `t`, if any (binary search; words are in order).
  func wordIndex(at t: Double) -> Int? { DirectorCore.wordIndex(at: t, in: words) }

  /// The source time range the selected words cover, from the first word's start to the last's end.
  var transcriptRange: Range<Double>? { transcriptSel.flatMap { wordRange($0, in: words) } }

  /// Whether every selected word is already cut (then the action is Restore).
  var transcriptSelectionIsCut: Bool {
    guard let sel = transcriptSel, let plan else { return false }
    return wordsAreCut(sel, in: words, plan: plan)
  }

  /// Click a word: select it (shift-click extends) and seek there.
  func clickWord(_ i: Int, extend: Bool) {
    guard words.indices.contains(i) else { return }
    if extend, let sel = transcriptSel {
      transcriptSel = min(sel.lowerBound, i)...max(sel.upperBound, i)
    } else {
      transcriptSel = i...i
    }
    player.pause()
    seek(src: words[i].start)
  }

  func cutTranscriptSelection() {
    guard let r = transcriptRange else { return }
    apply { $0.cut(range: r) }
    status = "Cut \(fmtTime(r.upperBound - r.lowerBound)) of speech. ⌘Z puts it back."
    transcriptSel = nil
  }

  /// ⇧← and ⇧→ with words selected: grow or shrink the selection by a word at its end.
  func extendTranscriptSelection(_ step: Int) {
    guard let sel = transcriptSel else { return }
    let extended = extendWordSelection(sel, by: step, wordCount: words.count)
    transcriptSel = extended
    seek(src: words[extended.upperBound].start)
  }

  /// The range the next "over a range" action uses: selected words, else the in/out range.
  var actionRange: Range<Double>? { transcriptRange ?? markedRange }

  private func doneWithRange() {
    if transcriptSel != nil { transcriptSel = nil } else { clearInOut() }
  }

  /// Zooms in over the selected words (or in/out range), toward a click in it (else the last one).
  func zoomOverRange() {
    guard let r = actionRange, let plan else { return }
    let clicks = project?.clicks ?? []
    let inside = clicks.last { $0.t >= r.lowerBound - 1 && $0.t <= r.upperBound && (0...1).contains($0.x) && (0...1).contains($0.y) }
    let f = inside.map { (x: $0.x, y: $0.y) } ?? zoomFocus(at: r.upperBound, clicks: clicks)
    let z = Zoom(
      start: r.lowerBound, end: min(plan.source.duration, max(r.upperBound, r.lowerBound + 1.5)), x: f.x, y: f.y, scale: 1.8,
      note: transcriptSel != nil ? "from transcript" : "from in/out")
    apply { $0.zooms.append(z) }
    if let i = self.plan?.zooms.firstIndex(of: z) { select(.zoom(i), adding: false) }
    doneWithRange()
  }

  /// A title (or lower third, slate, chapter) over the range, worded from what's said in it.
  func titleOverRange(style: String) {
    guard let r = actionRange, let plan else { return }
    let said = words.filter { $0.start < r.upperBound && $0.end > r.lowerBound }
    var text = said.prefix(8).map(\.text).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
    if text.isEmpty { text = "Title" }
    if let first = text.first { text = first.uppercased() + text.dropFirst() }
    let c = Callout(
      start: r.lowerBound, end: min(plan.source.duration, max(r.upperBound, r.lowerBound + 2)), text: text,
      style: style == "title" ? nil : style, subtitle: style == "chapter" ? "Part 1" : nil)
    apply { $0.callouts.append(c) }
    if let i = self.plan?.callouts.firstIndex(of: c) { select(.callout(i), adding: false) }
    doneWithRange()
  }

  /// An annotation over the range, around a click in it (else the last one).
  func annotateRange(_ kind: String) {
    guard let r = actionRange else { return }
    addAnnotation(kind, from: r.lowerBound, to: max(r.upperBound, r.lowerBound + 1.5))
    doneWithRange()
  }

  func restoreTranscriptSelection() {
    guard let r = transcriptRange else { return }
    apply { $0.restore(range: r) }
    status = "Restored \(fmtTime(r.upperBound - r.lowerBound))."
    transcriptSel = nil
  }

  // MARK: Version history

  struct Version: Identifiable {
    let id: URL
    let date: Date
    let length: Double?
    let summary: String
  }

  /// Saved versions of plan.json, newest first, each with how it differs from now.
  func versions() -> [Version] {
    PlanHistory.list(planURL: planURL).map { e in
      let old = try? Plan.load(e.url)
      let length = old.map(planSeconds)
      let summary = old.flatMap { o in plan.map { PlanHistory.summary(from: $0, to: o) } } ?? "unreadable"
      return Version(id: e.url, date: e.date, length: length, summary: summary)
    }
  }

  /// Makes an earlier version current. Undoable, and the version it replaces goes into history.
  func restoreVersion(_ url: URL) {
    let old: Plan
    do { old = try Plan.load(url) } catch {
      Notices.shared.show(error, "Couldn't read that version")
      return
    }
    apply { $0 = old }
    status = "Restored the version from \(DateFormatter.localizedString(from: (PlanHistory.list(planURL: planURL).first { $0.url == url }?.date ?? Date()), dateStyle: .none, timeStyle: .medium)). ⌘Z undoes it."
  }

  // MARK: Keyboard actions (Screen Studio's defaults; see Shortcuts.swift)

  /// The selected clip, else the one under the playhead.
  private var targetSegment: Int? {
    if case .segment(let i) = selection { return i }
    return plan?.segmentIndex(at: playheadSrc)
  }

  /// X: remove from the previous cut up to the playhead.
  func removeToPreviousCut() {
    let t = playheadSrc
    guard let i = plan?.segmentIndex(at: t) else { return }
    apply { $0.segments[i].start = t }
    seek(src: t)
  }

  /// S: step the clip's speed through 1, 1.5, 2, 3, 4, 8.
  func cycleSpeed() {
    guard let i = targetSegment, let plan, plan.segments.indices.contains(i) else { return }
    let next = nextClipSpeed(after: plan.segments[i].speed)
    apply { $0.segments[i].speed = next }
    selection = .segment(i)
    status = "Clip speed \(next.formatted())×"
  }

  /// = and -: change the selected zoom's level.
  func nudgeZoom(_ delta: Double) {
    guard case .zoom(let i) = selection else { return }
    guard plan?.zooms.indices.contains(i) == true else { return }
    apply(coalesce: "zoomScale\(i)") { $0.zooms[i].scale = nudgedZoomScale($0.zooms[i].scale, by: delta) }
  }

  /// ⌘D: copy the selected zoom to just after itself.
  func duplicateZoom() {
    guard case .zoom(let i) = selection, let z = plan?.duplicateOfZoom(i) else { return }
    apply { $0.zooms.append(z) }
    if let j = self.plan?.zooms.firstIndex(of: z) { selection = .zoom(j) }
  }

  /// 1-4: set the selected layout's mode, or add one at the playhead.
  func setLayoutMode(_ mode: LayoutMode) {
    if case .layout(let i) = selection, plan?.layouts.indices.contains(i) == true {
      apply { $0.layouts[i].mode = mode }
    } else {
      addLayout(mode)
    }
  }

  func step(frames n: Double) {
    player.pause()
    seek(outFrame: outFrame + n)
  }

  func goToStart() { seek(outFrame: 0) }
  func goToEnd() { seek(outFrame: Double(totalOutFrames - 1)) }

  /// L: play, or play faster each press (up to 8×).
  func shuttleForward() {
    let r = player.rate
    player.rate = r <= 0 ? 1 : min(r * 2, 8)
  }

  /// J: play backward, faster each press. Falls back to stepping back a second if reverse isn't possible.
  func shuttleBackward() {
    guard player.currentItem?.canPlayReverse == true else {
      step(frames: -Double(fps))
      return
    }
    let r = player.rate
    player.rate = r >= 0 ? -1 : max(r * 2, -8)
  }

  /// K: stop and reset the speed.
  func stop() {
    player.pause()
    player.rate = 0
  }

  // MARK: Playback

  func togglePlay() {
    if player.rate != 0 { player.pause() } else {
      // Stopped at the end (the playhead often rests a frame or two short of the last one, and the
      // player's own clock is the better judge): play again from the top.
      let endF = Double(totalOutFrames - 1)
      let playerF = player.currentTime().seconds * Double(fps)
      if outFrame >= endF - Double(fps) * 0.25 || (playerF.isFinite && playerF >= endF - Double(fps) * 0.25) { seek(outFrame: 0) }
      player.play()
    }
  }

  func seek(outFrame f: Double) {
    let clamped = max(0, min(f, Double(totalOutFrames - 1)))
    outFrame = clamped
    player.seek(to: CMTime(value: CMTimeValue(clamped.rounded()), timescale: CMTimeScale(fps)), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  /// Seeks to a source time; a cut moment lands on the next kept frame.
  func seek(src t: Double) {
    seek(outFrame: srcToOutClamped(mapped, t, fps: fps))
  }

  /// A frame of the raw recording, for picking a zoom's focus point.
  func thumbnail(at t: Double, done: @escaping (NSImage?) -> Void) {
    let key = Int(t * 2)
    if let img = thumbnails[key] { return done(img) }
    guard let video = project?.source.video else { return done(nil) }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: dir.appendingPathComponent(video)))
    gen.maximumSize = CGSize(width: 640, height: 640)
    gen.appliesPreferredTrackTransform = true
    Task { @MainActor in
      let img = (try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image).map {
        NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
      }
      if let img { thumbnails[key] = img }
      done(img)
    }
  }

  /// Re-cuts silences at a level; cuts that removed words stay cut.
  func setPauses(_ level: PauseLevel) {
    guard let project, let video = plan?.source.video else { return }
    run("Finding pauses…") { [self] in
      let silences = Analyzer.silences(try await Analyzer.loudness(project, video: video), minLength: 0.2)
      apply {
        $0.retrimPauses(words: project.words, level: level, silences: silences, paused: project.paused)
        $0.pauses = level
      }
      status = "Pauses: \(level.label)"
    }
  }

  // MARK: Camera framing

  /// Finds where the speaker's face usually is and centers the camera on it.
  func centerCameraOnFace() {
    run("Finding your face…") { [self] in
      guard let plan, let project, plan.camera != nil else { return }
      guard let face = try await Publish.faceCenter(project: project, plan: plan) else {
        status = "No face found in the camera footage."
        return
      }
      apply {
        $0.camera?.x = face.x
        $0.camera?.y = face.y
        $0.camera?.zoom = Publish.centeringZoom(x: face.x, y: face.y)
      }
      status = "Camera centered on your face."
    }
  }

  /// Lines the camera up with the voice by watching the lips (see LipSync).
  func syncCameraToVoice() {
    run("Matching your lips to your voice…") { [self] in
      guard let plan, let project, let camera = plan.camera else { return }
      guard let sync = try await LipSync.measure(project: project, camera: camera), sync.confident else {
        status = "Couldn't tell how far off the camera is. Set Lip sync by hand."
        Notices.shared.show(status)
        return
      }
      apply { $0.camera?.offset = sync.offset }
      status = String(format: "Camera synced to your voice (moved %+.2f s).", sync.offset - camera.offset)
    }
  }

  /// A frame of the camera video, for the framing picker.
  func cameraThumbnail(done: @escaping (NSImage?) -> Void) {
    guard let cam = plan?.camera else { return done(nil) }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: dir.appendingPathComponent(cam.video)))
    gen.maximumSize = CGSize(width: 640, height: 640)
    gen.appliesPreferredTrackTransform = true
    Task { @MainActor in
      let img = (try? await gen.image(at: CMTime(seconds: 5, preferredTimescale: 600)).image).map {
        NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
      }
      done(img)
    }
  }

  // MARK: Publishing

  var publishDir: URL { dir.appendingPathComponent("publish") }

  func openPublish() {
    if publishTitle.isEmpty { publishTitle = plan?.callouts.first?.text ?? name }
    publishFiles = (try? FileManager.default.contentsOfDirectory(at: publishDir, includingPropertiesForKeys: nil))?
      .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    descriptionText = (try? String(contentsOf: publishDir.appendingPathComponent("description.md"), encoding: .utf8)) ?? ""
    showPublish = true
  }

  /// Captions, chapters, transcript and thumbnails into publish/.
  func makePublishKit() {
    run("Making captions and thumbnails…") { [self] in
      guard let plan, let project else { return }
      let files = try await Publish.run(project: project, plan: plan, title: publishTitle) { msg in
        Task { @MainActor in self.status = msg }
      }
      publishFiles = files
      status = "Wrote \(files.count) files to publish/"
    }
  }

  func draftDescription() {
    let ai = AISettings.shared
    run("\(ai.provider.shortName) is writing the description…") { [self] in
      guard let plan, let project else { return }
      let scene = Scene(plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts)
      let user = "Video title: \(publishTitle)\nLength: \(fmtTime(Double(scene.frameCount) / Double(scene.fps)))\n\nTranscript with timestamps:\n\(Publish.timedTranscript(scene))"
      let text = try await AIText.generate(system: AIText.descriptionSystem, user: user, settings: ai)
      try FileManager.default.createDirectory(at: publishDir, withIntermediateDirectories: true)
      let url = publishDir.appendingPathComponent("description.md")
      try text.write(to: url, atomically: true, encoding: .utf8)
      descriptionText = text
      if !publishFiles.contains(url) { publishFiles.append(url) }
      status = "Wrote publish/description.md"
    }
  }

  // MARK: Pipeline

  /// The running pipeline step, so Stop can cancel it.
  private var task: Task<Void, Never>?
  /// Called with `dir` when a step ends (done, failed or stopped); the library applies queued renames.
  var onFinishedWork: ((URL) -> Void)?

  func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    status = label
    task = Task { @MainActor in
      do {
        try await work()
      } catch is CancellationError {
        status = "Stopped."
      } catch where Task.isCancelled {
        status = "Stopped."
      } catch {
        status = "\(label.replacingOccurrences(of: "…", with: "")) failed: \(error.localizedDescription)"
        Notices.shared.show(status, error: true)
      }
      busy = false
      task = nil
      onFinishedWork?(dir)
    }
  }

  /// Stops the AI edit in progress. What it already changed stays, as one undo step.
  func stopAsk() {
    task?.cancel()
  }

  /// Transcribe, measure motion, and write a first-draft plan (keeps an existing plan unless `force`).
  /// A joined recording already has its transcript and motion, so it passes `analyzeFirst: false`.
  func analyzeAndPlan(force: Bool = false, analyzeFirst: Bool = true, then done: (() -> Void)? = nil) {
    run("Analyzing…") { [self] in
      defer { done?() }
      if analyzeFirst { try await analyze(dir) { msg in Task { @MainActor in self.status = msg } } }
      var draft = buildPlan(try Project.load(dir))
      try ProfileStore.shared.defaultProfile()?.apply(to: &draft, name: name)
      let level = AppSettings.shared.pauseLevel
      let fresh = try Project.load(dir)
      let silences = Analyzer.silences(try await Analyzer.loudness(fresh, video: draft.source.video), minLength: 0.2)
      draft.retrimPauses(words: fresh.words, level: level, silences: silences, paused: fresh.paused)
      draft.pauses = level
      if AppSettings.shared.polishVoice { draft.audio = AudioSettings.polished(draft.audio) }
      if draft.camera != nil, let face = try await Publish.faceCenter(project: try Project.load(dir), plan: draft) {
        draft.camera?.x = face.x
        draft.camera?.y = face.y
        draft.camera?.zoom = Publish.centeringZoom(x: face.x, y: face.y)
      }
      // The recorder's offset comes from stream timestamps, which some webcams stamp late.
      if let camera = draft.camera {
        status = "Matching your lips to your voice…"
        if let sync = try await LipSync.measure(project: try Project.load(dir), camera: camera), sync.confident {
          draft.camera?.offset = sync.offset
        } else {
          Notices.shared.show("Couldn't check that the camera is in sync with your voice. If it looks off, set Camera > Lip sync.")
        }
      }
      if let current = plan, force {
        undoStack.append(current)
        commit(draft)
      } else if plan == nil {
        commit(draft)
      } else {
        rebuild(now: true)
      }
    }
  }

  /// One file to export: the plan as it'll render, where it goes, and how `director animate` renders its animations.
  private struct ExportJob {
    let plan: Plan, url: URL, label: String, animateArgs: [String]
  }

  /// Queues the current format, or presets, for export (one file each). Exports run in the
  /// background on the plan as it is right now, so you can keep editing.
  func export(_ presets: [ExportPreset?] = [nil]) {
    flushWrite()
    guard let plan else { return }
    enqueue(presets.map { preset in
      ExportJob(
        plan: preset.map { $0.applied(to: plan) } ?? plan, url: exportURL(dir: dir, preset: preset),
        label: preset?.name ?? "current format", animateArgs: preset.map { ["--preset", $0.id] } ?? [])
    })
  }

  /// Queues clips for export, each cut from the edit in its own format, named "<project> - <clip>.mp4".
  func exportClips(_ clips: [Clip]) {
    flushWrite()
    guard let plan else { return }
    let jobs = clips.map { ExportJob(plan: plan.trimmed(to: $0, words: words, silences: project?.silences), url: exportURL(dir: dir, clip: $0), label: $0.name, animateArgs: ["--clip", $0.name]) }
    if let empty = jobs.first(where: { $0.plan.segments.isEmpty }) {
      Notices.shared.show("The clip \(empty.label) is entirely cut from the edit, so there's nothing to export.", error: true)
      return
    }
    // Each clip's captions file goes beside its video, for platforms that take one.
    if let project {
      for job in jobs {
        let srt = job.url.deletingPathExtension().appendingPathExtension("srt")
        do {
          try Publish.srt(Scene(plan: job.plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts))
            .write(to: srt, atomically: true, encoding: .utf8)
        } catch { Notices.shared.show(error, "Couldn't write the captions for \(job.label)") }
      }
    }
    enqueue(jobs)
  }

  private func enqueue(_ jobs: [ExportJob]) {
    guard let plan, !jobs.isEmpty else { return }
    // An export without its animations would quietly drop them, and each format has its own clips.
    if let job = jobs.first(where: { !$0.plan.animationsToRender(dir: dir).isEmpty }) {
      Notices.shared.show("Animations are still rendering for \(job.label). Export again when they're done.")
      renderAnimationsIfNeeded(plan, target: job.plan, args: job.animateArgs)
      return
    }
    // Menus, buttons and key shortcuts all call this on the main thread.
    MainActor.assumeIsolated {
      for job in jobs { ExportQueue.shared.enqueue(projectDir: dir, plan: job.plan, label: "\(name): \(job.label)", url: job.url) }
      ExportQueue.shared.showList = true
    }
    status = jobs.count == 1 ? "Exporting in the background." : "Queued \(jobs.count) exports."
  }

  func applyProfile(_ name: String) {
    let profile: Profile
    do { profile = try ProfileStore.shared.load(name) } catch {
      Notices.shared.show(error, "Couldn't read the profile \(name)")
      return
    }
    let title = self.name
    apply { profile.apply(to: &$0, name: title) }
    status = "Applied profile \(name)"
  }

  /// Changes the video's shape; vertical, square and feed crop the screen and follow the action.
  func setFormat(aspect: Aspect? = nil, resolution: Resolution? = nil) {
    guard let plan else { return }
    let a = aspect ?? Aspect.of(plan.output)
    let r = resolution ?? Resolution.of(plan.output)
    let size = outputSize(a, r)
    apply {
      $0.output.width = size.width
      $0.output.height = size.height
      if aspect != nil { $0.style.screenAspect = ExportPreset.all.first { $0.aspect == a }?.screenAspect }
    }
  }

  /// Where you are in the editor, so "zoom here" or "cut this" mean something to the AI.
  func askContext() -> String {
    editorContext(
      plan: plan, words: words, playhead: playheadSrc, selection: TimelineSelection(primary: selection, others: multi), wordSelection: transcriptSel,
      marked: markedRange)
  }

  func askClaude() {
    let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !busy else { return }
    flushWrite()
    asks.append(Ask(instruction: text))
    // Everything below writes to this ask by its index, never "the newest one": a reply or wrap-up
    // that lands after another request has started must not end up on it.
    let n = asks.count - 1
    planBeforeAsk = plan
    let ai = AISettings.shared
    let request = "\(text)\n\n(Where I am in the editor, for words like \"here\" or \"this\":\n\(askContext()))"
    if ai.provider != .claudeCode {
      run("\(ai.provider.shortName) is editing…") { [self] in
        var outcome = ""
        defer { finishAsk(n, outcome) }
        do {
          try await readScreenTextIfNeeded()
          guard let plan, let project else {
            outcome = "There was no plan to edit."
            return
          }
          asks[n].steps.append("Sending the timeline to \(ai.provider.shortName)")
          let (summary, newPlan) = try await APIEditor.edit(project: project, plan: plan, instruction: request, settings: ai)
          apply { $0 = newPlan }
          asks[n].reply = summary
          instruction = ""
          status = "Edited by \(ai.provider == .anthropic ? ai.anthropicModel : ai.model). ⌘Z undoes it."
        } catch {
          outcome = Task.isCancelled ? "Stopped." : "\(ai.provider.shortName) couldn't make the edit: \(error.localizedDescription)"
          throw error
        }
      }
      return
    }
    aiEditing = true
    run("Claude is editing…") { [self] in
      var outcome = ""
      defer { finishAsk(n, outcome) }
      do {
        try await readScreenTextIfNeeded()
        let result = try await Claude.edit(project: dir, instruction: request) { event in
          Task { @MainActor in
            guard self.asks.indices.contains(n) else { return }
            switch event {
            case .step(let s): self.asks[n].steps.append(s)
            case .text(let t):
              let reply = self.asks[n].reply
              self.asks[n].reply = reply + (reply.isEmpty ? "" : "\n\n") + t
            }
          }
        }
        instruction = ""
        if Task.isCancelled {
          status = "Stopped. ⌘Z undoes anything it changed."
          outcome = "Stopped. What it already changed stays, and ⌘Z undoes it."
        } else if result.status != 0 {
          status = "Claude Code stopped with an error."
          // Its own words say why (signed out, rate limited, a crash); they used to be thrown away.
          outcome = claudeErrorOutcome(status: result.status, errors: result.errors)
        } else {
          status = "Claude finished. ⌘Z undoes its edit."
          outcome = "Claude finished without saying anything."
        }
      } catch {
        outcome = Task.isCancelled ? "Stopped." : "Couldn't run Claude Code: \(error.localizedDescription)"
        throw error
      }
    }
  }

  /// Closes out ask `n`. `outcome` is how it ended; it becomes the reply when Claude said nothing,
  /// and is added to it after an error, so an ask never shows "editing…" once it's over.
  private func finishAsk(_ n: Int, _ outcome: String) {
    guard asks.indices.contains(n) else { return }
    asks[n].running = false
    asks[n].reply = closingReply(asks[n].reply, outcome: outcome)
    saveAsks()
    // Claude Code writes plan.json itself and the watcher picks it up within a second; compare then.
    let old = planBeforeAsk
    planBeforeAsk = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
      // A newer ask that started meanwhile owns aiEditing now.
      let latest = asks.count - 1 == n
      let wasEditing = aiEditing && latest
      if latest { aiEditing = false }
      guard let old, let new = plan else { return }
      if wasEditing, old != new {
        undoStack.append(old)
        redoStack.removeAll()
      }
      let ranges = changedRanges(from: old, to: new)
      if !ranges.isEmpty { aiChange = (UUID(), ranges) }
      if asks.indices.contains(n) { asks[n].changes = planChanges(from: old, to: new) }
    }
  }

  /// The app is quitting: stop any Claude still editing (or it carries on in the background,
  /// changing the plan with nobody watching) and record that the ask was stopped.
  func stopForQuit() {
    guard asks.last?.running == true else { return }
    Claude.stopAll()
    let n = asks.count - 1
    asks[n].running = false
    asks[n].reply += (asks[n].reply.isEmpty ? "" : "\n\n") + "Stopped when the app quit. What it already changed stays."
    saveAsks()
  }

  /// Recordings analyzed before screen text existed get it once, before their first AI edit, so the
  /// timeline says what each click landed on.
  private func readScreenTextIfNeeded() async throws {
    guard project?.clicks.isEmpty == false, !FileManager.default.fileExists(atPath: ScreenText.url(dir).path) else { return }
    if !asks.isEmpty { asks[asks.count - 1].steps.append("Reading text on screen") }
    try await readScreenText(dir)
  }

  /// Undoes one change from an AI edit (itself undoable) and drops it from the list.
  func rejectChange(_ change: PlanChange, in askID: UUID) {
    apply { change.revert(&$0) }
    dropChange(change.id, in: askID)
  }

  func dropChange(_ id: UUID, in askID: UUID) {
    guard let i = asks.firstIndex(where: { $0.id == askID }) else { return }
    asks[i].changes.removeAll { $0.id == id }
  }

  func acceptAllChanges(in askID: UUID) {
    guard let i = asks.firstIndex(where: { $0.id == askID }) else { return }
    asks[i].changes = []
  }

  private var asksURL: URL { PlanHistory.directory(for: planURL).appendingPathComponent("asks.json") }

  private func loadAsks() {
    guard let data = try? Data(contentsOf: asksURL), let saved = try? JSONDecoder().decode([SavedAsk].self, from: data) else { return }
    asks = saved.map { s in
      // Older versions could save the "is editing…" status as the reply of an edit that never
      // finished, which then looked stuck forever.
      let lost = s.reply.hasSuffix(" is editing…")
      return Ask(
        instruction: s.instruction, reply: lost ? "This edit didn't finish, and its reply was lost. Ask again if the change isn't there." : s.reply,
        running: false, steps: s.steps ?? [])
    }
  }

  /// Keeps the last 50 asks with the project, so the history survives switching recordings.
  private func saveAsks() {
    let saved = asks.filter { !$0.running }.suffix(50).map { SavedAsk(instruction: $0.instruction, reply: $0.reply, steps: $0.steps) }
    try? FileManager.default.createDirectory(at: asksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(Array(saved)).write(to: asksURL, options: .atomic)
  }
}
