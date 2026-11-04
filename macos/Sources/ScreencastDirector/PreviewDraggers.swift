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
