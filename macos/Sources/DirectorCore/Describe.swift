import Foundation

/// The plan as a readable timeline (port of scripts/describe.ts). Claude reads this before editing plan.json.
public func describe(_ project: Project, _ plan: Plan) -> String {
  let fps = plan.output.fps
  let mapped = mapPlan(plan)

  func said(_ a: Double, _ b: Double) -> String {
    let text = project.words.filter { $0.start < b && $0.end > a }.map(\.text).joined(separator: " ")
    return text.isEmpty ? "" : "\"\(text)\""
  }
  func activity(_ a: Double, _ b: Double) -> String {
    let ev = project.events.filter { $0.t >= a && $0.t < b }
    var parts: [String] = []
    let keys = ev.filter { $0.type == .key }.count
    if keys > 0 { parts.append("\(keys) keys") }
    parts += ev.filter { $0.type == .click }.map { String(format: "click@%@(%.2f,%.2f)", fmtTime($0.t), $0.x, $0.y) }
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
  out.append(
    "source \(fmtTime(plan.source.duration)) -> output \(fmtTime(Double(planFrames(plan)) / Double(fps))) at \(plan.output.width)x\(plan.output.height)@\(fps)"
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
  }

  out.append("")
  out.append("## Zooms")
  if plan.zooms.isEmpty { out.append("  (none)") }
  for (i, z) in plan.zooms.enumerated() {
    out.append(
      line(
        "  #\(i) src \(fmtTime(z.start))-\(fmtTime(z.end)) at (\(z.x.formatted()), \(z.y.formatted())) x\(z.scale.formatted())",
        z.note ?? "", said(z.start, z.end)))
  }
  out.append("")
  out.append("## Layout: default \"\(plan.defaultLayout.rawValue)\"\(plan.camera == nil ? " (no camera recorded)" : "")")
  for l in plan.layouts { out.append(line("  src \(fmtTime(l.start))-\(fmtTime(l.end)) \(l.mode.rawValue)", l.note ?? "")) }
  if !plan.callouts.isEmpty {
    out.append("")
    out.append("## Callouts")
    for c in plan.callouts { out.append("  src \(fmtTime(c.start))-\(fmtTime(c.end)) \"\(c.text)\"") }
  }
  return out.joined(separator: "\n")
}
