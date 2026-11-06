import CoreGraphics
import CoreText
import Foundation

// Big type chapters (look.chapterStyle "big"), after joekarlsson.com's hero: a black block rises
// under the picture, the chapter's words fill it in huge type, its label sits on the block's edge
// in a chip, and crayon rays and a coil draw in. The block drops away at the end.

extension Scene {
  /// The block's share of the frame's height.
  static let bigChapterBlock = 0.38

  /// The visible big chapter at an output frame, if any.
  func bigChapter(at f: Double) -> (s: Double, e: Double, c: Callout)? {
    guard look.chapterStyle == "big" else { return nil }
    return callouts.last { $0.c.style == "chapter" && f >= $0.s && f < $0.e }
  }

  /// How far the block is up at `f` (0 down, 1 fully risen): up over 0.35 s, down over the last 0.3 s.
  func bigChapterRise(_ ch: (s: Double, e: Double, c: Callout), at f: Double) -> Double {
    let fps = Double(plan.output.fps)
    let t = (f - ch.s) / fps, left = (ch.e - f) / fps
    let up = 1 - pow(1 - min(1, max(0, t / 0.35)), 3)
    let down = min(1, max(0, (0.3 - left) / 0.3))
    return up * (1 - down * down)
  }

  /// The top of the block at `f` (top-left coordinates), for captions to stay above; nil without one.
  func bigChapterTop(at f: Double) -> Double? {
    guard let ch = bigChapter(at: f) else { return nil }
    return H - H * Scene.bigChapterBlock * bigChapterRise(ch, at: f)
  }

  func drawBigChapter(_ ctx: CGContext, _ ch: (s: Double, e: Double, c: Callout), frame f: Double) {
    let fps = Double(plan.output.fps)
    let t = (f - ch.s) / fps
    let rise = bigChapterRise(ch, at: f)
    guard rise > 0.001 else { return }
    let blockH = H * Scene.bigChapterBlock
    let top = H - blockH * rise
    let accent = Scene.color(look.accent ?? "#FF4FD8")
    ctx.setFillColor(Scene.color(look.chipBackground ?? "#000000"))
    ctx.fill(CGRect(x: 0, y: top, width: W, height: H - top + 1))

    // The words: as big as two lines across the frame allow.
    let left = W * 0.05, maxW = W * 0.9
    var size = blockH * 0.4
    var words = Scene.text(ch.c.text.uppercased(), size: size, weight: .bold, font: look.titleFont, color: look.captionText ?? "#EDEDED", align: .left)
    var measured = Scene.measure(words, maxWidth: maxW)
    for _ in 0..<12 where measured.height > blockH * 0.78 || measured.width > maxW {
      size *= 0.9
      words = Scene.text(ch.c.text.uppercased(), size: size, weight: .bold, font: look.titleFont, color: look.captionText ?? "#EDEDED", align: .left)
      measured = Scene.measure(words, maxWidth: maxW)
    }
    let textTop = top + blockH * 0.1
    let shown = min(1, max(0, (t - 0.15) / 0.25))
    if shown > 0 {
      ctx.saveGState()
      ctx.setAlpha(shown)
      drawText(ctx, words, at: CGPoint(x: left, y: textTop + (1 - (1 - pow(1 - shown, 3))) * blockH * 0.08), size: measured)
      ctx.restoreGState()
    }

    let boil = Int(t * 6)
    // Rays over the end of the first line, a coil under the words.
    let raysW = W * 0.2, raysRect = CGRect(x: min(left + measured.width - raysW * 0.2, W - raysW * 1.05), y: textTop - raysW * 0.55, width: raysW, height: raysW * 0.75)
    let rays = Scribble.rays
    rays.draw(ctx, in: raysRect, color: accent, lineWidth: max(4 * u, 9 * raysW / rays.size.width),
      shares: rays.shares(min(1, max(0, (t - 0.4) / 0.35))), boil: boil)
    let coilW = min(W * 0.8, measured.width * 1.05), coilRect = CGRect(x: left - W * 0.01, y: textTop + measured.height - coilW * 0.12, width: coilW, height: coilW / 3)
    let coil = Scribble.coil
    coil.draw(ctx, in: coilRect, color: accent, lineWidth: max(4 * u, 8 * coilW / coil.size.width),
      shares: coil.shares(min(1, max(0, (t - 0.5) / 0.7))), boil: boil)

    // The label ("Step 1") in a chip on the block's top edge, popping in.
    if let label = ch.c.subtitle, !label.isEmpty {
      let pop = min(1, max(0, (t - 0.25) / 0.2))
      guard pop > 0 else { return }
      let s = Scene.text(label.uppercased(), size: 52 * u, weight: .bold, font: look.titleFont, color: look.titleText ?? "#000000")
      let ls = Scene.measure(s, maxWidth: W)
      let padX = 26 * u, padY = 12 * u
      let rect = CGRect(x: left, y: top - (ls.height + 2 * padY) * 0.6, width: ls.width + 2 * padX, height: ls.height + 2 * padY)
      ctx.saveGState()
      ctx.translateBy(x: rect.midX, y: rect.midY)
      let k = pop < 1 ? 0.6 + 0.5 * pop - 0.1 * pop * pop : 1
      ctx.scaleBy(x: k, y: k)
      ctx.translateBy(x: -rect.midX, y: -rect.midY)
      ctx.setFillColor(Scene.color(look.titleBackground ?? (look.accent ?? "#FF4FD8")))
      ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil))
      ctx.fillPath()
      drawText(ctx, s, at: CGPoint(x: rect.minX + padX, y: rect.minY + padY), size: ls)
      ctx.restoreGState()
    }
  }
}
