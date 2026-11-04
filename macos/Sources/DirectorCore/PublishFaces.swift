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
