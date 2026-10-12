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
}

/// One request to the AI editor and its reply (streamed in while it runs).
struct Ask: Identifiable {
  let id = UUID()
  let instruction: String
  var reply = ""
  var running = true
}

/// One open project: the plan (with undo), a live preview, a playhead, and the pipeline actions.
/// Every edit, from the timeline, the inspector or Claude, ends up in plan.json.
final class ProjectModel: ObservableObject {
  let dir: URL
  @Published private(set) var plan: Plan?
  @Published private(set) var project: Project?
  @Published private(set) var player = AVPlayer()
  /// Playhead in output frames.
  @Published private(set) var outFrame = 0.0
  @Published private(set) var isPlaying = false
  @Published var selection: Selection?
  @Published var status = ""
  @Published private(set) var busy = false
  @Published private(set) var previewReady = false
  @Published var instruction = ""
  @Published private(set) var claudeLog = ""
  /// What you've asked the AI to do in this session, and what it said back.
  @Published private(set) var asks: [Ask] = []
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
  }

  var name: String { dir.lastPathComponent }
  var planURL: URL { dir.appendingPathComponent("plan.json") }
  var outURL: URL { dir.appendingPathComponent("out.mp4") }
  var hasPlan: Bool { plan != nil }
  var fps: Int { plan?.output.fps ?? 30 }
  var mapped: [MappedSegment] { plan.map(mapPlan) ?? [] }
  var totalOutFrames: Int { plan.map(planFrames) ?? 1 }
  /// Playhead in source seconds (what the timeline shows).
  var playheadSrc: Double { outToSrc(mapped, min(outFrame, Double(totalOutFrames - 1)), fps: fps) ?? 0 }

  func close() {
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
      if let old = self.plan {
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
            case .failed: self?.status = "Preview failed: \(item.error?.localizedDescription ?? "unknown error")"
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
      }
    }
  }

  // MARK: Editing

  private var lastEditKey: String?
  private var lastEditAt = Date.distantPast

  /// Applies an edit, saves plan.json and refreshes the preview. Edits with the same `coalesce`
  /// key in quick succession (a slider drag) share one undo step.
  func apply(coalesce key: String? = nil, _ change: (inout Plan) -> Void) {
    // An edit made outside the app (Claude, the CLI, a text editor) may not have been picked up
    // yet. Apply this change on top of the file, not over it.
    if let disk = try? Data(contentsOf: planURL), disk != lastPlanData, let fresh = try? JSONDecoder().decode(Plan.self, from: disk) {
      if let old = plan { undoStack.append(old) }
      lastPlanData = disk
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
    commit(p)
  }

  private func commit(_ p: Plan) {
    // Drop a selection the new plan doesn't have before publishing it, so views never see both.
    switch selection {
    case .segment(let i) where i >= p.segments.count: selection = nil
    case .zoom(let i) where i >= p.zooms.count: selection = nil
    case .layout(let i) where i >= p.layouts.count: selection = nil
    case .callout(let i) where i >= p.callouts.count: selection = nil
    default: break
    }
    plan = p
    do {
      try p.write(to: planURL)
      lastPlanData = try Data(contentsOf: planURL)
      lastPlanMtime = (try? FileManager.default.attributesOfItem(atPath: planURL.path))?[.modificationDate] as? Date
    } catch {
      status = "Couldn't save: \(error.localizedDescription)"
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
    guard let selection else { return }
    apply { p in
      switch selection {
      case .segment(let i) where p.segments.indices.contains(i): p.segments.remove(at: i)
      case .zoom(let i) where p.zooms.indices.contains(i): p.zooms.remove(at: i)
      case .layout(let i) where p.layouts.indices.contains(i): p.layouts.remove(at: i)
      case .callout(let i) where p.callouts.indices.contains(i): p.callouts.remove(at: i)
      default: break
      }
    }
    self.selection = nil
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

  func addCallout() {
    guard let plan else { return }
    let t = playheadSrc
    let c = Callout(start: t, end: min(plan.source.duration, t + 2.5), text: "Title")
    apply { $0.callouts.append(c) }
    if let i = self.plan?.callouts.firstIndex(of: c) { selection = .callout(i) }
  }

  // MARK: Transcript editing

  var words: [Word] { project?.words ?? [] }

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

  func run(_ label: String, _ work: @escaping () async throws -> Void) {
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

  func askClaude() {
    let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !busy else { return }
    claudeLog = ""
    asks.append(Ask(instruction: text))
    let ai = AISettings.shared
    if ai.provider != .claudeCode {
      run("\(ai.provider.shortName) is editing…") { [self] in
        defer { finishAsk() }
        guard let plan, let project else { return }
        let (summary, newPlan) = try await APIEditor.edit(project: project, plan: plan, instruction: text, settings: ai)
        apply { $0 = newPlan }
        claudeLog = summary
        asks[asks.count - 1].reply = summary
        instruction = ""
        status = "Edited by \(ai.provider == .anthropic ? ai.anthropicModel : ai.model). ⌘Z undoes it."
      }
      return
    }
    run("Claude is editing…") { [self] in
      defer { finishAsk() }
      let code = try await Claude.edit(project: dir, instruction: text) { chunk in
        Task { @MainActor in
          self.claudeLog += chunk
          if !self.asks.isEmpty { self.asks[self.asks.count - 1].reply = self.claudeLog }
        }
      }
      instruction = ""
      status = code == 0 ? "Claude finished. ⌘Z undoes its edit." : "Claude exited with status \(code)."
    }
  }

  private func finishAsk() {
    guard !asks.isEmpty else { return }
    asks[asks.count - 1].running = false
    // On a failure, run() sets the status after this; pick it up on the next turn.
    DispatchQueue.main.async { [self] in
      if !asks.isEmpty, asks[asks.count - 1].reply.isEmpty { asks[asks.count - 1].reply = claudeLog.isEmpty ? status : claudeLog }
    }
  }
}
