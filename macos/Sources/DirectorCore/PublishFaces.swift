import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Picking the clearest camera frames, cutting the person out, and centering on the face.

extension Publish {
  // MARK: Thumbnails

  public struct Candidate: Sendable {
    public var sourceTime: Double
    public var score: Double
    public var smiling: Bool
    public var image: CGImage
    /// The face's center in the image, fractions with y down (0.5, 0.4 when unknown).
    public var faceX: Double = 0.5
    public var faceY: Double = 0.4
    /// The face's width as a fraction of the image's (nil when unknown), to frame it on a cover.
    public var faceWidth: Double?
  }

  /// Whether the camera is covered at a source time: full-frame B-roll or an animation is showing.
  static func cameraHidden(_ plan: Plan, at t: Double) -> Bool {
    (plan.inserts ?? []).contains { $0.isFull && $0.start <= t && t < $0.end }
      || plan.animationList.contains { $0.start <= t && t < $0.end }
  }

  /// A cover score for a detected face: capture quality first, a smile a big bonus, a blink a big
  /// penalty, bigger faces better; a face cut off by the frame's edge or turned away from the lens
  /// (yaw past about 17°) is marked down hard, and one crowding the top (no room above the head for
  /// a cover's title) a little. `box` is Vision's, normalized with y up.
  static func faceScore(quality: Double, box: CGRect, smiling: Bool, blinking: Bool, yaw: Double?) -> Double {
    let atEdge = box.minX < 0.03 || box.maxX > 0.97 || box.minY < 0.03 || box.maxY > 0.97
    let turned = abs(yaw ?? 0) > 0.3
    let cramped = box.maxY > 0.8
    return quality + (smiling ? 0.5 : 0) - (blinking ? 0.6 : 0) + Double(box.width) * 0.3 - (atEdge ? 0.8 : 0) - (turned ? 0.5 : 0)
      - (cramped ? 0.3 : 0)
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
      // Moments the video shows the camera: not sped up, not under full-frame B-roll.
      for s in plan.segments where s.speed <= 1.01 {
        times += stride(from: s.start + 0.25, to: s.end, by: 0.5).filter { !cameraHidden(plan, at: $0) }
      }
    }
    var found: [Candidate] = []
    for t in times {
      do {
        let ct = t + camera.offset
        guard ct >= 0, ct < duration, let img = try? await gen.image(at: CMTime(seconds: ct, preferredTimescale: 600)).image else {
          continue
        }
        let quality = VNDetectFaceCaptureQualityRequest(), rects = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: img).perform([quality, rects])
        guard let face = quality.results?.max(by: { ($0.faceCaptureQuality ?? 0) < ($1.faceCaptureQuality ?? 0) }) else {
          if chosen != nil { found.append(Candidate(sourceTime: t, score: 0, smiling: false, image: img)) }
          continue
        }
        let features = detector.features(in: CIImage(cgImage: img), options: [CIDetectorSmile: true, CIDetectorEyeBlink: true])
          .compactMap { $0 as? CIFaceFeature }
        let main = features.max { $0.bounds.width < $1.bounds.width }
        let smiling = main?.hasSmile ?? false
        let blinking = (main?.leftEyeClosed ?? false) || (main?.rightEyeClosed ?? false)
        let box = face.boundingBox  // Vision: normalized, y up
        // Which way the face turns comes from the rectangles request (the same face, the box nearest it).
        let yaw = rects.results?.min { abs($0.boundingBox.midX - box.midX) < abs($1.boundingBox.midX - box.midX) }?.yaw?.doubleValue
        let score = faceScore(quality: Double(face.faceCaptureQuality ?? 0), box: box, smiling: smiling, blinking: blinking, yaw: yaw)
        found.append(
          Candidate(sourceTime: t, score: score, smiling: smiling, image: img, faceX: box.midX, faceY: 1 - box.midY, faceWidth: box.width))
      }
    }
    var picked: [Candidate] = []
    if let chosen, !chosen.isEmpty {
      picked = found
    } else {
      for c in found.sorted(by: { $0.score > $1.score }) where picked.allSatisfy({ abs($0.sourceTime - c.sourceTime) >= 3 }) {
        picked.append(c)
        if picked.count == count { break }
      }
    }
    // Scoring used small frames; the covers get the picked moments at full size.
    gen.maximumSize = CGSize(width: 2160, height: 2160)
    for i in picked.indices {
      if let big = try? await gen.image(at: CMTime(seconds: picked[i].sourceTime + camera.offset, preferredTimescale: 600)).image {
        picked[i].image = big
      }
    }
    return picked
  }

  /// Frames of the video's full-frame B-roll for the top of a split cover: each clip's sharpest
  /// moment (a picture as it is), in the order the video shows them (the first is usually the
  /// establishing shot), leaving out clips much blurrier than the sharpest; at most `count`.
  public static func subjectFrames(project: Project, plan: Plan, count: Int = 3) async -> [CGImage] {
    var best: [(image: CGImage, sharpness: Double)] = []
    for ins in (plan.inserts ?? []).sorted(by: { $0.start < $1.start }) where ins.isFull {
      let url = project.dir.appendingPathComponent(ins.file)
      if ins.isImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
          best.append((img, sharpness(img)))
        }
        continue
      }
      let asset = AVURLAsset(url: url)
      guard let duration = try? await asset.load(.duration).seconds else { continue }
      let gen = AVAssetImageGenerator(asset: asset)
      gen.appliesPreferredTrackTransform = true
      gen.maximumSize = CGSize(width: 2160, height: 2160)
      gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
      gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
      // Five moments across the part of the clip the video plays.
      let from = ins.from ?? 0, to = min(duration, from + ins.end - ins.start)
      var frames: [(image: CGImage, sharpness: Double)] = []
      for k in 0..<5 {
        let t = from + (to - from) * (Double(k) + 0.5) / 5
        if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { frames.append((img, sharpness(img))) }
      }
      if let sharpest = frames.max(by: { $0.sharpness < $1.sharpness }) { best.append(sharpest) }
    }
    let sharpest = best.map(\.sharpness).max() ?? 0
    return best.filter { $0.sharpness >= sharpest * 0.5 }.prefix(count).map(\.image)
  }

  /// How sharp a frame is: the mean squared difference between neighboring pixels of a small gray
  /// copy. Motion blur and soft focus score low.
  static func sharpness(_ img: CGImage) -> Double {
    let w = 192, h = max(1, Int(192 * Double(img.height) / Double(max(1, img.width))))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0),
      let data = { ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }()
    else { return 0 }
    let p = data.bindMemory(to: UInt8.self, capacity: w * h)
    var sum = 0.0
    for y in 0..<(h - 1) {
      for x in 0..<(w - 1) {
        let v = Double(p[y * w + x]), dx = Double(p[y * w + x + 1]) - v, dy = Double(p[(y + 1) * w + x]) - v
        sum += dx * dx + dy * dy
      }
    }
    return sum / Double(max(1, (w - 1) * (h - 1)))
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
