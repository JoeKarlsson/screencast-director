import AVFoundation
import CoreImage
import Foundation

// The custom video compositor: each frame's instruction, and rendering it through Scene.

final class DirectorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = true
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID = kCMPersistentTrackID_Invalid
  let scene: Scene
  let screenTrack: CMPersistentTrackID
  let cameraTrack: CMPersistentTrackID?
  let handleTrack: CMPersistentTrackID?
  /// B-roll clip tracks by their index in plan.inserts (then rendered animations, after them).
  let insertTracks: [Int: CMPersistentTrackID]

  init(
    timeRange: CMTimeRange, scene: Scene, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID?,
    handleTrack: CMPersistentTrackID? = nil, insertTracks: [Int: CMPersistentTrackID] = [:]
  ) {
    self.timeRange = timeRange
    self.scene = scene
    self.screenTrack = screenTrack
    self.cameraTrack = cameraTrack
    self.handleTrack = handleTrack
    self.insertTracks = insertTracks
    requiredSourceTrackIDs = ([screenTrack] + [cameraTrack, handleTrack].compactMap { $0 } + insertTracks.values.sorted()).map {
      NSNumber(value: $0)
    }
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
      request.finish(with: DirectorError("The preview couldn't get a frame to draw into"))
      return
    }
    let scene = instruction.scene
    let frame = Int((request.compositionTime.seconds * Double(scene.fps)).rounded())
    let screen = request.sourceFrame(byTrackID: instruction.screenTrack).map { CIImage(cvPixelBuffer: $0) }
    let camera = instruction.cameraTrack.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
    let handle = instruction.handleTrack.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
    var inserts: [Int: CIImage] = [:]
    for (index, track) in instruction.insertTracks {
      if let px = request.sourceFrame(byTrackID: track) { inserts[index] = CIImage(cvPixelBuffer: px) }
    }
    let image = scene.render(frame: frame, screen: screen, camera: camera, handle: handle, insertFrames: inserts)
    context.render(image, to: out, bounds: CGRect(origin: .zero, size: request.renderContext.size), colorSpace: Scene.srgb)
    request.finish(withComposedVideoFrame: out)
  }

  func cancelAllPendingVideoCompositionRequests() {}
}
