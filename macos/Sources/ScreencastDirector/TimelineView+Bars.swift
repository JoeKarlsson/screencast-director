import AppKit
import DirectorCore
import SwiftUI

// Item bars: hover, drag, trim handles, filmstrips and snapping.

extension TimelineView {
  func setHover(_ sel: Selection, _ inside: Bool) {
    if inside { ui.hover = sel } else if ui.hover == sel { ui.hover = nil }
  }

  /// Where a dragged clip would drop: a line at the edge between the clips of `slot`.
  func clipDropMarker(slot: Int) -> some View {
    let mapped = project.mapped
    let frame = slot < mapped.count ? mapped[slot].outStart : mapped.last.map { $0.outStart + $0.frames } ?? 0
    let px = CGFloat(Double(frame) / Double(project.fps) * ui.pxPerSec)
    return Capsule().fill(Color.white)
      .frame(width: 3, height: Track.clips.height + 8)
      .shadow(color: .black.opacity(0.5), radius: 2)
      .allowsHitTesting(false)
      .offset(x: px - 1.5, y: rows.y(.clips) - 4)
  }

  /// A selectable bar with drag handles on both edges; `movable` bars can also be dragged whole.
  /// `badge` is a capsule before the label (a clip's speed); `striped` hatches it (sped-up clips).
  /// `reorder` is a clip's index: in output time, dragging its body moves it to play elsewhere.
  func bar(
    sel: Selection, start: Double, end: Double, track: Track, color: Color, label: String,
    badge: String? = nil, striped: Bool = false, movable: Bool, bounds: ClosedRange<Double>? = nil,
    reorder: Int? = nil, commit: @escaping (Double, Double) -> Void
  ) -> some View {
    let selected = project.isSelected(sel)
    // Trim handles only when this is the one selected item.
    let trimmable = project.selection == sel && project.multi.isEmpty
    let hovered = ui.hover == sel
    let w = max(3, xEnd(end) - x(start))
    let limits = bounds ?? 0...(project.plan?.source.duration ?? 0)
    let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    let base = selected ? 1 : hovered ? 0.85 : 0.7
    let film = track == .clips ? filmstrip(start: start, end: end, barX: x(start), barW: w) : nil
    return shape
      .fill(color.opacity(striped ? base * 0.6 : base))
      .overlay {
        // Frames under a tint of the track color, so the bar still reads as a clip.
        if let film {
          ZStack {
            film
            shape.fill(color.opacity(selected ? 0.3 : hovered ? 0.4 : 0.5))
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
          }
        }
      }
      .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)))
      .overlay {
        if striped { Hatch(spacing: 7).stroke(Color.white.opacity(0.22), lineWidth: 2).clipShape(shape) }
      }
      .overlay(
        shape.strokeBorder(
          selected ? Color.white : Color.white.opacity(hovered ? 0.35 : 0.12), lineWidth: selected ? 1.5 : 0.5)
      )
      .overlay(alignment: .leading) {
        HStack(spacing: 5) {
          if let badge, w > 30 {
            Text(badge).font(.system(size: 9, weight: .bold).monospacedDigit())
              .lineLimit(1).fixedSize()
              .padding(.horizontal, 4).padding(.vertical, 1)
              .background(Capsule().fill(Color.black.opacity(0.25)))
          }
          if w > 24 && !label.isEmpty {
            Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
          }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(film == nil ? 0 : 0.6), radius: 1.5)
        .padding(.horizontal, 7)
      }
      .clipShape(shape)
      .shadow(color: selected ? color.opacity(0.55) : .black.opacity(hovered ? 0.15 : 0), radius: selected ? 5 : 2, y: 1)
      .frame(width: w, height: track.height)
      .contentShape(Rectangle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(track.label) \([badge, label].compactMap { $0 }.joined(separator: " ")) at \(fmtTime(start))")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        project.select(sel, adding: false)
        project.seek(src: start)
      }
      .onTapGesture(coordinateSpace: .local) { loc in
        let add = adding
        project.select(sel, adding: add)
        if !add { project.seek(src: time(atX: x(start) + loc.x)) }
      }
      .onHover { setHover(sel, $0) }
      .simultaneousGesture(
        DragGesture(minimumDistance: 3)
          .onChanged { v in
            if let clip = reorder {
              // Recording order (source time) has no play order to drop into, so clips stay put there.
              guard ui.outputTime else { return }
              if project.selection != sel || !project.multi.isEmpty { project.select(sel, adding: false) }
              let frame = Double(x(start) + v.location.x) / ui.pxPerSec * Double(project.fps)
              ui.clipDrop = clipDrop(moving: clip, atFrame: frame, mapped: project.mapped).map { (clip, $0.slot, $0.target) }
              return
            }
            guard movable else { return }
            if project.isSelected(sel), !project.multi.isEmpty {
              // Several items selected: they all move together, snapping on this bar's edges.
              var shift = time(atX: x(start) + v.translation.width) - start
              shift += snapShift([start + shift, end + shift], start: start, end: end)
              ui.groupShift = shift
              return
            }
            if !project.isSelected(sel) { project.select(sel, adding: false) }
            let len = end - start
            let clamp = { (s: Double) in min(max(limits.lowerBound, s), limits.upperBound - len) }
            var s = clamp(time(atX: x(start) + v.translation.width))
            s = clamp(s + snapShift([s, s + len], start: start, end: end))
            ui.drag = (sel, s, s + len)
          }
          .onEnded { _ in
            if let clip = reorder {
              guard let d = ui.clipDrop, d.clip == clip else { return }
              ui.clipDrop = nil
              project.moveSelectedClip(to: d.target)
              return
            }
            ui.snap = nil
            if let shift = ui.groupShift {
              ui.groupShift = nil
              project.moveSelected(by: shift)
              return
            }
            guard movable, let d = ui.drag, d.sel == sel else { return }
            ui.drag = nil
            commit(d.start, d.end)
          }
      )
      .overlay(alignment: .leading) {
        if trimmable { handle(sel: sel, start: start, end: end, left: true, limits: limits, commit: commit) }
      }
      .overlay(alignment: .trailing) {
        if trimmable { handle(sel: sel, start: start, end: end, left: false, limits: limits, commit: commit) }
      }
      .offset(x: x(start), y: rows.y(track))
  }

  /// The source recording's frames for a clip bar, or nil without a plan.
  func filmstrip(start: Double, end: Double, barX: CGFloat, barW: CGFloat) -> EquatableView<Filmstrip>? {
    guard let src = project.plan?.source, src.height > 0 else { return nil }
    let cache = FilmstripCache.shared(dir: project.dir, video: src.video, duration: src.duration)
    return Filmstrip(
      cache: cache, viewport: ui.viewport, start: start, end: end, barX: barX, barW: barW, height: Track.clips.height,
      aspect: src.width / src.height
    ).equatable()
  }

  func handle(
    sel: Selection, start: Double, end: Double, left: Bool, limits: ClosedRange<Double>,
    commit: @escaping (Double, Double) -> Void
  ) -> some View {
    return Capsule().fill(Color.white)
      .frame(width: 4)
      .padding(.vertical, 6)
      .padding(.horizontal, 2)
      .shadow(color: .black.opacity(0.3), radius: 1)
      .contentShape(Rectangle().inset(by: -3))
      // A pointer style, not push/pop: a handle that vanishes under the pointer can't leave it stuck.
      .pointerStyle(.columnResize)
      .highPriorityGesture(
        DragGesture(minimumDistance: 1)
          .onChanged { v in
            var t = time(atX: x(left ? start : end) + v.translation.width)
            t += snapShift([t], start: start, end: end)
            ui.drag =
              left
              ? (sel, min(max(limits.lowerBound, t), end - 0.1), end)
              : (sel, start, max(min(limits.upperBound, t), start + 0.1))
          }
          .onEnded { _ in
            ui.snap = nil
            guard let d = ui.drag, d.sel == sel else { return }
            ui.drag = nil
            commit(d.start, d.end)
          }
      )
  }

  // MARK: Snapping

  /// Edges a dragged item can snap to: the playhead, the ends of the recording, the in/out points,
  /// and every item's start and end (the dragged item's saved edges excluded).
  func snapTargets(start: Double, end: Double) -> [Double] {
    guard let p = project.plan else { return [] }
    var ts = [project.playheadSrc, 0, p.source.duration] + [project.inPoint, project.outPoint].compactMap { $0 }
    for s in p.allItems { if let (a, b) = p.timeRange(of: s) { ts += [a, b] } }
    return ts.filter { abs($0 - start) > 1e-9 && abs($0 - end) > 1e-9 || $0 == project.playheadSrc }
  }

  /// The shift that lands the nearest of `edges` on a target within `snapDistance` points (0 when
  /// none is close, or while ⌘ is held). Sets or clears the guide line.
  func snapShift(_ edges: [Double], start: Double, end: Double) -> Double {
    guard !NSEvent.modifierFlags.contains(.command) else {
      ui.snap = nil
      return 0
    }
    let tolerance = Double(Self.snapDistance) / ui.pxPerSec
    var best: (shift: Double, at: Double)?
    for t in snapTargets(start: start, end: end) {
      for e in edges where abs(t - e) <= tolerance && abs(t - e) < abs(best?.shift ?? .infinity) {
        best = (t - e, t)
      }
    }
    if ui.snap != best?.at { ui.snap = best?.at }
    return best?.shift ?? 0
  }
}
