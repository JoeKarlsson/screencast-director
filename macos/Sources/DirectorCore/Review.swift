import Foundation

/// One thing an AI edit changed, which the user can keep or undo on its own.
public struct PlanChange: Identifiable {
  public let id = UUID()
  /// clips, zoom, layout, title, annotation, insert, animation, sound or style.
  public let kind: String
  public let label: String
  /// Where it is, in source seconds (nil for style changes).
  public let range: (Double, Double)?
  /// Puts this one change back the way it was, leaving the rest of the edit.
  public let revert: (inout Plan) -> Void
}

/// The changes between two plans, item by item for zooms, layouts, titles, annotations, B-roll,
/// animations and sound effects, as one
/// change for the clips (cuts and speed), and one for everything about the look.
public func planChanges(from old: Plan, to new: Plan) -> [PlanChange] {
  var out: [PlanChange] = []
  if old.segments != new.segments {
    var onlyClips = old
    onlyClips.segments = new.segments
    let ranges = changedRanges(from: old, to: onlyClips)
    let before = planSeconds(old), after = planSeconds(new)
    let oldSegments = old.segments
    out.append(
      PlanChange(
        kind: "clips", label: "Cuts and speed (\(fmtTime(before)) → \(fmtTime(after)))",
        range: ranges.first.map { ($0.0, ranges.last!.1) }, revert: { $0.segments = oldSegments }))
  }
  func items<T: Equatable>(
    _ path: WritableKeyPath<Plan, [T]>, kind: String, _ describe: @escaping (T) -> String, _ range: @escaping (T) -> (Double, Double)
  ) {
    let a = old[keyPath: path], b = new[keyPath: path]
    var removed = a.filter { !b.contains($0) }
    for item in b where !a.contains(item) {
      // An added item over a removed one is the same item, changed.
      let r = range(item)
      if let i = removed.firstIndex(where: { let o = range($0); return o.0 < r.1 && r.0 < o.1 }) {
        let was = removed.remove(at: i)
        out.append(
          PlanChange(kind: kind, label: "Changed \(describe(item))", range: r) { p in
            if let j = p[keyPath: path].firstIndex(of: item) { p[keyPath: path][j] = was }
          })
      } else {
        out.append(
          PlanChange(kind: kind, label: "Added \(describe(item))", range: r) { p in
            if let j = p[keyPath: path].firstIndex(of: item) { p[keyPath: path].remove(at: j) }
          })
      }
    }
    for item in removed {
      out.append(PlanChange(kind: kind, label: "Removed \(describe(item))", range: range(item)) { $0[keyPath: path].append(item) })
    }
  }
  items(\.zooms, kind: "zoom", { "zoom \($0.scale.formatted())× at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.layouts, kind: "layout", { "\($0.mode.rawValue) layout at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.callouts, kind: "title", { "\($0.style ?? "title") “\($0.text)”" }, { ($0.start, $0.end) })
  items(\.insertList, kind: "insert", { "B-roll \(($0.file as NSString).lastPathComponent) at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.annotationList, kind: "annotation", { "\($0.kind)\($0.text.map { " “\($0)”" } ?? "") at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.animationList, kind: "animation", { "\($0.template) animation at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.punchInList, kind: "punch-in", { "\($0.scale.formatted())x punch-in at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.effectRangeList, kind: "effect", { "\($0.name) effect at \(fmtTime($0.start))" }, { ($0.start, $0.end) })
  items(\.sfxList, kind: "sound", { "sound \(($0.file as NSString).lastPathComponent) at \(fmtTime($0.t))" }, { ($0.t, $0.t) })
  if old.withTimedItems(from: new) != new {
    let was = old
    out.append(PlanChange(kind: "style", label: "Style, captions and settings", range: nil) { p in p = was.withTimedItems(from: p) })
  }
  return out.sorted { ($0.range?.0 ?? .infinity) < ($1.range?.0 ?? .infinity) }
}

extension Plan {
  /// This plan with `other`'s clips and timed items: everything planChanges reviews item by item,
  /// so what's left differing is the look and settings.
  func withTimedItems(from other: Plan) -> Plan {
    var p = self
    p.segments = other.segments
    p.zooms = other.zooms
    p.layouts = other.layouts
    p.callouts = other.callouts
    p.annotations = other.annotations
    p.inserts = other.inserts
    p.animations = other.animations
    p.sfx = other.sfx
    p.effectRanges = other.effectRanges
    p.punchInList = other.punchInList
    return p
  }
}

/// What an AI's second look at its own edit needs: for each zoom, what was said and clicked while
/// it's on screen, and every cut edge that lands inside a word.
public func editReview(_ project: Project, _ plan: Plan, cameraFPS: Double? = nil) -> String {
  var lines: [String] = []
  let fps = plan.output.fps
  let mapped = mapPlan(plan)
  for (i, z) in plan.zooms.enumerated() {
    let said = project.words.filter { $0.end > z.start && $0.start < z.end }.map(\.text).joined(separator: " ")
    let clicks = project.events.filter { $0.type == .click && $0.t >= z.start && $0.t < z.end }
      .map { String(format: "(%.2f, %.2f)", $0.x, $0.y) }
    let mid = Int(srcToOutClamped(mapped, (z.start + z.end) / 2, fps: fps))
    lines.append(
      "zoom #\(i) src \(fmtTime(z.start))-\(fmtTime(z.end)) at " + String(format: "(%.2f, %.2f) x%.1f", z.x, z.y, z.scale)
        + ": said \"\(said)\"" + (clicks.isEmpty ? ", no clicks" : ", clicks at " + clicks.joined(separator: " "))
        + "; middle is output frame \(mid)")
  }
  // Each place the video jumps over a cut, and the frame 0.5 s after it.
  for (i, m) in mapped.enumerated() where i > 0 ? abs(mapped[i - 1].end - m.start) > 0.001 : m.start > 0.001 {
    lines.append("cut before src \(fmtTime(m.start)): 0.5 s after it is output frame \(m.outStart + fps / 2)")
  }
  for (edge, w) in cutsInsideWords(plan, words: project.words) {
    lines.append("cut edge at src \(fmtTime(edge)) splits the word \"\(w.text)\" (\(fmtTime(w.start))-\(fmtTime(w.end)))")
  }
  for f in flashes(plan, dir: project.dir) { lines.append("WARNING: \(describeFlash(f, plan))") }
  let polish = Polish.notes(project, plan, cameraFPS: cameraFPS)
  if !polish.isEmpty {
    lines.append("")
    lines.append("## Polish (judgment calls that make an edit feel produced; fix each or say why it stays)")
    lines += polish.map { "POLISH \($0.kind): \($0.text)" }
  }
  lines += retentionReview(project, plan)
  return lines.isEmpty ? "No zooms, no cuts inside words and nothing to polish or flag for retention." : lines.joined(separator: "\n")
}

/// `review`'s retention section: structure against the video's length bucket (Retention.swift).
public func retentionReview(_ project: Project, _ plan: Plan) -> [String] {
  let notes = Retention.notes(project, plan)
  guard !notes.isEmpty else { return [] }
  return ["", "## Retention (\(EngagementTargets.of(plan).name) video: limits from measured hit videos; fix each or say why it stays)"]
    + notes.map { "RETENTION \($0.kind): \($0.text)" }
}

/// Source-time ranges an edit touched: clips and timed items (zooms, layouts, titles, annotations,
/// B-roll, animations, sound effects) that were added, removed or changed between two plans, merged
/// where they overlap. The timeline flashes these after an AI edit.
public func changedRanges(from old: Plan, to new: Plan) -> [(Double, Double)] {
  func diff<T: Equatable>(_ a: [T], _ b: [T], _ range: (T) -> (Double, Double)) -> [(Double, Double)] {
    a.filter { !b.contains($0) }.map(range) + b.filter { !a.contains($0) }.map(range)
  }
  let all =
    diff(old.segments, new.segments) { ($0.start, $0.end) } + diff(old.zooms, new.zooms) { ($0.start, $0.end) }
    + diff(old.layouts, new.layouts) { ($0.start, $0.end) } + diff(old.callouts, new.callouts) { ($0.start, $0.end) }
    + diff(old.annotations ?? [], new.annotations ?? []) { ($0.start, $0.end) }
    + diff(old.insertList, new.insertList) { ($0.start, $0.end) }
    + diff(old.animationList, new.animationList) { ($0.start, $0.end) } + diff(old.sfxList, new.sfxList) { ($0.t, $0.t) }
    + diff(old.effectRangeList, new.effectRangeList) { ($0.start, $0.end) }
    + diff(old.punchInList, new.punchInList) { ($0.start, $0.end) }
  var merged: [(Double, Double)] = []
  for r in all.sorted(by: { $0.0 < $1.0 }) {
    if let last = merged.last, r.0 <= last.1 {
      merged[merged.count - 1].1 = max(last.1, r.1)
    } else {
      merged.append(r)
    }
  }
  return merged
}

/// Clip edges that land inside a spoken word (more than 50 ms in from either end), which clips the
/// word: each edge in source seconds with the word it splits.
public func cutsInsideWords(_ plan: Plan, words: [Word]) -> [(edge: Double, word: Word)] {
  plan.segments.flatMap { s in [s.start, s.end] }.compactMap { edge in
    words.first { $0.start + 0.05 < edge && edge < $0.end - 0.05 }.map { (edge, $0) }
  }
}
