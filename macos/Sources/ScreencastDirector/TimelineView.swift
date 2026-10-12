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
}

private enum Track: CaseIterable {
  case ruler, clips, words, zooms, layouts, titles

  var height: CGFloat {
    switch self {
    case .ruler: return 22
    case .clips: return 34
    case .words: return 18
    default: return 24
    }
  }
  var label: String {
    switch self {
    case .ruler: return ""
    case .clips: return "Clips"
    case .words: return "Words"
    case .zooms: return "Zoom"
    case .layouts: return "Layout"
    case .titles: return "Titles"
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

struct TimelineView: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: TimelineUI

  var body: some View {
    VStack(spacing: 6) {
      toolbar
      if let plan = project.plan {
        GeometryReader { geo in
          HStack(spacing: 0) {
            labels
            ScrollView(.horizontal) {
              tracks(plan).frame(width: max(geo.size.width - 60, plan.source.duration * ui.pxPerSec), height: Track.total)
            }
          }
          .onAppear {
            ui.width = geo.size.width - 60
            if !ui.fitted {
              ui.fit(plan.source.duration)
              ui.fitted = true
            }
          }
          .onChange(of: geo.size.width) { _, w in ui.width = w - 60 }
        }
        .frame(height: Track.total + 14)
      }
    }
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 8) {
      Button(action: project.togglePlay) { Image(systemName: project.isPlaying ? "pause.fill" : "play.fill").frame(width: 16) }
        .help("Play/Pause (Space; J/K/L to shuttle)")
      Text("\(fmtTime(project.outFrame / Double(project.fps))) / \(fmtTime(Double(project.totalOutFrames) / Double(project.fps)))")
        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        .fixedSize()
      Divider().frame(height: 16)
      Button(action: project.splitAtPlayhead) { Label("Split", systemImage: "scissors") }
        .help("Split the clip at the playhead (C)")
      Button(action: project.deleteSelection) { Label("Delete", systemImage: "trash") }
        .disabled(project.selection == nil || isGap)
        .help("Cut the selected clip, or remove the selected zoom, layout or title (⌫)")
      Divider().frame(height: 16)
      Button(action: project.addZoom) { Label("Zoom", systemImage: "plus.magnifyingglass") }
        .help("Add a zoom at the playhead, aimed at the last click (Z)")
      Menu {
        ForEach(LayoutMode.allCases, id: \.self) { m in Button(modeName(m)) { project.addLayout(m) } }
      } label: { Label("Layout", systemImage: "rectangle.split.2x1").labelStyle(.titleAndIcon) }
        .fixedSize()
        .help("Change the camera layout from the playhead (⌃L, or 1-4)")
      Button(action: project.addCallout) { Label("Title", systemImage: "textformat") }.help("Add a title at the playhead (T)")
      Spacer(minLength: 4)
      Slider(value: $ui.pxPerSec, in: 4...400).frame(minWidth: 60, maxWidth: 110)
        .help("Timeline zoom")
      Button { ui.fit(project.plan?.source.duration ?? 1) } label: { Label("Fit", systemImage: "arrow.left.and.right") }
        .help("Fit the whole recording")
    }
    .labelStyle(.iconOnly)
    .controlSize(.regular)
    .disabled(!project.hasPlan)
  }

  private var isGap: Bool {
    if case .gap = project.selection { return true }
    return false
  }

  private var labels: some View {
    ZStack(alignment: .topLeading) {
      ForEach(Track.allCases, id: \.self) { t in
        Text(t.label).font(.caption2).foregroundStyle(.secondary)
          .frame(width: 56, height: t.height, alignment: .leading)
          .offset(y: t.y)
      }
    }
    .frame(width: 60, height: Track.total, alignment: .topLeading)
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
      ruler(plan)
      // Clips: kept segments, and cuts you can restore.
      ForEach(Array(plan.gaps.enumerated()), id: \.offset) { _, g in
        let sel = Selection.gap(g)
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .foregroundStyle(project.selection == sel ? Color.white : Color.gray.opacity(0.6))
          .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.12)))
          .overlay(Text(x(g.end) - x(g.start) > 30 ? "cut" : "").font(.caption2).foregroundStyle(.secondary))
          .frame(width: max(2, x(g.end) - x(g.start)), height: Track.clips.height)
          .contentShape(Rectangle())
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Cut at \(fmtTime(g.start))")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { project.selection = sel }
          .onTapGesture { project.selection = sel }
          .offset(x: x(g.start), y: Track.clips.y)
      }
      ForEach(Array(plan.segments.enumerated()), id: \.offset) { i, s in
        let sel = Selection.segment(i)
        let (a, b) = range(sel, s.start, s.end)
        bar(
          sel: sel, start: a, end: b, track: .clips, color: s.speed > 1.01 ? .orange : .blue,
          label: s.speed == 1 ? (s.note ?? "") : "\(s.speed.formatted())×  \(s.note ?? "")", movable: false
        ) { newStart, newEnd in
          project.apply { $0.trimSegment(i, start: newStart, end: newEnd) }
        }
      }
      words(plan)
      ForEach(Array(plan.zooms.enumerated()), id: \.offset) { i, z in
        let sel = Selection.zoom(i)
        let (a, b) = range(sel, z.start, z.end)
        bar(sel: sel, start: a, end: b, track: .zooms, color: .purple, label: "\(z.scale.formatted())×", movable: true) { s, e in
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
        bar(sel: sel, start: a, end: b, track: .layouts, color: .teal, label: modeName(l.mode), movable: true) { s, e in
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
        bar(sel: sel, start: a, end: b, track: .titles, color: .pink, label: c.text, movable: true) { s, e in
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
      // Playhead.
      Rectangle().fill(Color.red).frame(width: 2, height: Track.total)
        .offset(x: x(project.playheadSrc) - 1)
        .allowsHitTesting(false)
    }
  }

  private func ruler(_ plan: Plan) -> some View {
    let pps = ui.pxPerSec
    let step: Double = pps > 120 ? 1 : pps > 40 ? 5 : pps > 12 ? 10 : 30
    return Canvas { ctx, size in
      var t = 0.0
      while t <= plan.source.duration {
        let px = t * pps
        ctx.fill(Path(CGRect(x: px, y: 14, width: 1, height: 8)), with: .color(.secondary))
        ctx.draw(Text(fmtTime(t).replacingOccurrences(of: ".0", with: "")).font(.system(size: 9)).foregroundColor(.secondary),
                 at: CGPoint(x: px + 2, y: 6), anchor: .leading)
        t += step
      }
    }
    .frame(height: Track.ruler.height)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0).onChanged { v in
        project.player.pause()
        project.seek(src: max(0, v.location.x / pps))
      }
    )
    .help("Drag to scrub")
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
        let text = ctx.resolve(Text(w.text).font(.system(size: 9)).foregroundColor(kept ? .primary : .secondary.opacity(0.5)))
        let sz = text.measure(in: CGSize(width: 400, height: 20))
        ctx.draw(text, at: CGPoint(x: px, y: 9), anchor: .leading)
        lastEnd = px + sz.width
      }
    }
    .frame(height: Track.words.height)
    .offset(y: Track.words.y)
    .allowsHitTesting(false)
  }

  /// A selectable bar with drag handles on both edges; `movable` bars can also be dragged whole.
  private func bar(
    sel: Selection, start: Double, end: Double, track: Track, color: Color, label: String, movable: Bool,
    commit: @escaping (Double, Double) -> Void
  ) -> some View {
    let selected = project.selection == sel
    let w = max(3, x(end) - x(start))
    let pps = ui.pxPerSec
    let dur = project.plan?.source.duration ?? 0
    return RoundedRectangle(cornerRadius: 5)
      .fill(color.opacity(selected ? 0.95 : 0.7))
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.white : Color.clear, lineWidth: 2))
      .overlay(alignment: .leading) {
        Text(w > 24 ? label : "").font(.caption2).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 6)
      }
      .frame(width: w, height: track.height)
      .contentShape(Rectangle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(track.label) \(label) at \(fmtTime(start))")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        project.selection = sel
        project.seek(src: start)
      }
      .onTapGesture(coordinateSpace: .local) { loc in
        project.selection = sel
        project.seek(src: start + loc.x / pps)
      }
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { v in
            guard movable else { return }
            project.selection = sel
            let d = v.translation.width / pps
            let len = end - start
            let s = min(max(0, start + d), dur - len)
            ui.drag = (sel, s, s + len)
          }
          .onEnded { _ in
            guard movable, let d = ui.drag, d.sel == sel else { return }
            ui.drag = nil
            commit(d.start, d.end)
          }
      )
      .overlay(alignment: .leading) { if selected { handle(sel: sel, start: start, end: end, left: true, commit: commit) } }
      .overlay(alignment: .trailing) { if selected { handle(sel: sel, start: start, end: end, left: false, commit: commit) } }
      .offset(x: x(start), y: track.y)
  }

  private func handle(sel: Selection, start: Double, end: Double, left: Bool, commit: @escaping (Double, Double) -> Void) -> some View {
    let pps = ui.pxPerSec
    let dur = project.plan?.source.duration ?? 0
    return RoundedRectangle(cornerRadius: 2).fill(Color.white)
      .frame(width: 6)
      .padding(.vertical, 4)
      .contentShape(Rectangle().inset(by: -4))
      .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { v in
            let d = v.translation.width / pps
            ui.drag = left ? (sel, min(max(0, start + d), end - 0.1), end) : (sel, start, max(min(dur, end + d), start + 0.1))
          }
          .onEnded { _ in
            guard let d = ui.drag, d.sel == sel else { return }
            ui.drag = nil
            commit(d.start, d.end)
          }
      )
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
