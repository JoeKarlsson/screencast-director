import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Vision

// What Scene draws over the screen and camera: titles, chips, annotations and the cursor (captions are
// in SceneCaptions.swift; B-roll, privacy blurs and cut transitions in SceneBroll.swift).
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
    // Flip to top-left coordinates, which plan boxes use; text is unflipped per draw.
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
        // Sized in px inside the zoomed card, so they grow with the zoom.
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
  /// Draws an overlay posed for its entrance or exit. In a vertical video it's moved, whole, inside
  /// the part the apps' own UI doesn't cover (SafeArea), unless `keepSafe` is false: annotations
  /// mark a spot on the screen and must stay on it.
  func animated(
    _ ctx: CGContext, _ rect: CGRect, _ pose: OverlayPose, keepSafe: Bool = true, blurred: inout [CIImage], _ draw: (CGContext) -> Void
  ) {
    guard pose.visible else { return }
    let safe = keepSafe ? SafeArea.shift(rect, plan: plan) : .zero
    func apply(_ c: CGContext) {
      c.translateBy(x: safe.width, y: safe.height)
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
    ).union(rect).insetBy(dx: -pad, dy: -pad).offsetBy(dx: safe.width, dy: safe.height).integral
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
      // The checklist: earlier chapters, ticked, in rows under the chip.
      // Earlier in the video, which isn't recording order when clips are moved.
      let shownAt = callouts.first { $0.c == c }?.s ?? 0
      let done = look.chapterChecklist == true
        ? callouts.filter { $0.c.style == "chapter" && $0.s < shownAt }.sorted { $0.s < $1.s }.map(\.c) : []
      let rows = done.map { Scene.text("✓  " + $0.text, size: 34 * u, weight: .semibold, font: look.captionFont, color: look.chipText ?? "#ffffff") }
      let rowSizes = rows.map { Scene.measure($0, maxWidth: W * 0.8) }
      let rowPadX = 20 * u, rowPadY = 8 * u, gap = 10 * u
      var rowRects: [CGRect] = []
      var y = rect.maxY + gap
      for size in rowSizes {
        rowRects.append(CGRect(x: rect.minX, y: y, width: size.width + 2 * rowPadX, height: size.height + 2 * rowPadY))
        y += size.height + 2 * rowPadY + gap
      }
      let whole = rowRects.reduce(rect) { $0.union($1) }
      animated(ctx, whole, pose, blurred: &blurred) { g in
        g.setFillColor(Scene.color(self.look.titleBackground ?? accent))
        g.addPath(CGPath(roundedRect: rect, cornerWidth: 14 * self.u, cornerHeight: 14 * self.u, transform: nil))
        g.fillPath()
        self.drawText(g, reveal(s), at: CGPoint(x: rect.minX + padX, y: rect.minY + padY), size: size)
        for (k, r) in rowRects.enumerated() {
          g.setFillColor(Scene.color(self.look.chipBackground ?? "#111318").copy(alpha: 0.88)!)
          g.addPath(CGPath(roundedRect: r, cornerWidth: 10 * self.u, cornerHeight: 10 * self.u, transform: nil))
          g.fillPath()
          self.drawText(g, rows[k], at: CGPoint(x: r.minX + rowPadX, y: r.minY + rowPadY), size: rowSizes[k])
        }
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
      // Portrait keeps clear of the platforms' tabs up top and buttons down the right edge.
      let maxW = portrait ? W * 0.76 : W
      let size = Scene.measure(s, maxWidth: maxW)
      let padX = 28 * u, padY = 14 * u
      let top = portrait ? H * 0.14 : ins.fullBleed ? ins.safe : H * 0.06
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
      animated(ctx, rect, pose, keepSafe: false, blurred: &blurred) { g in
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
      animated(ctx, box, pose, keepSafe: false, blurred: &blurred) { g in
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
      animated(ctx, rect, pose, keepSafe: false, blurred: &blurred) { g in
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

}
