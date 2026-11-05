import Foundation

// Flashes: something on screen for under a second with something else on both sides, like half a
// second of the face between two B-roll clips, or a clip too short to register. They read as a
// glitch, so describe, review and the app flag them.

public struct Flash: Equatable, Sendable {
  /// Output frames.
  public var startF: Double
  public var endF: Double
  /// What flashes, and what's on either side.
  public var what: String
  public var before: String
  public var after: String
}

/// What fills the frame at each output frame between the cards, as a name: a full-frame B-roll or
/// animation, else the layout (with any B-roll or animation in the screen card).
func frameContents(_ scene: Scene) -> [String] {
  let portrait = socialTop(scene.plan) != nil
  func layoutName(_ m: LayoutMode) -> String {
    switch m {
    case .camera: return "your face (full camera)"
    case .screen: return "the screen"
    case .pip: return portrait ? "the split (screen over your face)" : "the screen with your bubble"
    case .side: return portrait ? "the split (screen over your face)" : "screen and camera side by side"
    }
  }
  func insertName(_ a: Insert) -> String {
    let file = (a.file as NSString).lastPathComponent
    // Rendered animation clips are named "<template>-<hash>.mp4".
    if a.file.contains(".animations/") { return "animation \(file.split(separator: "-").first.map(String.init) ?? file)" }
    return file
  }
  let start = scene.introFrames, end = scene.outroStart
  var out: [String] = []
  for f in start..<max(start, end) {
    let fd = Double(f)
    let covering = scene.inserts.filter { fd >= $0.s && fd < $0.e }
    if let full = covering.last(where: { $0.a.isFull }) {
      out.append(insertName(full.a))
      continue
    }
    var mode = scene.plan.defaultLayout
    for l in scene.layouts where fd >= l.startF && fd < l.endF { mode = l.mode }
    var name = mode != .camera ? covering.last.map { "\(insertName($0.a)) in \(layoutName(mode))" } ?? layoutName(mode) : layoutName(mode)
    // With the camera in view, a punch-in ending or a cut to another clip changes the shot too: a
    // punch-in that ends a moment before a cut leaves a sliver of the wide shot.
    if mode != .screen, scene.plan.camera != nil {
      if scene.punchIns.contains(where: { fd >= $0.s && fd < $0.e }) { name += ", punched in" }
      if let clip = scene.mapped.first(where: { fd >= Double($0.outStart) && fd < Double($0.outStart + $0.frames) }) {
        name += " [clip src \(fmtTime(clip.start))]"
      }
    }
    out.append(name)
  }
  return out
}

/// Stretches shorter than `minSeconds` with something different on both sides, and clips playing
/// for under half a second.
public func flashes(_ plan: Plan, dir: URL? = nil, minSeconds: Double = 1.0) -> [Flash] {
  let scene = Scene(plan: plan, words: [], clicks: [], shortcuts: [], dir: dir)
  let fps = Double(plan.output.fps)
  let contents = frameContents(scene)
  var runs: [(start: Int, end: Int, what: String)] = []
  for (i, c) in contents.enumerated() {
    if let last = runs.last, last.what == c { runs[runs.count - 1].end = i + 1 } else { runs.append((i, i + 1, c)) }
  }
  let base = Double(scene.introFrames)
  var out: [Flash] = []
  if runs.count >= 3 {
    for k in 1..<(runs.count - 1) where Double(runs[k].end - runs[k].start) < minSeconds * fps {
      out.append(
        Flash(
          startF: base + Double(runs[k].start), endF: base + Double(runs[k].end), what: runs[k].what,
          before: runs[k - 1].what, after: runs[k + 1].what))
    }
  }
  // A clip under half a second is a flicker even when what's on screen stays the same kind of thing.
  let mapped = scene.mapped
  for (k, m) in mapped.enumerated() where Double(m.frames) < 0.5 * fps && mapped.count > 1
    && !out.contains(where: { $0.startF < Double(m.outStart + m.frames) && $0.endF > Double(m.outStart) }) {
    out.append(
      Flash(
        startF: Double(m.outStart), endF: Double(m.outStart + m.frames), what: "clip src \(fmtTime(m.start))-\(fmtTime(m.end))",
        before: k > 0 ? "clip src \(fmtTime(mapped[k - 1].start))" : "the start",
        after: k + 1 < mapped.count ? "clip src \(fmtTime(mapped[k + 1].start))" : "the end"))
  }
  return out.sorted { $0.startF < $1.startF }
}

/// One line for a flash: output time, length, what, and the source time to fix it at.
public func describeFlash(_ f: Flash, _ plan: Plan) -> String {
  let fps = Double(plan.output.fps)
  let src = outToSrc(mapPlan(plan), f.startF, fps: plan.output.fps).map { " (src \(fmtTime($0)))" } ?? ""
  let frames = Int((f.endF - f.startF).rounded())
  let length = frames < Int(fps / 10) ? "\(frames) frame\(frames == 1 ? "" : "s")" : String(format: "%.1f s", (f.endF - f.startF) / fps)
  return "flash at out \(fmtTime(f.startF / fps))\(src): \(f.what) for \(length) between \(f.before) and \(f.after)"
}
