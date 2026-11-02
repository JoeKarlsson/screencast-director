import AppKit
import DirectorCore
import SwiftUI

/// Timeline view state (no @State without macro plugins, so it lives here).
final class TimelineUI: ObservableObject {
  @Published var pxPerSec: Double = 60
  @Published var fitted = false
  /// Lay the timeline out in output time: cuts collapse and sped-up clips draw at their real length.
  @Published var outputTime = true
  /// Visible width of the track area, for Fit.
  var width: CGFloat = 800
  /// How long the axis is (seconds); zooming all the way out shows all of it.
  var axisSeconds: Double = 60
  var minPxPerSec: Double { min(4, (width - 20) / max(axisSeconds, 1)) }

  /// Whether the zoom is where Fit puts it for this width and length.
  func isFitted(width: CGFloat, seconds: Double) -> Bool {
    abs(pxPerSec - min(400, (width - 20) / max(seconds, 1))) < 0.01
  }

  func fit(_ duration: Double) {
    axisSeconds = duration
    pxPerSec = min(400, max(minPxPerSec, (width - 20) / max(duration, 1)))
  }
  /// A drag in progress: which item and its live range, drawn instead of the saved one.
  @Published var drag: (sel: Selection, start: Double, end: Double)?
  /// Dragging several selected items: how far they've moved so far (seconds).
  @Published var groupShift: Double?
  /// A drag box over empty track space, selecting what it touches.
  @Published var marquee: CGRect?
  /// The bar under the pointer.
  @Published var hover: Selection?
  /// The source time a dragged edge is snapped to, drawn as a guide line.
  @Published var snap: Double?
  /// What's scrolled into view; only the filmstrip observes it.
  let viewport = TimelineViewport()
  /// The ranges of the last AI edit, flashed over every track, and the flash's fading opacity.
  @Published var flashRanges: [(Double, Double)] = []
  @Published var flashOpacity: Double = 0
  /// Where the track area is scrolled; set to zoom around a point or follow the playhead.
  @Published var scroll = ScrollPosition(edge: .leading)
  /// The pointer is over the tracks (so ⌥-scroll zooms the timeline) at this source time.
  var pointerTime: Double?
  /// The playhead along the axis (source or output seconds, by mode); every zoom keeps it in place.
  var playheadTime: () -> Double = { 0 }
  /// Where the last zoom scrolled to, until the scroll view reports it: zooms fire faster than
  /// layout (a slider drag), so reading the laid-out position would drift away from the playhead.
  private var pendingScrollX: Double?
  /// The timeline zoom when a pinch began.
  var pinchBase: Double?
  private var scrollMonitor: Any?

  init() {
    // ⌥-scroll over the tracks zooms the timeline around the pointer.
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
      guard let self, self.pointerTime != nil else { return e }
      guard e.modifierFlags.contains(.option) else {
        self.pendingScrollX = nil  // the user is scrolling; trust the scroll view again
        return e
      }
      self.zoom(by: exp(Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08)), around: self.playheadTime())
      return nil
    }
  }

  deinit {
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
  }

  /// Zooms the timeline, keeping axis time `t` (the playhead) where it is on screen, or centering
  /// it when it's scrolled out of view.
  func zoom(by factor: Double, around t: Double) {
    let old = pxPerSec
    let new = min(400, max(minPxPerSec, old * factor))
    guard abs(new - old) > 0.01 else { return }
    let x = timelineZoomScroll(
      around: t, from: old, to: new, scrollX: pendingScrollX ?? viewport.visible.minX, visibleWidth: viewport.visible.width,
      minContentWidth: Double(width), axisSeconds: axisSeconds)
    pxPerSec = new
    pendingScrollX = x
    // After the wider content lays out.
    DispatchQueue.main.async { self.scroll.scrollTo(x: x) }
  }

  /// The scroll view moved: once it lands where the last zoom asked, its position is current again.
  func scrolled(to r: CGRect) {
    viewport.update(r)
    if let x = pendingScrollX, abs(r.minX - x) < 1 { pendingScrollX = nil }
  }

  /// Scrolls a page when the playhead runs off the right edge while playing. `t` is a position
  /// along the axis (source or output seconds, by mode).
  func follow(_ t: Double) {
    let x = t * pxPerSec, v = viewport.visible
    if x > v.maxX - 24 || x < v.minX { scroll.scrollTo(x: max(0, x - 40)) }
  }
}

private enum Track: CaseIterable {
  case ruler, clips, audio, words, zooms, layouts, titles, marks, broll, animations, sounds

  var height: CGFloat {
    switch self {
    case .ruler: return 22
    case .clips: return 34
    case .audio: return 30
    case .words: return 18
    default: return 24
    }
  }
  /// The track an item's bar sits on (nil for markers, which sit in the ruler).
  static func of(_ s: Selection) -> Track? {
    switch s {
    case .segment, .gap: return .clips
    case .zoom: return .zooms
    case .layout: return .layouts
    case .callout: return .titles
    case .annotation: return .marks
    case .insert: return .broll
    case .animation: return .animations
    case .sfx: return .sounds
    case .marker: return nil
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
    case .marks: return "Marks"
    case .broll: return "B-roll"
    case .animations: return "Animations"
    case .sounds: return "Sound FX"
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
    case .marks: return "scribble"
    case .broll: return "photo.on.rectangle"
    case .animations: return "sparkles"
    case .sounds: return "speaker.wave.2"
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
    case .marks: return Theme.mark
    case .broll: return Theme.broll
    case .animations: return Theme.animation
    case .sounds: return Theme.sfx
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

/// Moves the playhead line. Only this modifier observes the playhead, so playback redraws one line
/// instead of every track.
private struct PlayheadOffset: ViewModifier {
  let project: ProjectModel
  @ObservedObject var playhead: Playhead
  let ui: TimelineUI
  /// Passed as values (not read from ui/project) so a timeline zoom or a new plan redraws the line.
  let pxPerSec: Double
  let mapped: [MappedSegment]
  let outputTime: Bool

  func body(content: Content) -> some View {
    let total = Double(max(project.totalOutFrames - 1, 0))
    let frame = min(playhead.frame, total)
    let axis = outputTime ? frame / Double(project.fps) : outToSrc(mapped, frame, fps: project.fps) ?? 0
    return content.offset(x: axis * pxPerSec - 6)
      .onChange(of: playhead.frame) { _, _ in
        if project.isPlaying { ui.follow(axis) }
      }
  }
}

/// A marker's flag: a pole with a pennant.
private struct MarkerFlag: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    p.addRect(CGRect(x: r.minX, y: r.minY, width: 1.5, height: r.height))
    p.move(to: CGPoint(x: r.minX + 1.5, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.3))
    p.addLine(to: CGPoint(x: r.minX + 1.5, y: r.minY + r.height * 0.6))
    p.closeSubpath()
    return p
  }
}

/// An in or out bracket: [ or ].
private struct InOutBracket: Shape {
  let left: Bool
  func path(in r: CGRect) -> Path {
    var p = Path()
    let edge = left ? r.minX : r.maxX, tip = left ? r.maxX : r.minX
    p.move(to: CGPoint(x: tip, y: r.minY))
    p.addLine(to: CGPoint(x: edge, y: r.minY))
    p.addLine(to: CGPoint(x: edge, y: r.maxY))
    p.addLine(to: CGPoint(x: tip, y: r.maxY))
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
            ScrollViewReader { proxy in
              ScrollView(.horizontal) {
                tracks(plan).frame(width: max(geo.size.width - Self.headerWidth, axisLength * ui.pxPerSec), height: Track.total)
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
              .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, r in ui.scrolled(to: r) }
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
        .frame(height: Track.total + 14)
      }
    }
  }

  /// Show the AI edit's ranges at full glow, scroll the first into view, then fade out.
  private func flash(_ ranges: [(Double, Double)], _ proxy: ScrollViewProxy) {
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

  private static let flashAnchor = "aiFlash"

  /// A glow over every track at each range the last AI edit changed. Fades on its own.
  private var aiFlash: some View {
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
          .frame(width: max(4, x(r.1) - x(r.0)), height: Track.total)
          .offset(x: x(r.0))
      }
      .opacity(ui.flashOpacity)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 10) {
      toolGroup {
        iconButton("Split", "scissors", help: "Split the clip at the playhead (C)", action: project.splitAtPlayhead)
        iconButton(
          isGap ? "Restore" : "Delete", isGap ? "arrow.uturn.backward" : "trash",
          help: isGap ? "Restore the selected cut (⌫)" : "Cut the selected clip, or remove the selected zoom, layout or title (⌫)",
          action: project.deleteSelection)
          .disabled(project.selectedItems.isEmpty)
      }
      if project.markedRange != nil { rangeActions }
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
        Menu {
          ForEach(ChoiceTiles.calloutStyles, id: \.name) { c in
            Button { project.addCallout(style: c.name) } label: { Label(c.label, systemImage: c.icon) }
          }
        } label: {
          Image(systemName: "textformat")
        } primaryAction: {
          project.addCallout()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 22)
        .accessibilityLabel("Title")
        .help("Add a title at the playhead (T); hold for lower thirds, slates and chapters")
        Menu {
          ForEach(ChoiceTiles.annotationKinds, id: \.name) { k in
            Button { project.addAnnotation(k.name) } label: { Label(k.label, systemImage: k.icon) }
          }
        } label: {
          Image(systemName: "scribble")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 22)
        .accessibilityLabel("Annotate")
        .help("Add a spotlight, box, arrow, highlight or blur at the playhead, around the last click (A)")
        iconButton("B-roll", "photo.on.rectangle", help: "Show a picture or clip over the video from the playhead", action: project.addInsert)
        Menu {
          ForEach(AnimationLibrary.templates(project.dir).map(\.template), id: \.name) { t in
            Button { project.addAnimation(t) } label: { Text("\(t.title): \(t.summary)") }
          }
        } label: {
          Image(systemName: "sparkles")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 22)
        .accessibilityLabel("Animate")
        .help("Add an animation over the in/out range, the selected words, or from the playhead")
      }
      Spacer(minLength: 4)
      HStack(spacing: 6) {
        Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
        Slider(
          value: Binding(get: { ui.pxPerSec }, set: { ui.zoom(by: $0 / ui.pxPerSec, around: axis(project.playheadSrc)) }), in: ui.minPxPerSec...400)
          .accessibilityLabel("Timeline zoom")
          .controlSize(.small)
          .frame(minWidth: 60, maxWidth: 120)
          .help("Timeline zoom")
        Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      toolGroup {
        Toggle(isOn: Binding(get: { ui.outputTime }, set: { on in
          ui.outputTime = on
          ui.fit(axisLength(on))
        })) {
          Image(systemName: "rectangle.compress.vertical").frame(width: 28, height: 22)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Output time")
        .help(ui.outputTime ? "Showing the finished video's length; click for the whole recording" : "Show the finished video's length: cuts collapse, sped-up clips shrink")
        iconButton("Fit", "arrow.left.and.right", help: "Fit the whole timeline") {
          ui.fit(axisLength)
        }
      }
    }
    .font(.system(size: 13))
    .disabled(!project.hasPlan)
  }

  /// What to do with the in/out range: cut, speed up, zoom, title, annotate, or clear it.
  private var rangeActions: some View {
    toolGroup {
      Text("In/Out").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent).padding(.horizontal, 6)
      iconButton("Cut range", "scissors.badge.ellipsis", help: "Cut the in/out range", action: project.cutMarked)
      Menu {
        ForEach([1.5, 2, 3, 4, 8], id: \.self) { s in Button("\(s.formatted())×") { project.speedMarked(s) } }
      } label: {
        Image(systemName: "hare")
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 22)
      .accessibilityLabel("Speed up range")
      .help("Speed up the range (sped-up parts are muted, so use it for typing and waiting)")
      iconButton("Zoom range", "plus.magnifyingglass", help: "Zoom in over the range", action: project.zoomOverRange)
      Menu {
        ForEach(ChoiceTiles.calloutStyles, id: \.name) { c in
          Button { project.titleOverRange(style: c.name) } label: { Label(c.label, systemImage: c.icon) }
        }
      } label: {
        Image(systemName: "textformat")
      } primaryAction: {
        project.titleOverRange(style: "title")
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 22)
      .accessibilityLabel("Title over range")
      .help("A title over the range, worded from what's said")
      Menu {
        ForEach(ChoiceTiles.annotationKinds, id: \.name) { k in
          Button { project.annotateRange(k.name) } label: { Label(k.label, systemImage: k.icon) }
        }
      } label: {
        Image(systemName: "scribble")
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 22)
      .accessibilityLabel("Annotate range")
      .help("An annotation over the range")
      iconButton("Clear range", "xmark", help: "Clear the in/out range (⌥X)", action: project.clearInOut)
    }
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

  /// A source time's position along the axis, in seconds: itself, or its output time in output mode.
  private func axis(_ t: Double) -> Double {
    ui.outputTime ? srcToOutClamped(project.mapped, t, fps: project.fps) / Double(project.fps) : t
  }

  private func x(_ t: Double) -> CGFloat { CGFloat(axis(t) * ui.pxPerSec) }

  /// The source time at a point along the axis (in output mode, a card or the end snaps to the
  /// nearest kept moment).
  private func time(atX px: CGFloat) -> Double {
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
  private var axisLength: Double { axisLength(ui.outputTime) }

  private func axisLength(_ output: Bool) -> Double {
    output ? Double(project.totalOutFrames) / Double(project.fps) : project.plan?.source.duration ?? 1
  }

  private func range(_ sel: Selection, _ start: Double, _ end: Double) -> (Double, Double) {
    if let d = ui.drag, d.sel == sel { return (d.start, d.end) }
    if let shift = ui.groupShift, sel.movable, project.isSelected(sel) { return (start + shift, end + shift) }
    return (start, end)
  }

  /// ⇧ or ⌘ held: clicks and drag boxes add to the selection.
  private var adding: Bool { !NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty }

  @ViewBuilder
  private func tracks(_ plan: Plan) -> some View {
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
          project.retime(sel, start: s, end: e)
        }
      }
      ForEach(Array(plan.layouts.enumerated()), id: \.offset) { i, l in
        let sel = Selection.layout(i)
        let (a, b) = range(sel, l.start, l.end)
        bar(sel: sel, start: a, end: b, track: .layouts, color: Theme.layout, label: modeName(l.mode), movable: true) { s, e in
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
        bar(sel: sel, start: a, end: b, track: .broll, color: Theme.broll, label: c.isFull ? "\(name) · full" : name, movable: true) { s, e in
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
          .frame(width: 1, height: Track.total - Track.ruler.height)
          .offset(x: x(s) - 0.5, y: Track.ruler.height)
          .allowsHitTesting(false)
      }
      aiFlash
      playhead
    }
  }

  /// A faint band behind each track. Clicking an empty spot moves the playhead there and deselects.
  private var lanes: some View {
    ZStack(alignment: .topLeading) {
      ForEach(Track.allCases.filter { $0 != .ruler }, id: \.self) { t in
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.primary.opacity(0.03))
          .frame(height: t.height)
          .offset(y: t.y)
      }
    }
    // Offsets don't grow a ZStack, so give it the tracks' full height to catch clicks everywhere.
    .frame(maxWidth: .infinity, minHeight: Track.total, alignment: .topLeading)
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
  private func items(in box: CGRect, _ plan: Plan) -> [Selection] {
    plan.allItems.filter { s in
      guard let track = Track.of(s), let (a, b) = plan.timeRange(of: s) else { return false }
      return box.intersects(CGRect(x: x(a), y: track.y, width: max(3, x(b) - x(a)), height: track.height))
    }
  }

  /// The in/out range: a band over the tracks and brackets in the ruler.
  @ViewBuilder
  private func inOutBand(_ plan: Plan) -> some View {
    if project.inPoint != nil || project.outPoint != nil {
      let a = project.inPoint ?? 0, b = project.outPoint ?? plan.source.duration
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Theme.accent.opacity(0.1))
          .frame(width: max(1, x(b) - x(a)), height: Track.total - Track.ruler.height)
          .offset(x: x(a), y: Track.ruler.height)
        if let i = project.inPoint {
          InOutBracket(left: true).stroke(Theme.accent, lineWidth: 2).frame(width: 6, height: Track.total - 2).offset(x: x(i), y: 1)
        }
        if let o = project.outPoint {
          InOutBracket(left: false).stroke(Theme.accent, lineWidth: 2).frame(width: 6, height: Track.total - 2).offset(x: x(o) - 6, y: 1)
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  /// Sound effects: a chip at each effect's start on its own row (click to jump and select, drag to move).
  /// Sounds attached to a title or annotation sit at its start; clicking one selects that item.
  private func soundEffects(_ plan: Plan) -> some View {
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
        .offset(x: x(t), y: Track.sounds.y + 2)
        .onTapGesture {
          project.select(a.owner, adding: adding)
          project.seek(src: a.t)
        }
        .help("\(name), attached to \(a.label). It moves with it; change it in the inspector.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound \(name) on \(a.label)")
        .accessibilityAddTraits(.isButton)
      }
      ForEach(Array((plan.sfx ?? []).enumerated()), id: \.offset) { i, e in
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
        .offset(x: x(t), y: Track.sounds.y + 2)
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
  private func attachedSounds(_ plan: Plan) -> [(t: Double, file: String, owner: Selection, label: String)] {
    var out: [(t: Double, file: String, owner: Selection, label: String)] = []
    for (i, c) in plan.callouts.enumerated() { if let s = c.sound { out.append((c.start, s.file, .callout(i), "the title \"\(c.text)\"")) } }
    for (i, m) in plan.annotationList.enumerated() { if let s = m.sound { out.append((m.start, s.file, .annotation(i), "an annotation")) } }
    for (i, an) in plan.animationList.enumerated() {
      for (cue, s) in an.sounds ?? [:] { out.append((cue == "start" ? an.start : an.cues?[cue] ?? an.start, s.file, .animation(i), "an animation")) }
    }
    return out
  }

  /// Marker flags in the ruler (click to jump and select, drag to move) and a faint line below each.
  private func markers(_ plan: Plan) -> some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(plan.markerList.enumerated()), id: \.offset) { i, m in
        let sel = Selection.marker(i)
        let (t, _) = range(sel, m.t, m.t)
        let selected = project.isSelected(sel)
        Rectangle().fill(Theme.accent.opacity(0.35))
          .frame(width: 1, height: Track.total - Track.ruler.height)
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
    .modifier(
      PlayheadOffset(project: project, playhead: project.playhead, ui: ui, pxPerSec: ui.pxPerSec, mapped: project.mapped, outputTime: ui.outputTime))
    .allowsHitTesting(false)
  }

  private func ruler(_ plan: Plan) -> some View {
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
  private func audio(_ plan: Plan) -> some View {
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
    .offset(y: Track.audio.y)
    .allowsHitTesting(false)
  }

  private func words(_ plan: Plan) -> some View {
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
    .offset(y: Track.words.y)
    .allowsHitTesting(false)
  }

  /// A cut: hatched and dashed, selectable so it can be restored.
  private func gap(_ g: Gap) -> some View {
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
    let selected = project.isSelected(sel)
    // Trim handles only when this is the one selected item.
    let trimmable = project.selection == sel && project.multi.isEmpty
    let hovered = ui.hover == sel
    let w = max(3, x(end) - x(start))
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
      .offset(x: x(start), y: track.y)
  }

  /// The source recording's frames for a clip bar, or nil without a plan.
  private func filmstrip(start: Double, end: Double, barX: CGFloat, barW: CGFloat) -> EquatableView<Filmstrip>? {
    guard let src = project.plan?.source, src.height > 0 else { return nil }
    let cache = FilmstripCache.shared(dir: project.dir, video: src.video, duration: src.duration)
    return Filmstrip(
      cache: cache, viewport: ui.viewport, start: start, end: end, barX: barX, barW: barW, height: Track.clips.height,
      aspect: src.width / src.height
    ).equatable()
  }

  private func handle(
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
  private func snapTargets(start: Double, end: Double) -> [Double] {
    guard let p = project.plan else { return [] }
    var ts = [project.playheadSrc, 0, p.source.duration] + [project.inPoint, project.outPoint].compactMap { $0 }
    for s in p.allItems { if let (a, b) = p.timeRange(of: s) { ts += [a, b] } }
    return ts.filter { abs($0 - start) > 1e-9 && abs($0 - end) > 1e-9 || $0 == project.playheadSrc }
  }

  /// The shift that lands the nearest of `edges` on a target within `snapDistance` points (0 when
  /// none is close, or while ⌘ is held). Sets or clears the guide line.
  private func snapShift(_ edges: [Double], start: Double, end: Double) -> Double {
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

func modeName(_ m: LayoutMode) -> String {
  switch m {
  case .screen: return "Screen only"
  case .pip: return "Camera bubble"
  case .side: return "Side by side"
  case .camera: return "Camera only"
  }
}
