import AppKit
import DirectorCore
import SwiftUI

// The timeline's view state, its track rows, and the shapes it draws.

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
  /// A clip dragged on the output timeline: its index, the slot between clips it would drop into,
  /// and the play position it would move to (`clipDrop`).
  @Published var clipDrop: (clip: Int, slot: Int, target: Int)?
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

enum Track: CaseIterable {
  case ruler, clips, audio, words, zooms, layouts, titles, marks, broll, animations, effects, sounds

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
    case .effectRange: return .effects
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
    case .effects: return "Effects"
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
    case .effects: return "wand.and.stars"
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
    case .effects: return Theme.effect
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
struct Hatch: Shape {
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
struct PlayheadOffset: ViewModifier {
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
struct MarkerFlag: Shape {
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
struct InOutBracket: Shape {
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
struct PlayheadCap: Shape {
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
