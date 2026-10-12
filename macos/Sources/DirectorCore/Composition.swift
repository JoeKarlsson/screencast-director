import AVFoundation
import CoreImage
import Foundation

/// An AVFoundation timeline for a plan. The same composition feeds the preview player and the
/// exporter, so what you see is what you export.
public struct BuiltComposition {
  public let asset: AVMutableComposition
  public let videoComposition: AVMutableVideoComposition
  public let audioMix: AVMutableAudioMix
  public let scene: Scene

  public func playerItem() -> AVPlayerItem {
    let item = AVPlayerItem(asset: asset)
    item.videoComposition = videoComposition
    item.audioMix = audioMix
    return item
  }
}

public enum CompositionError: LocalizedError {
  case noVideo(String)
  public var errorDescription: String? {
    switch self {
    case .noVideo(let f): return "\(f) has no video track."
    }
  }
}

private let fadeFrames = 3

public func buildComposition(project: Project, plan: Plan) async throws -> BuiltComposition {
  let scene = Scene(plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts)
  let fps = Int32(plan.output.fps)
  let comp = AVMutableComposition()

  let screenAsset = AVURLAsset(url: project.dir.appendingPathComponent(plan.source.video))
  guard let srcVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
    throw CompositionError.noVideo(plan.source.video)
  }
  let srcAudio = try await screenAsset.loadTracks(withMediaType: .audio).first
  let screenDuration = try await screenAsset.load(.duration)

  let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
  let aTrack = srcAudio != nil ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

  var camTrack: AVMutableCompositionTrack?
  var camSource: (AVAssetTrack, CMTime, Double)?
  // Held for the whole function: an AVAssetTrack doesn't keep its asset alive, and inserting
  // from a track whose asset is gone fails with -12780.
  var camAsset: AVURLAsset?
  if let camera = plan.camera {
    camAsset = AVURLAsset(url: project.dir.appendingPathComponent(camera.video))
    if let camAsset, let t = try await camAsset.loadTracks(withMediaType: .video).first {
      camSource = (t, try await camAsset.load(.duration), camera.offset)
      camTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    }
  }

  func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }
  func insert(_ track: AVMutableCompositionTrack, _ range: CMTimeRange, of src: AVAssetTrack, at: CMTime, _ what: String) throws {
    do {
      try track.insertTimeRange(range, of: src, at: at)
    } catch {
      throw NSError(
        domain: "Composition", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Couldn't add \(what) \(range.start.seconds)-\(range.end.seconds)s at \(at.seconds)s (source track \(src.timeRange.start.seconds)-\(src.timeRange.end.seconds)s)",
          NSUnderlyingErrorKey: error,
        ])
    }
  }
  let audioParams = aTrack.map { AVMutableAudioMixInputParameters(track: $0) }
  audioParams?.audioTimePitchAlgorithm = .spectral

  for s in scene.mapped {
    let at = CMTime(value: CMTimeValue(s.outStart), timescale: fps)
    let outDur = CMTime(value: CMTimeValue(s.frames), timescale: fps)
    let srcRange = CMTimeRange(start: t(s.start), end: CMTimeMinimum(t(s.end), screenDuration))
    guard srcRange.duration.seconds > 0 else { continue }

    try insert(vTrack, srcRange, of: srcVideo, at: at, "screen video")
    vTrack.scaleTimeRange(CMTimeRange(start: at, duration: srcRange.duration), toDuration: outDur)
    if let aTrack, let srcAudio {
      try insert(aTrack, srcRange, of: srcAudio, at: at, "audio")
      aTrack.scaleTimeRange(CMTimeRange(start: at, duration: srcRange.duration), toDuration: outDur)
      if s.speed > 1.01 {
        audioParams?.setVolume(0, at: at)
      } else {
        // Short fades at each cut hide clicks in the audio.
        let fade = CMTime(value: CMTimeValue(min(fadeFrames, s.frames / 2)), timescale: fps)
        audioParams?.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: at, duration: fade))
        audioParams?.setVolumeRamp(
          fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeSubtract(CMTimeAdd(at, outDur), fade), duration: fade))
      }
    }

    // The camera file covers [-offset, duration - offset] in screen time; insert only the overlap.
    if let camTrack, let (track, camDur, offset) = camSource {
      let a = max(s.start + offset, 0), b = min(s.end + offset, camDur.seconds)
      if b > a {
        let lead = (a - (s.start + offset)) / s.speed
        let camAt = CMTimeAdd(at, t(lead))
        try insert(camTrack, CMTimeRange(start: t(a), end: t(b)), of: track, at: camAt, "camera")
        camTrack.scaleTimeRange(CMTimeRange(start: camAt, duration: t(b - a)), toDuration: t((b - a) / s.speed))
      }
    }
  }

  withExtendedLifetime(camAsset) {}
  withExtendedLifetime(screenAsset) {}
  let total = CMTime(value: CMTimeValue(scene.frameCount), timescale: fps)
  // Rounding can leave a track (usually the camera) a few milliseconds past the last frame.
  // AVPlayer rejects a video composition whose instruction doesn't cover every track and then
  // plays nothing at all (black, silent), so trim everything to the exact frame count.
  if comp.duration > total {
    comp.removeTimeRange(CMTimeRange(start: total, end: comp.duration))
  }
  let instruction = DirectorInstruction(
    timeRange: CMTimeRange(start: .zero, duration: total), scene: scene, screenTrack: vTrack.trackID, cameraTrack: camTrack?.trackID)
  let vc = AVMutableVideoComposition()
  vc.customVideoCompositorClass = DirectorCompositor.self
  vc.frameDuration = CMTime(value: 1, timescale: fps)
  vc.renderSize = CGSize(width: plan.output.width, height: plan.output.height)
  vc.instructions = [instruction]

  let mix = AVMutableAudioMix()
  if let audioParams { mix.inputParameters = [audioParams] }
  return BuiltComposition(asset: comp, videoComposition: vc, audioMix: mix, scene: scene)
}

final class DirectorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = true
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID = kCMPersistentTrackID_Invalid
  let scene: Scene
  let screenTrack: CMPersistentTrackID
  let cameraTrack: CMPersistentTrackID?

  init(timeRange: CMTimeRange, scene: Scene, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID?) {
    self.timeRange = timeRange
    self.scene = scene
    self.screenTrack = screenTrack
    self.cameraTrack = cameraTrack
    requiredSourceTrackIDs = ([screenTrack] + (cameraTrack.map { [$0] } ?? [])).map { NSNumber(value: $0) }
  }
}

final class DirectorCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
  private let context = CIContext(options: [.workingColorSpace: Scene.srgb, .cacheIntermediates: false])

  var sourcePixelBufferAttributes: [String: any Sendable]? {
    [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA], kCVPixelBufferMetalCompatibilityKey as String: true]
  }
  var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
    [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA], kCVPixelBufferMetalCompatibilityKey as String: true]
  }

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    guard let instruction = request.videoCompositionInstruction as? DirectorInstruction,
      let out = request.renderContext.newPixelBuffer()
    else {
      request.finish(with: NSError(domain: "DirectorCompositor", code: 1))
      return
    }
    let scene = instruction.scene
    let frame = Int((request.compositionTime.seconds * Double(scene.fps)).rounded())
    let screen = request.sourceFrame(byTrackID: instruction.screenTrack).map { CIImage(cvPixelBuffer: $0) }
    let camera = instruction.cameraTrack.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
    let image = scene.render(frame: frame, screen: screen, camera: camera)
    context.render(image, to: out, bounds: CGRect(origin: .zero, size: request.renderContext.size), colorSpace: Scene.srgb)
    request.finish(withComposedVideoFrame: out)
  }

  func cancelAllPendingVideoCompositionRequests() {}
}

/// Renders the plan to an MP4. `progress` gets 0...1.
public func export(_ built: BuiltComposition, to url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
  try? FileManager.default.removeItem(at: url)
  guard let session = AVAssetExportSession(asset: built.asset, presetName: AVAssetExportPresetHighestQuality) else {
    throw NSError(domain: "Export", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't create an export session."])
  }
  session.videoComposition = built.videoComposition
  session.audioMix = built.audioMix
  let watcher = Task {
    for await state in session.states(updateInterval: 0.5) {
      if case .exporting(let p) = state { progress?(p.fractionCompleted) }
    }
  }
  defer { watcher.cancel() }
  try await session.export(to: url, as: .mp4)
  progress?(1)
}

/// One output frame, rendered through the same compositor as preview and export.
public func stillImage(_ built: BuiltComposition, frame: Int) async throws -> CGImage {
  let gen = AVAssetImageGenerator(asset: built.asset)
  gen.videoComposition = built.videoComposition
  gen.requestedTimeToleranceBefore = .zero
  gen.requestedTimeToleranceAfter = .zero
  let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(built.scene.fps))
  return try await gen.image(at: time).image
}
