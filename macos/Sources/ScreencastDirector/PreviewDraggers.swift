import AVKit
import AppKit
import DirectorCore
import SwiftUI

// Dragging captions and the camera bubble around in the preview.

/// Over the preview: a handle where the captions sit, to drag them anywhere. An outline follows the
/// pointer; the plan changes once, when the drag ends (`captions.x`/`y`).
struct CaptionDragger: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var playhead: Playhead
  @ObservedObject var drag: BubbleDragUI

  var body: some View {
    GeometryReader { geo in
      if let plan = project.plan, plan.captions.enabled {
        let center = captionCenter(plan)
        let d = drag.offset ?? .zero
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        shape
          .fill(Color.white.opacity(0.001))
          .overlay(shape.strokeBorder(Color.white.opacity(drag.offset == nil ? 0 : 0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
          .frame(width: geo.size.width * 0.7, height: geo.size.height * (plan.output.height > plan.output.width ? 0.09 : 0.12))
          .position(x: center.x * geo.size.width + d.width, y: center.y * geo.size.height + d.height)
          .pointerStyle(.grabIdle)
          .gesture(
            DragGesture(minimumDistance: 2)
              .onChanged { v in drag.offset = v.translation }
              .onEnded { v in
                drag.offset = nil
                let x = min(1, max(0, center.x + v.translation.width / geo.size.width))
                let y = min(1, max(0, center.y + v.translation.height / geo.size.height))
                project.apply { p in
                  p.captions.x = (x * 1000).rounded() / 1000
                  p.captions.y = (y * 1000).rounded() / 1000
                }
              }
          )
          .help("Drag to move the captions")
      }
    }
  }

  /// Where the captions are centered now, as fractions of the frame: the dragged place, else about
  /// where the style puts them (the seam of a vertical split for social, else the bottom).
  private func captionCenter(_ plan: Plan) -> (x: Double, y: Double) {
    _ = playhead.frame
    if let y = plan.captions.y { return (plan.captions.x ?? 0.5, y) }
    guard plan.captions.style == "social" else { return (0.5, 0.88) }
    let t = project.playheadSrc
    let mode = plan.layouts.last { $0.start <= t && t < $0.end }?.mode ?? plan.defaultLayout
    if mode != .camera, let seam = socialTop(plan) { return (0.5, seam / Double(plan.output.height)) }
    return (0.5, 0.68)
  }
}

final class BubbleDragUI: ObservableObject {
  @Published var offset: CGSize?
}

/// Over the preview: a handle on the camera bubble while the bubble is showing, to drag it anywhere.
/// An outline follows the pointer; the plan changes once, when the drag ends.
struct BubbleDragger: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var playhead: Playhead
  @ObservedObject var drag: BubbleDragUI

  var body: some View {
    GeometryReader { geo in
      if let plan = project.plan, plan.camera != nil, plan.output.height <= plan.output.width, showingBubble(plan) {
        let k = geo.size.width / Double(plan.output.width)
        let b = layoutBoxes(.pip, plan: plan).cam
        let d = drag.offset ?? .zero
        let shape = RoundedRectangle(cornerRadius: min(b.r, b.w / 2) * k, style: .continuous)
        shape
          .fill(Color.white.opacity(0.001))
          .overlay(shape.strokeBorder(Color.white.opacity(drag.offset == nil ? 0 : 0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
          .frame(width: b.w * k, height: b.h * k)
          .position(x: (b.x + b.w / 2) * k + d.width, y: (b.y + b.h / 2) * k + d.height)
          .pointerStyle(.grabIdle)
          .gesture(
            DragGesture(minimumDistance: 2)
              .onChanged { v in drag.offset = v.translation }
              .onEnded { v in
                drag.offset = nil
                let start = bubblePlacement(plan)
                let x = min(1, max(0, start.x + v.translation.width / geo.size.width))
                let y = min(1, max(0, start.y + v.translation.height / geo.size.height))
                project.apply { p in
                  p.camera?.bubbleX = (x * 1000).rounded() / 1000
                  p.camera?.bubbleY = (y * 1000).rounded() / 1000
                }
              }
          )
          .help("Drag to move the camera bubble")
      }
    }
  }

  /// Whether the layout at the playhead shows the bubble.
  private func showingBubble(_ plan: Plan) -> Bool {
    _ = playhead.frame
    let t = project.playheadSrc
    return (plan.layouts.last { $0.start <= t && t < $0.end }?.mode ?? plan.defaultLayout) == .pip
  }
}

final class PlaceDragUI: ObservableObject {
  /// Where the sticker or overlay being dragged would land.
  @Published var live: PlacedItem?
  /// It and its box when the drag began.
  var start: (item: PlacedItem, box: PlacedItem.Box)?
  /// Pictures' and clips' sizes, by file, for stickers' boxes.
  @Published private var sizes: [String: CGSize] = [:]
  private var reading: Set<String> = []

  /// A file's size, read in the background the first time it's asked for (nil until then, and
  /// asked again later while an animation's clip isn't rendered yet).
  func size(_ file: String, dir: URL) -> CGSize? {
    if let s = sizes[file] { return s }
    guard !reading.contains(file) else { return nil }
    reading.insert(file)
    Task { @MainActor in
      let s = await PlacedItem.mediaSize(of: file, dir: dir)
      reading.remove(file)
      if let s { sizes[file] = s }
    }
    return nil
  }
}

/// Over the preview: a box on each sticker on screen, and on the selected overlay, to click to
/// select it and drag to move it. The selected one gets a corner knob to size it (bottom right) and
/// one to turn it (top right). An outline follows the pointer; the plan changes once, when the drag ends.
struct PlacementDragger: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var playhead: Playhead
  @ObservedObject var drag: PlaceDragUI

  var body: some View {
    GeometryReader { geo in
      if let plan = project.plan {
        let k = geo.size.width / Double(plan.output.width)
        ForEach(Array(shown(plan).enumerated()), id: \.offset) { _, shown in
          handle(shown.item, shown.box, plan: plan, k: k)
        }
      }
    }
    .coordinateSpace(.named("placer"))
  }

  /// Stickers on screen at the playhead, and the selected overlay when it is, each with its box.
  private func shown(_ plan: Plan) -> [(item: PlacedItem, box: PlacedItem.Box)] {
    _ = playhead.frame
    let t = project.playheadSrc
    return plan.placedItems(dir: project.dir).compactMap { found in
      guard t >= found.start, t < found.end, found.isSticker || project.selection == found.selection else { return nil }
      let item = drag.live?.selection == found.selection ? drag.live! : found
      return item.box(in: plan, mediaSize: item.isSticker ? drag.size(item.file, dir: project.dir) : nil).map { (item, $0) }
    }
  }

  private func handle(_ item: PlacedItem, _ box: PlacedItem.Box, plan: Plan, k: Double) -> some View {
    let selected = project.selection == item.selection
    let outlined = selected || drag.live?.selection == item.selection
    let center = CGPoint(x: box.center.x * k, y: box.center.y * k)
    return Rectangle()
      .fill(Color.white.opacity(0.001))
      .overlay(Rectangle().strokeBorder(Color.white.opacity(outlined ? 0.9 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
      .overlay(alignment: .bottomTrailing) {
        if selected {
          knob.offset(x: 7, y: 7)
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .gesture(
              dragging(item, box) { start, v in
                let factor =
                  hypot(v.location.x - center.x, v.location.y - center.y) / max(1, hypot(v.startLocation.x - center.x, v.startLocation.y - center.y))
                return start.item.sized(by: factor, from: start.box, in: plan)
              }
            )
            .help("Drag to size it")
        }
      }
      .overlay(alignment: .topTrailing) {
        if selected {
          knob.overlay(Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .bold)).foregroundStyle(.black))
            .offset(x: 7, y: -7)
            .gesture(
              dragging(item, box) { start, v in
                let angle = atan2(v.location.y - center.y, v.location.x - center.x) - atan2(v.startLocation.y - center.y, v.startLocation.x - center.x)
                return start.item.turned(to: start.item.rotation + angle * 180 / .pi, from: start.box, in: plan)
              }
            )
            .help("Drag to turn it")
        }
      }
      .frame(width: box.size.width * k, height: box.size.height * k)
      .pointerStyle(.grabIdle)
      .gesture(
        dragging(item, box) { start, v in
          start.item.moved(by: CGSize(width: v.translation.width / k, height: v.translation.height / k), from: start.box, in: plan)
        }
      )
      .onTapGesture { selected ? project.togglePlay() : project.select(item.selection, adding: false) }
      .help("Drag to move it")
      .rotationEffect(.degrees(box.rotation))
      .position(center)
  }

  private var knob: some View {
    Circle().fill(Color.white).frame(width: 14, height: 14).shadow(color: .black.opacity(0.4), radius: 2)
  }

  /// A drag (in the preview's own space, so a turned box doesn't turn the pointer) that shows where
  /// `place` would put the item and saves that, selected, when it ends.
  private func dragging(
    _ item: PlacedItem, _ box: PlacedItem.Box, place: @escaping ((item: PlacedItem, box: PlacedItem.Box), DragGesture.Value) -> PlacedItem
  ) -> some Gesture {
    DragGesture(minimumDistance: 2, coordinateSpace: .named("placer"))
      .onChanged { v in
        if drag.start == nil { drag.start = (item, box) }
        if let start = drag.start { drag.live = place(start, v) }
      }
      .onEnded { _ in
        if let live = drag.live {
          project.apply { $0.place(live) }
          if project.selection != live.selection { project.select(live.selection, adding: false) }
        }
        drag.live = nil
        drag.start = nil
      }
  }
}
