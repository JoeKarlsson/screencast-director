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
    let c0 = Scene.color(scene.plan.style.background.first ?? "#1d2b64")
    let c1 = Scene.color(scene.plan.style.background.last ?? "#f8cdda")
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
  /// largest size (down from `start`) where every word fits and it takes at most four lines. The last
  /// line goes on the accent chip.
  static func coverTitle(_ title: String, font: String?, maxWidth: Double, start: Double = 140) -> (lines: [String], size: Double) {
    let words = title.uppercased().split(separator: " ").map(String.init)
    var size = start
    while size > 48 {
      func width(_ s: String) -> Double { Scene.measure(Scene.text(s, size: size, weight: .heavy, font: font), maxWidth: .greatestFiniteMagnitude).width }
      if words.allSatisfy({ width($0) <= maxWidth }) {
        var lines: [String] = []
        for w in words {
          if let last = lines.last, width(last + " " + w) <= maxWidth { lines[lines.count - 1] = last + " " + w } else { lines.append(w) }
        }
        if lines.count <= 4 { return (lines, size) }
      }
      size -= 6
    }
    return ([title.uppercased()], size)
  }

  /// A 1080x1920 cover for a vertical video: the title big on the look's dark color at the top, the
  /// last line on the accent chip, and the camera frame filling the bottom, framed on the face.
  public static func verticalThumbnail(plan: Plan, person: CGImage, faceX: Double, title: String) -> CGImage? {
    let W = 1080.0, H = 1920.0
    guard let (ctx, look, bg) = coverCanvas(plan, width: W, height: H) else { return nil }
    // The photo fills the bottom 52% (y-up drawing), its top edge fading into the background.
    let photoH = H * 0.52
    drawFramed(ctx, plan: plan, person: person, faceX: faceX, in: CGRect(x: 0, y: 0, width: W, height: photoH))
    let fade = CGGradient(colorsSpace: Scene.srgb, colors: [bg, bg.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: photoH), end: CGPoint(x: 0, y: photoH - 200), options: [])
    // The title fills the dark area above, down to where the photo shows through its fade.
    drawCoverTitle(ctx, look: look, title: title, in: CGRect(x: 0, y: photoH - 60, width: W, height: H - photoH + 60), margin: 80)
    return ctx.makeImage()
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
    drawCoverTitle(ctx, look: look, title: title, in: CGRect(x: 0, y: 0, width: photoX + 40, height: H), margin: 48)
    return ctx.makeImage()
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

  /// The camera frame as the video shows it, cropped to the rect's shape around the face and drawn there.
  static func drawFramed(_ ctx: CGContext, plan: Plan, person: CGImage, faceX: Double, in rect: CGRect) {
    let photo = asShown(person, plan: plan)
    let iw = Double(photo.width), ih = Double(photo.height)
    let cropW = min(iw, ih * rect.width / rect.height), cropH = cropW * rect.height / rect.width
    let fx = plan.camera?.mirror == true ? 1 - faceX : faceX
    let cx = min(max(fx * iw - cropW / 2, 0), iw - cropW)
    if let crop = photo.cropping(to: CGRect(x: cx, y: (ih - cropH) / 2, width: cropW, height: cropH)) {
      ctx.draw(styledLikeVideo(crop, plan: plan), in: rect)
    }
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
  static func drawCoverTitle(_ ctx: CGContext, look: Look, title: String, in area: CGRect, margin: Double) {
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
    for (k, s) in texts.enumerated() {
      let m = sizes[k]
      if k == lines.count - 1 {
        y -= gap + chipPadY
        let r = CGRect(x: area.midX - m.width / 2 - chipPadX, y: y - m.height - chipPadY, width: m.width + 2 * chipPadX, height: m.height + 2 * chipPadY)
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
