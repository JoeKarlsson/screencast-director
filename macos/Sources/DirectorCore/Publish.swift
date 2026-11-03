import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Everything for posting a video: captions (SRT), chapters, an output-timed transcript for
/// writing a description, and thumbnails.
public enum Publish {
  // MARK: Captions and chapters

  static func stamp(_ seconds: Double, srt: Bool) -> String {
    let ms = Int((seconds * 1000).rounded())
    let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
    if srt { return String(format: "%02d:%02d:%02d,%03d", h, m, s, f) }
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  /// SubRip captions in output time, one cue per caption page (same grouping as the burned-in captions).
  public static func srt(_ scene: Scene) -> String {
    let fps = Double(scene.fps)
    let pages = Scene.captionPages(scene.words, scene.mapped, fps: scene.fps, maxWords: max(scene.plan.captions.maxWords, 8))
    return pages.enumerated().map { i, p in
      let start = p.startF / fps
      let next = i + 1 < pages.count ? pages[i + 1].startF / fps : .infinity
      let end = min(max(start + 0.3, (p.endF + 2) / fps), next)
      return "\(i + 1)\n\(stamp(start, srt: true)) --> \(stamp(end, srt: true))\n\(p.words.map(\.text).joined(separator: " "))\n"
    }.joined(separator: "\n")
  }

  /// YouTube chapters from the plan's titles: "0:00 Intro" plus one line per title. YouTube needs
  /// at least three, starting at 0:00, each at least 10 s long; returns nil when that can't be met.
  public static func chapters(_ scene: Scene) -> String? {
    let fps = Double(scene.fps)
    var marks: [(Double, String)] = [(0, "Intro")]
    let placed = scene.plan.callouts.compactMap { c in srcToOut(scene.mapped, c.start, fps: scene.fps).map { ($0, c) } }
    for (f, c) in placed.sorted(by: { $0.0 < $1.0 }) {
      let t = f / fps
      if t - (marks.last?.0 ?? 0) >= 10 { marks.append((t, c.text)) } else if t < 10 { marks[0].1 = c.text }
    }
    let total = Double(scene.frameCount) / fps
    if let last = marks.last, total - last.0 < 10 { marks.removeLast() }
    guard marks.count >= 3 else { return nil }
    return marks.map { "\(stamp($0.0, srt: false)) \($0.1)" }.joined(separator: "\n")
  }

  /// The narration with output timestamps, for an AI to write a description and chapters from.
  public static func timedTranscript(_ scene: Scene) -> String {
    let fps = Double(scene.fps)
    let pages = Scene.captionPages(scene.words, scene.mapped, fps: scene.fps, maxWords: 14)
    return pages.map { "[\(stamp($0.startF / fps, srt: false))] \($0.words.map(\.text).joined(separator: " "))" }.joined(separator: "\n")
  }

  // MARK: Thumbnails

  public struct Candidate {
    public var sourceTime: Double
    public var score: Double
    public var smiling: Bool
    public var image: CGImage
    /// The face's center in the image, fractions with y down (0.5, 0.4 when unknown).
    public var faceX: Double = 0.5
    public var faceY: Double = 0.4
  }

  /// Scores camera frames (every half second of kept video) for a sharp, smiling, eyes-open face
  /// and returns the best few, at least 3 s apart.
  public static func bestFaces(project: Project, plan: Plan, count: Int = 3, at chosen: [Double]? = nil) async throws -> [Candidate] {
    guard let camera = plan.camera else { return [] }
    let asset = AVURLAsset(url: project.dir.appendingPathComponent(camera.video))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 1280, height: 1280)
    gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
    gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
    let duration = try await asset.load(.duration).seconds
    let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!

    // Chosen moments (source seconds) are taken as they are, face or not; otherwise every half
    // second of real-time video is scored.
    var times: [Double] = []
    if let chosen, !chosen.isEmpty {
      times = chosen
    } else {
      for s in plan.segments where s.speed <= 1.01 { times += Array(stride(from: s.start + 0.25, to: s.end, by: 0.5)) }
    }
    var found: [Candidate] = []
    for t in times {
      do {
        let ct = t + camera.offset
        guard ct >= 0, ct < duration, let img = try? await gen.image(at: CMTime(seconds: ct, preferredTimescale: 600)).image else {
          continue
        }
        let quality = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: img).perform([quality])
        guard let face = quality.results?.max(by: { ($0.faceCaptureQuality ?? 0) < ($1.faceCaptureQuality ?? 0) }) else {
          if chosen != nil { found.append(Candidate(sourceTime: t, score: 0, smiling: false, image: img)) }
          continue
        }
        let features = detector.features(in: CIImage(cgImage: img), options: [CIDetectorSmile: true, CIDetectorEyeBlink: true])
          .compactMap { $0 as? CIFaceFeature }
        let main = features.max { $0.bounds.width < $1.bounds.width }
        let smiling = main?.hasSmile ?? false
        let blinking = (main?.leftEyeClosed ?? false) || (main?.rightEyeClosed ?? false)
        // Quality first; a smile is a big bonus, a blink a big penalty; bigger faces read better.
        let score = Double(face.faceCaptureQuality ?? 0) + (smiling ? 0.5 : 0) - (blinking ? 0.6 : 0)
          + Double(face.boundingBox.width) * 0.3
        let box = face.boundingBox  // Vision: normalized, y up
        found.append(Candidate(sourceTime: t, score: score, smiling: smiling, image: img, faceX: box.midX, faceY: 1 - box.midY))
      }
    }
    if let chosen, !chosen.isEmpty { return found }
    var picked: [Candidate] = []
    for c in found.sorted(by: { $0.score > $1.score }) where picked.allSatisfy({ abs($0.sourceTime - c.sourceTime) >= 3 }) {
      picked.append(c)
      if picked.count == count { break }
    }
    return picked
  }

  /// The person cut out of a camera frame (transparent elsewhere), or nil if no one is found.
  static func cutout(_ image: CGImage) -> CIImage? {
    let req = VNGeneratePersonSegmentationRequest()
    req.qualityLevel = .accurate
    req.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try? VNImageRequestHandler(cgImage: image).perform([req])
    guard let mask = req.results?.first?.pixelBuffer else { return nil }
    let src = CIImage(cgImage: image)
    var m = CIImage(cvPixelBuffer: mask)
    m = m.transformed(by: CGAffineTransform(scaleX: src.extent.width / m.extent.width, y: src.extent.height / m.extent.height))
    return src.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": CIImage.empty(), "inputMaskImage": m])
  }

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
    let look = plan.look ?? Look()
    Fonts.register(look.fontFiles)
    guard
      let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0, space: Scene.srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    let bgHex = look.chipBackground ?? look.captionBackground ?? "#111318"
    ctx.setFillColor(Scene.color(bgHex))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // The photo: the bottom 52%, cropped to that shape around the face (y-up drawing below).
    let photo = asShown(person, plan: plan)
    let photoH = H * 0.52
    let iw = Double(photo.width), ih = Double(photo.height)
    let cropW = min(iw, ih * W / photoH), cropH = cropW * photoH / W
    let fx = plan.camera?.mirror == true ? 1 - faceX : faceX
    let cx = min(max(fx * iw - cropW / 2, 0), iw - cropW)
    if let crop = photo.cropping(to: CGRect(x: cx, y: (ih - cropH) / 2, width: cropW, height: cropH)) {
      ctx.draw(crop, in: CGRect(x: 0, y: 0, width: W, height: photoH))
    }
    // Fade the photo's top edge into the background.
    let bg = Scene.color(bgHex)
    let fade = CGGradient(colorsSpace: Scene.srgb, colors: [bg, bg.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: photoH), end: CGPoint(x: 0, y: photoH - 200), options: [])

    // The title: white lines, then the last on the chip, each centered, the block centered in the
    // dark area above the photo with even margins.
    let margin = 80.0, chipPadX = 30.0, chipPadY = 14.0
    // The area runs from the top of the frame down to where the photo starts to show through its
    // fade; the title gets the largest size that fits it with a margin all round.
    let areaBottom = photoH - 60
    var start = 132.0
    var lines: [String] = [], texts: [NSAttributedString] = [], sizes: [CGSize] = []
    var gap = 0.0, blockH = 0.0
    repeat {
      let fit = coverTitle(title, font: look.titleFont, maxWidth: W - 2 * margin - 2 * chipPadX, start: start)
      lines = fit.lines
      texts = lines.enumerated().map { k, line in
        Scene.text(
          line, size: fit.size, weight: .heavy, font: look.titleFont,
          color: k == lines.count - 1 ? (look.titleText ?? "#111318") : (look.captionText ?? "#F3F4F6"), align: .left)
      }
      sizes = texts.map { Scene.measure($0, maxWidth: .greatestFiniteMagnitude) }
      gap = fit.size * 0.14
      blockH = sizes.reduce(0) { $0 + $1.height } + gap * Double(lines.count - 1) + 2 * chipPadY + gap
      start = fit.size - 6
    } while blockH > H - areaBottom - 2 * margin && start > 48
    var y = areaBottom + (H - areaBottom) / 2 + blockH / 2  // the block's top, y up
    for (k, s) in texts.enumerated() {
      let m = sizes[k]
      let chip = k == lines.count - 1
      if chip {
        y -= gap + chipPadY
        let r = CGRect(x: (W - m.width) / 2 - chipPadX, y: y - m.height - chipPadY, width: m.width + 2 * chipPadX, height: m.height + 2 * chipPadY)
        ctx.setFillColor(Scene.color(look.titleBackground ?? look.accent ?? "#FDAE84"))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.fillPath()
      }
      let frame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(s), CFRange(location: 0, length: 0),
        CGPath(rect: CGRect(x: (W - m.width) / 2, y: y - m.height, width: m.width + 2, height: m.height), transform: nil), nil)
      CTFrameDraw(frame, ctx)
      y -= m.height + gap
    }
    return ctx.makeImage()
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

  /// Writes publish/captions.srt, publish/chapters.txt (when titles allow), publish/transcript.txt and
  /// publish/thumbnail-N.png. Returns the files written.
  /// `coverAt`: source seconds to make the covers from, instead of the best-scoring faces.
  public static func run(project: Project, plan: Plan, title: String, coverAt: [Double]? = nil, log: (String) -> Void = { _ in }) async throws -> [URL] {
    let out = project.dir.appendingPathComponent("publish")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let scene = Scene(plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts)
    var files: [URL] = []

    let srtURL = out.appendingPathComponent("captions.srt")
    try srt(scene).write(to: srtURL, atomically: true, encoding: .utf8)
    files.append(srtURL)
    let tURL = out.appendingPathComponent("transcript.txt")
    try timedTranscript(scene).write(to: tURL, atomically: true, encoding: .utf8)
    files.append(tURL)
    if let ch = chapters(scene) {
      let u = out.appendingPathComponent("chapters.txt")
      try ch.write(to: u, atomically: true, encoding: .utf8)
      files.append(u)
    }

    log("Finding your best camera frames…")
    // Moments picked on the command line, else the ones saved in the plan, else the best faces.
    let faces = try await bestFaces(project: project, plan: plan, at: coverAt ?? plan.coverAt)
    let built = try await buildComposition(project: project, plan: plan)
    // One thumbnail per good face; without a camera, one per title moment (or the middle).
    // A vertical video gets vertical covers: the title over the camera frame, framed on the face.
    if plan.output.height > plan.output.width, !faces.isEmpty {
      for (i, f) in faces.enumerated() {
        log("Composing cover \(i + 1) of \(faces.count)…")
        guard let thumb = verticalThumbnail(plan: plan, person: f.image, faceX: f.faceX, title: title) else { continue }
        let u = out.appendingPathComponent("thumbnail-\(i + 1).png")
        try writePNG(thumb, to: u)
        files.append(u)
      }
      return files
    }
    var moments: [(Double, CGImage?)] = faces.map { ($0.sourceTime, $0.image) }
    if moments.isEmpty {
      let titled = plan.callouts.map { $0.start + 0.5 }
      moments = (titled.isEmpty ? [plan.segments[plan.segments.count / 2].start] : Array(titled.prefix(3))).map { ($0, nil) }
    }
    let srcAsset = AVURLAsset(url: project.dir.appendingPathComponent(plan.source.video))
    let srcGen = AVAssetImageGenerator(asset: srcAsset)
    srcGen.maximumSize = CGSize(width: 1920, height: 1920)
    for (i, m) in moments.enumerated() {
      log("Composing thumbnail \(i + 1) of \(moments.count)…")
      guard let screen = try? await srcGen.image(at: CMTime(seconds: m.0, preferredTimescale: 600)).image,
        let thumb = thumbnail(scene: built.scene, screen: screen, person: m.1, title: title)
      else { continue }
      let u = out.appendingPathComponent("thumbnail-\(i + 1).png")
      try writePNG(thumb, to: u)
      files.append(u)
    }
    return files
  }
}

extension Publish {
  /// The zoom that lets the face sit dead center (the crop needs room to pan), from 1.15x up to 1.8x.
  public static func centeringZoom(x: Double, y: Double) -> Double {
    let need = max(0.5 / max(min(x, 1 - x), 0.05), 0.5 / max(min(y, 1 - y), 0.05))
    return min(1.8, max(1.15, (need * 20).rounded(.up) / 20))
  }

  /// Where the speaker's face usually is in the camera footage (median of face centers sampled
  /// every few seconds), for auto-framing. nil when no face is found.
  public static func faceCenter(project: Project, plan: Plan) async throws -> (x: Double, y: Double)? {
    guard let camera = plan.camera else { return nil }
    let asset = AVURLAsset(url: project.dir.appendingPathComponent(camera.video))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 960, height: 960)
    gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
    gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
    let duration = try await asset.load(.duration).seconds
    var xs: [Double] = [], ys: [Double] = []
    var t = 1.0
    while t < duration {
      defer { t += max(2, duration / 40) }
      guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
      let req = VNDetectFaceRectanglesRequest()
      try? VNImageRequestHandler(cgImage: img).perform([req])
      // The biggest face is the speaker; Vision's boxes are normalized with y up.
      guard let face = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { continue }
      xs.append(face.boundingBox.midX)
      ys.append(1 - face.boundingBox.midY)
    }
    guard !xs.isEmpty else { return nil }
    xs.sort()
    ys.sort()
    return (xs[xs.count / 2], ys[ys.count / 2])
  }
}
