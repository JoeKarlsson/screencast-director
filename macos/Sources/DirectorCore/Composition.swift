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
  let scene = Scene(
    plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts, cursorPath: project.cursorPath,
    dir: project.dir)
  let fps = Int32(plan.output.fps)
  let comp = AVMutableComposition()

  let screenAsset = AVURLAsset(url: project.dir.appendingPathComponent(plan.source.video))
  guard let srcVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
    throw CompositionError.noVideo(plan.source.video)
  }
  var srcAudio = try await screenAsset.loadTracks(withMediaType: .audio).first
  let screenDuration = try await screenAsset.load(.duration)
  // Clean up voice: same timing, audio from the cached voice-clean.m4a. If the render fails, keep
  // the original audio rather than failing the whole preview.
  var cleanAsset: AVURLAsset?
  if plan.audio?.cleanup == true, srcAudio != nil, let url = try? await VoiceCleanup.cleaned(project, video: plan.source.video) {
    cleanAsset = AVURLAsset(url: url)
    if let track = try? await cleanAsset?.loadTracks(withMediaType: .audio).first { srcAudio = track }
  }
  let audioEnd = try await srcAudio?.load(.timeRange).end ?? screenDuration

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
  // Voice level: normalize (from measured loudness) plus the manual trim.
  var gainDB = plan.audio?.gainDB ?? 0
  if plan.audio?.normalize == true, let levels = try? await Analyzer.loudness(project, video: plan.source.video) {
    gainDB += AudioGain.normalizeGain(levels)
  }
  if abs(gainDB) > 0.05 { audioParams?.audioTapProcessor = AudioGain.tap(gainDB: gainDB) }

  for s in scene.mapped {
    let at = CMTime(value: CMTimeValue(s.outStart), timescale: fps)
    let outDur = CMTime(value: CMTimeValue(s.frames), timescale: fps)
    let srcRange = CMTimeRange(start: t(s.start), end: CMTimeMinimum(t(s.end), screenDuration))
    guard srcRange.duration.seconds > 0 else { continue }

    try insert(vTrack, srcRange, of: srcVideo, at: at, "screen video")
    vTrack.scaleTimeRange(CMTimeRange(start: at, duration: srcRange.duration), toDuration: outDur)
    if let aTrack, let srcAudio {
      let audioRange = CMTimeRange(start: srcRange.start, end: CMTimeMinimum(srcRange.end, audioEnd))
      if audioRange.duration.seconds > 0 {
        try insert(aTrack, audioRange, of: srcAudio, at: at, "audio")
        let audioOut = audioRange == srcRange ? outDur : t(outDur.seconds * audioRange.duration.seconds / srcRange.duration.seconds)
        aTrack.scaleTimeRange(CMTimeRange(start: at, duration: audioRange.duration), toDuration: audioOut)
      }
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

  // Crossfade handles: the frames each dissolve fades to, on their own track.
  var handleTrack: AVMutableCompositionTrack?
  if !scene.fades.isEmpty, let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
    handleTrack = track
    let srcEnd = screenDuration.seconds
    for c in scene.fades {
      let len = Double(c.half) / Double(fps)
      // Before the cut: the next clip's source leading up to its start.
      let preStart = max(0, c.next.start - len * c.next.speed)
      if c.next.start - preStart > 0.01 {
        let at = CMTime(value: CMTimeValue(c.f - c.half), timescale: fps)
        try insert(track, CMTimeRange(start: t(preStart), end: t(c.next.start)), of: srcVideo, at: at, "crossfade handle")
        track.scaleTimeRange(CMTimeRange(start: at, duration: t(c.next.start - preStart)), toDuration: CMTime(value: CMTimeValue(c.half), timescale: fps))
      }
      // After the cut: the previous clip's source carrying on past its end.
      let postEnd = min(srcEnd, c.prev.end + len * c.prev.speed)
      if postEnd - c.prev.end > 0.01 {
        let at = CMTime(value: CMTimeValue(c.f), timescale: fps)
        try insert(track, CMTimeRange(start: t(c.prev.end), end: t(postEnd)), of: srcVideo, at: at, "crossfade handle")
        track.scaleTimeRange(CMTimeRange(start: at, duration: t(postEnd - c.prev.end)), toDuration: CMTime(value: CMTimeValue(c.half), timescale: fps))
      }
    }
  }

  // B-roll clips: one track each, playing at real time from `from`, muted. Pictures are drawn by
  // the scene and need no track.
  var insertTracks: [Int: CMPersistentTrackID] = [:]
  var insertFills: [(AVMutableCompositionTrack, AVAssetTrack)] = []
  var insertAssets: [AVURLAsset] = []
  for ins in scene.inserts where !ins.a.isImage {
    guard let url = Scene.fileURL(ins.a.file, dir: project.dir) else { continue }
    let asset = AVURLAsset(url: url)
    guard let src = try? await asset.loadTracks(withMediaType: .video).first, let dur = try? await asset.load(.duration) else { continue }
    insertAssets.append(asset)
    let from = min(ins.a.from ?? 0, max(0, dur.seconds - 0.1))
    let length = min((ins.e - ins.s) / Double(fps), dur.seconds - from)
    guard length > 0.05, let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
    try insert(track, CMTimeRange(start: t(from), duration: t(length)), of: src, at: CMTime(value: CMTimeValue(ins.s), timescale: fps), "B-roll")
    insertTracks[ins.index] = track.trackID
    insertFills.append((track, src))
  }

  let total = CMTime(value: CMTimeValue(scene.frameCount), timescale: fps)
  var musicParams: AVMutableAudioMixInputParameters?
  var musicAsset: AVURLAsset?
  if let music = plan.music {
    let url = music.file.hasPrefix("/") ? URL(fileURLWithPath: music.file) : project.dir.appendingPathComponent(music.file)
    musicAsset = AVURLAsset(url: url)
    if let musicAsset, let src = try? await musicAsset.loadTracks(withMediaType: .audio).first {
      let range = try await src.load(.timeRange)
      let mTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
      // Loop the track to the end of the video; the trim below cuts the last pass to length.
      var at = CMTime.zero
      while range.duration.seconds > 0.1 && at < total {
        try insert(mTrack, range, of: src, at: at, "music")
        at = CMTimeAdd(at, range.duration)
      }
      let levels = (try? await Analyzer.loudness(project, video: plan.source.video)) ?? []
      let p = AVMutableAudioMixInputParameters(track: mTrack)
      MusicDuck.apply(music, to: p, speech: MusicDuck.speech(levels: levels, mapped: scene.mapped, fps: scene.fps), total: total.seconds)
      musicParams = p
    }
  }

  withExtendedLifetime(camAsset) {}
  withExtendedLifetime(screenAsset) {}
  withExtendedLifetime(cleanAsset) {}
  withExtendedLifetime(musicAsset) {}
  // Rounding can leave a track (usually the camera) a few milliseconds past the last frame.
  // AVPlayer rejects a video composition whose instruction doesn't cover every track and then
  // plays nothing at all (black, silent), so trim everything to the exact frame count.
  if comp.duration > total {
    comp.removeTimeRange(CMTimeRange(start: total, end: comp.duration))
  }
  // The same rule the other way: an outro card (or a camera that stops early) leaves tracks short
  // of the end, and a trailing empty edit doesn't count toward a track's length. Fill the gap with
  // a stretched sliver of the source; the compositor draws the card over it and the audio is
  // muted there. (Segments start after the intro, which leaves an empty edit at the front.)
  var fills: [(AVMutableCompositionTrack, AVAssetTrack)] = [(vTrack, srcVideo)]
  if let aTrack, let srcAudio { fills.append((aTrack, srcAudio)) }
  if let camTrack, let (track, _, _) = camSource { fills.append((camTrack, track)) }
  if let handleTrack { fills.append((handleTrack, srcVideo)) }
  fills += insertFills
  for (track, src) in fills where track.timeRange.end < total {
    let at = track.timeRange.end
    let sliver = CMTimeRange(start: src.timeRange.start, duration: CMTimeMinimum(src.timeRange.duration, t(0.5)))
    try insert(track, sliver, of: src, at: at, "padding")
    track.scaleTimeRange(CMTimeRange(start: at, duration: sliver.duration), toDuration: CMTimeSubtract(total, at))
  }
  // The padding inserts from these assets too.
  withExtendedLifetime((camAsset, screenAsset, cleanAsset, insertAssets)) {}
  if scene.outroStart < scene.frameCount {
    audioParams?.setVolume(0, at: CMTime(value: CMTimeValue(scene.outroStart), timescale: fps))
  }
  let instruction = DirectorInstruction(
    timeRange: CMTimeRange(start: .zero, duration: total), scene: scene, screenTrack: vTrack.trackID, cameraTrack: camTrack?.trackID,
    handleTrack: handleTrack?.trackID, insertTracks: insertTracks)
  let vc = AVMutableVideoComposition()
  vc.customVideoCompositorClass = DirectorCompositor.self
  vc.frameDuration = CMTime(value: 1, timescale: fps)
  vc.renderSize = CGSize(width: plan.output.width, height: plan.output.height)
  vc.instructions = [instruction]

  let mix = AVMutableAudioMix()
  mix.inputParameters = [audioParams, musicParams].compactMap { $0 }
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
  let handleTrack: CMPersistentTrackID?
  /// B-roll clip tracks by their index in plan.inserts.
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
      request.finish(with: NSError(domain: "DirectorCompositor", code: 1))
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
  // Cancelling the calling task stops the export and removes the partial file.
  try await withTaskCancellationHandler {
    try await session.export(to: url, as: .mp4)
  } onCancel: {
    session.cancelExport()
  }
  if Task.isCancelled {
    try? FileManager.default.removeItem(at: url)
    throw CancellationError()
  }
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
