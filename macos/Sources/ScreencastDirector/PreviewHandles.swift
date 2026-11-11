import AppKit
import DirectorCore
import SwiftUI

// Boxes over the preview on annotations, titles and the watermark: drag to move, the corner knob to
// size. Where they go comes from the preview's own scene (DirectorCore/PreviewPlacement.swift), so
// an annotation's box follows the zoom.

final class HandleDragUI: ObservableObject {
  /// The box being dragged and where it would land, in output pixels.
  @Published var live: (id: String, rect: CGRect)?
  @Published var hovered: String?
}

struct PreviewHandles: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var playhead: Playhead
  @ObservedObject var drag: HandleDragUI

  /// A box on the frame and the plan change a new box for it stands for.
  struct Item {
    let id: String
    let rect: CGRect
    let selection: Selection?
    let help: String
    /// Annotations size each way; titles and the watermark keep their shape.
    let freeSize: Bool
    let save: (CGRect, inout Plan) -> Void
  }

  var body: some View {
    GeometryReader { geo in
      if let plan = project.plan, let scene = project.previewScene, !project.isPlaying {
        let k = geo.size.width / Double(plan.output.width)
        ForEach(items(plan, scene), id: \.id) { handle($0, k: k) }
      }
    }
    .coordinateSpace(.named("handles"))
  }

  /// Annotations, titles and lower thirds on screen at the playhead, and the watermark.
  private func items(_ plan: Plan, _ scene: DirectorCore.Scene) -> [Item] {
    let f = Int(playhead.frame), t = project.playheadSrc
    var out: [Item] = []
    for (i, a) in (plan.annotations ?? []).enumerated() where t >= a.start && t < a.end {
      guard let r = scene.annotationRect(a, frame: f) else { continue }
      out.append(
        Item(id: "annotation\(i)", rect: r, selection: .annotation(i), help: "Drag to move the \(a.kind), or its corner to size it", freeSize: true
        ) { rect, p in
          guard let list = p.annotations, i < list.count else { return }
          p.annotations?[i] = scene.annotation(list[i], covering: rect, frame: f)
        })
    }
    for (i, c) in plan.callouts.enumerated() where t >= c.start && t < c.end {
      guard let r = scene.calloutRect(c) else { continue }
      out.append(
        Item(id: "callout\(i)", rect: r, selection: .callout(i), help: "Drag to move the title, or its corner to size it", freeSize: false
        ) { rect, p in
          guard i < p.callouts.count else { return }
          p.callouts[i] = scene.callout(p.callouts[i], covering: rect)
        })
    }
    if let r = scene.watermarkRect(frame: f) {
      out.append(
        Item(id: "watermark", rect: r, selection: nil, help: "Drag the logo to another corner, or its corner to size it", freeSize: false
        ) { rect, p in
          if let w = scene.watermark(covering: rect) { p.look?.watermark = w }
        })
    }
    return out
  }

  private func handle(_ item: Item, k: Double) -> some View {
    let dragging = drag.live?.id == item.id
    let rect = dragging ? drag.live!.rect : item.rect
    let selected = item.selection != nil && project.selection == item.selection
    let active = selected || dragging || drag.hovered == item.id
    let center = CGPoint(x: item.rect.midX * k, y: item.rect.midY * k)
    return Rectangle()
      .fill(Color.white.opacity(0.001))
      .overlay(Rectangle().strokeBorder(Color.white.opacity(active ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
      .overlay(alignment: .bottomTrailing) {
        if active {
          Circle().fill(Color.white).frame(width: 14, height: 14).shadow(color: .black.opacity(0.4), radius: 2)
            .offset(x: 7, y: 7)
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .gesture(
              moving(item) { v in
                let r = item.rect
                if item.freeSize {
                  return CGRect(x: r.minX, y: r.minY, width: max(8, r.width + v.translation.width / k), height: max(8, r.height + v.translation.height / k))
                }
                let factor =
                  hypot(v.location.x - center.x, v.location.y - center.y) / max(1, hypot(v.startLocation.x - center.x, v.startLocation.y - center.y))
                return CGRect(x: r.midX - r.width * factor / 2, y: r.midY - r.height * factor / 2, width: r.width * factor, height: r.height * factor)
              }
            )
            .help("Drag to size it")
        }
      }
      .frame(width: rect.width * k, height: rect.height * k)
      .onHover { inside in
        if inside { drag.hovered = item.id } else if drag.hovered == item.id { drag.hovered = nil }
      }
      .pointerStyle(.grabIdle)
      .gesture(moving(item) { v in item.rect.offsetBy(dx: v.translation.width / k, dy: v.translation.height / k) })
      .onTapGesture {
        if let s = item.selection, !selected { project.select(s, adding: false) } else { project.togglePlay() }
      }
      .help(item.help)
      .position(x: rect.midX * k, y: rect.midY * k)
  }

  /// A drag (in the preview's space, so the box moving under the pointer doesn't shift it) that shows
  /// the box `place` gives and saves it, selected, when it ends.
  private func moving(_ item: Item, place: @escaping (DragGesture.Value) -> CGRect) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .named("handles"))
      .onChanged { v in drag.live = (item.id, place(v)) }
      .onEnded { _ in
        if let live = drag.live, live.id == item.id {
          project.apply { item.save(live.rect, &$0) }
          if let s = item.selection, project.selection != s { project.select(s, adding: false) }
        }
        drag.live = nil
      }
  }
}
