import AVFoundation
import CoreVideo
import Foundation

// Headless playback check: builds a composition from a synthetic recording and plays it through
// AVPlayer with an AVPlayerItemVideoOutput, the same path the editor preview takes. Proves real,
// non-black frames come out of buildComposition (a mismatched track length renders black).
// Run: macos/playback-test.sh

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok {
    failures += 1
    print("FAIL line \(line): \(what)")
  } else {
    print("ok: \(what)")
  }
}

/// Writes `seconds` of 640x360 H.264 at 30 fps: an orange background with a white bar that grows
/// left to right, so every frame is bright and frames differ over time.
func writeSyntheticVideo(to url: URL, seconds: Int) throws {
  let w = 640, h = 360, fps: Int32 = 30
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
      kCVPixelBufferHeightKey as String: h,
    ])
  writer.add(input)
  guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Playback", code: 1) }
  writer.startSession(atSourceTime: .zero)
  let total = seconds * Int(fps)
  for i in 0..<total {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "Playback", code: 2) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    guard let buf = pb else { throw NSError(domain: "Playback", code: 3) }
    CVPixelBufferLockBaseAddress(buf, [])
    let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buf)
    let bar = w * (i + 1) / total
    for y in 0..<h {
      for x in 0..<w {
        let p = base + y * stride + x * 4
        let white = y < 40 && x < bar
        p[0] = white ? 255 : 0x4a  // B
        p[1] = white ? 255 : 0xa0  // G
        p[2] = white ? 255 : 0xe2  // R
        p[3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  if writer.status != .completed { throw writer.error ?? NSError(domain: "Playback", code: 4) }
}

/// Mean luma (0...255) of a BGRA pixel buffer, sampled on a grid.
func meanLuma(_ buf: CVPixelBuffer) -> Double {
  CVPixelBufferLockBaseAddress(buf, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
  let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
  let stride = CVPixelBufferGetBytesPerRow(buf)
  let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
  var sum = 0.0, n = 0.0
  for y in Swift.stride(from: 0, to: h, by: 8) {
    for x in Swift.stride(from: 0, to: w, by: 8) {
      let p = base + y * stride + x * 4
      sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
      n += 1
    }
  }
  return sum / max(n, 1)
}

/// Spins the main run loop (AVPlayer delivers on it) until `done` or the timeout.
func spin(_ seconds: Double, until done: () -> Bool = { false }) {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

@main
struct Playback {
  static func main() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-playback-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var built: BuiltComposition?
    do {
      try writeSyntheticVideo(to: dir.appendingPathComponent("screen.mp4"), seconds: 4)
      let source = Project.Source(video: "screen.mp4", width: 640, height: 360, duration: 4, captureStart: nil, camera: nil)
      try JSONEncoder().encode(source).write(to: dir.appendingPathComponent("source.json"))
      let project = try Project.load(dir)
      var plan = buildPlan(project)
      // A crossfade cut, a speed change and a zoom, so the timeline mapping, the camera and the
      // crossfade handle track (an extra video track, which must end with the others) all run.
      plan.segments = [Segment(start: 0, end: 1.5, speed: 1), Segment(start: 2, end: 4, speed: 2, transition: "crossfade")]
      plan.zooms = [Zoom(start: 0.5, end: 1.4, x: 0.3, y: 0.3, scale: 2)]
      // A B-roll clip (the recording itself) adds another video track that has to end with the rest.
      plan.inserts = [Insert(start: 0.6, end: 1.2, file: "screen.mp4", placement: "full")]
      let box = ResultBox<BuiltComposition>()
      let sem = DispatchSemaphore(value: 0)
      let planCopy = plan
      Task.detached {
        do { box.value = try await buildComposition(project: project, plan: planCopy) } catch { box.error = error }
        sem.signal()
      }
      while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
      if let e = box.error { throw e }
      built = box.value
    } catch {
      print("FAIL: couldn't build the fixture or composition: \(error)")
      exit(1)
    }
    guard let built else { exit(1) }

    // 1.5 s at 1x + 2 s at 2x = 2.5 s = 75 frames.
    expect(built.scene.frameCount == 75, "composition is 75 frames (got \(built.scene.frameCount))")
    expect(abs(built.asset.duration.seconds - 2.5) < 0.05, "asset duration matches the plan (\(built.asset.duration.seconds)s)")

    let item = built.playerItem()
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    spin(10) { item.status != .unknown }
    expect(item.status == .readyToPlay, "player item is ready (status \(item.status.rawValue), \(item.error?.localizedDescription ?? "no error"))")
    player.play()

    var frames = 0
    var lumas: [Double] = []
    var size = (0, 0)
    let start = Date()
    while Date().timeIntervalSince(start) < 6, player.currentTime().seconds < 2.4 || frames == 0 {
      RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
      let now = output.itemTime(forHostTime: CACurrentMediaTime())
      if output.hasNewPixelBuffer(forItemTime: now), let pb = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) {
        frames += 1
        lumas.append(meanLuma(pb))
        size = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
      }
    }
    player.pause()
    let minLuma = lumas.min() ?? 0
    let maxLuma = lumas.max() ?? 0
    print(
      String(
        format: "frames=%d size=%dx%d luma min=%.1f max=%.1f played to %.2fs", frames, size.0, size.1, minLuma, maxLuma,
        player.currentTime().seconds))
    expect(frames >= 20, "playback delivered frames (\(frames))")
    expect(size.0 == Int(built.videoComposition.renderSize.width), "frames are the render size")
    expect(minLuma > 30, "no black frames (darkest mean luma \(String(format: "%.1f", minLuma)))")

    // Intro and outro cards add time with no source video: every track must still end exactly
    // where the instruction does, and playback must run through the outro.
    do {
      let project = try Project.load(dir)
      var plan = built.scene.plan
      plan.intro = Card(duration: 1, title: "Intro")
      plan.outro = Card(duration: 1, title: "Outro")
      let box = ResultBox<BuiltComposition>()
      let sem = DispatchSemaphore(value: 0)
      let planCopy = plan
      Task.detached {
        do { box.value = try await buildComposition(project: project, plan: planCopy) } catch { box.error = error }
        sem.signal()
      }
      while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
      if let e = box.error { throw e }
      let carded = box.value!
      expect(carded.scene.frameCount == 135, "cards add 30 frames each (got \(carded.scene.frameCount))")
      let end = carded.videoComposition.instructions.last!.timeRange.end
      for t in carded.asset.tracks {
        expect(t.timeRange.end == end, "\(t.mediaType.rawValue) track \(t.trackID) ends at the instruction end (\(t.timeRange.end.seconds)s vs \(end.seconds)s)")
      }
      let item = carded.playerItem()
      let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      item.add(out)
      let player = AVPlayer(playerItem: item)
      player.isMuted = true
      spin(10) { item.status != .unknown }
      expect(item.status == .readyToPlay, "carded player item is ready")
      player.play()
      var cardFrames = 0
      let t0 = Date()
      while Date().timeIntervalSince(t0) < 8, player.currentTime().seconds < 4.4 {
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        let now = out.itemTime(forHostTime: CACurrentMediaTime())
        if out.hasNewPixelBuffer(forItemTime: now), out.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil,
          now.seconds < 1 || now.seconds >= 3.5
        {
          cardFrames += 1
        }
      }
      player.pause()
      expect(cardFrames >= 20, "intro and outro frames played (\(cardFrames)), reached \(String(format: "%.2f", player.currentTime().seconds))s")
    } catch {
      expect(false, "carded composition: \(error)")
    }

    if failures > 0 {
      print("\(failures) playback check(s) failed")
      exit(1)
    }
    print("playback checks passed")
  }
}

final class ResultBox<T>: @unchecked Sendable {
  var value: T?
  var error: Error?
}
