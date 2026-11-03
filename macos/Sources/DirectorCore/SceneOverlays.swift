import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Vision

// What Scene draws over the screen and camera: titles, captions, annotations, B-roll, privacy blurs
// and cut transitions.
extension Scene {
  // MARK: Overlays (CoreGraphics + CoreText, drawn in top-left coordinates)

  func overlays(frame f: Double, screen b: Box, cam: CameraState, camBox: Box?) -> CIImage? {
    let fps = Double(plan.output.fps)
    let page = pages.first { f >= $0.startF && f < $0.endF + fps * 0.4 }
    // Screen marks (cursor, clicks, key chips, annotations, the camera border) belong under an animation.
    let covered = fullFrameCovers(f)
    // An animation or picture filling the screen card hides the screen's marks too, but not the camera's border.
    let screenHidden = covered || cardCovers(f)
    let chip = screenHidden ? nil : chips.last { f >= $0.f && f < $0.f + fps * 1.2 }
    let shownCallouts = callouts.filter { f >= $0.s && f < $0.e }
    let shownMarks = b.opacity > 0.01 && !screenHidden ? annotations.filter { f >= $0.s && f < $0.e && $0.a.kind != "blur" } : []
    let ripples = screenHidden ? [] : clicks.filter { f >= $0.f && f <= $0.f + fps * 0.5 }
    // A cutout has no shape to outline, and a full-frame animation hides the bubble it would outline.
    let border = !covered && plan.camera?.cutout != true && plan.camera?.bubbleBorder != false && (camBox.map { $0.opacity > 0.01 } ?? false)
    let ins = insets(plan)
    let brackets = look.frame == "brackets" && (ins.fullBleed || b.opacity > 0.01)
    let pointerAt = b.opacity > 0.01 && !screenHidden ? cursorPosition(frame: f) : nil
    if page == nil && chip == nil && shownCallouts.isEmpty && shownMarks.isEmpty && ripples.isEmpty && !border && !brackets
      && watermark == nil && pointerAt == nil
    {
      return nil
    }

    guard let ctx = Scene.context(Int(W), Int(H)) else { return nil }
    // Flip to top-left coordinates like the CSS version; text is unflipped per draw.
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    /// Overlays mid-blur are drawn on their own and blurred with Core Image, above the rest.
    var blurred: [CIImage] = []

    if b.opacity > 0.01, !ripples.isEmpty {
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), cornerWidth: b.r, cornerHeight: b.r, transform: nil))
      ctx.clip()
      for c in ripples {
        let age = (f - c.f) / (fps * 0.5)
        let (k, tx, ty) = screenMap(b, cam)
        let cx = tx + k * c.x * plan.source.width
        let cy = ty + k * c.y * plan.source.height
        // Sized like the CSS version: px inside the zoomed card, so they grow with the zoom.
        let d = (18 + age * 50) * u * cam.scale
        let rect = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        let accent = Scene.color(look.accent ?? "#78a0ff")
        ctx.setFillColor(accent.copy(alpha: 0.25 * (1 - age))!)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(look.accent == nil ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9 * (1 - age)) : accent.copy(alpha: 0.9 * (1 - age))!)
        ctx.setLineWidth(3 * u)
        ctx.strokeEllipse(in: rect)
      }
      ctx.restoreGState()
    }

    if !shownMarks.isEmpty {
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), cornerWidth: b.r, cornerHeight: b.r, transform: nil))
      ctx.clip()
      for m in shownMarks { drawAnnotation(ctx, m.a, frame: f, start: m.s, end: m.e, screen: b, cam: cam, blurred: &blurred) }
      ctx.restoreGState()
    }

    if let p = pointerAt {
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: CGRect(x: b.x, y: b.y, width: b.w, height: b.h), cornerWidth: b.r, cornerHeight: b.r, transform: nil))
      ctx.clip()
      let (k, tx, ty) = screenMap(b, cam)
      drawCursor(ctx, at: CGPoint(x: tx + k * p.x * plan.source.width, y: ty + k * p.y * plan.source.height),
        height: (plan.cursor?.size ?? 32) * u * cam.scale * p.pulse)
      ctx.restoreGState()
    }

    if let cb = camBox, border {
      let r = min(cb.r, min(cb.w, cb.h) / 2)
      ctx.setStrokeColor(Scene.color(look.cameraBorder ?? "#ffffff").copy(alpha: 0.85 * cb.opacity)!)
      ctx.setLineWidth(3 * u)
      ctx.addPath(
        CGPath(
          roundedRect: CGRect(x: cb.x, y: cb.y, width: cb.w, height: cb.h).insetBy(dx: 1.5 * u, dy: 1.5 * u),
          cornerWidth: max(0, r - 1.5 * u), cornerHeight: max(0, r - 1.5 * u), transform: nil))
      ctx.strokePath()
    }

    for c in shownCallouts {
      let pose = Motion.pose(frame: f, start: c.s, end: c.e, fps: Int(fps), enter: c.c.enter, exit: c.c.exit, style: motion)
      drawCallout(ctx, c.c, pose: pose, insets: ins, screen: b, blurred: &blurred)
    }
    if let chip {
      let pose = Motion.pose(
        frame: f, start: chip.f, end: chip.f + fps * 1.2, fps: Int(fps),
        enter: motion.name == "classic" ? Motion(preset: "none") : Motion(preset: "pop", seconds: 0.25, ease: "spring"),
        exit: motion.name == "classic" ? Motion(preset: "none") : Motion(preset: "fade", seconds: 0.2, ease: "ease-in"), style: motion)
      let s = Scene.text(chip.label, size: 44 * u, weight: .semibold, kern: 4 * u, font: look.chipFont, color: look.chipText ?? "#ffffff")
      let size = Scene.measure(s, maxWidth: W)
      let padX = 22 * u, padY = 10 * u
      let top = H - H * 0.2 - size.height - 20 * u
      let rect = CGRect(x: W / 2 - size.width / 2 - padX, y: top, width: size.width + 2 * padX, height: size.height + 2 * padY)
      animated(ctx, rect, pose, blurred: &blurred) { c in
        self.pill(
          c, s, centerX: self.W / 2, top: top, padX: padX, padY: padY, radius: 12 * self.u,
          fill: Scene.color(self.look.chipBackground ?? "#0f0f14").copy(alpha: 0.88)!)
      }
    }
    if let page { drawCaptions(ctx, page, frame: f, insets: ins, camBox: camBox, blurred: &blurred) }
    if brackets {
      // Full bleed: the brackets frame the whole picture at the margin. Padded: they hug the screen card.
      if ins.fullBleed {
        let m = ins.margin, t = ins.bracket
        drawBrackets(ctx, Box(x: m + t + 10 * u, y: m + t + 10 * u, w: W - 2 * (m + t + 10 * u), h: H - 2 * (m + t + 10 * u), r: 24 * u, opacity: 1))
      } else {
        drawBrackets(ctx, b)
      }
    }
    // In the portrait split the logo would sit on the screen card's edge; it shows over the camera.
    if let watermark, let w = look.watermark, !(socialTop(plan) != nil && b.opacity > 0.5) { drawWatermark(ctx, watermark, w) }

    guard let cg = ctx.makeImage() else { return nil }
    return blurred.reduce(CIImage(cgImage: cg)) { $1.composited(over: $0) }
  }

  static func context(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(
      data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  }

  // MARK: Animated overlays

  /// Draws `draw` (top-left frame coordinates) posed: faded, moved, scaled about `rect`'s center
  /// and wiped. Mid-blur, it's drawn into its own layer and blurred into `blurred` instead.
  func animated(_ ctx: CGContext, _ rect: CGRect, _ pose: OverlayPose, blurred: inout [CIImage], _ draw: (CGContext) -> Void) {
    guard pose.visible else { return }
    func apply(_ c: CGContext) {
      c.setAlpha(min(1, pose.opacity))
      c.translateBy(x: rect.midX + pose.dx * rect.width, y: rect.midY + pose.dy * rect.height)
      c.scaleBy(x: pose.scale, y: pose.scale)
      c.translateBy(x: -rect.midX, y: -rect.midY)
      if pose.reveal < 0.999 { c.clip(to: CGRect(x: rect.minX, y: rect.minY - 4 * u, width: rect.width * pose.reveal, height: rect.height + 8 * u)) }
    }
    if pose.blur * u < 0.5 {
      ctx.saveGState()
      apply(ctx)
      draw(ctx)
      ctx.restoreGState()
      return
    }
    // A layer just big enough for the posed overlay and its blur.
    let pad = pose.blur * u * 3 + 8 * u
    let grown = rect.applying(
      CGAffineTransform(translationX: -rect.midX, y: -rect.midY).scaledBy(x: pose.scale, y: pose.scale)
        .translatedBy(x: rect.midX / pose.scale + pose.dx * rect.width / pose.scale, y: rect.midY / pose.scale + pose.dy * rect.height / pose.scale)
    ).union(rect).insetBy(dx: -pad, dy: -pad).integral
    guard let layer = Scene.context(Int(grown.width), Int(grown.height)) else { return }
    layer.translateBy(x: 0, y: grown.height)
    layer.scaleBy(x: 1, y: -1)
    layer.translateBy(x: -grown.minX, y: -grown.minY)
    apply(layer)
    draw(layer)
    guard let cg = layer.makeImage() else { return }
    let img = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: grown.minX, y: H - grown.maxY))
    blurred.append(img.applyingGaussianBlur(sigma: pose.blur * u / 2).cropped(to: img.extent.insetBy(dx: -pad, dy: -pad)))
  }

  /// Text with only the first `share` of it shown (by word or by character); the hidden part keeps
  /// its space so the layout doesn't move as it types.
  static func revealed(_ s: NSAttributedString, share: Double, byWord: Bool) -> NSAttributedString {
    guard share < 0.999 else { return s }
    let str = s.string as NSString
    var cut = Int((Double(str.length) * share).rounded(.down))
    if byWord {
      let words = s.string.split(separator: " ", omittingEmptySubsequences: false)
      let shown = Int((Double(words.count) * share).rounded(.up))
      cut = min(str.length, words.prefix(shown).map { ($0 as Substring).utf16.count + 1 }.reduce(0, +))
    }
    let out = NSMutableAttributedString(attributedString: s)
    if cut < str.length {
      let key = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
      out.addAttribute(key, value: CGColor(gray: 0, alpha: 0), range: NSRange(location: cut, length: str.length - cut))
    }
    return out
  }

  func drawCallout(_ ctx: CGContext, _ c: Callout, pose: OverlayPose, insets ins: Insets, screen b: Box, blurred: inout [CIImage]) {
    let preset = c.enter?.preset ?? motion.enter.preset
    let byWord = preset == "words"
    let typing = byWord || preset == "typewriter"
    func reveal(_ s: NSAttributedString) -> NSAttributedString { typing ? Scene.revealed(s, share: pose.text, byWord: byWord) : s }
    let accent = look.accent ?? "#78a0ff"
    let panel = Scene.color(look.titleBackground ?? "#0f0f14").copy(alpha: look.titleBackground == nil ? 0.88 : 1)!
    let titleColor = look.titleText ?? "#ffffff"
    switch c.style ?? "title" {
    case "lower-third":
      let title = Scene.text(c.text, size: 46 * u, weight: .bold, font: look.titleFont, color: titleColor, align: .left)
      let sub = c.subtitle.map { Scene.text($0, size: 30 * u, weight: .semibold, alpha: 0.8, font: look.captionFont, color: titleColor, align: .left) }
      let maxW = W * 0.6
      let ts = Scene.measure(title, maxWidth: maxW)
      let ss = sub.map { Scene.measure($0, maxWidth: maxW) } ?? .zero
      let bar = 8 * u, padX = 28 * u, padY = 18 * u, gap = sub == nil ? 0 : 6 * u
      let w = max(ts.width, ss.width) + 2 * padX + bar
      let h = ts.height + ss.height + gap + 2 * padY
      let x = ins.fullBleed ? ins.safe : max(ins.safe, plan.style.padding * min(W, H) + 24 * u)
      let rect = CGRect(x: x, y: H * 0.74 - h, width: w, height: h)
      animated(ctx, rect, pose, blurred: &blurred) { g in
        g.setFillColor(panel)
        g.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * self.u, cornerHeight: 12 * self.u, transform: nil))
        g.fillPath()
        g.setFillColor(Scene.color(accent))
        g.fill(CGRect(x: rect.minX, y: rect.minY + 10 * self.u, width: bar, height: rect.height - 20 * self.u))
        self.drawText(g, reveal(title), at: CGPoint(x: rect.minX + bar + padX, y: rect.minY + padY), size: ts)
        if let sub { self.drawText(g, reveal(sub), at: CGPoint(x: rect.minX + bar + padX, y: rect.minY + padY + ts.height + gap), size: ss) }
      }
    case "chapter" where socialTop(plan) != nil:
      // Portrait: a chip on the screen card ("STEP 1  Find the plugin") instead of a full-frame card.
      let label = c.subtitle.map { Scene.text($0.uppercased() + "  ", size: 30 * u, weight: .bold, kern: 3 * u, font: look.captionFont, color: titleColor) }
      let title = Scene.text(c.text, size: 50 * u, weight: .bold, font: look.titleFont, color: titleColor)
      let s = NSMutableAttributedString()
      if let label { s.append(label) }
      s.append(title)
      let size = Scene.measure(s, maxWidth: W * 0.8)
      let padX = 28 * u, padY = 12 * u
      let origin = b.opacity > 0.5 ? CGPoint(x: b.x + 30 * u, y: b.y + 30 * u) : CGPoint(x: ins.margin, y: ins.margin * 2)
      let rect = CGRect(x: origin.x, y: origin.y, width: size.width + 2 * padX, height: size.height + 2 * padY)
      animated(ctx, rect, pose, blurred: &blurred) { g in
        g.setFillColor(Scene.color(self.look.titleBackground ?? accent))
        g.addPath(CGPath(roundedRect: rect, cornerWidth: 14 * self.u, cornerHeight: 14 * self.u, transform: nil))
        g.fillPath()
        self.drawText(g, reveal(s), at: CGPoint(x: rect.minX + padX, y: rect.minY + padY), size: size)
      }
    case "slate", "chapter":
      let chapter = c.style == "chapter"
      // The scrim only fades; the text does the moving. It's dark enough to read over a busy screen.
      ctx.setFillColor(CGColor(gray: 0, alpha: (chapter ? 0.72 : 0.62) * min(1, pose.opacity)))
      ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
      let title = Scene.text(c.text, size: (chapter ? 76 : 92) * u, weight: .bold, font: look.titleFont, color: "#ffffff")
      let label = c.subtitle.map {
        Scene.text(chapter ? $0.uppercased() : $0, size: (chapter ? 28 : 38) * u, weight: .semibold, kern: chapter ? 5 * u : 0,
          font: look.captionFont, color: chapter ? accent : "#ffffff")
      }
      let maxW = W * 0.8
      let ts = Scene.measure(title, maxWidth: maxW)
      let ls = label.map { Scene.measure($0, maxWidth: maxW) } ?? .zero
      let gap = 22 * u, barH = 7 * u
      let total = ts.height + (label == nil ? 0 : ls.height + gap) + (chapter ? gap + barH : 0)
      let top = (H - total) / 2
      let rect = CGRect(x: (W - max(ts.width, ls.width)) / 2, y: top, width: max(ts.width, ls.width), height: total)
      animated(ctx, rect, pose, blurred: &blurred) { g in
        var y = top
        if chapter, let label {
          self.drawText(g, label, at: CGPoint(x: (self.W - ls.width) / 2, y: y), size: ls)
          y += ls.height + gap
        }
        self.drawText(g, reveal(title), at: CGPoint(x: (self.W - ts.width) / 2, y: y), size: ts)
        y += ts.height + gap
        if chapter {
          g.setFillColor(Scene.color(accent))
          g.fill(CGRect(x: (self.W - 96 * self.u) / 2, y: y, width: 96 * self.u, height: barH))
        } else if let label {
          self.drawText(g, reveal(label), at: CGPoint(x: (self.W - ls.width) / 2, y: y), size: ls)
        }
      }
    default:
      // Portrait titles are hooks: big, wrapped, under the logo.
      let portrait = socialTop(plan) != nil
      let s = Scene.text(c.text, size: (portrait ? 80 : look.titleFont == nil ? 40 : 46) * u, weight: .bold, font: look.titleFont, color: titleColor)
      let maxW = portrait ? W * 0.84 : W
      let size = Scene.measure(s, maxWidth: maxW)
      let padX = 28 * u, padY = 14 * u
      let top = portrait ? H * 0.075 : ins.fullBleed ? ins.safe : H * 0.06
      let rect = CGRect(x: W / 2 - size.width / 2 - padX, y: top, width: size.width + 2 * padX, height: size.height + 2 * padY)
      animated(ctx, rect, pose, blurred: &blurred) { g in
        self.pill(g, reveal(s), centerX: self.W / 2, top: top, padX: padX, padY: padY, radius: 14 * self.u, fill: panel, maxWidth: maxW)
      }
    }
  }

  /// Draws text with its top-left corner at `at` (top-left coordinates).
  func drawText(_ ctx: CGContext, _ s: NSAttributedString, at p: CGPoint, size: CGSize) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: p.y + size.height)
    ctx.scaleBy(x: 1, y: -1)
    let path = CGPath(rect: CGRect(x: p.x, y: 0, width: size.width + 1, height: size.height), transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0), path, nil), ctx)
    ctx.restoreGState()
  }

  func drawCaptions(_ ctx: CGContext, _ page: Page, frame f: Double, insets ins: Insets, camBox: Box?, blurred: inout [CIImage]) {
    let fps = Double(plan.output.fps)
    let style = plan.captions.style ?? "pill"
    // Social is bold made for vertical: bigger, and it sits on the seam over the split camera.
    let social = style == "social"
    let bold = style == "bold" || social
    let s = NSMutableAttributedString()
    var current: NSRange?
    let highlight = look.captionHighlight ?? (style == "pill" ? nil : look.accent ?? "#ffe500")
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
      if isCurrent { current = NSRange(location: s.length, length: (text as NSString).length - (i < page.words.count - 1 ? 1 : 0)) }
      s.append(
        Scene.text(
          text, size: (social ? 92 : bold ? 64 : 42) * u, weight: social ? .heavy : bold ? .bold : .semibold, alpha: alpha, font: look.captionFont,
          color: color, stroke: social ? 3.5 : bold ? 7 : 0))
    }
    let maxW = social ? W * 0.88 : W * 0.8 - 52 * u
    let size = Scene.measure(s, maxWidth: maxW)
    let padX = bold ? 0 : 26 * u, padY = bold ? 0 : 12 * u
    let seam = camBox.flatMap { $0.y > 1 && $0.opacity > 0.5 ? $0.y : nil }
    let top =
      social
      ? (seam.map { $0 - size.height / 2 } ?? H * 0.64)
      : H - (ins.fullBleed ? ins.safe : H * 0.07) - size.height - (bold ? 40 : 24) * u
    let rect = CGRect(x: W / 2 - size.width / 2 - padX, y: top, width: size.width + 2 * padX, height: size.height + 2 * padY)
    let pose =
      motion.name == "classic"
      ? .full
      : Motion.pose(
        frame: f, start: page.startF, end: page.endF + fps * 0.4, fps: Int(fps), enter: Motion(preset: bold ? "pop" : "fade-up", seconds: 0.16, ease: "smooth"),
        exit: Motion(preset: "fade", seconds: 0.12, ease: "ease-in"), style: motion)
    let fill =
      bold ? CGColor(gray: 0, alpha: 0) : Scene.color(look.captionBackground ?? "#0a0a0e").copy(alpha: look.captionBackgroundOpacity ?? 0.78)!
    let mark = style == "karaoke" ? current.map { ($0, Scene.color(highlight ?? "#ffe500")) } : nil
    animated(ctx, rect, pose, blurred: &blurred) { g in
      // Social captions cast a hard ink shadow, so they read over a busy screen or a face.
      if social { g.setShadow(offset: CGSize(width: 0, height: -7 * self.u), blur: 0, color: Scene.color("#15151C")) }
      self.pill(g, s, centerX: self.W / 2, top: top, padX: padX, padY: padY, radius: 14 * self.u, fill: fill, maxWidth: maxW, mark: mark)
    }
  }

  /// A spotlight, box, arrow or highlight on the screen, placed through the camera so it moves
  /// with zooms. Drawn inside the screen card's clip.
  func drawAnnotation(
    _ ctx: CGContext, _ a: Annotation, frame f: Double, start s: Double, end e: Double, screen b: Box, cam: CameraState, blurred: inout [CIImage]
  ) {
    let (k, tx, ty) = screenMap(b, cam)
    let rect = CGRect(
      x: tx + k * a.x * plan.source.width, y: ty + k * a.y * plan.source.height, width: k * a.w * plan.source.width,
      height: k * a.h * plan.source.height)
    let defaultEnter: Motion? =
      switch a.kind {
      case "spotlight": Motion(preset: "fade", seconds: 0.35, ease: "smooth")
      case "highlight": Motion(preset: "wipe", seconds: 0.4, ease: "smooth")
      default: nil
      }
    let pose = Motion.pose(frame: f, start: s, end: e, fps: plan.output.fps, enter: a.enter ?? defaultEnter, exit: a.exit, style: motion)
    let accent = Scene.color(look.accent ?? "#ffcc00")
    let r = 10 * u * cam.scale
    switch a.kind {
    case "spotlight":
      // Dim everything but the rectangle; the hole closes in from a little larger as it fades in.
      let grow = (1 - min(1, pose.opacity)) * 40 * u
      let hole = rect.insetBy(dx: -6 * u - grow, dy: -6 * u - grow)
      ctx.saveGState()
      ctx.addRect(CGRect(x: b.x, y: b.y, width: b.w, height: b.h))
      ctx.addPath(CGPath(roundedRect: hole, cornerWidth: r, cornerHeight: r, transform: nil))
      ctx.setFillColor(CGColor(gray: 0, alpha: 0.6 * min(1, pose.opacity)))
      ctx.fillPath(using: .evenOdd)
      ctx.restoreGState()
    case "highlight":
      animated(ctx, rect, pose, blurred: &blurred) { g in
        g.setFillColor(accent.copy(alpha: 0.32)!)
        g.addPath(CGPath(roundedRect: rect.insetBy(dx: -4 * self.u, dy: -2 * self.u), cornerWidth: 4 * self.u, cornerHeight: 4 * self.u, transform: nil))
        g.fillPath()
      }
    case "arrow":
      // Points at the rectangle's center from below and to the right (or the left near the edge).
      let tip = CGPoint(x: rect.midX, y: rect.maxY + 4 * u)
      let fromLeft = tip.x > b.x + b.w * 0.75
      let tail = CGPoint(x: tip.x + (fromLeft ? -1 : 1) * 110 * u, y: tip.y + 130 * u)
      let box = CGRect(x: min(tip.x, tail.x), y: tip.y, width: abs(tail.x - tip.x), height: tail.y - tip.y)
      animated(ctx, box, pose, blurred: &blurred) { g in
        self.drawArrow(g, from: tail, to: tip, color: accent)
        if let text = a.text, !text.isEmpty {
          let str = Scene.text(text, size: 30 * self.u, weight: .bold, color: "#ffffff")
          let size = Scene.measure(str, maxWidth: self.W * 0.4)
          self.pill(
            g, str, centerX: tail.x, top: tail.y + 8 * self.u, padX: 16 * self.u, padY: 8 * self.u, radius: 10 * self.u,
            fill: Scene.color(self.look.titleBackground ?? "#0f0f14").copy(alpha: 0.9)!, maxWidth: size.width)
        }
      }
    default:  // box
      animated(ctx, rect, pose, blurred: &blurred) { g in
        g.setStrokeColor(accent)
        g.setLineWidth(5 * self.u)
        g.setShadow(offset: .zero, blur: 12 * self.u, color: CGColor(gray: 0, alpha: 0.35))
        g.addPath(CGPath(roundedRect: rect.insetBy(dx: -6 * self.u, dy: -6 * self.u), cornerWidth: r, cornerHeight: r, transform: nil))
        g.strokePath()
        g.setShadow(offset: .zero, blur: 0, color: nil)
        if let text = a.text, !text.isEmpty {
          let str = Scene.text(text, size: 28 * self.u, weight: .bold, color: "#111111")
          let size = Scene.measure(str, maxWidth: self.W * 0.4)
          let top = rect.minY - 6 * self.u - size.height - 18 * self.u
          self.pill(
            g, str, centerX: rect.minX - 6 * self.u + size.width / 2 + 14 * self.u, top: max(self.u * 4, top), padX: 14 * self.u, padY: 6 * self.u,
            radius: 8 * self.u, fill: accent, maxWidth: size.width)
        }
      }
    }
  }

  func drawArrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, color: CGColor) {
    let angle = atan2(b.y - a.y, b.x - a.x)
    let head = 34 * u
    let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
    let path = CGMutablePath()
    path.move(to: a)
    path.addLine(to: base)
    let tri = CGMutablePath()
    tri.move(to: b)
    tri.addLine(to: CGPoint(x: b.x - cos(angle - 0.45) * head, y: b.y - sin(angle - 0.45) * head))
    tri.addLine(to: CGPoint(x: b.x - cos(angle + 0.45) * head, y: b.y - sin(angle + 0.45) * head))
    tri.closeSubpath()
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // A white outline keeps it readable on any screen.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
    ctx.setLineWidth(14 * u)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.addPath(tri)
    ctx.setLineWidth(6 * u)
    ctx.strokePath()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(8 * u)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.setFillColor(color)
    ctx.addPath(tri)
    ctx.fillPath()
    ctx.restoreGState()
  }

  /// How an insert enters and leaves. Full-frame inserts that meet across a cut (two parts of one
  /// animation) skip the fade where they touch, so the screen and camera never flash through, and
  /// one that runs to the video's last frame (an end card) holds instead of revealing the footage under it.
  func insertPose(_ ins: (s: Double, e: Double, a: Insert, index: Int), frame f: Double) -> OverlayPose {
    let neighbors = ins.a.isFull ? inserts.filter { $0.index != ins.index && $0.a.isFull } : []
    let none = Motion(preset: "none")
    let endsVideo = ins.a.isFull && ins.e >= Double(frameCount)
    let enter = ins.a.enter ?? (neighbors.contains { $0.e == ins.s } ? none : Motion(preset: "fade", seconds: 0.3, ease: "smooth"))
    let exit = ins.a.exit ?? (endsVideo || neighbors.contains { $0.s == ins.e } ? none : Motion(preset: "fade", seconds: 0.25, ease: "ease-in"))
    return Motion.pose(frame: f, start: ins.s, end: ins.e, fps: plan.output.fps, enter: enter, exit: exit, style: motion)
  }

  /// Whether a full-frame insert fully covers the screen at this frame (so screen marks stay hidden).
  /// Whether B-roll in the screen card (a portrait animation, say) fully covers it at this frame.
  func cardCovers(_ f: Double) -> Bool {
    inserts.contains { !$0.a.isFull && f >= $0.s && f < $0.e && insertPose($0, frame: f).opacity >= 0.99 }
  }

  func fullFrameCovers(_ f: Double) -> Bool {
    inserts.contains { $0.a.isFull && f >= $0.s && f < $0.e && insertPose($0, frame: f).opacity >= 0.99 }
  }

  /// B-roll showing at this frame: in the screen card (`full` false) or over the whole frame.
  func broll(_ image: CIImage, frame f: Double, full: Bool, box b: Box, frames: [Int: CIImage]) -> CIImage {
    var out = image
    for ins in inserts where ins.a.isFull == full && f >= ins.s && f < ins.e {
      guard let src = insertImages[ins.index] ?? frames[ins.index] else { continue }
      let pose = insertPose(ins, frame: f)
      guard pose.visible else { continue }
      let rect = full ? CGRect(x: 0, y: 0, width: W, height: H) : ciRect(b)
      let radius = full ? 0 : b.r
      let fill = ins.a.fit != "fit"
      let iw = src.extent.width, ih = src.extent.height
      guard iw > 0, ih > 0 else { continue }
      let k = fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
      var placed = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
      placed = placed.transformed(by: CGAffineTransform(translationX: rect.midX - iw * k / 2, y: rect.midY - ih * k / 2))
      if !fill {
        // Letterbox on black so the screen doesn't show around a fitted picture.
        placed = placed.composited(over: CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05)).cropped(to: rect))
      }
      if abs(pose.scale - 1) > 0.001 || abs(pose.dx) + abs(pose.dy) > 0.001 {
        let t = CGAffineTransform(translationX: -rect.midX, y: -rect.midY).concatenating(CGAffineTransform(scaleX: pose.scale, y: pose.scale))
          .concatenating(CGAffineTransform(translationX: rect.midX + pose.dx * rect.width, y: rect.midY - pose.dy * rect.height))
        placed = placed.transformed(by: t)
      }
      out = masked(placed, rect, radius: radius, opacity: min(1, pose.opacity)).composited(over: out)
    }
    return out
  }

  /// Blurs the parts of the screen covered by blur annotations (passwords, emails), following zooms.
  func privacyBlurs(_ image: CIImage, frame f: Double, screen b: Box, cam: CameraState) -> CIImage {
    let shown = annotations.filter { f >= $0.s && f < $0.e && $0.a.kind == "blur" }
    guard !shown.isEmpty else { return image }
    let (k, tx, ty) = screenMap(b, cam)
    var out = image
    let soft = out.clampedToExtent().applyingGaussianBlur(sigma: 22 * u * cam.scale)
    for m in shown {
      let a = m.a
      let pose = Motion.pose(frame: f, start: m.s, end: m.e, fps: plan.output.fps, enter: a.enter ?? Motion(preset: "fade", seconds: 0.2),
        exit: a.exit ?? Motion(preset: "fade", seconds: 0.2), style: motion)
      let rect = ciRect(
        Box(x: tx + k * a.x * plan.source.width, y: ty + k * a.y * plan.source.height, w: k * a.w * plan.source.width,
          h: k * a.h * plan.source.height, r: 0, opacity: 1)
      ).intersection(ciRect(b))
      guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }
      out = masked(soft, rect, radius: 8 * u * cam.scale, opacity: min(1, pose.opacity)).composited(over: out)
    }
    return out
  }

  /// Styled cuts: blur, dip to the background, flash, punch in or whip pan, peaking on the cut.
  func cutTransition(_ image: CIImage, frame f: Double) -> CIImage {
    let half = Double(plan.output.fps) * 0.22
    guard let cut = cuts.first(where: { abs(f - $0.f) < half }) else { return image }
    let d = (f - cut.f) / half
    // 1 on the cut, easing to 0 at either end.
    let x = 1 - abs(d)
    let peak = x * x * (3 - 2 * x)
    let frame = CGRect(x: 0, y: 0, width: W, height: H)
    switch cut.kind {
    case "blur":
      return image.clampedToExtent().applyingGaussianBlur(sigma: 30 * u * peak).cropped(to: frame)
    case "dip":
      return background().applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: peak)])
        .composited(over: image)
    case "flash":
      return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85 * peak)).cropped(to: frame).composited(over: image)
    case "punch":
      let k = 1 + 0.07 * peak
      return image.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2).concatenating(CGAffineTransform(scaleX: k, y: k))
        .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))).cropped(to: frame)
    case "whip":
      // Out to the left before the cut, in from the right after it.
      let shift = (d < 0 ? -1.0 : 1.0) * W * 0.18 * peak
      return image.clampedToExtent().transformed(by: CGAffineTransform(translationX: shift, y: 0))
        .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 70 * u * peak, kCIInputAngleKey: 0]).cropped(to: frame)
    default:
      return image
    }
  }
}
