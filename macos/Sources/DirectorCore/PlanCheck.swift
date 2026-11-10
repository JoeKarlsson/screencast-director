import Foundation

/// `director validate`: whether plan.json loads and builds, as precise problems an agent can fix
/// ("zooms[3].x is 1.4; positions are 0 to 1"). Covers what decoding can't: ranges, values from a
/// fixed list, files that aren't there, templates and effects that don't exist.
public enum PlanCheck {
  /// A decoding error as the JSON path and what's wrong, e.g. `zooms[2].scale: expected a number`.
  public static func describe(_ error: Error) -> String {
    guard let e = error as? DecodingError else { return error.localizedDescription }
    func path(_ keys: [CodingKey]) -> String {
      keys.reduce("") { out, k in
        if let i = k.intValue { return out + "[\(i)]" }
        return out.isEmpty ? k.stringValue : out + "." + k.stringValue
      }
    }
    switch e {
    case .typeMismatch(let type, let c): return "\(path(c.codingPath)): expected \(typeName(type)) (\(c.debugDescription))"
    case .valueNotFound(let type, let c): return "\(path(c.codingPath)): missing \(typeName(type))"
    case .keyNotFound(let key, let c):
      let at = path(c.codingPath)
      return (at.isEmpty ? "" : at + ": ") + "missing \"\(key.stringValue)\""
    case .dataCorrupted(let c): return (c.codingPath.isEmpty ? "" : path(c.codingPath) + ": ") + c.debugDescription
    @unknown default: return "\(e)"
    }
  }

  private static func typeName(_ type: Any.Type) -> String {
    switch "\(type)" {
    case "Double", "Float", "Int": return "a number"
    case "String": return "text"
    case "Bool": return "true or false"
    case let t where t.hasPrefix("Array"): return "a list"
    case let t where t.hasPrefix("Dictionary"): return "an object"
    case let t: return t
    }
  }

  public struct Report {
    /// Wrong: the plan won't build, or won't do what it says.
    public var problems: [String] = []
    /// Off but harmless, like an item running past the recording's end (it stops there).
    public var warnings: [String] = []
  }

  /// Shorter than this on screen and a zoom, title, annotation, B-roll or animation reads as a glitch.
  public static let shortestItem = 1.0

  /// Everything wrong with a plan that loaded. `templates` names the animation templates this video
  /// can use (nil skips that check, for callers that can't find the built-in ones). `raw` is
  /// plan.json as written, for the keys decoding ignored; nil skips that check.
  public static func check(_ plan: Plan, project: Project, templates: Set<String>?, raw: Data? = nil) -> Report {
    var report = Report()
    var out: [String] = []
    let duration = plan.source.duration
    func span(_ what: String, _ start: Double, _ end: Double) {
      if !(start < end) { out.append("\(what): start \(fmt(start)) isn't before end \(fmt(end))") }
      if start < 0 || start >= duration {
        out.append("\(what): starts at \(fmt(start)), outside the recording (0-\(fmt(duration)) s, source seconds)")
      } else if end > duration + 0.05 {
        report.warnings.append("\(what): ends at \(fmt(end)), past the recording's end (\(fmt(duration)) s); it stops there")
      }
    }
    func unit(_ what: String, _ v: Double) {
      if !(0...1).contains(v) { out.append("\(what) is \(fmt(v)); positions are fractions from 0 to 1") }
    }
    func oneOf(_ what: String, _ v: String?, _ allowed: [String]) {
      if let v, !allowed.contains(v) { out.append("\(what) is \"\(v)\"; use one of \(allowed.joined(separator: ", "))") }
    }

    // Segments: in order of play, no overlaps except a repeat.
    if plan.segments.isEmpty { out.append("segments is empty, so the whole recording is cut") }
    for (i, s) in plan.segments.enumerated() {
      span("segments[\(i)]", s.start, s.end)
      if !(s.speed > 0) { out.append("segments[\(i)].speed is \(fmt(s.speed)); it must be above 0") }
      oneOf("segments[\(i)].transition", s.transition, Segment.transitions.map(\.name))
    }
    let kept = plan.segments.enumerated().filter { $0.element.repeats != true }.sorted { $0.element.start < $1.element.start }
    for (a, b) in zip(kept, kept.dropFirst()) where b.element.start < a.element.end - 0.001 {
      out.append("segments[\(a.offset)] and segments[\(b.offset)] overlap (\(fmt(b.element.start)) < \(fmt(a.element.end))); only a segment with repeats: true may")
    }

    for (i, z) in plan.zooms.enumerated() {
      span("zooms[\(i)]", z.start, z.end)
      unit("zooms[\(i)].x", z.x)
      unit("zooms[\(i)].y", z.y)
      if !(1...4).contains(z.scale) { out.append("zooms[\(i)].scale is \(fmt(z.scale)); use 1 to 4 (1.4 to 2.2 looks natural)") }
    }
    for (i, l) in plan.layouts.enumerated() { span("layouts[\(i)]", l.start, l.end) }
    for (i, c) in plan.callouts.enumerated() {
      span("callouts[\(i)]", c.start, c.end)
      oneOf("callouts[\(i)].style", c.style, ["title", "lower-third", "slate", "chapter"])
    }
    for (i, a) in plan.annotationList.enumerated() {
      span("annotations[\(i)]", a.start, a.end)
      oneOf("annotations[\(i)].kind", a.kind, Annotation.kinds.map(\.name))
      unit("annotations[\(i)].x", a.x)
      unit("annotations[\(i)].y", a.y)
      if !(a.w > 0 && a.h > 0) { out.append("annotations[\(i)] has no size (w \(fmt(a.w)), h \(fmt(a.h)))") }
      if a.x + a.w > 1.001 || a.y + a.h > 1.001 { out.append("annotations[\(i)] runs off the screen (x + w and y + h must be at most 1)") }
    }
    for (i, p) in plan.punchInList.enumerated() {
      span("camera.punchIns[\(i)]", p.start, p.end)
      if plan.camera == nil { out.append("camera.punchIns[\(i)]: this recording has no camera") }
    }
    for (i, r) in plan.effectRangeList.enumerated() { span("effectRanges[\(i)]", r.start, r.end) }
    for (i, a) in plan.animationList.enumerated() {
      span("animations[\(i)]", a.start, a.end)
      for (k, v) in a.versions.enumerated() {
        if let templates, !templates.contains(v.template) {
          let at = k == 0 ? "animations[\(i)]" : "animations[\(i)].alternates[\(k - 1)]"
          out.append("\(at).template \"\(v.template)\" doesn't exist (there are: \(templates.sorted().joined(separator: ", ")))")
        }
      }
      for (cue, t) in a.cues ?? [:] where t < a.start - 0.001 || t > a.end + 0.001 {
        out.append("animations[\(i)].cues.\(cue) at \(fmt(t)) is outside the animation (\(fmt(a.start))-\(fmt(a.end)))")
      }
    }
    let presets = ExportPreset.all.map(\.id)
    for (i, c) in plan.clipList.enumerated() {
      span("clips[\(i)] (\(c.name))", c.start, c.end)
      oneOf("clips[\(i)].format", c.format, presets)
    }

    for (i, ins) in plan.insertList.enumerated() { span("inserts[\(i)]", ins.start, ins.end) }
    report.problems = (raw.map { ignoredKeys(raw: $0, plan: plan) } ?? []) + out + assetProblems(plan, project: project)
      + presentationProblems(plan) + timelineWarnings(project, plan)
    return report
  }

  /// Files that aren't there, and effects that don't exist or don't take the params given.
  private static func assetProblems(_ plan: Plan, project: Project) -> [String] {
    var out: [String] = []
    // Files: in the project, absolute, or (sounds and music) in a library.
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: resolvePath(path, in: project.dir).path) }
    func file(_ what: String, _ path: String?) {
      if let path, !exists(path) { out.append("\(what): no file at \(path)") }
    }
    for (i, ins) in plan.insertList.enumerated() { file("inserts[\(i)].file", ins.file) }
    do {
      let sounds = try AudioLibrary(.sounds, for: plan), music = try AudioLibrary(.music, for: plan)
      let workOnly = sounds.workOnlyPaths(plan.soundEffects.map(\.file)) + music.workOnlyPaths(plan.music.map { [$0.file] } ?? [])
      for s in plan.soundEffects where !workOnly.contains(s.file) && !exists(s.file) && (try? sounds.entry(forPlanPath: s.file)) == nil {
        out.append("sound \(s.file) at \(fmt(s.t)): no such file in the project or the sound library")
      }
      if let m = plan.music, !workOnly.contains(m.file), !exists(m.file), (try? music.entry(forPlanPath: m.file)) == nil {
        out.append("music.file: no file at \(m.file) in the project or the music library")
      }
      for path in workOnly {
        out.append("\(path) is licensed for work videos only; profile \(plan.profile.map { "\"\($0)\"" } ?? "(none)") isn't a work profile")
      }
    } catch {
      out.append("profile: \(error.localizedDescription)")
    }
    file("camera.grade.lut", plan.camera?.grade?.lut)
    file("intro.logo", plan.intro?.logo)
    file("outro.logo", plan.outro?.logo)
    file("look.watermark.image", plan.look?.watermark?.image)
    for (i, f) in (plan.look?.fontFiles ?? []).enumerated() { file("look.fontFiles[\(i)]", f) }
    for (i, c) in plan.clipList.enumerated() { file("clips[\(i)].logo", c.logo) }

    // Effects: the shader exists and takes the params given (this compiles them, as a build would).
    let sources = EffectSources(project: project.dir)
    do { _ = try Effects.load(plan.effects ?? [], sources: sources) } catch { out.append("effects: \(error.localizedDescription)") }
    for (i, r) in plan.effectRangeList.enumerated() {
      do { _ = try Effects.load([r.use], sources: sources) } catch { out.append("effectRanges[\(i)]: \(error.localizedDescription)") }
    }
    return out
  }

  /// What the renderer reads as something else or the viewer can't take in: eases and presets it
  /// doesn't know, empty titles, items on screen under `shortestItem`, framing off the camera.
  private static func presentationProblems(_ plan: Plan) -> [String] {
    var out: [String] = []
    let duration = plan.source.duration
    func oneOf(_ what: String, _ v: String?, _ allowed: [String]) {
      if let v, !allowed.contains(v) { out.append("\(what) is \"\(v)\"; use one of \(allowed.joined(separator: ", "))") }
    }
    func ease(_ what: String, _ v: String?) {
      if let v, Ease.named(v) == nil { out.append("\(what) is \"\(v)\", which isn't an ease") }
    }
    func motion(_ what: String, _ m: Motion?) {
      guard let m else { return }
      oneOf("\(what).preset", m.preset, Motion.presets.map(\.name))
      ease("\(what).ease", m.ease)
    }
    func short(_ what: String, _ start: Double, _ end: Double) {
      if end > start, end - start < shortestItem {
        out.append("\(what) is on screen for only \(fmt(end - start)) s; make it \(fmt(shortestItem)) s or more, or remove it")
      }
    }
    func unit(_ what: String, _ v: Double?) {
      if let v, !(0...1).contains(v) { out.append("\(what) is \(fmt(v)); positions are fractions from 0 to 1") }
    }
    for (i, z) in plan.zooms.enumerated() {
      ease("zooms[\(i)].ease", z.ease)
      short("zooms[\(i)]", z.start, z.end)
    }
    for (i, c) in plan.callouts.enumerated() {
      if c.text.trimmingCharacters(in: .whitespaces).isEmpty { out.append("callouts[\(i)].text is empty") }
      motion("callouts[\(i)].enter", c.enter)
      motion("callouts[\(i)].exit", c.exit)
      short("callouts[\(i)]", c.start, c.end)
    }
    for (i, a) in plan.annotationList.enumerated() {
      motion("annotations[\(i)].enter", a.enter)
      motion("annotations[\(i)].exit", a.exit)
      short("annotations[\(i)]", a.start, a.end)
    }
    for (i, b) in plan.insertList.enumerated() {
      oneOf("inserts[\(i)].placement", b.placement, ["screen", "full", "overlay"])
      oneOf("inserts[\(i)].fit", b.fit, ["fill", "fit"])
      motion("inserts[\(i)].enter", b.enter)
      motion("inserts[\(i)].exit", b.exit)
      short("inserts[\(i)]", b.start, b.end)
    }
    for (i, a) in plan.animationList.enumerated() { short("animations[\(i)]", a.start, a.end) }
    for (i, p) in plan.punchInList.enumerated() {
      if !(p.scale > 0) { out.append("camera.punchIns[\(i)].scale is \(fmt(p.scale)); it must be above 0") }
      unit("camera.punchIns[\(i)].x", p.x)
      unit("camera.punchIns[\(i)].y", p.y)
    }
    for (i, m) in plan.markerList.enumerated() where m.t < 0 || m.t > duration + 0.05 {
      out.append("markers[\(i)].t is \(fmt(m.t)), outside the recording (0-\(fmt(duration)) s, source seconds)")
    }
    oneOf("captions.style", plan.captions.style, Plan.Captions.styles.map(\.name))
    oneOf("style.motion", plan.style.motion, MotionStyle.all.map(\.name))
    return out
  }

  /// What describe warns about (flashes, full camera over clicks, a sound in a cut, a LUT that won't
  /// load, bad colors) is fixable too, so one command reports everything.
  private static func timelineWarnings(_ project: Project, _ plan: Plan) -> [String] {
    timelineText(project, plan).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("WARNING: ") }.map { String($0.dropFirst(9)) }
  }

  /// Keys in the file that decoding dropped: a typo (`"styl"`) or a field that doesn't exist, so
  /// the edit silently does nothing. Found by comparing the file with the plan encoded again (nil
  /// values encode as nothing, so a null in the file isn't counted).
  public static func ignoredKeys(raw: Data, plan: Plan) -> [String] {
    guard let written = try? JSONSerialization.jsonObject(with: raw), let data = try? JSONEncoder().encode(plan),
      let kept = try? JSONSerialization.jsonObject(with: data)
    else { return [] }
    var out: [String] = []
    func walk(_ a: Any, _ b: Any, _ path: String) {
      if let a = a as? [String: Any], let b = b as? [String: Any] {
        for (key, value) in a.sorted(by: { $0.key < $1.key }) {
          let here = path.isEmpty ? key : "\(path).\(key)"
          if let other = b[key] {
            walk(value, other, here)
          } else if !(value is NSNull) {
            let near = b.keys.filter { editDistance($0, key) <= 2 }.sorted().first
            out.append("\(here) isn't a field here, so it's ignored" + (near.map { " (did you mean \"\($0)\"?)" } ?? ""))
          }
        }
      } else if let a = a as? [Any], let b = b as? [Any], a.count == b.count {
        for i in a.indices { walk(a[i], b[i], "\(path)[\(i)]") }
      }
    }
    walk(written, kept, "")
    return out
  }

  /// Levenshtein distance, for "did you mean" on a misspelled key.
  static func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    guard !a.isEmpty else { return b.count }
    var row = Array(0...b.count)
    for i in 1...a.count {
      var diagonal = row[0]
      row[0] = i
      for j in stride(from: 1, through: b.count, by: 1) {
        let above = row[j]
        row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
        diagonal = above
      }
    }
    return row[b.count]
  }

  private static func fmt(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...3))) }
}

/// `describe`'s text, from outside `PlanCheck`, whose own `describe(_:)` (for decoding errors) hides it.
private func timelineText(_ project: Project, _ plan: Plan) -> String { describe(project, plan) }
