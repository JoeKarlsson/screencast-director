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
          .foregroundStyle(on ? Theme.accent : Color.primary)
          .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.04)))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(on ? Theme.accent : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
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
  /// What nil means, shown as "Style (…)".
  let fallback: Motion

  private func label(_ preset: String) -> String { Motion.presets.first { $0.name == preset }?.label ?? preset }

  var body: some View {
    LabeledContent(title) {
      Menu {
        Button("Style Default (\(label(fallback.preset)))") { motion = nil }
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
            Image(systemName: c.icon).font(.system(size: 16))
            Text(c.label).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
          }
          .frame(maxWidth: .infinity, minHeight: 46)
          .foregroundStyle(on ? Theme.accent : Color.primary)
          .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.04)))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(on ? Theme.accent : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    .clipShape(RoundedRectangle(cornerRadius: 6))
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
