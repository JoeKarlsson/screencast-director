import AppKit
import DirectorCore
import SwiftUI

struct TimelineView: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: TimelineUI

  /// Width of the track header column.
  static let headerWidth: CGFloat = 76
  /// How close (in points) a dragged edge must come to another edge to snap to it.
  static let snapDistance: CGFloat = 6
  static let playheadColor = Color.red

  /// The rows shown: empty ones are hidden (TimelineRows).
  var rows: TimelineRows { TimelineRows(plan: project.plan, hasWords: !(project.project?.words.isEmpty ?? true)) }

  var body: some View {
    VStack(spacing: Theme.Space.s) {
      toolRow
      if let plan = project.plan {
        GeometryReader { geo in
          HStack(spacing: 0) {
            labels
            ScrollViewReader { proxy in
              ScrollView(.horizontal) {
                tracks(plan).frame(width: max(geo.size.width - Self.headerWidth, axisLength * ui.pxPerSec), height: rows.total)
                  .onContinuousHover { phase in
                    if case .active(let p) = phase { ui.pointerTime = p.x / ui.pxPerSec } else { ui.pointerTime = nil }
                  }
              }
              .scrollPosition($ui.scroll)
              .simultaneousGesture(
                MagnifyGesture()
                  .onChanged { v in
                    let base = ui.pinchBase ?? ui.pxPerSec
                    ui.pinchBase = base
                    ui.zoom(by: base * v.magnification / ui.pxPerSec, around: axis(project.playheadSrc))
                  }
                  .onEnded { _ in ui.pinchBase = nil })
              .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }, action: { _, r in ui.scrolled(to: r) })
              .onChange(of: project.aiChange?.id) { _, id in
                guard id != nil, let ranges = project.aiChange?.ranges else { return }
                flash(ranges, proxy)
              }
            }
          }
          .onAppear {
            ui.playheadTime = { [weak project, weak ui] in
              guard let project, let ui else { return 0 }
              return ui.outputTime ? srcToOutClamped(project.mapped, project.playheadSrc, fps: project.fps) / Double(project.fps) : project.playheadSrc
            }
            ui.width = geo.size.width - Self.headerWidth
            ui.axisSeconds = axisLength
            if !ui.fitted {
              ui.fit(axisLength)
              ui.fitted = true
            }
          }
          // Still showing the whole timeline when the width or length changes (the first fit runs
          // before the inspector opens and before the edit's length is known): keep showing all of it.
          .onChange(of: geo.size.width) { _, w in
            let wasFitted = ui.isFitted(width: ui.width, seconds: ui.axisSeconds)
            ui.width = w - Self.headerWidth
            if wasFitted { ui.fit(axisLength) }
          }
          .onChange(of: axisLength) { _, l in
            if ui.isFitted(width: ui.width, seconds: ui.axisSeconds) { ui.fit(l) } else { ui.axisSeconds = l }
          }
        }
        .frame(height: rows.total + 14)
      }
    }
  }

  /// Show the AI edit's ranges at full glow, scroll the first into view, then fade out.
  func flash(_ ranges: [(Double, Double)], _ proxy: ScrollViewProxy) {
    ui.flashRanges = ranges
    ui.flashOpacity = 1
    DispatchQueue.main.async {
      if let first = ranges.min(by: { $0.0 < $1.0 }) {
        let v = ui.viewport.visible
        if x(first.0) < v.minX || x(first.1) > v.maxX {
          withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(Self.flashAnchor, anchor: .center) }
        }
      }
      withAnimation(.easeOut(duration: 2)) { ui.flashOpacity = 0 }
    }
  }

  static let flashAnchor = "aiFlash"

  /// A glow over every track at each range the last AI edit changed. Fades on its own.
  var aiFlash: some View {
    let first = ui.flashRanges.min(by: { $0.0 < $1.0 })
    return ZStack(alignment: .topLeading) {
      // Invisible target for scrolling to the first range.
      if let first {
        Color.clear
          .frame(width: max(1, min(x(first.1) - x(first.0), ui.width)), height: 1)
          .id(Self.flashAnchor)
          .padding(.leading, x(first.0))
      }
      ForEach(Array(ui.flashRanges.enumerated()), id: \.offset) { _, r in
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        shape.fill(Theme.ai.opacity(0.22))
          .overlay(shape.strokeBorder(Theme.ai, lineWidth: 1.5))
          .shadow(color: Theme.ai.opacity(0.9), radius: 8)
          .frame(width: max(4, x(r.1) - x(r.0)), height: rows.total)
          .offset(x: x(r.0))
      }
      .opacity(ui.flashOpacity)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  var isGap: Bool {
    if case .gap = project.selection { return true }
    return false
  }

  /// Track headers: the track's icon in its color, and its name.
  var labels: some View {
    ZStack(alignment: .topLeading) {
      ForEach(rows.visible.filter { $0 != .ruler }, id: \.self) { t in
        HStack(spacing: Theme.Space.xs) {
          Image(systemName: t.icon)
            .font(Theme.font(t == .words ? .micro : .label, .semibold))
            .foregroundStyle(t.color)
            .frame(width: 14)
          Text(t.label)
            .font(Theme.font(.label, .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.leading, Theme.Space.s)
        .frame(width: Self.headerWidth - 6, height: t.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.04)))
        .offset(y: rows.y(t))
      }
    }
    .frame(width: Self.headerWidth, height: rows.total, alignment: .topLeading)
  }

  // MARK: Tracks

  /// A source time's position along the axis, in seconds: itself, or its output time in output mode.
  func axis(_ t: Double) -> Double {
    ui.outputTime ? srcToOutClamped(project.mapped, t, fps: project.fps) / Double(project.fps) : t
  }

  func x(_ t: Double) -> CGFloat { CGFloat(axis(t) * ui.pxPerSec) }

  /// Where a range's (exclusive) end sits: in output mode, the end of the kept moment before it, so
  /// a clip moved out of recording order doesn't stretch to wherever the next recorded moment plays.
  func xEnd(_ t: Double) -> CGFloat {
    guard ui.outputTime else { return x(t) }
    return CGFloat(srcToOutClamped(project.mapped, t, fps: project.fps, before: true) / Double(project.fps) * ui.pxPerSec)
  }

  /// The source time at a point along the axis (in output mode, a card or the end snaps to the
  /// nearest kept moment).
  func time(atX px: CGFloat) -> Double {
    let a = max(0, Double(px) / ui.pxPerSec)
    let duration = project.plan?.source.duration ?? 0
    guard ui.outputTime else { return min(a, duration) }
    let mapped = project.mapped
    let f = a * Double(project.fps)
    if let t = outToSrc(mapped, f, fps: project.fps) { return t }
    guard let first = mapped.first, let last = mapped.last else { return 0 }
    return f < Double(first.outStart) ? first.start : last.end
  }

  /// How long the axis is, in seconds.
  var axisLength: Double { axisLength(ui.outputTime) }

  func axisLength(_ output: Bool) -> Double {
    output ? Double(project.totalOutFrames) / Double(project.fps) : project.plan?.source.duration ?? 1
  }

  func range(_ sel: Selection, _ start: Double, _ end: Double) -> (Double, Double) {
    if let d = ui.drag, d.sel == sel { return (d.start, d.end) }
    if let shift = ui.groupShift, sel.movable, project.isSelected(sel) { return (start + shift, end + shift) }
    return (start, end)
  }

  /// While an edge or bar is dragged: its in and out times (on the timeline's axis) in a capsule in
  /// the ruler above it.
  func dragTip(start: Double, end: Double) -> some View {
    Text("\(fmtTime(axis(start))) – \(fmtTime(axis(end)))")
      .font(Theme.font(.micro, .semibold, mono: true))
      .foregroundStyle(.white)
      .padding(.horizontal, Theme.Space.s)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.black.opacity(0.75)))
      .fixedSize()
      .offset(x: x(start), y: 2)
      .allowsHitTesting(false)
  }

  /// ⇧ or ⌘ held: clicks and drag boxes add to the selection.
  var adding: Bool { !NSEvent.modifierFlags.isDisjoint(with: [.shift, .command]) }

  @ViewBuilder
  func tracks(_ plan: Plan) -> some View {
    ZStack(alignment: .topLeading) {
      lanes
      ruler(plan)
      // Clips: kept segments, and cuts you can restore.
      if !ui.outputTime {
        ForEach(Array(plan.gaps.enumerated()), id: \.offset) { _, g in
          gap(g)
        }
      }
      ForEach(Array(plan.segments.enumerated()), id: \.offset) { i, s in
        let sel = Selection.segment(i)
        let (a, b) = range(sel, s.start, s.end)
        let fast = s.speed > 1.01
        // Trim limits: its neighbors in the recording, wherever they play.
        let lo = plan.segments.filter { $0.end <= s.start + 1e-6 }.map(\.end).max() ?? 0
        let hi = plan.segments.filter { $0.start >= s.end - 1e-6 }.map(\.start).min() ?? plan.source.duration
        bar(
          sel: sel, start: a, end: b, track: .clips, color: Theme.clip, label: s.note ?? "",
          badge: s.speed == 1 ? nil : "\(s.speed.formatted())×", striped: fast, movable: false, bounds: lo...max(lo, hi),
          reorder: i
        ) { newStart, newEnd in
          project.apply { $0.trimSegment(i, start: newStart, end: newEnd) }
        }
      }
      if ui.outputTime, let d = ui.clipDrop { clipDropMarker(slot: d.slot) }
      audio(plan)
      words(plan)
      ForEach(Array(plan.zooms.enumerated()), id: \.offset) { i, z in
        let sel = Selection.zoom(i)
        let (a, b) = range(sel, z.start, z.end)
        bar(sel: sel, start: a, end: b, track: .zooms, color: Theme.zoom, label: z.note ?? "\(z.scale.formatted())×", movable: true) { s, e in
          project.retime(sel, start: s, end: e)
        }
      }
      ForEach(Array(plan.layouts.enumerated()), id: \.offset) { i, l in
        let sel = Selection.layout(i)
        let (a, b) = range(sel, l.start, l.end)
        bar(sel: sel, start: a, end: b, track: .layouts, color: Theme.layout, label: l.note ?? modeName(l.mode), movable: true) { s, e in
          project.retime(sel, start: s, end: e)
        }
      }
      ForEach(Array(plan.punchInList.enumerated()), id: \.offset) { i, p in
        let sel = Selection.punchIn(i)
        let (a, b) = range(sel, p.start, p.end)
        bar(sel: sel, start: a, end: b, track: .punchIns, color: Theme.punchIn, label: p.note ?? "\(p.scale.formatted())×", movable: true) { s, e in
          project.retime(sel, start: s, end: e)
        }
      }
      ForEach(Array(plan.callouts.enumerated()), id: \.offset) { i, c in
        let sel = Selection.callout(i)
        let (a, b) = range(sel, c.start, c.end)
        bar(sel: sel, start: a, end: b, track: .titles, color: Theme.title, label: c.text, movable: true) { s, e in
          project.retime(sel, start: s, end: e)
        }
      }
      ForEach(Array(plan.annotationList.enumerated()), id: \.offset) { i, m in
        let sel = Selection.annotation(i)
        let (a, b) = range(sel, m.start, m.end)
        let label = Annotation.kinds.first { $0.name == m.kind }?.label ?? m.kind
        bar(sel: sel, start: a, end: b, track: .marks, color: Theme.mark, label: m.text.map { "\(label): \($0)" } ?? label, movable: true) { s, e in
          project.retime(sel, start: s, end: e)
        }
      }
      ForEach(Array(plan.insertList.enumerated()), id: \.offset) { i, c in
        let sel = Selection.insert(i)
        let (a, b) = range(sel, c.start, c.end)
        let name = (c.file as NSString).lastPathComponent
        bar(sel: sel, start: a, end: b, track: .broll, color: Theme.broll, label: c.note ?? (c.isFull ? "\(name) · full" : name), movable: true) { s, e in
          project.retime(sel, start: s, end: e)
        }
      }
      ForEach(Array(plan.animationList.enumerated()), id: \.offset) { i, an in
        let sel = Selection.animation(i)
        let (a, b) = range(sel, an.start, an.end)
        let rendering = project.animating && plan.animationsToRender(dir: project.dir).contains { $0.index == i }
        let label = "\(an.note ?? AnimationLibrary.template(an.template, project.dir)?.title ?? an.template)\(rendering ? " · rendering…" : "")"
        bar(sel: sel, start: a, end: b, track: .animations, color: Theme.animation, label: label, striped: rendering, movable: true) { s, e in
          project.retime(sel, start: s, end: e)
        }
      }
      ForEach(Array(plan.effectRangeList.enumerated()), id: \.offset) { i, r in
        let sel = Selection.effectRange(i)
        let (a, b) = range(sel, r.start, r.end)
        let title = EffectSources(project: project.dir).manifest(r.name)?.title ?? r.name
        bar(sel: sel, start: a, end: b, track: .effects, color: Theme.effect, label: r.note ?? title, movable: true) { s, e in
          project.retime(sel, start: s, end: e)
        }
      }
      soundEffects(plan)
      inOutBand(plan)
      markers(plan)
      if let m = ui.marquee {
        Rectangle().fill(Theme.accent.opacity(0.12))
          .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
          .frame(width: m.width, height: m.height)
          .offset(x: m.minX, y: m.minY)
          .allowsHitTesting(false)
      }
      if let s = ui.snap {
        Rectangle().fill(Color.primary.opacity(0.8))
          .frame(width: 1, height: rows.total - Track.ruler.height)
          .offset(x: x(s) - 0.5, y: Track.ruler.height)
          .allowsHitTesting(false)
      }
      if let d = ui.drag { dragTip(start: d.start, end: d.end) }
      aiFlash
      playhead
    }
  }

  /// A faint band behind each track. Clicking an empty spot moves the playhead there and deselects.
  var lanes: some View {
    ZStack(alignment: .topLeading) {
      ForEach(rows.visible.filter { $0 != .ruler }, id: \.self) { t in
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.primary.opacity(0.03))
          .frame(height: t.height)
          .offset(y: rows.y(t))
      }
    }
    // Offsets don't grow a ZStack, so give it the tracks' full height to catch clicks everywhere.
    .frame(maxWidth: .infinity, minHeight: rows.total, alignment: .topLeading)
    .contentShape(Rectangle())
    .onTapGesture(coordinateSpace: .local) { loc in
      if !adding {
        project.selection = nil
        project.multi = []
      }
      project.player.pause()
      project.seek(src: time(atX: loc.x))
    }
    // Simultaneous, or the tap above claims every press and the box never starts.
    .simultaneousGesture(
      DragGesture(minimumDistance: 4, coordinateSpace: .local)
        .onChanged { v in
          let a = v.startLocation, b = v.location
          ui.marquee = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        .onEnded { _ in
          if let m = ui.marquee, let plan = project.plan { project.select(items(in: m, plan), adding: adding) }
          ui.marquee = nil
        }
    )
    .accessibilityHidden(true)
  }

  /// The items whose bars a drag box touches (markers sit in the ruler, outside the box's reach).
  func items(in box: CGRect, _ plan: Plan) -> [Selection] {
    plan.allItems.filter { s in
      guard let track = Track.of(s), let (a, b) = plan.timeRange(of: s) else { return false }
      return box.intersects(CGRect(x: x(a), y: rows.y(track), width: max(3, xEnd(b) - x(a)), height: track.height))
    }
  }

  /// The in/out range: a band over the tracks and brackets in the ruler.
  @ViewBuilder
  func inOutBand(_ plan: Plan) -> some View {
    if project.inPoint != nil || project.outPoint != nil {
      let a = project.inPoint ?? 0, b = project.outPoint ?? plan.source.duration
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Theme.accent.opacity(0.1))
          .frame(width: max(1, xEnd(b) - x(a)), height: rows.total - Track.ruler.height)
          .offset(x: x(a), y: Track.ruler.height)
        if let i = project.inPoint {
          InOutBracket(left: true).stroke(Theme.accent, lineWidth: 2).frame(width: 6, height: rows.total - 2).offset(x: x(i), y: 1)
        }
        if let o = project.outPoint {
          InOutBracket(left: false).stroke(Theme.accent, lineWidth: 2).frame(width: 6, height: rows.total - 2).offset(x: x(o) - 6, y: 1)
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
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

extension View {
  /// A timeline toolbar menu: an icon the size of the toolbar's buttons, with no menu arrow.
  func toolMenu() -> some View {
    menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 22)
  }
}
