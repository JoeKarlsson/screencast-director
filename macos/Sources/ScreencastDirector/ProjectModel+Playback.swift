import AVFoundation
import AppKit
import DirectorCore
import Foundation
import UniformTypeIdentifiers

// Keyboard actions, playback and camera framing.
extension ProjectModel {
  // MARK: Keyboard actions (Screen Studio's defaults; see Shortcuts.swift)

  /// The selected clip, else the one under the playhead.
  private var targetSegment: Int? {
    if case .segment(let i) = selection { return i }
    return plan?.segmentIndex(at: playheadSrc)
  }

  /// X: remove from the previous cut up to the playhead.
  func removeToPreviousCut() {
    let t = playheadSrc
    guard let i = plan?.segmentIndex(at: t) else { return }
    apply { $0.segments[i].start = t }
    seek(src: t)
  }

  /// S: step the clip's speed through 1, 1.5, 2, 3, 4, 8.
  func cycleSpeed() {
    guard let i = targetSegment, let plan, plan.segments.indices.contains(i) else { return }
    let next = nextClipSpeed(after: plan.segments[i].speed)
    apply { $0.segments[i].speed = next }
    selection = .segment(i)
    status = "Clip speed \(next.formatted())×"
  }

  /// = and -: change the selected zoom's level.
  func nudgeZoom(_ delta: Double) {
    guard case .zoom(let i) = selection else { return }
    guard plan?.zooms.indices.contains(i) == true else { return }
    apply(coalesce: "zoomScale\(i)") { $0.zooms[i].scale = nudgedZoomScale($0.zooms[i].scale, by: delta) }
  }

  /// ⌘D: copy the selected zoom to just after itself.
  func duplicateZoom() {
    guard case .zoom(let i) = selection, let z = plan?.duplicateOfZoom(i) else { return }
    apply { $0.zooms.append(z) }
    if let j = self.plan?.zooms.firstIndex(of: z) { selection = .zoom(j) }
  }

  /// 1-4: set the selected layout's mode, or add one at the playhead.
  func setLayoutMode(_ mode: LayoutMode) {
    if case .layout(let i) = selection, plan?.layouts.indices.contains(i) == true {
      apply { $0.layouts[i].mode = mode }
    } else {
      addLayout(mode)
    }
  }

  func step(frames n: Double) {
    player.pause()
    seek(outFrame: outFrame + n)
  }

  func goToStart() { seek(outFrame: 0) }
  func goToEnd() { seek(outFrame: Double(totalOutFrames - 1)) }

  /// L: play, or play faster each press (up to 8×).
  func shuttleForward() {
    let r = player.rate
    player.rate = r <= 0 ? 1 : min(r * 2, 8)
  }

  /// J: play backward, faster each press. Falls back to stepping back a second if reverse isn't possible.
  func shuttleBackward() {
    guard player.currentItem?.canPlayReverse == true else {
      step(frames: -Double(fps))
      return
    }
    let r = player.rate
    player.rate = r >= 0 ? -1 : max(r * 2, -8)
  }

  /// K: stop and reset the speed.
  func stop() {
    player.pause()
    player.rate = 0
  }

  // MARK: Playback

  func togglePlay() {
    if player.rate != 0 { player.pause() } else {
      // Stopped at the end (the playhead often rests a frame or two short of the last one, and the
      // player's own clock is the better judge): play again from the top.
      let endF = Double(totalOutFrames - 1)
      let playerF = player.currentTime().seconds * Double(fps)
      if outFrame >= endF - Double(fps) * 0.25 || (playerF.isFinite && playerF >= endF - Double(fps) * 0.25) { seek(outFrame: 0) }
      player.play()
    }
  }

  func seek(outFrame f: Double) {
    let clamped = max(0, min(f, Double(totalOutFrames - 1)))
    outFrame = clamped
    player.seek(to: CMTime(value: CMTimeValue(clamped.rounded()), timescale: CMTimeScale(fps)), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  /// Seeks to a source time; a cut moment lands on the next kept frame.
  func seek(src t: Double) {
    seek(outFrame: srcToOutClamped(mapped, t, fps: fps))
  }

  /// A frame of the raw recording, for picking a zoom's focus point.
  func thumbnail(at t: Double, done: @escaping (NSImage?) -> Void) {
    let key = Int(t * 2)
    if let img = thumbnails[key] { return done(img) }
    guard let video = project?.source.video else { return done(nil) }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: dir.appendingPathComponent(video)))
    gen.maximumSize = CGSize(width: 640, height: 640)
    gen.appliesPreferredTrackTransform = true
    Task { @MainActor in
      let img = (try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image).map {
        NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
      }
      if let img { thumbnails[key] = img }
      done(img)
    }
  }

  /// Re-cuts silences at a level; cuts that removed words stay cut.
  func setPauses(_ level: PauseLevel) {
    guard let project, let video = plan?.source.video else { return }
    run("Finding pauses…") { [self] in
      let silences = Analyzer.silences(try await Analyzer.loudness(project, video: video), minLength: 0.2)
      apply {
        $0.retrimPauses(words: project.words, level: level, silences: silences, paused: project.paused)
        $0.pauses = level
      }
      status = "Pauses: \(level.label)"
    }
  }

  // MARK: Camera framing

  /// Finds where the speaker's face usually is and centers the camera on it.
  func centerCameraOnFace() {
    run("Finding your face…") { [self] in
      guard let plan, let project, plan.camera != nil else { return }
      guard let face = try await Publish.faceCenter(project: project, plan: plan) else {
        status = "No face found in the camera footage."
        return
      }
      apply {
        $0.camera?.x = face.x
        $0.camera?.y = face.y
        $0.camera?.zoom = Publish.centeringZoom(x: face.x, y: face.y)
      }
      status = "Camera centered on your face."
    }
  }

  /// Lines the camera up with the voice by watching the lips (see LipSync).
  func syncCameraToVoice() {
    run("Matching your lips to your voice…") { [self] in
      guard let plan, let project, let camera = plan.camera else { return }
      guard let sync = try await LipSync.measure(project: project, camera: camera), sync.confident else {
        status = "Couldn't tell how far off the camera is. Set Lip sync by hand."
        Notices.shared.show(status)
        return
      }
      apply { $0.camera?.offset = sync.offset }
      status = String(format: "Camera synced to your voice (moved %+.2f s).", sync.offset - camera.offset)
    }
  }

  /// A frame of the camera video, for the framing picker.
  func cameraThumbnail(done: @escaping (NSImage?) -> Void) {
    guard let cam = plan?.camera else { return done(nil) }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: dir.appendingPathComponent(cam.video)))
    gen.maximumSize = CGSize(width: 640, height: 640)
    gen.appliesPreferredTrackTransform = true
    Task { @MainActor in
      let img = (try? await gen.image(at: CMTime(seconds: 5, preferredTimescale: 600)).image).map {
        NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
      }
      done(img)
    }
  }
}
