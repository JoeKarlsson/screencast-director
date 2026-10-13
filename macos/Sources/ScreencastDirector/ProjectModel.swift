import AVFoundation
import AppKit
import DirectorCore
import Foundation

/// What's selected on the timeline; the inspector edits it.
enum Selection: Equatable {
  case segment(Int)
  case gap(Gap)
  case zoom(Int)
  case layout(Int)
  case callout(Int)
  case annotation(Int)
  case marker(Int)
  case insert(Int)

  /// Items that can be dragged or nudged in time (clips are trimmed, cuts restored).
  var movable: Bool {
    switch self {
    case .zoom, .layout, .callout, .annotation, .marker, .insert: return true
    default: return false
    }
  }
}

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
  @Published private(set) var claudeLog = ""
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
  }

  var name: String { dir.lastPathComponent }
  var planURL: URL { dir.appendingPathComponent("plan.json") }
  var outURL: URL { dir.appendingPathComponent("out.mp4") }
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
    project = try? Project.load(dir)
    guard let data = try? Data(contentsOf: planURL), let p = try? JSONDecoder().decode(Plan.self, from: data) else {
      plan = nil
      status = "Not analyzed yet."
      if let src = project?.source {
        player.replaceCurrentItem(with: AVPlayerItem(url: dir.appendingPathComponent(src.video)))
      }
      return
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

  private func rebuildPreview() {
    guard let plan else { return }
    previewReady = false
    Task { @MainActor in
      do {
        let project = try Project.load(dir)
        self.project = project
        let built = try await buildComposition(project: project, plan: plan)
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
      } catch {
        status = "Couldn't load the plan: \(error.localizedDescription)"
        Notices.shared.show(error, "Couldn't load the plan")
      }
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
    switch selection {
    case .segment(let i) where i >= p.segments.count: selection = nil
    case .zoom(let i) where i >= p.zooms.count: selection = nil
    case .layout(let i) where i >= p.layouts.count: selection = nil
    case .callout(let i) where i >= p.callouts.count: selection = nil
    case .annotation(let i) where i >= p.annotationList.count: selection = nil
    case .marker(let i) where i >= p.markerList.count: selection = nil
    case .insert(let i) where i >= p.insertList.count: selection = nil
    default: break
    }
    multi = multi.filter { Self.exists($0, in: p) }
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

  func deleteSelection() {
    if transcriptSel != nil {
      cutTranscriptSelection()
      return
    }
    let items = selectedItems
    guard !items.isEmpty else { return }
    apply { p in
      // Clips are cut and cuts restored by time (indices shift as the clips change); the rest are
      // removed by index, last first.
      var cuts: [Range<Double>] = [], restores: [Gap] = []
      var zooms: [Int] = [], layouts: [Int] = [], callouts: [Int] = [], marks: [Int] = [], markers: [Int] = [], inserts: [Int] = []
      for s in items {
        switch s {
        case .segment(let i) where p.segments.indices.contains(i): cuts.append(p.segments[i].start..<p.segments[i].end)
        case .gap(let g): restores.append(g)
        case .zoom(let i): zooms.append(i)
        case .layout(let i): layouts.append(i)
        case .callout(let i): callouts.append(i)
        case .annotation(let i): marks.append(i)
        case .marker(let i): markers.append(i)
        case .insert(let i): inserts.append(i)
        default: break
        }
      }
      var insertList = p.insertList
      for i in inserts.sorted(by: >) where insertList.indices.contains(i) { insertList.remove(at: i) }
      p.insertList = insertList
      for i in zooms.sorted(by: >) where p.zooms.indices.contains(i) { p.zooms.remove(at: i) }
      for i in layouts.sorted(by: >) where p.layouts.indices.contains(i) { p.layouts.remove(at: i) }
      for i in callouts.sorted(by: >) where p.callouts.indices.contains(i) { p.callouts.remove(at: i) }
      var annotationList = p.annotationList
      for i in marks.sorted(by: >) where annotationList.indices.contains(i) { annotationList.remove(at: i) }
      p.annotationList = annotationList
      var markerList = p.markerList
      for i in markers.sorted(by: >) where markerList.indices.contains(i) { markerList.remove(at: i) }
      p.markerList = markerList
      for g in restores { p.restore(g) }
      for r in cuts { p.cut(range: r) }
    }
    selection = nil
    multi = []
  }

  // MARK: Selecting several items

  /// Everything selected on the timeline: the inspector's item first.
  var selectedItems: [Selection] { (selection.map { [$0] } ?? []) + multi }

  func isSelected(_ s: Selection) -> Bool { selection == s || multi.contains(s) }

  /// A click selects one item; ⇧/⌘-click adds it to (or takes it out of) the selection.
  func select(_ s: Selection, adding: Bool) {
    guard adding else {
      selection = s
      multi = []
      return
    }
    if selection == s {
      selection = multi.first
      if !multi.isEmpty { multi.removeFirst() }
    } else if let i = multi.firstIndex(of: s) {
      multi.remove(at: i)
    } else if selection == nil {
      selection = s
    } else {
      multi.append(s)
    }
  }

  /// A drag box selects what it touches (added to the selection with ⇧).
  func select(_ items: [Selection], adding: Bool) {
    var all = adding ? selectedItems : []
    for s in items where !all.contains(s) { all.append(s) }
    selection = all.first
    multi = Array(all.dropFirst())
  }

  static func exists(_ s: Selection, in p: Plan) -> Bool {
    switch s {
    case .segment(let i): return p.segments.indices.contains(i)
    case .zoom(let i): return p.zooms.indices.contains(i)
    case .layout(let i): return p.layouts.indices.contains(i)
    case .callout(let i): return p.callouts.indices.contains(i)
    case .annotation(let i): return p.annotationList.indices.contains(i)
    case .marker(let i): return p.markerList.indices.contains(i)
    case .insert(let i): return p.insertList.indices.contains(i)
    case .gap(let g): return p.gaps.contains(g)
    }
  }

  /// The source range of a selected item (a marker is a point).
  func timeRange(_ s: Selection) -> (Double, Double)? {
    guard let p = plan, Self.exists(s, in: p) else { return nil }
    switch s {
    case .segment(let i): return (p.segments[i].start, p.segments[i].end)
    case .zoom(let i): return (p.zooms[i].start, p.zooms[i].end)
    case .layout(let i): return (p.layouts[i].start, p.layouts[i].end)
    case .callout(let i): return (p.callouts[i].start, p.callouts[i].end)
    case .annotation(let i): return (p.annotationList[i].start, p.annotationList[i].end)
    case .marker(let i): return (p.markerList[i].t, p.markerList[i].t)
    case .insert(let i): return (p.insertList[i].start, p.insertList[i].end)
    case .gap(let g): return (g.start, g.end)
    }
  }

  /// Moves every selected zoom, layout, title, annotation and marker by `delta` seconds, as far as
  /// the group can go without leaving the recording, and keeps them selected.
  func moveSelected(by delta: Double, coalesce: String? = nil) {
    guard let plan else { return }
    let items = selectedItems.filter(\.movable)
    guard !items.isEmpty else { return }
    let ranges = items.compactMap(timeRange)
    guard let lo = ranges.map(\.0).min(), let hi = ranges.map(\.1).max() else { return }
    let d = min(max(delta, -lo), plan.source.duration - hi)
    guard abs(d) > 1e-9 else { return }
    var moved: [(Selection, Any)] = []
    apply(coalesce: coalesce) { p in
      var marks = p.annotationList, pins = p.markerList, clips = p.insertList
      for s in items {
        switch s {
        case .zoom(let i) where p.zooms.indices.contains(i):
          p.zooms[i].start += d
          p.zooms[i].end += d
          moved.append((s, p.zooms[i]))
        case .layout(let i) where p.layouts.indices.contains(i):
          p.layouts[i].start += d
          p.layouts[i].end += d
          moved.append((s, p.layouts[i]))
        case .callout(let i) where p.callouts.indices.contains(i):
          p.callouts[i].start += d
          p.callouts[i].end += d
          moved.append((s, p.callouts[i]))
        case .annotation(let i) where marks.indices.contains(i):
          marks[i].start += d
          marks[i].end += d
          moved.append((s, marks[i]))
        case .marker(let i) where pins.indices.contains(i):
          pins[i].t += d
          moved.append((s, pins[i]))
        case .insert(let i) where clips.indices.contains(i):
          clips[i].start += d
          clips[i].end += d
          moved.append((s, clips[i]))
        default: break
        }
      }
      p.annotationList = marks
      p.markerList = pins
      p.insertList = clips
    }
    // normalize() re-sorts, so find each moved item again.
    guard let now = self.plan else { return }
    let found: [Selection] = moved.compactMap { s, value in
      switch (s, value) {
      case (.zoom, let z as Zoom): return now.zooms.firstIndex(of: z).map { .zoom($0) }
      case (.layout, let l as LayoutRange): return now.layouts.firstIndex(of: l).map { .layout($0) }
      case (.callout, let c as Callout): return now.callouts.firstIndex(of: c).map { .callout($0) }
      case (.annotation, let a as Annotation): return now.annotationList.firstIndex(of: a).map { .annotation($0) }
      case (.marker, let m as Marker): return now.markerList.firstIndex(of: m).map { .marker($0) }
      case (.insert, let c as Insert): return now.insertList.firstIndex(of: c).map { .insert($0) }
      default: return nil
      }
    }
    let keep = selectedItems.filter { !$0.movable }
    select(found + keep, adding: false)
  }

  /// ⌘A: every zoom, layout, title and annotation (the things that move as a group).
  func selectAllItems() {
    guard let p = plan else { return }
    let all: [Selection] =
      p.zooms.indices.map { .zoom($0) } + p.layouts.indices.map { .layout($0) } + p.callouts.indices.map { .callout($0) }
      + p.annotationList.indices.map { .annotation($0) }
    select(all, adding: false)
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
        let file = try copyIntoProject(url, folder: "broll")
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
    if let window = AppDelegate.shared?.window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
  }

  /// Copies a file into a project subfolder (a new name if one's taken) and returns its plan path.
  private func copyIntoProject(_ url: URL, folder: String) throws -> String {
    let fm = FileManager.default
    let target = dir.appendingPathComponent(folder)
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
    var name = url.lastPathComponent, n = 2
    while fm.fileExists(atPath: target.appendingPathComponent(name).path) {
      name = "\(base) \(n).\(ext)"
      n += 1
    }
    try fm.copyItem(at: url, to: target.appendingPathComponent(name))
    return "\(folder)/\(name)"
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
    let pins = plan?.markerList ?? []
    let target = step > 0 ? pins.first { $0.t > t + 0.05 } : pins.last { $0.t < t - 0.05 }
    if let target { seek(src: target.t) }
  }

  // MARK: In and out

  /// The marked range, when both ends are set the right way round.
  var markedRange: Range<Double>? {
    guard let a = inPoint, let b = outPoint, b > a + 0.05 else { return nil }
    return a..<b
  }

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
  func wordIndex(at t: Double) -> Int? {
    let ws = words
    var lo = 0, hi = ws.count - 1
    while lo <= hi {
      let mid = (lo + hi) / 2
      if t < ws[mid].start { hi = mid - 1 } else if t >= ws[mid].end { lo = mid + 1 } else { return mid }
    }
    return nil
  }

  /// The source time range the selected words cover, from the first word's start to the last's end.
  var transcriptRange: Range<Double>? {
    guard let sel = transcriptSel, sel.lowerBound >= 0, sel.upperBound < words.count else { return nil }
    let a = words[sel.lowerBound].start, b = words[sel.upperBound].end
    return b > a ? a..<b : nil
  }

  /// Whether every selected word is already cut (then the action is Restore).
  var transcriptSelectionIsCut: Bool {
    guard let sel = transcriptSel, let plan, sel.upperBound < words.count else { return false }
    return words[sel].allSatisfy { plan.speed(at: ($0.start + $0.end) / 2) == nil }
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
    let end = min(max(sel.upperBound + step, sel.lowerBound), words.count - 1)
    transcriptSel = sel.lowerBound...end
    seek(src: words[end].start)
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
      let length = old.map { Double(planFrames($0)) / Double($0.output.fps) }
      let summary = old.flatMap { o in plan.map { PlanHistory.summary(from: $0, to: o) } } ?? "unreadable"
      return Version(id: e.url, date: e.date, length: length, summary: summary)
    }
  }

  /// Makes an earlier version current. Undoable, and the version it replaces goes into history.
  func restoreVersion(_ url: URL) {
    guard let old = try? Plan.load(url) else {
      status = "Couldn't read that version."
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
    let cur = plan.segments[i].speed
    let speeds = [1.0, 1.5, 2, 3, 4, 8]
    let next = speeds.first { $0 > cur + 0.01 } ?? 1
    apply { $0.segments[i].speed = next }
    selection = .segment(i)
    status = "Clip speed \(next.formatted())×"
  }

  /// = and -: change the selected zoom's level.
  func nudgeZoom(_ delta: Double) {
    guard case .zoom(let i) = selection else { return }
    guard plan?.zooms.indices.contains(i) == true else { return }
    apply(coalesce: "zoomScale\(i)") { $0.zooms[i].scale = (min(max($0.zooms[i].scale + delta, 1.1), 3) * 10).rounded() / 10 }
  }

  /// ⌘D: copy the selected zoom to just after itself.
  func duplicateZoom() {
    guard case .zoom(let i) = selection, let plan, plan.zooms.indices.contains(i) else { return }
    var z = plan.zooms[i]
    let len = z.end - z.start
    z.start = min(z.end + 0.5, plan.source.duration - len)
    z.end = z.start + len
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
      if outFrame >= Double(totalOutFrames - 1) { seek(outFrame: 0) }
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
      ProfileStore.shared.defaultProfile?.apply(to: &draft, name: name)
      let level = AppSettings.shared.pauseLevel
      let fresh = try Project.load(dir)
      let silences = Analyzer.silences(try await Analyzer.loudness(fresh, video: draft.source.video), minLength: 0.2)
      draft.retrimPauses(words: fresh.words, level: level, silences: silences, paused: fresh.paused)
      draft.pauses = level
      if draft.camera != nil, let face = try await Publish.faceCenter(project: try Project.load(dir), plan: draft) {
        draft.camera?.x = face.x
        draft.camera?.y = face.y
        draft.camera?.zoom = Publish.centeringZoom(x: face.x, y: face.y)
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

  /// Queues the current format, or presets, for export (one file each). Exports run in the
  /// background on the plan as it is right now, so you can keep editing.
  func export(_ presets: [ExportPreset?] = [nil]) {
    flushWrite()
    guard let plan else { return }
    // Menus, buttons and key shortcuts all call this on the main thread.
    MainActor.assumeIsolated {
      for preset in presets {
        let p = preset.map { $0.applied(to: plan) } ?? plan
        let url = preset.map { dir.appendingPathComponent("out-\($0.id).mp4") } ?? outURL
        ExportQueue.shared.enqueue(projectDir: dir, plan: p, label: "\(name): \(preset?.name ?? "current format")", url: url)
      }
      ExportQueue.shared.showList = true
    }
    status = presets.count == 1 ? "Exporting in the background." : "Queued \(presets.count) exports."
  }

  func applyProfile(_ name: String) {
    guard let profile = ProfileStore.shared.load(name) else { return }
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
    var lines: [String] = []
    let t = playheadSrc
    let near = words.filter { $0.end > t - 2 && $0.start < t + 2 }.map(\.text).joined(separator: " ")
    lines.append("Playhead: source \(fmtTime(t))\(near.isEmpty ? "" : ", around \"\(near)\"")")
    if let r = transcriptRange, let sel = transcriptSel {
      let text = words[sel].map(\.text).joined(separator: " ")
      lines.append("Selected transcript: source \(fmtTime(r.lowerBound))-\(fmtTime(r.upperBound)) \"\(text)\"")
    }
    if let plan, let selection {
      switch selection {
      case .segment(let i) where plan.segments.indices.contains(i):
        let s = plan.segments[i]
        lines.append("Selected clip: source \(fmtTime(s.start))-\(fmtTime(s.end)) at \(s.speed.formatted())x")
      case .zoom(let i) where plan.zooms.indices.contains(i):
        let z = plan.zooms[i]
        lines.append("Selected zoom #\(i): source \(fmtTime(z.start))-\(fmtTime(z.end))")
      case .layout(let i) where plan.layouts.indices.contains(i):
        lines.append("Selected layout #\(i): source \(fmtTime(plan.layouts[i].start))-\(fmtTime(plan.layouts[i].end))")
      case .callout(let i) where plan.callouts.indices.contains(i):
        lines.append("Selected title #\(i): \"\(plan.callouts[i].text)\"")
      case .annotation(let i) where plan.annotationList.indices.contains(i):
        let a = plan.annotationList[i]
        lines.append("Selected annotation #\(i): \(a.kind) source \(fmtTime(a.start))-\(fmtTime(a.end))")
      case .gap(let g):
        lines.append("Selected cut: source \(fmtTime(g.start))-\(fmtTime(g.end))")
      case .insert(let i) where plan.insertList.indices.contains(i):
        let c = plan.insertList[i]
        lines.append("Selected B-roll #\(i): \(c.file) source \(fmtTime(c.start))-\(fmtTime(c.end))")
      case .marker(let i) where plan.markerList.indices.contains(i):
        let m = plan.markerList[i]
        lines.append("Selected marker #\(i) at source \(fmtTime(m.t))\(m.label.map { " \"\($0)\"" } ?? "")")
      default: break
      }
    }
    if !multi.isEmpty {
      let ranges = multi.compactMap(timeRange).map { "\(fmtTime($0.0))-\(fmtTime($0.1))" }
      lines.append("Also selected: \(multi.count) more item(s) at source \(ranges.joined(separator: ", "))")
    }
    if let r = markedRange {
      let text = words.filter { $0.start < r.upperBound && $0.end > r.lowerBound }.map(\.text).joined(separator: " ")
      lines.append("In/out range: source \(fmtTime(r.lowerBound))-\(fmtTime(r.upperBound))\(text.isEmpty ? "" : " \"\(text)\"")")
    }
    return lines.joined(separator: "\n")
  }

  func askClaude() {
    let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !busy else { return }
    flushWrite()
    claudeLog = ""
    asks.append(Ask(instruction: text))
    planBeforeAsk = plan
    let ai = AISettings.shared
    let request = "\(text)\n\n(Where I am in the editor, for words like \"here\" or \"this\":\n\(askContext()))"
    if ai.provider != .claudeCode {
      run("\(ai.provider.shortName) is editing…") { [self] in
        defer { finishAsk() }
        try await readScreenTextIfNeeded()
        guard let plan, let project else { return }
        asks[asks.count - 1].steps.append("Sending the timeline to \(ai.provider.shortName)")
        let (summary, newPlan) = try await APIEditor.edit(project: project, plan: plan, instruction: request, settings: ai)
        apply { $0 = newPlan }
        claudeLog = summary
        asks[asks.count - 1].reply = summary
        instruction = ""
        status = "Edited by \(ai.provider == .anthropic ? ai.anthropicModel : ai.model). ⌘Z undoes it."
      }
      return
    }
    aiEditing = true
    run("Claude is editing…") { [self] in
      defer { finishAsk() }
      try await readScreenTextIfNeeded()
      let code = try await Claude.edit(project: dir, instruction: request) { event in
        Task { @MainActor in
          guard !self.asks.isEmpty else { return }
          switch event {
          case .step(let s): self.asks[self.asks.count - 1].steps.append(s)
          case .text(let t):
            self.claudeLog += (self.claudeLog.isEmpty ? "" : "\n\n") + t
            self.asks[self.asks.count - 1].reply = self.claudeLog
          }
        }
      }
      instruction = ""
      if Task.isCancelled {
        status = "Stopped. ⌘Z undoes anything it changed."
      } else {
        status = code == 0 ? "Claude finished. ⌘Z undoes its edit." : "Claude exited with status \(code)."
      }
    }
  }

  private func finishAsk() {
    guard !asks.isEmpty else { return }
    asks[asks.count - 1].running = false
    // Claude Code writes plan.json itself and the watcher picks it up within a second.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
      let wasEditing = aiEditing
      aiEditing = false
      guard let old = planBeforeAsk, let new = plan else { return }
      planBeforeAsk = nil
      if wasEditing, old != new {
        undoStack.append(old)
        redoStack.removeAll()
      }
      let ranges = changedRanges(from: old, to: new)
      if !ranges.isEmpty { aiChange = (UUID(), ranges) }
      if !asks.isEmpty { asks[asks.count - 1].changes = planChanges(from: old, to: new) }
    }
    // On a failure, run() sets the status after this; pick it up on the next turn.
    DispatchQueue.main.async { [self] in
      if !asks.isEmpty, asks[asks.count - 1].reply.isEmpty { asks[asks.count - 1].reply = claudeLog.isEmpty ? status : claudeLog }
      saveAsks()
    }
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
    asks = saved.map { Ask(instruction: $0.instruction, reply: $0.reply, running: false, steps: $0.steps ?? []) }
  }

  /// Keeps the last 50 asks with the project, so the history survives switching recordings.
  private func saveAsks() {
    let saved = asks.filter { !$0.running }.suffix(50).map { SavedAsk(instruction: $0.instruction, reply: $0.reply, steps: $0.steps) }
    try? FileManager.default.createDirectory(at: asksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(Array(saved)).write(to: asksURL, options: .atomic)
  }
}
