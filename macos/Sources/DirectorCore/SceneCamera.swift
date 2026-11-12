import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Vision

// The camera picture: grading, framing on the face and the person cutout.
extension Scene {
  /// The camera picture through the plan's grade, then `lut` (the grade's LUT, loaded by the caller).
  static func graded(_ img: CIImage, _ g: Grade?, lut: CubeLUT? = nil) -> CIImage {
    guard let g else { return img }
    var out = img
    if let e = g.exposure, e != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": e]) }
    let hi = min(0, max(-1, g.highlights ?? 0)), sh = min(1, max(-1, g.shadows ?? 0))
    if hi != 0 || sh != 0 {
      out = out.applyingFilter(
        "CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 + hi, "inputShadowAmount": sh, "inputRadius": 0])
    }
    if g.contrast != nil || g.saturation != nil {
      out = out.applyingFilter(
        "CIColorControls", parameters: ["inputContrast": g.contrast ?? 1, "inputSaturation": g.saturation ?? 1, "inputBrightness": 0])
    }
    if let v = g.vibrance, v != 0 { out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": v]) }
    if let w = g.warmth, w != 0 {
      // A target neutral below the source's warms the picture, above it cools it.
      out = out.applyingFilter(
        "CITemperatureAndTint",
        parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - w * 2500, y: 0)])
    }
    if let lut { out = lut.apply(to: out) }
    return out.cropped(to: img.extent)
  }

  func cameraCard(_ src0: CIImage, box b: Box, frame f: Double) -> CIImage {
    var src = Scene.graded(src0, plan.camera?.grade, lut: cameraLUT)
    let cw = src.extent.width, ch = src.extent.height
    let cam = plan.camera
    let mirrored = cam?.mirror == true
    if mirrored {
      // x -> minX + maxX - x: flipped in place, same extent.
      let e = src.extent
      src = src.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: e.minX + e.maxX, ty: 0))
    }
    let (r, zoom) = cameraFraming(b, frame: f, cameraWidth: cw, cameraHeight: ch)
    let k = max(r.width / cw, r.height / ch) * zoom
    // Keep the framing point centered, clamped so the camera image always covers the box.
    // The framing point is in the file's coordinates, so it mirrors with the picture. A punch-in
    // can move it for its span.
    let punch = punchIns.last(where: { f >= $0.s && f < $0.e })
    let px = punch?.x ?? cam?.x ?? 0.5, fy = punch?.y ?? cam?.y ?? 0.5
    let fx = mirrored ? 1 - px : px
    var tx = r.midX - fx * cw * k
    var ty = r.midY - (1 - fy) * ch * k
    tx = min(r.minX, max(tx, r.maxX - cw * k))
    ty = min(r.minY, max(ty, r.maxY - ch * k))
    // Effects draw on the picture as it's shown, so their text reads the right way round. They're
    // told which part of it the box shows (camera pixels, y down), so tracked boxes stay in view.
    let shown = CGRect(x: (r.minX - tx) / k, y: ch - (r.maxY - ty) / k, width: r.width / k, height: r.height / k)
    src = withEffects(src, layer: "camera", frame: Int(f), shown: shown)
    // The room as halftone and the outline: sized to the picture as shown, so the dots and the line
    // look the same in a bubble and a full-frame camera.
    if cam?.room == "halftone" || cam?.outline == true, let mask = steadyMask(src, frame: Int(f)) {
      let fps = Double(plan.output.fps)
      src = Scene.styledRoom(
        src, mask: mask, halftoneCell: cam?.room == "halftone" ? shown.width / 70 : nil, outline: cam?.outline == true ? min(W, H) / 150 / k : nil,
        ink: look.accent ?? Look.defaultAccent, boil: Int(f / fps * 6))
    }
    let cut = cutoutWeight(b)
    if cut > 0 {
      let person = Scene.personCutout(src)
      src = cut < 1 ? src.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: person, kCIInputTimeKey: cut]) : person
    }
    var moved = Scene.scaled(src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY)), by: k)
    // A camera blown up a lot (1080p filling a vertical 4K frame is about 3.5x) gets a little
    // crispness back: a moderate sharpen of brightness only, so no color halos. It can't add detail
    // the camera never recorded; recording the camera at 4K is what fixes that.
    if k > 1.5 {
      moved = moved.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.6, kCIInputRadiusKey: 2.0]).cropped(to: moved.extent)
    }
    let placed = moved.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    return masked(placed, r, radius: b.r, opacity: b.opacity)
  }

  /// Where the camera picture goes and how far it's zoomed, for a camera box at an output frame.
  /// The cutout is for the bubble over the screen; the full camera keeps the room behind the
  /// speaker, so as the box grows from the bubble to the full camera, the background fades back in.
  /// A cutout bubble has no edge to show, so it widens to the camera's shape around its center
  /// and skips the framing zoom: the whole person shows, standing on the box's bottom edge,
  /// instead of the box's sides and the zoom slicing off the shoulders and arms.
  func cameraFraming(_ b: Box, frame f: Double, cameraWidth cw: Double, cameraHeight ch: Double) -> (rect: CGRect, zoom: Double) {
    var r = ciRect(b)
    var zoom = max(1, plan.camera?.zoom ?? 1)
    let cut = cutoutWeight(b)
    if cut > 0 {
      let wide = max(r.width, r.height * cw / ch)
      r = r.insetBy(dx: (r.width - (r.width + (wide - r.width) * cut)) / 2, dy: 0)
      zoom += (1 - zoom) * cut
    }
    // The portrait split's camera is a short, wide strip: frame the face tighter, like a closer shot.
    if socialTop(plan) != nil, b.y > 1 { zoom *= 1.35 }
    // A punch-in snaps tighter for its whole span, with no ease, like a cut to a closer shot.
    if let punch = punchIns.last(where: { f >= $0.s && f < $0.e }) { zoom = max(1, zoom * punch.scale) }
    return (r, zoom)
  }

  /// How far the camera box is from the full camera toward the bubble (0 full camera, 1 bubble),
  /// when the plan cuts out the background; 0 without a cutout.
  func cutoutWeight(_ b: Box) -> Double {
    guard plan.camera?.cutout == true else { return 0 }
    let full = layoutBoxes(.camera, plan: plan).cam.h, bubble = layoutBoxes(.pip, plan: plan).cam.h
    guard full > bubble else { return 1 }
    return min(1, max(0, (full - b.h) / (full - bubble)))
  }

  /// The person in a camera frame with the background made clear (Vision person segmentation).
  /// When Vision fails or finds no one, the result is empty: the camera disappears for that frame
  /// rather than showing the background it was asked to remove.
  static func personCutout(_ src: CIImage) -> CIImage {
    guard let mask = personMask(src) else { return CIImage.empty() }
    return src.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": mask])
  }

  /// Where the person is in a camera frame (white), over the frame's extent; nil when Vision fails.
  static func personMask(_ src: CIImage) -> CIImage? {
    let req = VNGeneratePersonSegmentationRequest()
    req.qualityLevel = .balanced
    req.outputPixelFormat = kCVPixelFormatType_OneComponent8
    let origin = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
    do {
      try VNImageRequestHandler(ciImage: origin).perform([req])
    } catch {
      return nil
    }
    guard let buffer = req.results?.first?.pixelBuffer else { return nil }
    let mask = CIImage(cvPixelBuffer: buffer)
    return mask.transformed(by: CGAffineTransform(
      scaleX: origin.extent.width / mask.extent.width, y: origin.extent.height / mask.extent.height))
      .transformed(by: CGAffineTransform(translationX: src.extent.minX, y: src.extent.minY))
  }

  /// The earlier output frames whose masks frame `f`'s is averaged with: up to two, from the same
  /// clip, and none when that clip is sped up past 1.5x (the person moves too far between them).
  func maskFramesToAverage(_ f: Int) -> [Int] {
    guard let seg = mapped.first(where: { f >= $0.outStart && f < $0.outStart + $0.frames }), seg.speed <= 1.5 else { return [] }
    return [f - 1, f - 2].filter { $0 >= seg.outStart }
  }

  /// The person mask at output frame `f`, averaged with the two frames before it when they're from
  /// the same clip played at about real speed, so the edge doesn't jitter frame to frame. Never across
  /// a cut, so nothing ghosts. nil when Vision fails (the picture is then left as recorded).
  func steadyMask(_ src: CIImage, frame f: Int) -> CIImage? {
    guard let mask = Scene.personMask(src) else { return nil }
    return averaged(mask, frame: f, lane: -1, earlier: maskFramesToAverage(f))
  }

  /// `mask` stored for frame `f`, averaged equally with the stored masks of `earlier` frames.
  func averaged(_ mask: CIImage, frame f: Int, lane: Int, earlier frames: [Int]) -> CIImage {
    recentMasks.store(f, mask, lane: lane)
    let earlier = frames.compactMap { recentMasks.mask($0, lane: lane) }.filter { $0.extent == mask.extent }
    guard !earlier.isEmpty else { return mask }
    // A running mean: each earlier mask blended in at 1/2, then 1/3. (Scaling and adding them goes
    // wrong: Core Image premultiplies and unpremultiplies along the way and halves the mask.)
    return earlier.enumerated().reduce(mask) { acc, e in
      acc.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: e.element, kCIInputTimeKey: 1 / Double(e.offset + 2)])
    }.cropped(to: mask.extent)
  }

  /// Where the subject is in a B-roll frame (white): Vision's foreground instances, all of them, the
  /// way Photos lifts a subject. nil when Vision fails or finds nothing.
  static func subjectMask(_ src: CIImage) -> CIImage? {
    let req = VNGenerateForegroundInstanceMaskRequest()
    let origin = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
    let handler = VNImageRequestHandler(ciImage: origin)
    do {
      try handler.perform([req])
      guard let result = req.results?.first else { return nil }
      let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
      let mask = CIImage(cvPixelBuffer: buffer)
      return mask.transformed(by: CGAffineTransform(
        scaleX: origin.extent.width / mask.extent.width, y: origin.extent.height / mask.extent.height))
        .transformed(by: CGAffineTransform(translationX: src.extent.minX, y: src.extent.minY))
    } catch {
      return nil
    }
  }

  /// A halftone: dots on a 45-degree grid sized by brightness, in `ink`, over a
  /// half-strength duotone of the same ink, on black. `cell` is the dot spacing in pixels.
  static func halftone(_ img: CIImage, cell: Double, ink: String) -> CIImage {
    // Core Image works in linear light: the ink's sRGB values as multipliers would come out paler.
    let c = CIColor(cgColor: color(ink).converted(to: CGColorSpace(name: CGColorSpace.linearSRGB)!, intent: .defaultIntent, options: nil) ?? color(ink))
    let gray = img.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 1.15, "inputBrightness": 0])
    // CIDotScreen draws dark tones as big black dots; on the inverted picture that's bright tones
    // as big dots, which inverting again makes white.
    let dots = gray.applyingFilter("CIColorInvert")
      .applyingFilter("CIDotScreen", parameters: [
        "inputCenter": CIVector(x: img.extent.midX, y: img.extent.midY), "inputAngle": Double.pi / 4,
        "inputWidth": max(3, cell), "inputSharpness": 0.7,
      ])
      .applyingFilter("CIColorInvert")
    func tinted(_ i: CIImage, _ k: Double) -> CIImage {
      i.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: c.red * k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: c.green * k, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: c.blue * k, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ])
    }
    return tinted(dots, 1).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: tinted(gray, 0.5)])
      .cropped(to: img.extent)
  }

  /// The camera picture with its room in halftone (`halftoneCell`, dot spacing in pixels) and/or a
  /// chalk crayon line around the person (`outline`, its width in pixels). The line boils: `boil`
  /// changes six times a second. `mask` is where the person is (personMask, or steadyMask).
  static func styledRoom(_ src: CIImage, mask soft: CIImage, halftoneCell: Double?, outline: Double?, ink: String, boil: Int) -> CIImage {
    // Vision's mask is soft and half-gray around hair, and those patches change every frame:
    // the room and the line follow a hard edge at the mask's middle instead, so they hold still.
    let feather = max(1, min(src.extent.width, src.extent.height) / 400)
    let mask = soft.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
      .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 6, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 6, w: 0), "inputBiasVector": CIVector(x: -3, y: -3, z: -3, w: 0),
      ])
      .applyingFilter("CIColorClamp").cropped(to: src.extent)
    var out = src
    if let cell = halftoneCell {
      out = src.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: halftone(src, cell: cell, ink: ink), kCIInputMaskImageKey: mask,
      ])
    }
    if let width = outline, width > 0 {
      // The ring: the person grown by the line's width, minus the person.
      let grown = mask.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: width]).cropped(to: src.extent)
      let outside = mask.applyingFilter("CIColorInvert")
      var ring = grown.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: outside])
      // Wobble: pushed about by soft noise that changes with `boil`.
      let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
        .transformed(by: CGAffineTransform(translationX: Double(boil % 3) * 517, y: Double(boil % 3) * 311))
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: width * 2.5])
      ring = ring.clampedToExtent().applyingFilter("CIDisplacementDistortion", parameters: [
        "inputDisplacementImage": noise, kCIInputScaleKey: width * 2,
      ]).cropped(to: src.extent)
      // Crayon grain: specks of the line missing.
      let specks = CIFilter(name: "CIRandomGenerator")!.outputImage!
        .applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 4, "inputBrightness": 0.5])
      ring = ring.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: specks]).cropped(to: src.extent)
      let chalk = CIImage(color: CIColor(cgColor: color("#ECE6DA"))).cropped(to: src.extent)
      out = chalk.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: ring])
    }
    return out.cropped(to: src.extent)
  }
}

/// The last few person masks by output frame, shared by a scene's render threads.
/// `lane` keeps the camera's (-1) apart from each B-roll clip's (its index).
final class RecentMasks: @unchecked Sendable {
  private var masks: [Int: [Int: CIImage]] = [:]
  private let lock = NSLock()

  func store(_ f: Int, _ mask: CIImage, lane: Int = -1) {
    lock.lock()
    defer { lock.unlock() }
    // Keep only frames near this one: scrubbing or a second render starts over.
    var near = (masks[lane] ?? [:]).filter { abs($0.key - f) <= 4 }
    near[f] = mask
    masks[lane] = near
  }

  func mask(_ f: Int, lane: Int = -1) -> CIImage? {
    lock.lock()
    defer { lock.unlock() }
    return masks[lane]?[f]
  }
}
