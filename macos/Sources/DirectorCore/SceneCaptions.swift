import CoreGraphics
import CoreImage
import CoreText
import Foundation

// Burned-in captions: the current page, its revealed words, emphasis and the box behind them.

extension Scene {
  func drawCaptions(_ ctx: CGContext, _ page: Page, frame f: Double, insets ins: Insets, camBox: Box?, blurred: inout [CIImage]) {
    // A big type chapter says what's being said in its own words: captions step aside for it.
    guard bigChapter(at: f) == nil else { return }
    let fps = Double(plan.output.fps)
    let style = plan.captions.style ?? "pill"
    // Social is bold made for vertical: bigger, and it sits on the seam over the split camera.
    let social = style == "social"
    let bold = plan.captions.isBold
    let boxed = !bold || plan.captions.box == true
    let sizeScale = min(2, max(0.5, plan.captions.size ?? 1))
    let s = NSMutableAttributedString()
    var current: NSRange?
    var wordRanges: [NSRange] = []
    let highlight = look.captionHighlight ?? (style == "pill" ? nil : look.accent ?? "#ffe500")
    let emphasized = Scene.emphasized(page.words.map(\.text), plan.captions.emphasis ?? [])
    for (i, w) in page.words.enumerated() {
      let spoken = f >= w.startF
      let isCurrent = spoken && (i + 1 == page.words.count || f < page.words[i + 1].startF)
      let text = (bold ? w.text.uppercased() : w.text) + (i < page.words.count - 1 ? " " : "")
      var alpha = spoken ? 1.0 : 0.5
      if style == "pop" || bold {
        // Each word appears as it's said, fading in over a few frames.
        alpha = spoken ? min(1, (f - w.startF) / max(1, fps * 0.08)) : 0
      }
      var color = look.captionText ?? "#ffffff"
      if isCurrent, let highlight { color = style == "karaoke" ? Scene.readableOn(highlight) : highlight }
      if emphasized.contains(i), style != "karaoke" || !isCurrent { color = look.captionEmphasis ?? look.accent ?? "#ffe500" }
      let wordRange = NSRange(location: s.length, length: (text as NSString).length - (i < page.words.count - 1 ? 1 : 0))
      wordRanges.append(wordRange)
      if isCurrent { current = wordRange }
      s.append(
        Scene.text(
          text, size: (social ? 92 : bold ? 64 : 42) * sizeScale * (emphasized.contains(i) ? 1.2 : 1) * u, weight: social ? .heavy : bold ? .bold : .semibold, alpha: alpha,
            font: look.captionFont,
          color: color, stroke: social || boxed ? 0 : bold ? 7 : 0))
    }
    // Social captions stay clear of the like and share buttons down the right edge.
    let maxW = social ? W * 0.76 : W * 0.8 - 52 * u
    Scene.shrinkToFitWords(s, wordRanges, maxWidth: maxW)
    let size = Scene.measure(s, maxWidth: maxW)
    let padX = boxed ? (bold ? 30 : 26) * sizeScale * u : 0, padY = boxed ? (bold ? 16 : 12) * sizeScale * u : 0
    let seam = camBox.flatMap { $0.y > 1 && $0.opacity > 0.5 ? $0.y : nil }
    let boxW = size.width + 2 * padX, boxH = size.height + 2 * padY
    // Dragged somewhere: centered on that point, kept inside the frame.
    let centerX = plan.captions.x.map { min(W - boxW / 2, max(boxW / 2, $0 * W)) } ?? W / 2
    let top =
      plan.captions.y.map { min(H - boxH, max(0, $0 * H - boxH / 2)) }
      ?? (social
        ? (seam.map { $0 - size.height / 2 } ?? H * 0.64)
        : H - (ins.fullBleed ? ins.safe : H * 0.07) - size.height - (bold ? 40 : 24) * u)
    let rect = CGRect(x: centerX - boxW / 2, y: top, width: boxW, height: boxH)
    let pose =
      motion.name == "classic"
      ? .full
      : Motion.pose(
        frame: f, start: page.startF, end: page.endF + fps * 0.4, fps: Int(fps), enter: Motion(preset: bold ? "pop" : "fade-up", seconds: 0.16, ease: "smooth"),
        exit: Motion(preset: "fade", seconds: 0.12, ease: "ease-in"), style: motion)
    let fill =
      boxed ? Scene.color(look.captionBackground ?? "#0a0a0e").copy(alpha: look.captionBackgroundOpacity ?? 0.78)! : CGColor(gray: 0, alpha: 0)
    let mark = style == "karaoke" ? current.map { ($0, Scene.color(highlight ?? "#ffe500")) } : nil
    animated(ctx, rect, pose, blurred: &blurred) { g in
      // Social captions read over a face or a busy screen through shadows, not a stroke: stroking the
      // heavy system font outlines its overlapping glyph parts, which shows as lines inside the letters.
      // A soft dark halo first, then the same words again with a hard ink drop.
      // In a box the text needs neither.
      if social && !boxed {
        g.setShadow(offset: .zero, blur: 18 * self.u, color: CGColor(gray: 0, alpha: 0.75))
        self.pill(g, s, centerX: centerX, top: top, padX: padX, padY: padY, radius: 14 * self.u, fill: fill, maxWidth: maxW, mark: mark)
        g.setShadow(offset: CGSize(width: 0, height: -7 * self.u), blur: 0, color: Scene.color("#15151C"))
      }
      self.pill(g, s, centerX: centerX, top: top, padX: padX, padY: padY, radius: 14 * self.u, fill: fill, maxWidth: maxW, mark: mark)
    }
  }
}
