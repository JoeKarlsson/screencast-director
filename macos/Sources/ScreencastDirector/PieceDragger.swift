import DirectorCore
import SwiftUI

/// The preview's sticker and overlay handles, or, while arranging an animation's text pieces (the
/// animation inspector's Arrange Text), the pieces' handles instead, so a drag has one meaning.
struct PlacementLayer: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var live: LiveAnimationPreview
  let placeDrag: PlaceDragUI
  let pieceDrag: PieceDragUI

  var body: some View {
    if live.arranging, case .animation = project.selection {
      PieceDragger(project: project, live: live, drag: pieceDrag)
    } else {
      PlacementDragger(project: project, playhead: project.playhead, drag: placeDrag)
    }
  }
}

/// The inspector's switch for arranging the selected animation's text in the preview, and a way back
/// to the template's own layout.
struct ArrangeTextSection: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var live: LiveAnimationPreview
  let index: Int
  let placed: Bool

  var body: some View {
    InspectorSection("Text Placement", detail: "Pause inside the animation, then drag its text in the preview. The corner knob sizes it.") {
      Button {
        live.arranging.toggle()
      } label: {
        Label(live.arranging ? "Done Arranging" : "Arrange Text", systemImage: live.arranging ? "checkmark" : "character.cursor.ibeam")
          .frame(maxWidth: .infinity)
      }
      .help(live.arranging ? "Go back to dragging the whole sticker" : "Drag the animation's headings, labels and words in the preview instead of the whole sticker")
      if placed {
        Button("Reset Text Placement") { project.editAnimation(index) { $0.layout = nil } }
          .help("Put the text back where the template places it")
      }
    }
  }
}

/// The text piece being dragged: how far it has moved (preview points) and how much it has grown.
final class PieceDragUI: ObservableObject {
  @Published var live: (name: String, move: CGSize, factor: Double)?
}

/// A box on each text piece of the selected animation's live frame: drag it to move the piece, the
/// corner knob to size it. The outline follows the pointer; the plan changes once, when the drag
/// ends (the animation's `layout`), and the live frame redraws from it.
struct PieceDragger: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var live: LiveAnimationPreview
  @ObservedObject var drag: PieceDragUI

  var body: some View {
    GeometryReader { geo in
      if !project.isPlaying, let shown = live.shown, project.selection == .animation(shown.index), let plan = project.plan,
        let clip = plan.clipOnFrame(animation: shown.index, clipSize: shown.clipSize, dir: project.dir)
      {
        let k = geo.size.width / Double(plan.output.width)
        ForEach(shown.pieces.keys.sorted(), id: \.self) { name in
          if let piece = shown.pieces[name] { handle(name, clip.box(piece), clip: clip, index: shown.index, k: k) }
        }
      }
    }
    .coordinateSpace(.named("pieces"))
  }

  private func handle(_ name: String, _ box: PlacedItem.Box, clip: ClipOnFrame, index: Int, k: Double) -> some View {
    let dragging = drag.live?.name == name ? drag.live : nil
    let center = CGPoint(x: box.center.x * k, y: box.center.y * k)
    let factor = dragging?.factor ?? 1
    return Rectangle()
      .fill(Color.white.opacity(0.001))
      .overlay(Rectangle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
      .overlay(alignment: .bottomTrailing) {
        Circle().fill(Color.white).frame(width: 14, height: 14).shadow(color: .black.opacity(0.4), radius: 2)
          .offset(x: 7, y: 7)
          .pointerStyle(.frameResize(position: .bottomTrailing))
          .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("pieces"))
              .onChanged { v in
                let grown = hypot(v.location.x - center.x, v.location.y - center.y) / max(1, hypot(v.startLocation.x - center.x, v.startLocation.y - center.y))
                drag.live = (name, .zero, grown)
              }
              .onEnded { _ in commit(index, clip, k) }
          )
          .help("Drag to size it")
      }
      .frame(width: box.size.width * k * factor, height: box.size.height * k * factor)
      .pointerStyle(.grabIdle)
      .gesture(
        DragGesture(minimumDistance: 2, coordinateSpace: .named("pieces"))
          .onChanged { v in drag.live = (name, v.translation, 1) }
          .onEnded { _ in commit(index, clip, k) }
      )
      .help("Drag to move \(name)")
      .rotationEffect(.degrees(box.rotation))
      .position(x: center.x + (dragging?.move.width ?? 0), y: center.y + (dragging?.move.height ?? 0))
  }

  /// Saves the drag as the piece's layout: the move in output pixels becomes shares of the clip's width.
  private func commit(_ index: Int, _ clip: ClipOnFrame, _ k: Double) {
    guard let done = drag.live else { return }
    drag.live = nil
    let move = clip.layoutMove(CGSize(width: done.move.width / k, height: done.move.height / k))
    project.apply { $0.movePiece(done.name, ofAnimation: index, by: move, sizedBy: done.factor) }
  }
}
