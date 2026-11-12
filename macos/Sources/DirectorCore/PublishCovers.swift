import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Thumbnails and covers: the frame as shown, the cover canvas, its title, and PNG output.

extension Publish {
  /// A 1280x720 thumbnail: brand background, the screen at that moment, the person cut out large on
  /// the left (if there's a face), and the title in the profile's title font.
  public static func thumbnail(scene: Scene, screen: CGImage, person: CGImage?, title: String) -> CGImage? {
    let W = 1280.0, H = 720.0
    let look = scene.plan.look ?? Look()
    Fonts.register(look.fontFiles)
    guard
      let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }

    // Background (y-up coordinates in this function).
    let c0 = Scene.color(scene.plan.style.background.first ?? "#15151C")
    let c1 = Scene.color(scene.plan.style.background.last ?? "#15151C")
    let grad = CGGradient(colorsSpace: Scene.srgb, colors: [c0, c1] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

    // Right column: the title on top, the screen under it, tilted slightly.
    let colX = W * 0.43, colW = W * 0.53
    let text = Scene.text(title, size: 64, weight: .bold, font: look.titleFont, color: look.titleText ?? "#ffffff")
    let size = Scene.measure(text, maxWidth: colW - 44)
    let pad = 22.0
    let box = CGRect(x: colX, y: H - 44 - size.height - 2 * pad, width: size.width + 2 * pad, height: size.height + 2 * pad)

    let sw = colW, sh = sw * Double(screen.height) / Double(screen.width)
    let screenTop = box.minY - 34
    ctx.saveGState()
    ctx.translateBy(x: colX + sw / 2, y: max(sh / 2 + 30, screenTop - sh / 2))
    ctx.rotate(by: -0.03)
    let rect = CGRect(x: -sw / 2, y: -sh / 2, width: sw, height: sh)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: CGColor(gray: 0, alpha: 0.5))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.clip()
    ctx.draw(screen, in: rect)
    ctx.restoreGState()

    ctx.setFillColor(Scene.color(look.titleBackground ?? "#0f0f14"))
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.fillPath()
    let frame = CTFramesetterCreateFrame(
      CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
      CGPath(rect: box.insetBy(dx: pad, dy: pad), transform: nil), nil)
    CTFrameDraw(frame, ctx)

    // Left column: the person, cropped to their outline, standing on the bottom edge.
    if let person, let cut = cutout(asShown(person, plan: scene.plan)), let cg = CIContext().createCGImage(cut, from: cut.extent), let tight = cropToAlpha(cg) {
      let ph = H * 0.94
      var pw = ph * Double(tight.width) / Double(tight.height)
      var drawH = ph
      if pw > W * 0.48 {
        pw = W * 0.48
        drawH = pw * Double(tight.height) / Double(tight.width)
      }
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
      ctx.draw(tight, in: CGRect(x: W * 0.215 - pw / 2, y: 0, width: pw, height: drawH))
      ctx.restoreGState()
    }
    return ctx.makeImage()
  }

  /// A camera frame as the video shows it: flipped when the plan mirrors the camera.
  static func asShown(_ image: CGImage, plan: Plan) -> CGImage {
    guard plan.camera?.mirror == true,
      let ctx = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    ctx.translateBy(x: Double(image.width), y: 0)
    ctx.scaleBy(x: -1, y: 1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage() ?? image
  }

  /// The title's lines for a vertical cover: uppercase, broken greedily to fit `maxWidth` at the
  /// largest size (down from `start`) where every word fits and it takes at most `maxLines` lines.
  /// The last line goes on the accent chip.
  static func coverTitle(_ title: String, font: String?, maxWidth: Double, start: Double = 140, maxLines: Int = 4) -> (lines: [String], size: Double) {
    let words = title.uppercased().split(separator: " ").map(String.init)
    var size = start
    while size > 48 {
      func width(_ s: String) -> Double { Scene.measure(Scene.text(s, size: size, weight: .heavy, font: font), maxWidth: .greatestFiniteMagnitude).width }
      if words.allSatisfy({ width($0) <= maxWidth }) {
        var lines: [String] = []
        for w in words {
          if let last = lines.last, width(last + " " + w) <= maxWidth { lines[lines.count - 1] = last + " " + w } else { lines.append(w) }
        }
        if lines.count <= maxLines { return (lines, size) }
      }
      size -= 6
    }
    return ([title.uppercased()], size)
  }

  /// A 1080x1920 cover for a vertical video. With a `subject` (a frame of the video's B-roll): the
  /// subject on the top half, the camera frame on the bottom framed on the face, and the title on an
  /// accent bar across the seam. Without one: the title big on the look's dark color at the top, the
  /// last line on the accent chip, and the camera frame filling the bottom.
  /// `faceX`/`faceY` are the face's center and `faceWidth` its width, fractions of the camera frame.
  public static func verticalThumbnail(
    plan: Plan, person: CGImage, faceX: Double, faceY: Double = 0.4, faceWidth: Double? = nil, subject: CGImage? = nil, title: String
  ) -> CGImage? {
    let W = 1080.0, H = 1920.0
    guard let (ctx, look, bg) = coverCanvas(plan, width: W, height: H) else { return nil }
    if let subject {
      // Split: the camera on the bottom half, the subject on the top (y-up drawing).
      let seam = H * 0.5
      let face = drawFramed(ctx, plan: plan, person: person, faceX: faceX, faceY: faceY, faceWidth: faceWidth, in: CGRect(x: 0, y: 0, width: W, height: seam))
      drawFilled(ctx, subject, in: CGRect(x: 0, y: seam, width: W, height: H - seam))
      let bar = drawTitleBar(ctx, look: look, title: title, centerY: seam, width: W)
      drawSplitMarks(ctx, look: look, size: CGSize(width: W, height: H), bar: bar, face: face)
      return ctx.makeImage()
    }
    // The photo fills the bottom 52% (y-up drawing), its top edge fading into the background.
    let photoH = H * 0.52
    drawFramed(ctx, plan: plan, person: person, faceX: faceX, faceY: faceY, faceWidth: faceWidth, in: CGRect(x: 0, y: 0, width: W, height: photoH))
    let fade = CGGradient(colorsSpace: Scene.srgb, colors: [bg, bg.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: photoH), end: CGPoint(x: 0, y: photoH - 200), options: [])
    // The title fills the dark area above, down to where the photo shows through its fade.
    let titled = drawCoverTitle(ctx, look: look, title: title, in: CGRect(x: 0, y: photoH - 60, width: W, height: H - photoH + 60), margin: 80)
    drawCoverMarks(ctx, look: look, size: CGSize(width: W, height: H), chip: titled.chip, titleTop: titled.top, photo: CGRect(x: 0, y: 0, width: W, height: photoH))
    return ctx.makeImage()
  }

  /// An image cropped to the rect's shape around its center and drawn there.
  static func drawFilled(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
    let iw = Double(image.width), ih = Double(image.height), aspect = rect.width / rect.height
    let cropW = min(iw, ih * aspect), cropH = cropW / aspect
    if let crop = image.cropping(to: CGRect(x: (iw - cropW) / 2, y: (ih - cropH) / 2, width: cropW, height: cropH)) {
      ctx.draw(crop, in: rect)
    }
  }

  /// The title on one accent bar, centered on `centerY` (y up) across the cover with a thin stripe
  /// of the same color running to both edges: one line when it fits big, else two. Returns the bar.
  static func drawTitleBar(_ ctx: CGContext, look: Look, title: String, centerY: Double, width W: Double) -> CGRect {
    let inset = W * 0.03, padX = W * 0.035
    let room = W - 2 * inset - 2 * padX
    let one = coverTitle(title, font: look.titleFont, maxWidth: room, start: 170, maxLines: 1)
    let fit = one.size >= 100 ? one : coverTitle(title, font: look.titleFont, maxWidth: room, start: 150, maxLines: 2)
    let texts = fit.lines.map { Scene.text($0, size: fit.size, weight: .heavy, font: look.titleFont, color: look.titleText ?? "#111318", align: .left) }
    let sizes = texts.map { Scene.measure($0, maxWidth: .greatestFiniteMagnitude) }
    let gap = fit.size * 0.04, padY = fit.size * 0.12
    let textH = sizes.reduce(0) { $0 + $1.height } + gap * Double(texts.count - 1)
    let bar = CGRect(x: inset, y: centerY - (textH + 2 * padY) / 2, width: W - 2 * inset, height: textH + 2 * padY)
    ctx.setFillColor(Scene.color(look.titleBackground ?? look.accent ?? "#FDAE84"))
    ctx.fill(CGRect(x: 0, y: bar.minY + bar.height * 0.1, width: W, height: max(6, W * 0.009)))
    ctx.fill(bar)
    var y = bar.maxY - padY
    for (s, m) in zip(texts, sizes) {
      let frame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0),
        CGPath(rect: CGRect(x: bar.midX - m.width / 2, y: y - m.height, width: m.width + 2, height: m.height), transform: nil), nil)
      CTFrameDraw(frame, ctx)
      y -= m.height + gap
    }
    return bar
  }

  /// joekarlsson.com's crayon marks on a split zine cover, all in the accent: an asterisk and a burst
  /// in the subject's top corners, rays off the bar's top-right corner, a double underline and a coil
  /// under it, and a small asterisk by the head. Rects are y up; nothing for other looks.
  static func drawSplitMarks(_ ctx: CGContext, look: Look, size: CGSize, bar: CGRect, face: CGRect?) {
    guard look.animationTheme == "zine" else { return }
    let W = size.width, H = size.height, side = min(W, H)
    let pink = Scene.color(look.accent ?? "#FF4FD8"), line = side * 0.009
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    func down(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
    func mark(_ s: Scribble, _ r: CGRect, width: Double = line) { s.draw(ctx, in: r, color: pink, lineWidth: width, shares: s.shares(1), boil: 0) }
    let b = down(bar)
    mark(.asterisk, CGRect(x: W * 0.05, y: H * 0.085, width: side * 0.1, height: side * 0.1))
    mark(.burst, CGRect(x: W - side * 0.26, y: H * 0.07, width: side * 0.2, height: side * 0.2), width: line * 0.85)
    mark(.rays, CGRect(x: b.maxX - side * 0.12, y: b.minY - side * 0.12, width: side * 0.15, height: side * 0.11))
    mark(.underline, CGRect(x: b.minX + W * 0.06, y: b.maxY + side * 0.015, width: W * 0.42, height: side * 0.02))
    mark(.underline, CGRect(x: b.minX + W * 0.03, y: b.maxY + side * 0.045, width: W * 0.42, height: side * 0.02))
    mark(.coil, CGRect(x: b.minX, y: b.maxY + side * 0.07, width: W * 0.24, height: W * 0.08), width: line * 0.85)
    // By the top of the head, on the side with room, clear of the marks under the bar.
    if let face {
      let f = down(face), star = side * 0.07
      let x = f.maxX + star < W - side * 0.03 ? f.maxX : f.minX - star
      let y = f.minY - f.height * 0.6
      if y > b.maxY + side * 0.17 { mark(.asterisk, CGRect(x: x, y: y, width: star, height: star), width: line * 0.8) }
    }
  }

  /// A 1280x720 thumbnail for a landscape video: the title big on the look's dark color on the left,
  /// the last line on the accent chip, and the camera frame filling the right, framed on the face.
  public static func landscapeThumbnail(plan: Plan, person: CGImage, faceX: Double, title: String) -> CGImage? {
    let W = 1280.0, H = 720.0
    guard let (ctx, look, bg) = coverCanvas(plan, width: W, height: H) else { return nil }
    // The photo fills the right 58%, its left edge fading into the background.
    let photoX = W * 0.42
    drawFramed(ctx, plan: plan, person: person, faceX: faceX, in: CGRect(x: photoX, y: 0, width: W - photoX, height: H))
    let fade = CGGradient(colorsSpace: Scene.srgb, colors: [bg, bg.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: photoX, y: 0), end: CGPoint(x: photoX + 160, y: 0), options: [])
    let titled = drawCoverTitle(ctx, look: look, title: title, in: CGRect(x: 0, y: 0, width: photoX + 40, height: H), margin: 48)
    drawCoverMarks(ctx, look: look, size: CGSize(width: W, height: H), chip: titled.chip, titleTop: titled.top, photo: CGRect(x: photoX, y: 0, width: W - photoX, height: H))
    return ctx.makeImage()
  }

  /// joekarlsson.com's crayon marks on a zine-look cover: rays bursting off the chip, an asterisk and
  /// a burst in the black by the title, and a chalk coil along the photo's top edge.
  /// Rects are y up, like the cover; nothing for other looks.
  static func drawCoverMarks(_ ctx: CGContext, look: Look, size: CGSize, chip: CGRect, titleTop: Double, photo: CGRect) {
    guard look.animationTheme == "zine", chip.width > 0 else { return }
    let W = size.width, H = size.height, side = min(W, H)
    let pink = Scene.color(look.accent ?? "#FF4FD8"), chalk = Scene.color("#ECE6DA")
    // Scribble draws in top-left coordinates: flip the cover for it, and each rect with it.
    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    func down(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
    func mark(_ s: Scribble, _ r: CGRect, _ color: CGColor, width: Double) {
      s.draw(ctx, in: down(r), color: color, lineWidth: width, shares: s.shares(1), boil: 0)
    }
    let raysW = chip.height * 1.2
    mark(.rays, CGRect(x: chip.maxX - raysW * 0.05, y: chip.maxY - raysW * 0.4, width: raysW, height: raysW * 0.75), pink, width: side * 0.009)
    let star = side * 0.08
    mark(.asterisk, CGRect(x: W * 0.05, y: min(H - star * 1.1, titleTop - star * 0.6), width: star, height: star), pink, width: side * 0.007)
    let burst = side * 0.12
    mark(.burst, CGRect(x: W - burst * 1.2, y: min(H - burst * 1.05, titleTop - burst * 0.15), width: burst, height: burst), pink, width: side * 0.005)
    // A chalk coil along the photo's top edge, on the side away from the face.
    let coilW = photo.width * 0.32
    mark(.coil, CGRect(x: photo.minX + photo.width * 0.03, y: photo.maxY - coilW * 0.42, width: coilW, height: coilW / 3), chalk, width: side * 0.006)
  }

  /// A cover's canvas filled with the look's dark color, and that color.
  static func coverCanvas(_ plan: Plan, width W: Double, height H: Double) -> (CGContext, Look, CGColor)? {
    let look = plan.look ?? Look()
    Fonts.register(look.fontFiles)
    guard
      let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    let bg = Scene.color(look.chipBackground ?? look.captionBackground ?? "#111318")
    ctx.setFillColor(bg)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    return (ctx, look, bg)
  }

  /// The camera frame as the video shows it, cropped to the rect's shape around the face and drawn
  /// there: the face just above the middle, with headroom, and with `faceWidth` known, zoomed in
  /// (up to 2x) until the face is about 30% of the width. Returns the face's square in the
  /// cover (y up) when its width is known.
  @discardableResult
  static func drawFramed(
    _ ctx: CGContext, plan: Plan, person: CGImage, faceX: Double, faceY: Double = 0.4, faceWidth: Double? = nil, in rect: CGRect
  ) -> CGRect? {
    let photo = asShown(person, plan: plan)
    let iw = Double(photo.width), ih = Double(photo.height), aspect = rect.width / rect.height
    var cropW = min(iw, ih * aspect)
    if let fw = faceWidth, fw > 0 { cropW = min(cropW, max(cropW / 2, fw * iw / 0.3)) }
    let cropH = cropW / aspect
    let fx = plan.camera?.mirror == true ? 1 - faceX : faceX
    let cx = min(max(fx * iw - cropW / 2, 0), iw - cropW)
    let cy = min(max(faceY * ih - cropH * 0.47, 0), ih - cropH)  // y down, like the image
    guard let crop = photo.cropping(to: CGRect(x: cx, y: cy, width: cropW, height: cropH)) else { return nil }
    ctx.draw(styledLikeVideo(crop, plan: plan), in: rect)
    guard let fw = faceWidth else { return nil }
    let scale = rect.width / cropW, side = fw * iw * scale
    let centerX = rect.minX + (fx * iw - cx) * scale, centerY = rect.maxY - (faceY * ih - cy) * scale
    return CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side)
  }

  /// A camera frame through the video's camera grade and LUT; unchanged without a grade.
  static func gradedLikeVideo(_ photo: CGImage, scene: Scene) -> CGImage {
    guard scene.plan.camera?.grade != nil else { return photo }
    let img = CIImage(cgImage: photo)
    return CIContext().createCGImage(Scene.graded(img, scene.plan.camera?.grade, lut: scene.cameraLUT), from: img.extent) ?? photo
  }

  /// The camera photo (as cropped for the cover) with the video's halftone room and crayon outline, when the plan has them.
  static func styledLikeVideo(_ photo: CGImage, plan: Plan) -> CGImage {
    let cam = plan.camera
    guard cam?.room == "halftone" || cam?.outline == true else { return photo }
    let img = CIImage(cgImage: photo)
    guard let mask = Scene.personMask(img) else { return photo }
    let w = img.extent.width, side = min(img.extent.width, img.extent.height)
    let styled = Scene.styledRoom(
      img, mask: mask, halftoneCell: cam?.room == "halftone" ? w / 70 : nil, outline: cam?.outline == true ? side / 150 : nil,
      ink: plan.look?.accent ?? "#FF4FD8", boil: 0)
    return CIContext().createCGImage(styled, from: img.extent) ?? photo
  }

  /// The title in white lines with the last on the accent chip, each centered, the block centered in
  /// `area` (y up) at the largest size that fits with `margin` all round.
  @discardableResult
  static func drawCoverTitle(_ ctx: CGContext, look: Look, title: String, in area: CGRect, margin: Double) -> (chip: CGRect, top: Double) {
    let chipPadX = area.width * 0.028, chipPadY = area.width * 0.013
    var start = min(132, area.width * 0.13)
    var lines: [String] = [], texts: [NSAttributedString] = [], sizes: [CGSize] = []
    var gap = 0.0, blockH = 0.0
    repeat {
      let fit = coverTitle(title, font: look.titleFont, maxWidth: area.width - 2 * margin - 2 * chipPadX, start: start)
      lines = fit.lines
      texts = lines.enumerated().map { k, line in
        Scene.text(
          line, size: fit.size, weight: .heavy, font: look.titleFont,
          color: k == lines.count - 1 ? (look.titleText ?? "#111318") : (look.captionText ?? "#F3F4F6"), align: .left)
      }
      sizes = texts.map { Scene.measure($0, maxWidth: .greatestFiniteMagnitude) }
      gap = fit.size * 0.14
      blockH = sizes.reduce(0) { $0 + $1.height } + gap * Double(lines.count - 1) + 2 * chipPadY + gap
      start = fit.size - 4
    } while blockH > area.height - 2 * margin && start > 30
    var y = area.midY + blockH / 2  // the block's top, y up
    let top = y
    var chip = CGRect.zero
    for (k, s) in texts.enumerated() {
      let m = sizes[k]
      if k == lines.count - 1 {
        y -= gap + chipPadY
        let r = CGRect(x: area.midX - m.width / 2 - chipPadX, y: y - m.height - chipPadY, width: m.width + 2 * chipPadX, height: m.height + 2 * chipPadY)
        chip = r
        ctx.setFillColor(Scene.color(look.titleBackground ?? look.accent ?? "#FDAE84"))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: chipPadY * 1.4, cornerHeight: chipPadY * 1.4, transform: nil))
        ctx.fillPath()
      }
      let frame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0),
        CGPath(rect: CGRect(x: area.midX - m.width / 2, y: y - m.height, width: m.width + 2, height: m.height), transform: nil), nil)
      CTFrameDraw(frame, ctx)
      y -= m.height + gap
    }
    return (chip, top)
  }

  /// The image cropped to its non-transparent pixels.
  static func cropToAlpha(_ img: CGImage) -> CGImage? {
    let w = img.width, h = img.height
    guard
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Scene.srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = data.assumingMemoryBound(to: UInt8.self)
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in stride(from: 0, to: h, by: 2) {
      for x in stride(from: 0, to: w, by: 2) where px[(y * w + x) * 4 + 3] > 24 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
      }
    }
    guard maxX > minX, maxY > minY else { return nil }
    // Context rows run top-down in memory, so these are already image coordinates.
    return img.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
  }

  public static func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw DirectorError("Can't write \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw DirectorError("Couldn't finish writing \(url.lastPathComponent)") }
  }
}
