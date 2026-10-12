import AppKit
import DirectorCore
import SwiftUI

/// Timeline view state (no @State without macro plugins, so it lives here).
final class TimelineUI: ObservableObject {
  @Published var pxPerSec: Double = 60
  @Published var fitted = false
  /// Visible width of the track area, for Fit.
  var width: CGFloat = 800

  func fit(_ duration: Double) {
    pxPerSec = min(400, max(4, (width - 20) / max(duration, 1)))
  }
  /// A drag in progress: which item and its live range, drawn instead of the saved one.
  @Published var drag: (sel: Selection, start: Double, end: Double)?
  /// The bar under the pointer.
  @Published var hover: Selection?
  /// The source time a dragged edge is snapped to, drawn as a guide line.
  @Published var snap: Double?
}

private enum Track: CaseIterable {
  case ruler, clips, audio, words, zooms, layouts, titles

  var height: CGFloat {
    switch self {
    case .ruler: return 22
    case .clips: return 34
    case .audio: return 30
    case .words: return 18
    default: return 24
    }
  }
  var label: String {
    switch self {
    case .ruler: return ""
    case .clips: return "Clips"
    case .audio: return "Audio"
    case .words: return "Words"
    case .zooms: return "Zoom"
    case .layouts: return "Layout"
    case .titles: return "Titles"
    }
  }
  var icon: String {
    switch self {
    case .ruler: return ""
    case .clips: return "film"
    case .audio: return "waveform"
    case .words: return "text.quote"
    case .zooms: return "plus.magnifyingglass"
    case .layouts: return "rectangle.split.2x1"
    case .titles: return "textformat"
    }
  }
  var color: Color {
    switch self {
    case .ruler: return .secondary
    case .clips: return Theme.clip
    case .audio: return Theme.audio
    case .words: return Theme.words
    case .zooms: return Theme.zoom
    case .layouts: return Theme.layout
    case .titles: return Theme.title
    }
  }
  var y: CGFloat {
    var y: CGFloat = 0
    for t in Track.allCases {
      if t == self { return y }
      y += t.height + 4
    }
    return y
  }
  static var total: CGFloat { allCases.reduce(0) { $0 + $1.height + 4 } }
}

/// Diagonal hatching, for cuts and sped-up clips.
private struct Hatch: Shape {
  var spacing: CGFloat = 6

  func path(in r: CGRect) -> Path {
    var p = Path()
    var x = r.minX - r.height
    while x < r.maxX {
      p.move(to: CGPoint(x: x, y: r.maxY))
      p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
      x += spacing
    }
    return p
  }
}

/// The playhead's grip in the ruler: a rounded tab that tapers to a point.
private struct PlayheadCap: Shape {
  func path(in r: CGRect) -> Path {
    let c: CGFloat = 2.5
    let shoulder = r.maxY - r.width * 0.55
    var p = Path()
    p.move(to: CGPoint(x: r.midX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: shoulder))
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
    p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c), control: CGPoint(x: r.maxX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: shoulder))
    p.closeSubpath()
    return p
  }
}

struct TimelineView: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: TimelineUI

  /// Width of the track header column.
  private static let headerWidth: CGFloat = 76
  /// How close (in points) a dragged edge must come to another edge to snap to it.
  private static let snapDistance: CGFloat = 6
  private static let playheadColor = Color.red

  var body: some View {
    VStack(spacing: 8) {
      toolbar
      if let plan = project.plan {
        GeometryReader { geo in
          HStack(spacing: 0) {
            labels
            ScrollView(.horizontal) {
              tracks(plan).frame(width: max(geo.size.width - Self.headerWidth, plan.source.duration * ui.pxPerSec), height: Track.total)
            }
          }
          .onAppear {
            ui.width = geo.size.width - Self.headerWidth
            if !ui.fitted {
              ui.fit(plan.source.duration)
              ui.fitted = true
            }
          }
          .onChange(of: geo.size.width) { _, w in ui.width = w - Self.headerWidth }
        }
        .frame(height: Track.total + 14)
      }
    }
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 10) {
      toolGroup {
        iconButton("Split", "scissors", help: "Split the clip at the playhead (C)", action: project.splitAtPlayhead)
        iconButton("Delete", "trash", help: "Cut the selected clip, or remove the selected zoom, layout or title (⌫)", action: project.deleteSelection)
          .disabled(project.selection == nil || isGap)
      }
      toolGroup {
        iconButton("Zoom", "plus.magnifyingglass", help: "Add a zoom at the playhead, aimed at the last click (Z)", action: project.addZoom)
        Menu {
          ForEach(LayoutMode.allCases, id: \.self) { m in Button(modeName(m)) { project.addLayout(m) } }
        } label: {
          Image(systemName: "rectangle.split.2x1")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 22)
        .accessibilityLabel("Layout")
        .help("Change the camera layout from the playhead (⌃L, or 1-4)")
        iconButton("Title", "textformat", help: "Add a title at the playhead (T)", action: project.addCallout)
      }
      Spacer(minLength: 4)
      HStack(spacing: 6) {
        Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
        Slider(value: $ui.pxPerSec, in: 4...400)
          .controlSize(.small)
          .frame(minWidth: 60, maxWidth: 120)
          .help("Timeline zoom")
        Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      toolGroup {
        iconButton("Fit", "arrow.left.and.right", help: "Fit the whole recording") {
          ui.fit(project.plan?.source.duration ?? 1)
        }
      }
    }
    .font(.system(size: 13))
    .disabled(!project.hasPlan)
  }

  /// A borderless icon button of the toolbar's standard size.
  private func iconButton(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: 28, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(title)
    .help(help)
  }

  /// Related toolbar buttons on one shared rounded backing.
  private func toolGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 0) { content() }
      .padding(2)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.055)))
      .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
  }

  private var isGap: Bool {
    if case .gap = project.selection { return true }
    return false
  }

  /// Track headers: the track's icon in its color, and its name.
  private var labels: some View {
    ZStack(alignment: .topLeading) {
      ForEach(Track.allCases.filter { $0 != .ruler }, id: \.self) { t in
        HStack(spacing: 5) {
          Image(systemName: t.icon)
            .font(.system(size: t == .words ? 9 : 10, weight: .semibold))
            .foregroundStyle(t.color)
            .frame(width: 14)
          Text(t.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.leading, 6)
        .frame(width: Self.headerWidth - 6, height: t.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.04)))
        .offset(y: t.y)
      }
    }
    .frame(width: Self.headerWidth, height: Track.total, alignment: .topLeading)
  }

  // MARK: Tracks

  private func x(_ t: Double) -> CGFloat { CGFloat(t * ui.pxPerSec) }

  private func range(_ sel: Selection, _ start: Double, _ end: Double) -> (Double, Double) {
    if let d = ui.drag, d.sel == sel { return (d.start, d.end) }
    return (start, end)
  }

  @ViewBuilder
  private func tracks(_ plan: Plan) -> some View {
    ZStack(alignment: .topLeading) {
      lanes
      ruler(plan)
      // Clips: kept segments, and cuts you can restore.
      ForEach(Array(plan.gaps.enumerated()), id: \.offset) { _, g in
        gap(g)
      }
      ForEach(Array(plan.segments.enumerated()), id: \.offset) { i, s in
        let sel = Selection.segment(i)
        let (a, b) = range(sel, s.start, s.end)
        let fast = s.speed > 1.01
        let lo = i > 0 ? plan.segments[i - 1].end : 0
        let hi = i + 1 < plan.segments.count ? plan.segments[i + 1].start : plan.source.duration
        bar(
          sel: sel, start: a, end: b, track: .clips, color: Theme.clip, label: s.note ?? "",
          badge: s.speed == 1 ? nil : "\(s.speed.formatted())×", striped: fast, movable: false, bounds: lo...max(lo, hi)
        ) { newStart, newEnd in
          project.apply { $0.trimSegment(i, start: newStart, end: newEnd) }
        }
      }
      audio(plan)
      words(plan)
      ForEach(Array(plan.zooms.enumerated()), id: \.offset) { i, z in
        let sel = Selection.zoom(i)
        let (a, b) = range(sel, z.start, z.end)
        bar(sel: sel, start: a, end: b, track: .zooms, color: Theme.zoom, label: "\(z.scale.formatted())×", movable: true) { s, e in
          project.apply {
            guard $0.zooms.indices.contains(i) else { return }
            $0.zooms[i].start = s
            $0.zooms[i].end = e
          }
          // normalize() re-sorts, so find the moved item again.
          if let j = project.plan?.zooms.firstIndex(where: { abs($0.start - s) < 1e-9 && abs($0.end - e) < 1e-9 }) {
            project.selection = .zoom(j)
          }
        }
      }
      ForEach(Array(plan.layouts.enumerated()), id: \.offset) { i, l in
        let sel = Selection.layout(i)
        let (a, b) = range(sel, l.start, l.end)
        bar(sel: sel, start: a, end: b, track: .layouts, color: Theme.layout, label: modeName(l.mode), movable: true) { s, e in
          project.apply {
            guard $0.layouts.indices.contains(i) else { return }
            $0.layouts[i].start = s
            $0.layouts[i].end = e
          }
          // normalize() re-sorts, so find the moved item again.
          if let j = project.plan?.layouts.firstIndex(where: { abs($0.start - s) < 1e-9 && abs($0.end - e) < 1e-9 }) {
            project.selection = .layout(j)
          }
        }
      }
      ForEach(Array(plan.callouts.enumerated()), id: \.offset) { i, c in
        let sel = Selection.callout(i)
        let (a, b) = range(sel, c.start, c.end)
        bar(sel: sel, start: a, end: b, track: .titles, color: Theme.title, label: c.text, movable: true) { s, e in
          project.apply {
            guard $0.callouts.indices.contains(i) else { return }
            $0.callouts[i].start = s
            $0.callouts[i].end = e
          }
          // normalize() re-sorts, so find the moved item again.
          if let j = project.plan?.callouts.firstIndex(where: { abs($0.start - s) < 1e-9 && abs($0.end - e) < 1e-9 }) {
            project.selection = .callout(j)
          }
        }
      }
      if let s = ui.snap {
        Rectangle().fill(Color.primary.opacity(0.8))
          .frame(width: 1, height: Track.total - Track.ruler.height)
          .offset(x: x(s) - 0.5, y: Track.ruler.height)
          .allowsHitTesting(false)
      }
      playhead
    }
  }

  /// A faint band behind each track.
  private var lanes: some View {
    ZStack(alignment: .topLeading) {
      ForEach(Track.allCases.filter { $0 != .ruler }, id: \.self) { t in
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.primary.opacity(0.03))
          .frame(height: t.height)
          .offset(y: t.y)
      }
    }
    .allowsHitTesting(false)
  }

  /// The playhead: a grip in the ruler and a line through the tracks. The ruler handles dragging it.
  private var playhead: some View {
    ZStack(alignment: .top) {
      Rectangle().fill(Self.playheadColor)
        .frame(width: 1.5, height: Track.total - 4)
        .offset(y: 4)
      PlayheadCap().fill(Self.playheadColor)
        .frame(width: 11, height: 15)
        .offset(y: 2)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
    .frame(width: 12, height: Track.total, alignment: .top)
    .offset(x: x(project.playheadSrc) - 6)
    .allowsHitTesting(false)
  }

  private func ruler(_ plan: Plan) -> some View {
    let pps = ui.pxPerSec
    let step: Double = pps > 120 ? 1 : pps > 40 ? 5 : pps > 12 ? 10 : 30
    let minor = step / (step == 1 ? 4 : 5)
    return Canvas { ctx, size in
      var i = 0
      while Double(i) * minor <= plan.source.duration {
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
        project.seek(src: min(max(0, v.location.x / pps), plan.source.duration))
      }
    )
    .help("Click or drag to move the playhead")
  }

  /// The voice waveform from measured loudness; cut ranges are dimmed.
  private func audio(_ plan: Plan) -> some View {
    let pps = ui.pxPerSec
    let levels = project.levels
    let mapped = project.mapped
    let fps = project.fps
    let h = Track.audio.height
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
        let kept = srcToOut(mapped, t, fps: fps) != nil
        let w = max(1, Double(step) * 0.05 * pps - 0.6)
        let rect = CGRect(x: t * pps, y: (h - barH) / 2, width: w, height: barH)
        ctx.fill(
          Path(roundedRect: rect, cornerRadius: min(w, barH) / 2),
          with: .color(kept ? Theme.audio.opacity(0.8) : Color.secondary.opacity(0.25)))
        i += step
      }
    }
    .frame(height: h)
    .offset(y: Track.audio.y)
    .allowsHitTesting(false)
  }

  private func words(_ plan: Plan) -> some View {
    let pps = ui.pxPerSec
    let ws = project.project?.words ?? []
    let mapped = project.mapped
    let fps = project.fps
    return Canvas { ctx, size in
      guard pps >= 10 else { return }
      var lastEnd: CGFloat = -1000
      for w in ws {
        let px = w.start * pps
        guard px > lastEnd + 2 else { continue }
        let kept = srcToOut(mapped, w.start, fps: fps) != nil
        let text = ctx.resolve(Text(w.text).font(.system(size: 9)).foregroundColor(kept ? .primary.opacity(0.85) : .secondary.opacity(0.5)))
        let sz = text.measure(in: CGSize(width: 400, height: 20))
        ctx.draw(text, at: CGPoint(x: px + 2, y: 9), anchor: .leading)
        lastEnd = px + sz.width
      }
    }
    .frame(height: Track.words.height)
    .offset(y: Track.words.y)
    .allowsHitTesting(false)
  }

  /// A cut: hatched and dashed, selectable so it can be restored.
  private func gap(_ g: Gap) -> some View {
    let sel = Selection.gap(g)
    let selected = project.selection == sel
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
      .accessibilityAction { project.selection = sel }
      .onTapGesture { project.selection = sel }
      .onHover { setHover(sel, $0) }
      .help("Cut: select it and press ⌫ to restore")
      .offset(x: x(g.start), y: Track.clips.y)
  }

  private func setHover(_ sel: Selection, _ inside: Bool) {
    if inside { ui.hover = sel } else if ui.hover == sel { ui.hover = nil }
  }

  /// A selectable bar with drag handles on both edges; `movable` bars can also be dragged whole.
  /// `badge` is a capsule before the label (a clip's speed); `striped` hatches it (sped-up clips).
  private func bar(
    sel: Selection, start: Double, end: Double, track: Track, color: Color, label: String,
    badge: String? = nil, striped: Bool = false, movable: Bool, bounds: ClosedRange<Double>? = nil,
    commit: @escaping (Double, Double) -> Void
  ) -> some View {
    let selected = project.selection == sel
    let hovered = ui.hover == sel
    let w = max(3, x(end) - x(start))
    let pps = ui.pxPerSec
    let limits = bounds ?? 0...(project.plan?.source.duration ?? 0)
    let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
    let base = selected ? 1 : hovered ? 0.85 : 0.7
    return shape
      .fill(color.opacity(striped ? base * 0.6 : base))
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
        project.selection = sel
        project.seek(src: start)
      }
      .onTapGesture(coordinateSpace: .local) { loc in
        project.selection = sel
        project.seek(src: start + loc.x / pps)
      }
      .onHover { setHover(sel, $0) }
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { v in
            guard movable else { return }
            project.selection = sel
            let len = end - start
            let clamp = { (s: Double) in min(max(limits.lowerBound, s), limits.upperBound - len) }
            var s = clamp(start + v.translation.width / pps)
            s = clamp(s + snapShift([s, s + len], excluding: sel, start: start, end: end))
            ui.drag = (sel, s, s + len)
          }
          .onEnded { _ in
            ui.snap = nil
            guard movable, let d = ui.drag, d.sel == sel else { return }
            ui.drag = nil
            commit(d.start, d.end)
          }
      )
      .overlay(alignment: .leading) {
        if selected { handle(sel: sel, start: start, end: end, left: true, limits: limits, commit: commit) }
      }
      .overlay(alignment: .trailing) {
        if selected { handle(sel: sel, start: start, end: end, left: false, limits: limits, commit: commit) }
      }
      .offset(x: x(start), y: track.y)
  }

  private func handle(
    sel: Selection, start: Double, end: Double, left: Bool, limits: ClosedRange<Double>,
    commit: @escaping (Double, Double) -> Void
  ) -> some View {
    let pps = ui.pxPerSec
    return Capsule().fill(Color.white)
      .frame(width: 4)
      .padding(.vertical, 6)
      .padding(.horizontal, 2)
      .shadow(color: .black.opacity(0.3), radius: 1)
      .contentShape(Rectangle().inset(by: -3))
      .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { v in
            var t = (left ? start : end) + v.translation.width / pps
            t += snapShift([t], excluding: sel, start: start, end: end)
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

  /// Edges a dragged item can snap to: the playhead, the ends of the recording, and every other
  /// item's start and end (its own saved edges excluded).
  private func snapTargets(excluding sel: Selection, start: Double, end: Double) -> [Double] {
    guard let p = project.plan else { return [] }
    var ts = [project.playheadSrc, 0, p.source.duration]
    for s in p.segments { ts += [s.start, s.end] }
    for z in p.zooms { ts += [z.start, z.end] }
    for l in p.layouts { ts += [l.start, l.end] }
    for c in p.callouts { ts += [c.start, c.end] }
    return ts.filter { abs($0 - start) > 1e-9 && abs($0 - end) > 1e-9 || $0 == project.playheadSrc }
  }

  /// The shift that lands the nearest of `edges` on a target within `snapDistance` points (0 when
  /// none is close, or while ⌘ is held). Sets or clears the guide line.
  private func snapShift(_ edges: [Double], excluding sel: Selection, start: Double, end: Double) -> Double {
    guard !NSEvent.modifierFlags.contains(.command) else {
      ui.snap = nil
      return 0
    }
    let tolerance = Double(Self.snapDistance) / ui.pxPerSec
    var best: (shift: Double, at: Double)?
    for t in snapTargets(excluding: sel, start: start, end: end) {
      for e in edges where abs(t - e) <= tolerance && abs(t - e) < abs(best?.shift ?? .infinity) {
        best = (t - e, t)
      }
    }
    if ui.snap != best?.at { ui.snap = best?.at }
    return best?.shift ?? 0
  }
}

func modeName(_ m: LayoutMode) -> String {
  switch m {
  case .screen: return "Screen only"
  case .pip: return "Camera bubble"
  case .side: return "Side by side"
  case .camera: return "Camera only"
  }
}
