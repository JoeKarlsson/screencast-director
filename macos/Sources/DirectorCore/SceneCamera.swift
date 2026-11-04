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
    let req = VNGeneratePersonSegmentationRequest()
    req.qualityLevel = .balanced
    req.outputPixelFormat = kCVPixelFormatType_OneComponent8
    let origin = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
    do {
      try VNImageRequestHandler(ciImage: origin).perform([req])
    } catch {
      return CIImage.empty()
    }
    guard let buffer = req.results?.first?.pixelBuffer else { return CIImage.empty() }
    var mask = CIImage(cvPixelBuffer: buffer)
    mask = mask.transformed(by: CGAffineTransform(
      scaleX: origin.extent.width / mask.extent.width, y: origin.extent.height / mask.extent.height))
      .transformed(by: CGAffineTransform(translationX: src.extent.minX, y: src.extent.minY))
    return src.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": mask])
  }
}
