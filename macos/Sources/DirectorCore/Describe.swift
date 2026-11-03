import Foundation

/// The plan as a readable timeline. Claude reads this before editing plan.json.
public func describe(_ project: Project, _ plan: Plan) -> String {
  let fps = plan.output.fps
  let mapped = mapPlan(plan)
  let screen = ScreenText.load(project.dir)

  func said(_ a: Double, _ b: Double) -> String {
    let text = project.words.filter { $0.start < b && $0.end > a }.map(\.text).joined(separator: " ")
    return text.isEmpty ? "" : "\"\(text)\""
  }
  func activity(_ a: Double, _ b: Double) -> String {
    let ev = project.events.filter { $0.t >= a && $0.t < b }
    var parts: [String] = []
    let keys = ev.filter { $0.type == .key }.count
    if keys > 0 { parts.append("\(keys) keys") }
    parts += ev.filter { $0.type == .click }.map { c in
      String(format: "click@%@(%.2f,%.2f)", fmtTime(c.t), c.x, c.y) + (ScreenText.clicked(screen, at: c.t).map { " on \"\($0)\"" } ?? "")
    }
    let labels = ev.compactMap { $0.type == .key ? $0.label : nil }
    if !labels.isEmpty { parts.append(labels.joined(separator: " ")) }
    parts += ev.filter { $0.type == .retake }.map { "RETAKE@\(fmtTime($0.t))" }
    return parts.isEmpty ? "" : "[\(parts.joined(separator: ", "))]"
  }
  func line(_ parts: String...) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: " ")
  }

  var out: [String] = []
  out.append("# \(project.dir.path)")
  out.append("motion style: \(MotionStyle.named(plan.style.motion).name), moves \(plan.style.transition.formatted()) s")
  out.append(
    "source \(fmtTime(plan.source.duration)) -> output \(fmtTime(planSeconds(plan))) at \(plan.output.width)x\(plan.output.height)@\(fps)"
  )
  out.append("")
  out.append("## Timeline (source times; out = position in the final video)")
  let cards = cardFrames(plan)
  if cards.intro > 0 {
    out.append("  INTRO card out \(fmtTime(0)) for \(fmtTime(Double(cards.intro) / Double(fps))) \"\(plan.intro?.title ?? "")\"")
  }
  var cursor = 0.0
  for s in mapped {
    if s.start - cursor > 0.05 {
      out.append(line("  CUT  src \(fmtTime(cursor))-\(fmtTime(s.start))", said(cursor, s.start), activity(cursor, s.start)))
    }
    let speed = s.speed == 1 ? "1x " : "\(s.speed.formatted())x"
    if let t = s.transition, s.outStart > cards.intro { out.append("  ~\(t) cut~") }
    out.append(
      line(
        "  \(speed)  src \(fmtTime(s.start))-\(fmtTime(s.end))  out \(fmtTime(Double(s.outStart) / Double(fps)))  (\(s.note ?? ""))",
        said(s.start, s.end), activity(s.start, s.end)))
    cursor = s.end
  }
  if plan.source.duration - cursor > 0.05 { out.append("  CUT  src \(fmtTime(cursor))-\(fmtTime(plan.source.duration))") }
  if cards.outro > 0 {
    let at = Double(planFrames(plan) - cards.outro) / Double(fps)
    out.append("  OUTRO card out \(fmtTime(at)) for \(fmtTime(Double(cards.outro) / Double(fps))) \"\(plan.outro?.title ?? "")\"")
  }

  if !project.retakes.isEmpty {
    out.append("")
    out.append("## Retake marks (the phrase before each was a flub; the redo follows)")
    out.append("  " + project.retakes.map { fmtTime($0) }.joined(separator: ", "))
  }
  if !project.script.isEmpty {
    out.append("")
    out.append("## Script (script.md, \(project.script.count) lines). Keep the last good take of each line.")
    let missing = missingScriptLines(project.script, words: project.words, plan: plan)
    if !missing.isEmpty {
      out.append("  Not in the edit (never said, or every take is cut):")
      for l in missing.prefix(12) { out.append("  - \"\(l)\"") }
    }
  }
  if !project.editPlan.isEmpty {
    out.append("")
    out.append("## Edit plan (script.md header: the edit the user planned; each quote is spoken words to find in the transcript)")
    for l in project.editPlan { out.append("  " + l) }
  }

  out.append("")
  out.append("## Zooms")
  if plan.zooms.isEmpty { out.append("  (none)") }
  for (i, z) in plan.zooms.enumerated() {
    out.append(
      line(
        "  #\(i) src \(fmtTime(z.start))-\(fmtTime(z.end)) at (\(z.x.formatted()), \(z.y.formatted())) x\(z.scale.formatted())",
        ScreenText.near(screen, x: z.x, y: z.y, from: z.start, to: z.end).map { "aimed at \"\($0)\"" } ?? "",
        z.ease.map { "ease \($0)" } ?? "", z.seconds.map { "move \($0.formatted()) s" } ?? "", z.note ?? "", said(z.start, z.end)))
  }
  out.append("")
  out.append("## Layout: default \"\(plan.defaultLayout.rawValue)\"\(plan.camera == nil ? " (no camera recorded)" : "")")
  for l in plan.layouts { out.append(line("  src \(fmtTime(l.start))-\(fmtTime(l.end)) \(l.mode.rawValue)", l.note ?? "")) }
  for run in cameraHidesScreen(project, plan) {
    out.append("  WARNING: full camera hides screen activity at src \(fmtTime(run.start))-\(fmtTime(run.end)) (\(run.count) clicks/keys); use pip or side there")
  }
  if let lut = plan.camera?.grade?.lut {
    do {
      guard let url = Scene.fileURL(lut, dir: project.dir) else { throw DirectorError("no project folder") }
      _ = try CubeLUT.load(url)
    } catch {
      out.append("  WARNING: camera LUT \(lut) isn't applied: \(error.localizedDescription)")
    }
  }
  if let look = plan.look, case let problems = Fonts.problems(look), !problems.isEmpty {
    out.append("")
    out.append("## Fonts")
    for problem in problems { out.append("  WARNING: \(problem)") }
  }
  if let punches = plan.camera?.punchIns, !punches.isEmpty {
    out.append("")
    out.append("## Camera punch-ins")
    for p in punches { out.append(line("  src \(fmtTime(p.start))-\(fmtTime(p.end)) \(p.scale.formatted())x", p.note ?? "")) }
  }
  if !plan.callouts.isEmpty {
    out.append("")
    out.append("## Callouts")
    for c in plan.callouts {
      out.append(
        line(
          "  src \(fmtTime(c.start))-\(fmtTime(c.end)) \(c.style ?? "title") \"\(c.text)\"", c.subtitle.map { "/ \"\($0)\"" } ?? "",
          c.enter.map { "in:\($0.preset)" } ?? "", c.exit.map { "out:\($0.preset)" } ?? ""))
    }
  }
  if let marks = plan.annotations, !marks.isEmpty {
    out.append("")
    out.append("## Annotations (rect x,y,w,h in screen fractions)")
    for a in marks {
      out.append(
        line(
          "  src \(fmtTime(a.start))-\(fmtTime(a.end)) \(a.kind) (\(a.x.formatted()), \(a.y.formatted()), \(a.w.formatted()), \(a.h.formatted()))",
          a.text.map { "\"\($0)\"" } ?? "", a.note ?? ""))
    }
  }
  if let list = plan.inserts, !list.isEmpty {
    out.append("")
    out.append("## Inserts (B-roll)")
    for (i, a) in list.enumerated() {
      out.append(
        line(
          "  #\(i) src \(fmtTime(a.start))-\(fmtTime(a.end)) \(a.file) \(a.isFull ? "full frame" : "in the screen")",
          a.fit == "fit" ? "fit" : "", a.from.map { "from \($0.formatted()) s" } ?? "", a.note ?? ""))
    }
  }
  if !plan.animationList.isEmpty {
    out.append("")
    out.append("## Animations (template, cues in source time)")
    for (i, a) in plan.animationList.enumerated() {
      let cues = (a.cues ?? [:]).sorted { $0.value < $1.value }.map { "\($0.key) \(fmtTime($0.value))" }.joined(separator: ", ")
      out.append(line("  #\(i) src \(fmtTime(a.start))-\(fmtTime(a.end)) \(a.template)", cues.isEmpty ? "" : "cues: \(cues)", a.note ?? ""))
    }
  }
  if let marks = plan.markers, !marks.isEmpty {
    out.append("")
    out.append("## Markers (the user's named points)")
    for (i, m) in marks.enumerated() { out.append(line("  #\(i) src \(fmtTime(m.t))", m.label.map { "\"\($0)\"" } ?? "", said(m.t - 1, m.t + 1))) }
  }
  let library = AudioLibrary(.sounds)
  let musicLibrary = AudioLibrary(.music)
  func inProject(_ file: String) -> Bool {
    Scene.fileURL(file, dir: project.dir).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
  }
  let effects = plan.soundEffects
  if !effects.isEmpty {
    let free = plan.sfxList
    out.append("")
    out.append("## Sound effects (sfx #n, or attached to the item named)")
    for e in effects {
      let at = srcToOut(mapped, e.t, fps: fps).map { "out \(fmtTime($0 / Double(fps)))" } ?? "CUT (won't play)"
      let label = free.firstIndex(of: e).map { "sfx #\($0)" } ?? "on"
      let missing = inProject(e.file) || (try? library.entry(forPlanPath: e.file)) != nil ? "" : "MISSING FILE"
      out.append(line("  \(label) src \(fmtTime(e.t)) \(at) \(e.file)", e.gainDB.map { "\($0.formatted()) dB" } ?? "", e.note ?? "", missing))
    }
    for (i, e) in free.enumerated() where srcToOut(mapped, e.t, fps: fps) == nil {
      out.append("  WARNING: sfx #\(i) at src \(fmtTime(e.t)) is in a cut and won't play; move it, or attach it to the item it belongs to")
    }
  }
  if let music = plan.music {
    out.append("")
    let missing = inProject(music.file) || (try? musicLibrary.entry(forPlanPath: music.file)) != nil ? "" : " MISSING FILE"
    out.append("## Music: \(music.file)" + missing)
  }
  func listLibrary(_ lib: AudioLibrary, _ heading: String) {
    out.append("")
    do {
      let items = try lib.items()
      out.append("## \(heading) (use as \"\(lib.kind.planFolder)/<file>\"; it's copied into the project when the video builds)")
      var categories: [String] = []
      for e in items where !categories.contains(e.item.category) { categories.append(e.item.category) }
      for c in categories {
        let names = items.filter { $0.item.category == c }.map { e in e.item.file + (e.item.use.map { " (\($0))" } ?? "") }
        out.append("  \(c): " + names.joined(separator: ", "))
      }
    } catch {
      out.append("## \(heading): couldn't load (\(error.localizedDescription))")
    }
  }
  listLibrary(library, "Sound library, for sfx and attached sounds")
  listLibrary(musicLibrary, "Music library, for music.file")
  if plan.captions.enabled { out.append("\ncaptions: \(plan.captions.style ?? "pill"), up to \(plan.captions.maxWords) words") }
  return out.joined(separator: "\n")
}

/// Kept stretches where the layout is full camera but the screen has clicks or typing: the demo the
/// viewer should be watching is hidden behind the face. Events under a full-frame animation don't count.
public func cameraHidesScreen(_ project: Project, _ plan: Plan) -> [(start: Double, end: Double, count: Int)] {
  guard plan.camera != nil else { return [] }
  let kept = mapPlan(plan)
  let animations = plan.animationList
  let hidden = project.events.filter { e in
    // The last second and a half is the click that stops the recording.
    guard e.type == .click || e.type == .key, e.t < project.source.duration - 1.5, kept.contains(where: { e.t >= $0.start && e.t < $0.end }),
      !animations.contains(where: { e.t >= $0.start && e.t < $0.end })
    else { return false }
    return (plan.layouts.last { e.t >= $0.start && e.t < $0.end }?.mode ?? plan.defaultLayout) == .camera
  }.map(\.t).sorted()
  var runs: [(start: Double, end: Double, count: Int)] = []
  for t in hidden {
    if let last = runs.last, t - last.end < 10 { runs[runs.count - 1] = (last.start, t, last.count + 1) } else { runs.append((t, t, 1)) }
  }
  return runs
}
