import AVFoundation
import CoreImage
import Foundation

/// An AVFoundation timeline for a plan. The same composition feeds the preview player and the
/// exporter, so what you see is what you export.
/// Unchecked: AVComposition and AVAudioMix are immutable (these are copies of the mutable ones the
/// build assembled) but aren't marked Sendable.
public struct BuiltComposition: @unchecked Sendable {
  public let asset: AVComposition
  public let videoComposition: AVVideoComposition
  public let audioMix: AVAudioMix
  public let scene: Scene
  /// Things that didn't come out as the plan asked but didn't stop the build (the app shows them in
  /// the banner; the CLI prints them).
  public let warnings: [String]

  @MainActor
  public func playerItem() -> AVPlayerItem {
    let item = AVPlayerItem(asset: asset)
    item.videoComposition = videoComposition
    item.audioMix = audioMix
    return item
  }
}

public enum CompositionError: LocalizedError, Sendable {
  case noVideo(String)
  case noAudio(String)
  case missingFile(String)
  public var errorDescription: String? {
    switch self {
    case .noVideo(let f): return "\(f) has no video track."
    case .noAudio(let f): return "\(f) has no audio track."
    case .missingFile(let f): return "\(f) isn't in the project folder."
    }
  }
}

/// The voice's ramp at each cut: just long enough to stop a click, short enough not to eat a word.
private let cutRamp = 0.012

private func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }

private func insert(_ track: AVMutableCompositionTrack, _ range: CMTimeRange, of src: AVAssetTrack, at: CMTime, _ what: String) async throws {
  do {
    try track.insertTimeRange(range, of: src, at: at)
  } catch {
    // The source track's range, for the message; if even that can't load, say so rather than guess.
    let have = (try? await src.load(.timeRange)).map { "\($0.start.seconds)-\($0.end.seconds)s" } ?? "range unknown"
    throw DirectorError(
      "Couldn't add \(what) \(range.start.seconds)-\(range.end.seconds)s at \(at.seconds)s (source track \(have)): \(error.localizedDescription)")
  }
}

public func buildComposition(project: Project, plan: Plan) async throws -> BuiltComposition {
  let loadedEffects = try Effects.load(plan.effects ?? [], sources: EffectSources(project: project.dir))
  let rangeEffects = try Effects.load(plan.effectRangeList.map(\.use), sources: EffectSources(project: project.dir))
  var tracking: Tracking?
  if let camera = plan.camera, (loadedEffects + rangeEffects).contains(where: { $0.tracking && $0.layer == "camera" }) {
    tracking = try await Tracking.camera(project, video: camera.video)
  }
  let scene = Scene(
    plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts, cursorPath: project.cursorPath,
    dir: project.dir, effects: loadedEffects, rangeEffects: rangeEffects, tracking: tracking)
  let fps = Int32(plan.output.fps)
  let comp = AVMutableComposition()

  let screenAsset = AVURLAsset(url: project.dir.appendingPathComponent(plan.source.video))
  guard let srcVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
    throw CompositionError.noVideo(plan.source.video)
  }
  var srcAudio = try await screenAsset.loadTracks(withMediaType: .audio).first
  let screenDuration = try await screenAsset.load(.duration)
  // Clean up voice: same timing, audio from the cached voice-clean.m4a. If the render fails, keep
  // the original audio rather than failing the whole preview, and say so.
  var warnings: [String] = []
  var cleanAsset: AVURLAsset?
  if plan.audio?.cleanup == true, srcAudio != nil {
    do {
      let asset = AVURLAsset(url: try await VoiceCleanup.cleaned(project, video: plan.source.video))
      guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CompositionError.noAudio("voice-clean.m4a") }
      cleanAsset = asset
      srcAudio = track
    } catch {
      warnings.append("Clean up voice didn't work, so this plays the original voice: \(error.localizedDescription)")
    }
  }
  let audioEnd = try await srcAudio?.load(.timeRange).end ?? screenDuration
  // Measured voice loudness, for normalizing and music ducking (nothing to measure without audio).
  let voiceLevels =
    srcAudio != nil && (plan.audio?.normalize == true || plan.music != nil)
    ? try await Analyzer.loudness(project, video: plan.source.video) : []

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

  let audioParams = aTrack.map { AVMutableAudioMixInputParameters(track: $0) }
  audioParams?.audioTimePitchAlgorithm = .spectral
  // Voice level: the manual trim, and with normalize a leveling curve that rides the voice phrase by
  // phrase (from measured loudness), laid over output frames.
  let gainDB = plan.audio?.gainDB ?? 0
  let curveDB = plan.audio?.normalize == true && !voiceLevels.isEmpty ? levelingCurve(voiceLevels, scene) : []
  let warm = plan.audio?.warm == true
  if let audioParams, abs(gainDB) > 0.05 || !curveDB.isEmpty || warm {
    // Without the tap the voice would play with no leveling, gain or warmth, so fail instead.
    guard let tap = AudioGain.tap(gainDB: gainDB, curveDB: curveDB, fps: scene.fps, warm: warm) else {
      throw DirectorError("Couldn't set up the voice processing (leveling, volume, warm voice)")
    }
    audioParams.audioTapProcessor = tap
  }

  for s in scene.mapped {
    let at = CMTime(value: CMTimeValue(s.outStart), timescale: fps)
    let outDur = CMTime(value: CMTimeValue(s.frames), timescale: fps)
    let srcRange = CMTimeRange(start: t(s.start), end: CMTimeMinimum(t(s.end), screenDuration))
    guard srcRange.duration.seconds > 0 else { continue }

    try await insert(vTrack, srcRange, of: srcVideo, at: at, "screen video")
    vTrack.scaleTimeRange(CMTimeRange(start: at, duration: srcRange.duration), toDuration: outDur)
    if let aTrack, let srcAudio {
      let audioRange = CMTimeRange(start: srcRange.start, end: CMTimeMinimum(srcRange.end, audioEnd))
      if audioRange.duration.seconds > 0 {
        try await insert(aTrack, audioRange, of: srcAudio, at: at, "audio")
        let audioOut = audioRange == srcRange ? outDur : t(outDur.seconds * audioRange.duration.seconds / srcRange.duration.seconds)
        aTrack.scaleTimeRange(CMTimeRange(start: at, duration: audioRange.duration), toDuration: audioOut)
      }
      if s.speed > 1.01 {
        audioParams?.setVolume(0, at: at)
      } else {
        // Short fades at each cut hide clicks in the audio.
        let fade = CMTime(seconds: min(cutRamp, Double(s.frames) / Double(fps) / 2), preferredTimescale: 48000)
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
        try await insert(camTrack, CMTimeRange(start: t(a), end: t(b)), of: track, at: camAt, "camera")
        camTrack.scaleTimeRange(CMTimeRange(start: camAt, duration: t(b - a)), toDuration: t((b - a) / s.speed))
      }
    }
  }

  let handleTrack = try await crossfadeHandles(scene, screen: srcVideo, screenDuration: screenDuration, to: comp)

  let broll = try await addBroll(scene, project: project, to: comp)

  let total = CMTime(value: CMTimeValue(scene.frameCount), timescale: fps)
  let music = try await addMusic(plan, project: project, scene: scene, voiceLevels: voiceLevels, total: total, to: comp)

  let effects = try await addSoundEffects(plan, project: project, scene: scene, total: total, to: comp)

  var fills: [(AVMutableCompositionTrack, AVAssetTrack)] = [(vTrack, srcVideo)]
  if let aTrack, let srcAudio { fills.append((aTrack, srcAudio)) }
  if let camTrack, let (track, _, _) = camSource { fills.append((camTrack, track)) }
  if let handleTrack { fills.append((handleTrack, srcVideo)) }
  fills += broll.fills
  if let fill = effects.fill { fills.append(fill) }
  try await fitTracks(comp, to: total, padding: fills)
  // Every track inserts from these assets (padding too), and a track whose asset is freed fails.
  withExtendedLifetime((camAsset, screenAsset, cleanAsset, broll.assets, effects.assets, music.asset)) {}
  if scene.outroStart < scene.frameCount {
    audioParams?.setVolume(0, at: CMTime(value: CMTimeValue(scene.outroStart), timescale: fps))
  }
  let instruction = DirectorInstruction(
    timeRange: CMTimeRange(start: .zero, duration: total), scene: scene, screenTrack: vTrack.trackID, cameraTrack: camTrack?.trackID,
    handleTrack: handleTrack?.trackID, insertTracks: broll.tracks,
    insertOrientations: broll.orientations)
  let vc = AVMutableVideoComposition()
  vc.customVideoCompositorClass = DirectorCompositor.self
  vc.frameDuration = CMTime(value: 1, timescale: fps)
  vc.renderSize = CGSize(width: plan.output.width, height: plan.output.height)
  vc.instructions = [instruction]

  let mix = AVMutableAudioMix()
  mix.inputParameters = [audioParams, music.params, effects.params].compactMap { $0 }
  // swiftlint:disable force_cast
  return BuiltComposition(
    asset: comp.copy() as! AVComposition, videoComposition: vc.copy() as! AVVideoComposition, audioMix: mix.copy() as! AVAudioMix,
    scene: scene, warnings: warnings)
  // swiftlint:enable force_cast
}

/// Makes every track end exactly at `total`. Rounding can leave a track (usually the camera) a few
/// milliseconds past the last frame, and AVPlayer rejects a video composition whose instruction
/// doesn't cover every track, then plays nothing at all (black, silent). The other way, an outro
/// card (or a camera that stops early) leaves tracks short of the end, and a trailing empty edit
/// doesn't count toward a track's length, so each short track in `padding` is filled with a
/// stretched sliver of its source; the compositor draws the card over it and the audio is muted
/// there. (Segments start after the intro, which leaves an empty edit at the front.)
private func fitTracks(_ comp: AVMutableComposition, to total: CMTime, padding: [(AVMutableCompositionTrack, AVAssetTrack)]) async throws {
  if comp.duration > total {
    comp.removeTimeRange(CMTimeRange(start: total, end: comp.duration))
  }
  for (track, src) in padding where track.timeRange.end < total {
    let at = track.timeRange.end
    let have = try await src.load(.timeRange)
    let sliver = CMTimeRange(start: have.start, duration: CMTimeMinimum(have.duration, t(0.5)))
    try await insert(track, sliver, of: src, at: at, "padding")
    track.scaleTimeRange(CMTimeRange(start: at, duration: sliver.duration), toDuration: CMTimeSubtract(total, at))
  }
}

/// Crossfade handles: the frames each dissolve fades to, on their own track (nil without crossfades).
private func crossfadeHandles(
  _ scene: Scene, screen srcVideo: AVAssetTrack, screenDuration: CMTime, to comp: AVMutableComposition
) async throws -> AVMutableCompositionTrack? {
  let fps = Int32(scene.fps)
  guard !scene.fades.isEmpty, let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
    return nil
  }
  let srcEnd = screenDuration.seconds
  for c in scene.fades {
    let len = Double(c.half) / Double(fps)
    // Before the cut: the next clip's source leading up to its start.
    let preStart = max(0, c.next.start - len * c.next.speed)
    if c.next.start - preStart > 0.01 {
      let at = CMTime(value: CMTimeValue(c.f - c.half), timescale: fps)
      try await insert(track, CMTimeRange(start: t(preStart), end: t(c.next.start)), of: srcVideo, at: at, "crossfade handle")
      track.scaleTimeRange(CMTimeRange(start: at, duration: t(c.next.start - preStart)), toDuration: CMTime(value: CMTimeValue(c.half), timescale: fps))
    }
    // After the cut: the previous clip's source carrying on past its end.
    let postEnd = min(srcEnd, c.prev.end + len * c.prev.speed)
    if postEnd - c.prev.end > 0.01 {
      let at = CMTime(value: CMTimeValue(c.f), timescale: fps)
      try await insert(track, CMTimeRange(start: t(c.prev.end), end: t(postEnd)), of: srcVideo, at: at, "crossfade handle")
      track.scaleTimeRange(CMTimeRange(start: at, duration: t(postEnd - c.prev.end)), toDuration: CMTime(value: CMTimeValue(c.half), timescale: fps))
    }
  }
  return track
}

/// The voice gain (dB) for each output frame: the leveling curve from measured loudness, laid over
/// output frames.
private func levelingCurve(_ levels: [(Double, Double)], _ scene: Scene) -> [Double] {
  let curve = AudioGain.levelingCurve(levels)
  let step = curve.count > 1 ? curve[1].t - curve[0].t : 0.05
  let fallback = AudioGain.normalizeGain(levels)
  return (0..<scene.frameCount).map { f in
    guard let src = outToSrc(scene.mapped, Double(f), fps: scene.fps), !curve.isEmpty else { return fallback }
    return curve[min(curve.count - 1, max(0, Int(((src - curve[0].t) / step).rounded())))].gainDB
  }
}

/// B-roll clips: one track each, playing at real time from `from`, muted. Pictures are drawn by the
/// scene and need no track. Returns each clip's track by its index (the compositor's key), the tracks
/// and sources to pad to the end, the orientation that turns each rotated clip upright, and the assets,
/// which must outlive the composition's inserts.
private func addBroll(_ scene: Scene, project: Project, to comp: AVMutableComposition) async throws -> (
  tracks: [Int: CMPersistentTrackID], orientations: [Int: CGImagePropertyOrientation],
  fills: [(AVMutableCompositionTrack, AVAssetTrack)], assets: [AVURLAsset]
) {
  let fps = Int32(scene.fps)
  var tracks: [Int: CMPersistentTrackID] = [:]
  var orientations: [Int: CGImagePropertyOrientation] = [:]
  var fills: [(AVMutableCompositionTrack, AVAssetTrack)] = []
  var assets: [AVURLAsset] = []
  for ins in scene.inserts where !ins.a.isImage {
    guard let url = Scene.fileURL(ins.a.file, dir: project.dir), FileManager.default.fileExists(atPath: url.path) else {
      throw CompositionError.missingFile(ins.a.file)
    }
    let asset = AVURLAsset(url: url)
    guard let src = try await asset.loadTracks(withMediaType: .video).first else { throw CompositionError.noVideo(ins.a.file) }
    let dur = try await asset.load(.duration)
    assets.append(asset)
    let from = min(ins.a.from ?? 0, max(0, dur.seconds - 0.1))
    let length = min((ins.e - ins.s) / Double(fps), dur.seconds - from)
    guard length > 0.05, let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
    let at = CMTime(value: CMTimeValue(ins.s), timescale: fps)
    try await insert(track, CMTimeRange(start: t(from), duration: t(length)), of: src, at: at, "B-roll")
    // A clip a little shorter than its slot holds its last frame to the end; otherwise the track's
    // end padding (a sliver of the clip's first frame) would flash in before the slot ends.
    let slotEnd = CMTime(value: CMTimeValue(ins.e.rounded(.up)), timescale: fps)
    if track.timeRange.end < slotEnd {
      let held = CMTimeRange(start: t(from + length - 0.05), duration: t(0.05))
      let holdAt = track.timeRange.end
      try await insert(track, held, of: src, at: holdAt, "B-roll hold")
      track.scaleTimeRange(CMTimeRange(start: holdAt, duration: held.duration), toDuration: CMTimeSubtract(slotEnd, holdAt))
    }
    tracks[ins.index] = track.trackID
    if let orientation = videoOrientation(try await src.load(.preferredTransform)) { orientations[ins.index] = orientation }
    fills.append((track, src))
  }
  return (tracks, orientations, fills, assets)
}

/// The orientation that turns a clip's stored frames upright, from its track's preferred transform
/// (a phone held sideways or upside down); nil when it's already upright.
func videoOrientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation? {
  switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
  case (0, 1, -1, 0): return .right
  case (0, -1, 1, 0): return .left
  case (-1, 0, 0, -1): return .down
  default: return nil
  }
}

/// The plan's music, looped to `total` and ducked under the voice. Returns its mix parameters and
/// the asset, which must outlive the composition's inserts (nil for both without music).
private func addMusic(
  _ plan: Plan, project: Project, scene: Scene, voiceLevels: [(Double, Double)], total: CMTime, to comp: AVMutableComposition
) async throws -> (params: AVMutableAudioMixInputParameters?, asset: AVURLAsset?) {
  guard let music = plan.music else { return (nil, nil) }
  // A library track the plan names (music/<file>) is copied into the project the first time.
  try AudioLibrary(.music, for: plan).freezeMissing([music.file], project: project.dir)
  let asset = AVURLAsset(url: resolvePath(music.file, in: project.dir))
  guard let src = try await asset.loadTracks(withMediaType: .audio).first else { throw CompositionError.noAudio(music.file) }
  let range = try await src.load(.timeRange)
  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
  // Loop the track to the end of the video; buildComposition's trim cuts the last pass to length.
  var at = CMTime.zero
  while range.duration.seconds > 0.1 && at < total {
    try await insert(track, range, of: src, at: at, "music")
    at = CMTimeAdd(at, range.duration)
  }
  let params = AVMutableAudioMixInputParameters(track: track)
  MusicDuck.apply(music, to: params, speech: MusicDuck.speech(levels: voiceLevels, mapped: scene.mapped, fps: scene.fps), total: total.seconds)
  return (params, asset)
}

/// Sound effects: one shared track, each effect at its mapped output time and real speed, not
/// ducked. An effect that starts before the previous one ends cuts it short (one track can't hold
/// two at once). Returns the mix parameters, the track and source to pad to the end, and the
/// assets, which must outlive the composition's inserts.
private func addSoundEffects(_ plan: Plan, project: Project, scene: Scene, total: CMTime, to comp: AVMutableComposition) async throws -> (
  params: AVMutableAudioMixInputParameters?, fill: (AVMutableCompositionTrack, AVAssetTrack)?, assets: [AVURLAsset]
) {
  let fps = Int32(scene.fps)
  let times: [(at: CMTime, effect: SoundEffect)] = plan.soundEffects.compactMap { e in
    guard let f = srcToOut(scene.mapped, e.t, fps: scene.fps) else { return nil }
    let at = CMTime(value: CMTimeValue(f.rounded()), timescale: fps)
    return at < total ? (at, e) : nil
  }.sorted { $0.at < $1.at }
  guard !times.isEmpty, let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
    return (nil, nil, [])
  }
  // Library sounds the plan names (sfx/<file>) are copied into the project the first time.
  try AudioLibrary(.sounds, for: plan).freezeMissing(times.map(\.effect.file), project: project.dir)
  let params = AVMutableAudioMixInputParameters(track: track)
  var fill: (AVMutableCompositionTrack, AVAssetTrack)?
  var assets: [AVURLAsset] = []
  for (i, (at, e)) in times.enumerated() {
    guard let url = Scene.fileURL(e.file, dir: project.dir), FileManager.default.fileExists(atPath: url.path) else {
      throw CompositionError.missingFile(e.file)
    }
    let asset = AVURLAsset(url: url)
    guard let src = try await asset.loadTracks(withMediaType: .audio).first else { throw CompositionError.noAudio(e.file) }
    assets.append(asset)
    let range = try await src.load(.timeRange)
    let until = i + 1 < times.count ? times[i + 1].at : total
    let length = CMTimeMinimum(range.duration, CMTimeSubtract(until, at))
    guard length.seconds > 0.01 else { continue }
    try await insert(track, CMTimeRange(start: range.start, duration: length), of: src, at: at, "sound effect")
    params.setVolume(Float(pow(10, (e.gainDB ?? 0) / 20)), at: at)
    // Silent after the effect, so the end padding can't be heard.
    params.setVolume(0, at: CMTimeAdd(at, length))
    fill = (track, src)
  }
  return (params, fill, assets)
}

/// Renders the plan to an MP4. `progress` gets 0...1.
public func export(_ built: BuiltComposition, to url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
  try? FileManager.default.removeItem(at: url)
  // AVAssetExportSession isn't marked Sendable, but cancelExport is meant to be called from anywhere.
  guard let made = AVAssetExportSession(asset: built.asset, presetName: AVAssetExportPresetHighestQuality) else {
    throw DirectorError("Can't create an export session.")
  }
  nonisolated(unsafe) let session = made
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
