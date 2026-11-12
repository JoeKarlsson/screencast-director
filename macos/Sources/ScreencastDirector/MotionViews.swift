import AppKit
import DirectorCore
import SwiftUI

// Inspector controls for motion: the house style, per-item entrances and exits, and annotation
// rectangles.

/// An easing curve drawn as a line, with a dot running along it while the pointer is over it.
struct EaseCurve: View {
  let ease: Ease
  var active = false

  var body: some View {
    SwiftUI.TimelineView(.animation(paused: !active)) { tl in
      Canvas { ctx, size in
        // Springs overshoot, so leave headroom above 1.
        let top = 0.22, bottom = 0.08
        func point(_ t: Double) -> CGPoint {
          CGPoint(x: t * size.width, y: size.height * (1 - bottom - (1 - top - bottom) * ease.at(t)))
        }
        var path = Path()
        path.move(to: point(0))
        for i in 1...48 { path.addLine(to: point(Double(i) / 48)) }
        ctx.stroke(path, with: .color(active ? Theme.accent : .secondary), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        if active {
          let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.1
          let p = point(min(t, 1))
          ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(Theme.accent))
        }
      }
    }
  }
}

/// The motion styles as tiles, each with its camera curve.
struct MotionStyleGrid: View {
  let selected: String
  let pick: (String) -> Void

  var body: some View {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
      ForEach(MotionStyle.all, id: \.name) { style in
        let on = style.name == selected
        Button {
          pick(style.name)
        } label: {
          VStack(spacing: 4) {
            EaseCurve(ease: style.ease, active: on).frame(height: 30).padding(.horizontal, 6)
            Text(style.label).font(.caption)
          }
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity)
          .selectableTile(on: on)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.help(style.name))
        .accessibilityLabel("\(style.label) motion")
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }

  static func help(_ name: String) -> String {
    switch name {
    case "smooth": return "Quick start, long soft landing. Titles fade up."
    case "snappy": return "Fast and crisp. Titles pop in on a spring."
    case "cinematic": return "Slow in, slow out. Titles blur in."
    case "bouncy": return "Springy moves with a little overshoot."
    default: return "The original look: windowed smoothing, titles appear instantly."
    }
  }
}

/// Picks an entrance or exit: the preset, its length and its ease. nil is the motion style's.
struct MotionPicker: View {
  let title: String
  @Binding var motion: Motion?
  /// What nil means, shown as "<defaultTitle> (…)".
  let fallback: Motion
  var defaultTitle = "Style Default"

  private func label(_ preset: String) -> String { Motion.presets.first { $0.name == preset }?.label ?? preset }

  var body: some View {
    LabeledContent(title) {
      Menu {
        Button("\(defaultTitle) (\(label(fallback.preset)))") { motion = nil }
        Divider()
        ForEach(Motion.presets, id: \.name) { p in
          Button {
            var m = motion ?? fallback
            m.preset = p.name
            motion = m
          } label: {
            if (motion ?? fallback).preset == p.name && motion != nil { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
          }
        }
        Divider()
        Menu("Length") {
          ForEach([0.2, 0.3, 0.45, 0.6, 0.9, 1.2], id: \.self) { s in
            Button("\(s.formatted()) s") {
              var m = motion ?? fallback
              m.seconds = s
              motion = m
            }
          }
        }
        Menu("Ease") {
          ForEach(Ease.names, id: \.self) { e in
            Button(e.capitalized) {
              var m = motion ?? fallback
              m.ease = e
              motion = m
            }
          }
        }
      } label: {
        let m = motion ?? fallback
        Text(motion == nil ? "Style (\(label(m.preset)))" : "\(label(m.preset)) · \((m.seconds ?? fallback.seconds ?? 0.35).formatted()) s")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Spacer(minLength: 0)
    }
    if let own = motion {
      MotionTuner(motion: Binding(get: { motion ?? own }, set: { motion = $0 }), fallback: fallback)
    }
  }
}

/// Hand-tuning for an item's own entrance or exit: any length, and its curve, dragged by its two
/// cubic-bezier handles, or for a spring, how much it bounces.
struct MotionTuner: View {
  @Binding var motion: Motion
  let fallback: Motion

  var body: some View {
    let seconds = motion.seconds ?? fallback.seconds ?? 0.35
    LabeledContent("Length") {
      Slider(value: Binding(get: { seconds }, set: { motion.seconds = ($0 * 100).rounded() / 100 }), in: 0.05...2).controlSize(.small)
      Text("\(seconds.formatted()) s").font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
    }
    switch Ease.named(motion.ease ?? fallback.ease) ?? .linear {
    // The plan's easing curve, not a UI animation.
    // swiftlint:disable:next motion_tokens
    case .spring(let zeta):
      LabeledContent("Bounce") {
        Slider(value: Binding(get: { 1 - zeta }, set: { motion.ease = "spring(\(((1 - $0) * 100).rounded() / 100))" }), in: 0...0.8).controlSize(.small)
        Text("\(Int(((1 - zeta) * 100).rounded()))%").font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
      }
    case .cubic(let x1, let y1, let x2, let y2):
      BezierEditor(points: (x1, y1, x2, y2)) { motion.ease = $0 }
    case .linear:
      BezierEditor(points: (0, 0, 1, 1)) { motion.ease = $0 }
    }
  }
}

/// An easing curve with its two cubic-bezier handles to drag. `set` gets the new curve as
/// "cubic-bezier(x1, y1, x2, y2)"; handles go above 1 and below 0 for overshoot and anticipation.
struct BezierEditor: View {
  let points: (Double, Double, Double, Double)
  let set: (String) -> Void
  /// The value range drawn top to bottom, so overshooting handles stay on the canvas.
  static let yRange = (lo: -0.5, hi: 1.5)

  var body: some View {
    GeometryReader { geo in editor(geo.size) }
      .frame(height: 96)
      .help("Drag the two dots to shape how it eases")
      .accessibilityLabel("Easing curve")
  }

  private func editor(_ size: CGSize) -> some View {
    let w = Double(size.width), h = Double(size.height)
    let span = Self.yRange.hi - Self.yRange.lo
    func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: h * (Self.yRange.hi - y) / span) }
    let (x1, y1, x2, y2) = points
    let ease = Ease.cubic(x1, y1, x2, y2)
    func r(_ d: Double) -> String { ((d * 100).rounded() / 100).formatted() }
    // Each handle has its own drag, in the editor's coordinates, so moving one never picks up the other.
    func handle(_ p: CGPoint, _ moved: @escaping (Double, Double) -> (Double, Double, Double, Double)) -> some View {
      Circle().fill(Theme.accent).frame(width: 12, height: 12).padding(6).contentShape(Circle()).position(p)
        .gesture(
          DragGesture(minimumDistance: 0, coordinateSpace: .named("bezier")).onChanged { v in
            let x = min(max(Double(v.location.x) / w, 0), 1)
            let y = min(max(Self.yRange.hi - Double(v.location.y) / h * span, Self.yRange.lo), Self.yRange.hi)
            let c = moved(x, y)
            set("cubic-bezier(\(r(c.0)), \(r(c.1)), \(r(c.2)), \(r(c.3)))")
          })
    }
    return ZStack {
      Canvas { ctx, _ in
        for y in [0.0, 1.0] {
          ctx.stroke(Path { $0.move(to: at(0, y)); $0.addLine(to: at(1, y)) }, with: .color(.secondary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        ctx.stroke(Path { $0.move(to: at(0, 0)); $0.addLine(to: at(x1, y1)); $0.move(to: at(1, 1)); $0.addLine(to: at(x2, y2)) }, with: .color(.secondary), lineWidth: 1)
        var curve = Path()
        curve.move(to: at(0, 0))
        for i in 1...64 { let t = Double(i) / 64; curve.addLine(to: at(t, ease.at(t))) }
        ctx.stroke(curve, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      }
      handle(at(x1, y1)) { x, y in (x, y, x2, y2) }
      handle(at(x2, y2)) { x, y in (x1, y1, x, y) }
    }
    .coordinateSpace(name: "bezier")
  }
}

/// Icon tiles for a short list of named choices (title styles, annotation kinds).
struct ChoiceTiles: View {
  let choices: [(name: String, label: String, icon: String)]
  let selected: String
  let pick: (String) -> Void
  var columns = 4

  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
      ForEach(choices, id: \.name) { c in
        let on = c.name == selected
        Button {
          pick(c.name)
        } label: {
          VStack(spacing: 4) {
            Image(systemName: c.icon).font(Theme.glyph(16))
            Text(c.label).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
          }
          .frame(maxWidth: .infinity, minHeight: 46)
          .selectableTile(on: on)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.label)
        .accessibilityLabel(c.label)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }

  static let calloutStyles: [(name: String, label: String, icon: String)] = [
    ("title", "Title", "textformat"), ("lower-third", "Lower Third", "text.below.photo"),
    ("slate", "Slate", "rectangle.center.inset.filled"), ("chapter", "Chapter", "bookmark"),
  ]
  static let annotationKinds: [(name: String, label: String, icon: String)] = [
    ("spotlight", "Spotlight", "light.max"), ("box", "Box", "rectangle.dashed"), ("arrow", "Arrow", "arrow.up.left"),
    ("highlight", "Highlight", "highlighter"), ("blur", "Blur", "eye.slash"),
  ]
}

/// A frame of the recording with the annotation's rectangle; drag across the frame to draw a new one.
struct RectPicker: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: InspectorUI
  let index: Int
  let mark: Annotation

  var body: some View {
    let aspect = (project.plan?.source.width ?? 16) / (project.plan?.source.height ?? 9)
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      let r = CGRect(x: mark.x * w, y: mark.y * h, width: mark.w * w, height: mark.h * h)
      ZStack(alignment: .topLeading) {
        if let img = ui.thumbnail {
          Image(nsImage: img).resizable().frame(width: w, height: h)
        } else {
          Rectangle().fill(Color.black)
        }
        Rectangle().fill(Color.black.opacity(0.35)).frame(width: w, height: h)
          .mask(
            Rectangle().overlay(Rectangle().frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY).blendMode(.destinationOut))
              .compositingGroup())
        RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accent, lineWidth: 2).frame(width: r.width, height: r.height)
          .position(x: r.midX, y: r.midY)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 2).onChanged { v in
          func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x / w, 0), 1), y: min(max(p.y / h, 0), 1)) }
          let a = clamp(v.startLocation), b = clamp(v.location)
          let rect = (x: min(a.x, b.x), y: min(a.y, b.y), w: max(abs(b.x - a.x), 0.01), h: max(abs(b.y - a.y), 0.01))
          func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
          project.apply(coalesce: "rect\(index)") {
            guard $0.annotationList.indices.contains(index) else { return }
            $0.annotationList[index].x = round3(rect.x)
            $0.annotationList[index].y = round3(rect.y)
            $0.annotationList[index].w = round3(rect.w)
            $0.annotationList[index].h = round3(rect.h)
          }
        })
    }
    .aspectRatio(aspect, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
    .onAppear(perform: load)
    .onChange(of: mark.start) { _, _ in load() }
  }

  private func load() {
    let t = mark.start + min(0.5, (mark.end - mark.start) / 2)
    guard abs(ui.thumbnailFor - t) > 0.01 else { return }
    ui.thumbnailFor = t
    project.thumbnail(at: t) { img in ui.thumbnail = img }
  }
}
