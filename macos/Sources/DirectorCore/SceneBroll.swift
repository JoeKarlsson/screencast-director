import CoreGraphics
import CoreImage
import CoreText
import Foundation

// B-roll and animations over the screen or the whole frame, privacy blurs, and styled cuts.

extension Scene {
  /// How an insert enters and leaves: a hard cut unless the insert asks for a motion. Fades by default
  /// half-dissolved B-roll over the face at every edge, which read as glitches.
  func insertPose(_ ins: (s: Double, e: Double, a: Insert, index: Int), frame f: Double) -> OverlayPose {
    let fallback = plan.brollDefaultMotion
    // A sticker springs on from nothing and shrinks away, whatever the B-roll default.
    let enter = ins.a.enter ?? (ins.a.isSticker ? Motion(preset: "stick", seconds: 0.45, ease: "bouncy") : fallback)
    let exit = ins.a.exit ?? (ins.a.isSticker ? Motion(preset: "stick", seconds: 0.3, ease: "ease-in") : fallback)
    return Motion.pose(frame: f, start: ins.s, end: ins.e, fps: plan.output.fps, enter: enter, exit: exit, style: motion)
  }

  /// Whether a full-frame insert fully covers the screen at this frame (so screen marks stay hidden).
  /// Whether B-roll in the screen card (a portrait animation, say) fully covers it at this frame.
  func cardCovers(_ f: Double) -> Bool {
    inserts.contains { !$0.a.isFull && !$0.a.isOverlay && f >= $0.s && f < $0.e && insertPose($0, frame: f).opacity >= 0.99 }
  }

  func fullFrameCovers(_ f: Double) -> Bool {
    inserts.contains { $0.a.isFull && f >= $0.s && f < $0.e && insertPose($0, frame: f).opacity >= 0.99 }
  }

  /// The room a B-roll clip is shown with: its own `room`, else the camera's for a video clip (the
  /// plan's own B-roll only: animations are never restyled). nil for as shot.
  func brollRoom(_ ins: (s: Double, e: Double, a: Insert, index: Int)) -> String? {
    guard ins.index < plan.insertList.count else { return nil }
    let room = ins.a.room ?? (ins.a.isImage ? nil : plan.camera?.room)
    return room == "none" ? nil : room
  }

  /// A B-roll frame with its background in halftone, the subject in color and, when the camera has
  /// one, the crayon outline, sized to how wide it's shown. Its mask is averaged over the clip's last
  /// frames like the camera's. Left as shot when Vision finds no subject.
  func styledBroll(_ src: CIImage, _ ins: (s: Double, e: Double, a: Insert, index: Int), frame f: Int, shownWidth: Double) -> CIImage {
    guard let raw = Scene.subjectMask(src) else { return src }
    let earlier = ins.a.isImage ? [] : [f - 1, f - 2].filter { Double($0) >= ins.s }
    let mask = averaged(raw, frame: f, lane: ins.index, earlier: earlier)
    let k = shownWidth / src.extent.width
    return Scene.styledRoom(
      src, mask: mask, halftoneCell: src.extent.width / 70, outline: plan.camera?.outline == true ? min(W, H) / 150 / k : nil,
      ink: look.accent ?? "#FF4FD8", boil: Int(Double(f) / Double(plan.output.fps) * 6))
  }

  /// B-roll showing at this frame: in the screen card (`full` false) or over the whole frame, or
  /// with `overlay` the see-through clips floating over everything.
  func broll(_ image: CIImage, frame f: Double, full: Bool, overlay: Bool = false, box b: Box, frames: [Int: CIImage]) -> CIImage {
    var out = image
    for ins in inserts where ins.a.isOverlay == overlay && (overlay || ins.a.isFull == full) && f >= ins.s && f < ins.e {
      guard var src = insertImages[ins.index] ?? frames[ins.index] else { continue }
      let pose = insertPose(ins, frame: f)
      guard pose.visible else { continue }
      if ins.a.isSticker {
        out = sticker(src, ins.a, pose: pose).composited(over: out)
        continue
      }
      if brollRoom(ins) == "halftone" {
        src = styledBroll(src, ins, frame: Int(f), shownWidth: full ? W : b.w)
      }
      let rect = full ? CGRect(x: 0, y: 0, width: W, height: H) : ciRect(b)
      let radius = full ? 0 : b.r
      let fill = ins.a.fit != "fit"
      let iw = src.extent.width, ih = src.extent.height
      guard iw > 0, ih > 0 else { continue }
      let k = fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
      var placed = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
      placed = placed.transformed(by: CGAffineTransform(translationX: rect.midX - iw * k / 2, y: rect.midY - ih * k / 2))
      if !fill && !overlay {
        // Letterbox on black so the screen doesn't show around a fitted picture (an overlay is meant to show it).
        placed = placed.composited(over: CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.05)).cropped(to: rect))
      }
      if abs(pose.scale - 1) > 0.001 || abs(pose.dx) + abs(pose.dy) > 0.001 {
        let t = CGAffineTransform(translationX: -rect.midX, y: -rect.midY).concatenating(CGAffineTransform(scaleX: pose.scale, y: pose.scale))
          .concatenating(CGAffineTransform(translationX: rect.midX + pose.dx * rect.width, y: rect.midY - pose.dy * rect.height))
        placed = placed.transformed(by: t)
      }
      let shown = masked(placed, rect, radius: radius, opacity: min(1, pose.opacity))
      out = pose.lines < 0.999 ? interlaced(shown, over: out, in: rect, share: pose.lines) : shown.composited(over: out)
    }
    return out
  }

  /// Where a sticker sits (Core Image coordinates): `w` of the frame's width at the clip's shape, no
  /// taller than 80% of the frame, centered on `x`, `y` but kept, border and all, 4% of the frame's
  /// height from its edges.
  func stickerRect(_ a: Insert, imageSize s: CGSize) -> CGRect {
    let edge = stickerBorder + H * 0.04
    var w = W * (a.w ?? 0.32), h = w * s.height / s.width
    if h > H * 0.8 { (w, h) = (H * 0.8 * s.width / s.height, H * 0.8) }
    let cx = min(max(W * (a.x ?? 0.74), w / 2 + edge), W - w / 2 - edge)
    let cy = min(max(H * (a.y ?? 0.3), h / 2 + edge), H - h / 2 - edge)
    return CGRect(x: cx - w / 2, y: H - cy - h / 2, width: w, height: h)
  }

  var stickerBorder: Double { 10 * u }

  /// A sticker: the clip or picture in a white border with a soft drop shadow and its meme text,
  /// posed as one piece about its center.
  func sticker(_ src: CIImage, _ a: Insert, pose: OverlayPose) -> CIImage {
    let rect = stickerRect(a, imageSize: src.extent.size)
    let k = rect.width / src.extent.width
    var piece = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
      .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)).cropped(to: rect)
    if let text = memeText(a, size: rect.size) {
      piece = text.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)).composited(over: piece)
    }
    let paper = rect.insetBy(dx: -stickerBorder, dy: -stickerBorder)
    let shade = CIFilter(
      name: "CIRoundedRectangleGenerator",
      parameters: ["inputExtent": CIVector(cgRect: paper.offsetBy(dx: 0, dy: -8 * u)), "inputRadius": 6 * u, "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)]
    )!.outputImage!.applyingGaussianBlur(sigma: 10 * u)
    piece = piece.composited(over: roundedMask(paper, radius: 6 * u)).composited(over: shade)
    // Tilted like a sticker slapped on by hand (Core Image's y runs up, so the angle flips to turn clockwise on screen).
    let tilt = -(a.rotation ?? Insert.stickerTilt) * .pi / 180
    let t = CGAffineTransform(translationX: -rect.midX, y: -rect.midY).concatenating(CGAffineTransform(rotationAngle: tilt))
      .concatenating(CGAffineTransform(scaleX: pose.scale, y: pose.scale))
      .concatenating(CGAffineTransform(translationX: rect.midX + pose.dx * rect.width, y: rect.midY - pose.dy * rect.height))
    piece = piece.transformed(by: t)
    if pose.opacity < 0.999 {
      piece = piece.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, pose.opacity))])
    }
    return piece
  }

  /// A sticker's top and bottom text, sized to fit its width (at most a quarter of its height
  /// each), as an image the sticker's size; nil without text.
  func memeText(_ a: Insert, size: CGSize) -> CIImage? {
    let lines = [a.topText, a.bottomText].map { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    guard lines.contains(where: { !$0.isEmpty }), let ctx = Scene.context(Int(size.width), Int(size.height)) else { return nil }
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    let pad = size.height * 0.04, maxW = size.width * 0.94
    for (i, line) in lines.enumerated() where !line.isEmpty {
      var fontSize = size.height * 0.16 / 0.9
      var s: NSAttributedString, fit: CGSize
      repeat {
        fontSize *= 0.9
        s = Scene.text(line, size: fontSize, weight: .heavy, font: "Impact", stroke: 5)
        fit = CTFramesetterSuggestFrameSizeWithConstraints(
          CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0), nil, CGSize(width: maxW, height: .greatestFiniteMagnitude), nil)
      } while fit.height > size.height * 0.25 && fontSize > 8
      let y = i == 0 ? pad : size.height - pad - fit.height
      drawText(ctx, s, at: CGPoint(x: (size.width - maxW) / 2, y: y), size: CGSize(width: maxW, height: fit.height))
    }
    return ctx.makeImage().map { CIImage(cgImage: $0) }
  }

  /// `top` over `bottom` through an interlaced reveal of `rect`: bands of lines four pixels tall (at
  /// 1080p), the even ones sweeping in from the left over the first half of `share`, the odd ones
  /// over the second half, like an old TV picture filling in.
  func interlaced(_ top: CIImage, over bottom: CIImage, in rect: CGRect, share: Double) -> CIImage {
    let band = max(2, (4 * u).rounded())
    // Horizontal stripes: the generator makes vertical ones, so draw them along x and turn them.
    let stripes = CIFilter(
      name: "CIStripesGenerator",
      parameters: ["inputColor0": CIColor.white, "inputColor1": CIColor.black, "inputWidth": band, "inputSharpness": 1, "inputCenter": CIVector(x: 0, y: 0)]
    )!.outputImage!.transformed(by: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
    let even = stripes.cropped(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * min(1, share * 2), height: rect.height))
    let odd = stripes.applyingFilter("CIColorInvert")
      .cropped(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * max(0, share * 2 - 1), height: rect.height))
    let black = CIImage(color: .black).cropped(to: rect)
    let mask = even.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: odd.composited(over: black)])
      .composited(over: black)
    return top.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bottom, kCIInputMaskImageKey: mask])
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
