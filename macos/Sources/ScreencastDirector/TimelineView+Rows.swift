import AppKit
import DirectorCore
import SwiftUI

// The timeline's fixed rows: sound effects, markers, the playhead, ruler, audio waveform, words and cuts.

extension TimelineView {
  /// Sound effects: a chip at each effect's start on its own row (click to jump and select, drag to move).
  /// Sounds attached to a title or annotation sit at its start; clicking one selects that item.
  func soundEffects(_ plan: Plan) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(attachedSounds(plan).enumerated()), id: \.offset) { _, a in
        let (t, _) = project.timeRange(a.owner).map { range(a.owner, $0.0, $0.1) } ?? (a.t, a.t)
        let name = ((a.file as NSString).lastPathComponent as NSString).deletingPathExtension
        HStack(spacing: 3) {
          Image(systemName: "link").font(.system(size: 8, weight: .semibold))
          if ui.pxPerSec > 8 { Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1).fixedSize() }
        }
        .foregroundStyle(Theme.sfx)
        .padding(.horizontal, 5)
        .frame(height: Track.sounds.height - 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.sfx.opacity(0.6), lineWidth: 1))
        .contentShape(Rectangle())
        .offset(x: x(t), y: rows.y(.sounds) + 2)
        .onTapGesture {
          project.select(a.owner, adding: adding)
          project.seek(src: a.t)
        }
        .help("\(name), attached to \(a.label). It moves with it; change it in the inspector.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound \(name) on \(a.label)")
        .accessibilityAddTraits(.isButton)
      }
      ForEach(Array(plan.sfxList.enumerated()), id: \.offset) { i, e in
        let sel = Selection.sfx(i)
        let (t, _) = range(sel, e.t, e.t)
        let selected = project.isSelected(sel)
        let name = ((e.file as NSString).lastPathComponent as NSString).deletingPathExtension
        HStack(spacing: 3) {
          Image(systemName: "speaker.wave.2.fill").font(.system(size: 9, weight: .semibold))
          if ui.pxPerSec > 8 { Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1).fixedSize() }
        }
        .foregroundStyle(selected ? Color.white : Theme.sfx)
        .padding(.horizontal, 5)
        .frame(height: Track.sounds.height - 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.sfx.opacity(selected ? 0.9 : 0.22)))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.sfx).frame(width: 2) }
        .contentShape(Rectangle())
        .offset(x: x(t), y: rows.y(.sounds) + 2)
        .onTapGesture {
          project.select(sel, adding: adding)
          project.seek(src: e.t)
        }
        .simultaneousGesture(
          DragGesture(minimumDistance: 2)
            .onChanged { v in
              var nt = time(atX: x(e.t) + v.translation.width)
              nt += snapShift([nt], start: e.t, end: e.t)
              ui.drag = (sel, nt, nt)
            }
            .onEnded { _ in
              ui.snap = nil
              guard let d = ui.drag, d.sel == sel else { return }
              ui.drag = nil
              project.select(sel, adding: false)
              project.moveSelected(by: d.start - e.t)
            }
        )
        .help("Sound effect \(name) at \(fmtTime(e.t))\(e.note.map { ": \($0)" } ?? ""). Click to jump, drag to move, ⌫ to remove.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound effect \(name) at \(fmtTime(e.t))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
          project.select(sel, adding: false)
          project.seek(src: e.t)
        }
      }
    }
  }

  /// Sounds attached to titles and annotations, with the item each belongs to.
  func attachedSounds(_ plan: Plan) -> [(t: Double, file: String, owner: Selection, label: String)] {
    var out: [(t: Double, file: String, owner: Selection, label: String)] = []
    for (i, c) in plan.callouts.enumerated() { if let s = c.sound { out.append((c.start, s.file, .callout(i), "the title \"\(c.text)\"")) } }
    for (i, m) in plan.annotationList.enumerated() { if let s = m.sound { out.append((m.start, s.file, .annotation(i), "an annotation")) } }
    for (i, an) in plan.animationList.enumerated() {
      for (cue, s) in an.sounds ?? [:] { out.append((cue == "start" ? an.start : an.cues?[cue] ?? an.start, s.file, .animation(i), "an animation")) }
    }
    return out
  }

  /// Marker flags in the ruler (click to jump and select, drag to move) and a faint line below each.
  func markers(_ plan: Plan) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(plan.markerList.enumerated()), id: \.offset) { i, m in
        let sel = Selection.marker(i)
        let (t, _) = range(sel, m.t, m.t)
        let selected = project.isSelected(sel)
        Rectangle().fill(Theme.accent.opacity(0.35))
          .frame(width: 1, height: rows.total - Track.ruler.height)
          .offset(x: x(t), y: Track.ruler.height)
          .allowsHitTesting(false)
        HStack(spacing: 3) {
          MarkerFlag().fill(selected ? Color.white : Theme.accent).frame(width: 9, height: 12)
          if let label = m.label, !label.isEmpty, ui.pxPerSec > 8 {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent).lineLimit(1).fixedSize()
          }
        }
        .contentShape(Rectangle())
        .offset(x: x(t), y: 0)
        .onTapGesture {
          project.select(sel, adding: adding)
          project.seek(src: m.t)
        }
        .simultaneousGesture(
          DragGesture(minimumDistance: 2)
            .onChanged { v in
              var nt = time(atX: x(m.t) + v.translation.width)
              nt += snapShift([nt], start: m.t, end: m.t)
              ui.drag = (sel, nt, nt)
            }
            .onEnded { _ in
              ui.snap = nil
              guard let d = ui.drag, d.sel == sel else { return }
              ui.drag = nil
              project.select(sel, adding: false)
              project.moveSelected(by: d.start - m.t)
            }
        )
        .help("Marker\(m.label.map { ": \($0)" } ?? "") at \(fmtTime(m.t)). Click to jump, drag to move, ⌫ to remove.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Marker \(m.label ?? "") at \(fmtTime(m.t))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
          project.select(sel, adding: false)
          project.seek(src: m.t)
        }
      }
    }
  }

  /// The playhead: a grip in the ruler and a line through the tracks. The ruler handles dragging it.
  var playhead: some View {
    ZStack(alignment: .top) {
      Rectangle().fill(Self.playheadColor)
        .frame(width: 1.5, height: rows.total - 4)
        .offset(y: 4)
      PlayheadCap().fill(Self.playheadColor)
        .frame(width: 11, height: 15)
        .offset(y: 2)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
    .frame(width: 12, height: rows.total, alignment: .top)
    .modifier(
      PlayheadOffset(project: project, playhead: project.playhead, ui: ui, pxPerSec: ui.pxPerSec, mapped: project.mapped, outputTime: ui.outputTime))
    .allowsHitTesting(false)
  }

  func ruler(_ plan: Plan) -> some View {
    let pps = ui.pxPerSec
    let step: Double = pps > 120 ? 1 : pps > 40 ? 5 : pps > 12 ? 10 : 30
    let minor = step / (step == 1 ? 4 : 5)
    let length = axisLength
    return Canvas { ctx, size in
      var i = 0
      while Double(i) * minor <= length {
        let t = Double(i) * minor
        let px = t * pps
        let major = i % Int((step / minor).rounded()) == 0
        ctx.fill(
          Path(CGRect(x: px, y: major ? 13 : 17, width: 1, height: major ? 9 : 5)),
          with: .color(.secondary.opacity(major ? 0.7 : 0.35)))
        if major {
          ctx.draw(
            Text(fmtTime(t).replacingOccurrences(of: ".0", with: "")).font(.system(size: 9, weight: .medium).monospacedDigit())
              .foregroundColor(.secondary),
            at: CGPoint(x: px + 3, y: 7), anchor: .leading)
        }
        i += 1
      }
    }
    .frame(height: Track.ruler.height)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0).onChanged { v in
        project.player.pause()
        project.seek(src: time(atX: v.location.x))
      }
    )
    .help("Click or drag to move the playhead")
  }

  /// The voice waveform from measured loudness; cut ranges are dimmed.
  func audio(_ plan: Plan) -> some View {
    let pps = ui.pxPerSec
    let levels = project.levels
    let mapped = project.mapped
    let fps = project.fps
    let h = Track.audio.height
    let output = ui.outputTime
    return Canvas { ctx, size in
      guard !levels.isEmpty else { return }
      // One bar per 2 px column, from the loudest 50 ms sample in it.
      let step = max(1, Int((2 / pps) / 0.05))
      var i = 0
      while i < levels.count {
        let chunk = levels[i..<min(i + step, levels.count)]
        let t = chunk.first!.0
        let db = chunk.map(\.1).max() ?? -90
        let v = max(0, min(1, (db + 55) / 50))
        let barH = max(1, v * (h - 6))
        let out = srcToOut(mapped, t, fps: fps)
        let kept = out != nil
        if output && !kept {
          i += step
          continue
        }
        // In output time a sped-up stretch is drawn narrower, at its real length.
        let speed = output ? (mapped.first { t >= $0.start && t < $0.end }?.speed ?? 1) : 1
        let w = max(1, Double(step) * 0.05 * pps / speed - 0.6)
        let px = output ? (out ?? 0) / Double(fps) * pps : t * pps
        let rect = CGRect(x: px, y: (h - barH) / 2, width: w, height: barH)
        ctx.fill(
          Path(roundedRect: rect, cornerRadius: min(w, barH) / 2),
          with: .color(kept ? Theme.audio.opacity(0.8) : Color.secondary.opacity(0.25)))
        i += step
      }
    }
    .frame(height: h)
    .offset(y: rows.y(.audio))
    .allowsHitTesting(false)
  }

  func words(_ plan: Plan) -> some View {
    let pps = ui.pxPerSec
    let ws = project.project?.words ?? []
    let mapped = project.mapped
    let fps = project.fps
    let output = ui.outputTime
    return Canvas { ctx, size in
      // Zoomed out too far for readable labels: mark where words are spoken instead.
      guard pps >= 10 else {
        let barH: CGFloat = 4
        for m in speechMarks(ws, mapped: mapped, fps: fps, pxPerSec: pps, outputTime: output) {
          let rect = CGRect(x: m.x, y: (size.height - barH) / 2, width: m.width, height: barH)
          ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(m.kept ? Color.primary.opacity(0.45) : Color.secondary.opacity(0.2)))
        }
        return
      }
      var lastEnd: CGFloat = -1000
      for w in ws {
        let out = srcToOut(mapped, w.start, fps: fps)
        if output && out == nil { continue }
        let px = output ? (out ?? 0) / Double(fps) * pps : w.start * pps
        guard px > lastEnd + 2 else { continue }
        let kept = out != nil
        let text = ctx.resolve(Text(w.text).font(.system(size: 9)).foregroundColor(kept ? .primary.opacity(0.85) : .secondary.opacity(0.5)))
        let sz = text.measure(in: CGSize(width: 400, height: 20))
        ctx.draw(text, at: CGPoint(x: px + 2, y: 9), anchor: .leading)
        lastEnd = px + sz.width
      }
    }
    .frame(height: Track.words.height)
    .offset(y: rows.y(.words))
    .allowsHitTesting(false)
  }

  /// A cut: hatched and dashed, selectable so it can be restored.
  func gap(_ g: Gap) -> some View {
    let sel = Selection.gap(g)
    let selected = project.isSelected(sel)
    let hovered = ui.hover == sel
    let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    return shape.fill(Color.primary.opacity(hovered ? 0.07 : 0.035))
      .overlay(Hatch().stroke(Color.primary.opacity(hovered ? 0.16 : 0.1), lineWidth: 1).clipShape(shape))
      .overlay(
        shape.strokeBorder(
          selected ? Color.accentColor : Color.primary.opacity(0.22),
          style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: selected ? [] : [4, 3])))
      .frame(width: max(2, x(g.end) - x(g.start)), height: Track.clips.height)
      .contentShape(Rectangle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Cut at \(fmtTime(g.start))")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { project.select(sel, adding: false) }
      .onTapGesture { project.select(sel, adding: adding) }
      .onHover { setHover(sel, $0) }
      .help("Cut: select it and press ⌫ to restore")
      .offset(x: x(g.start), y: rows.y(.clips))
  }
}
