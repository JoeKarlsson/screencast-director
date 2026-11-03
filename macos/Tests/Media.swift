import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO

// Headless media pipeline checks: analysis (motion, audio extraction, loudness), analyze() and screen
// text, joining takes, GIF export, publishing and the export queue, on synthetic recordings made here
// (ffmpeg muxes the audio); the face steps (thumbnail faces, face centering, cutout, lip sync) on the
// public-domain talking head in test/fixtures; and turning whisper-cli's JSON into transcript.json, from
// a captured sample (no model runs here). Needs ffmpeg. Run from macos/: macos/media-test.sh

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok {
    failures += 1
    print("FAIL line \(line): \(what)")
  } else {
    print("ok: \(what)")
  }
}

/// Writes `seconds` of H.264 at 30 fps, each frame drawn by `draw` into a CGContext (bottom-left origin).
func writeVideo(to url: URL, width w: Int, height h: Int, seconds: Double, draw: (CGContext, Int) -> Void) async throws {
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
  guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Media", code: 1) }
  writer.startSession(atSourceTime: .zero)
  for i in 0..<Int(seconds * 30) {
    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
    var pb: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "Media", code: 2) }
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    guard let buf = pb else { throw NSError(domain: "Media", code: 3) }
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(
      data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    draw(ctx, i)
    CVPixelBufferUnlockBaseAddress(buf, [])
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
  }
  input.markAsFinished()
  await writer.finishWriting()
  if writer.status != .completed { throw writer.error ?? NSError(domain: "Media", code: 4) }
}

/// A gray screen that stays still until `movesFrom` seconds, then a white bar grows across it.
func barVideo(to url: URL, width: Int = 640, height: Int = 360, seconds: Double, movesFrom: Double = 0) async throws {
  try await writeVideo(to: url, width: width, height: height, seconds: seconds) { ctx, i in
    ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let t = Double(i) / 30
    guard t >= movesFrom else { return }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: Double(width) * (t - movesFrom + 0.1) / (seconds - movesFrom), height: Double(height) / 2))
  }
}

/// Muxes a 440 Hz tone onto a video with ffmpeg: `parts` are (start, end, amplitude) seconds; silence elsewhere.
func addTone(_ video: URL, parts: [(Double, Double, Double)], seconds: Double) throws {
  let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
  let n = AVAudioFrameCount(seconds * 48000)
  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
  buf.frameLength = n
  for i in 0..<Int(n) {
    let t = Double(i) / 48000
    let amp = parts.first { t >= $0.0 && t < $0.1 }?.2 ?? 0
    buf.floatChannelData![0][i] = Float(amp * sin(2 * .pi * 440 * t))
  }
  let tone = video.deletingLastPathComponent().appendingPathComponent("tone-\(UUID().uuidString).caf")
  try AVAudioFile(forWriting: tone, settings: format.settings).write(from: buf)
  let muxed = video.deletingLastPathComponent().appendingPathComponent("muxed-\(UUID().uuidString).mp4")
  try run("ffmpeg", ["-v", "error", "-y", "-i", video.path, "-i", tone.path, "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", muxed.path])
  try FileManager.default.removeItem(at: video)
  try FileManager.default.moveItem(at: muxed, to: video)
  try FileManager.default.removeItem(at: tone)
}

func run(_ tool: String, _ args: [String]) throws {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = [tool] + args
  try p.run()
  p.waitUntilExit()
  guard p.terminationStatus == 0 else { throw NSError(domain: "Media", code: 5, userInfo: [NSLocalizedDescriptionKey: "\(tool) failed"]) }
}

func write(_ text: String, _ url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }

func writeSource(_ dir: URL, width: Double, height: Double, duration: Double, captureStart: Double? = nil, camera: Plan.Camera? = nil) throws {
  let source = Project.Source(video: "screen.mp4", width: width, height: height, duration: duration, captureStart: captureStart, camera: camera)
  try JSONEncoder().encode(source).write(to: dir.appendingPathComponent("source.json"))
}

func duration(_ url: URL) async -> Double { (try? await AVURLAsset(url: url).load(.duration).seconds) ?? -1 }

func folder(_ root: URL, _ name: String) throws -> URL {
  let d = root.appendingPathComponent(name)
  try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
  return d
}

@main
struct Media {
  static func main() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sd-media-\(getpid())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      try await analysis(root)
      try await analyzeAndScreenText(root)
      try await join(root)
      try await gifAndPublish(root)
      try await exportQueue(root)
      try await faces(root)
      try await transcription(root)
    } catch {
      expect(false, "media checks threw: \(error)")
    }
    print(failures == 0 ? "media checks passed" : "\(failures) media check(s) failed")
    exit(failures == 0 ? 0 : 1)
  }

  /// Motion, audio extraction, loudness and silences.
  static func analysis(_ root: URL) async throws {
    let dir = try folder(root, "analysis")
    let video = dir.appendingPathComponent("screen.mp4")
    try await barVideo(to: video, seconds: 4, movesFrom: 2)

    let motion = try await Analyzer.measureMotion(video)
    // 40 sampled frames over 4 s, the first with nothing to compare to; one every 0.1 s, none skipped.
    let steps = Set(zip(motion.dropFirst(), motion).map { (($0.0 - $1.0) * 10).rounded() })
    expect(motion.count == 39 && steps == [1], "motion is sampled every 0.1 s (\(motion.count) samples, steps \(steps))")
    let still = motion.filter { $0.0 < 1.9 }.map(\.1).max() ?? 99
    let moving = motion.filter { $0.0 > 2.1 }.map(\.1)
    expect(still < 0.5, "a still screen measures no motion (max \(still))")
    expect(!moving.isEmpty && moving.allSatisfy { $0 > 1 }, "a growing bar measures motion (\(moving.prefix(3)))")
    try SampleSeries.write(motion, to: dir.appendingPathComponent("motion.json"), decimals: 3)
    try writeSource(dir, width: 640, height: 360, duration: 4)
    let loaded = try Project.load(dir)
    expect(loaded.motion.count == motion.count && abs((loaded.motion.last?.1 ?? 0) - (motion.last?.1 ?? 0)) < 0.001, "motion.json loads back")

    let wav = dir.appendingPathComponent("audio.wav")
    expect(try await !Analyzer.extractAudio(video, to: wav), "a silent video has no audio to extract")
    expect(!FileManager.default.fileExists(atPath: wav.path), "and writes no WAV")
    expect(try await Analyzer.loudness(loaded, video: "screen.mp4").isEmpty, "no audio, no loudness")

    // Loud tone, silence, a quiet tone, silence.
    try addTone(video, parts: [(0, 1, 0.5), (2, 3, 0.05)], seconds: 4)
    expect(try await Analyzer.extractAudio(video, to: wav), "audio extracted")
    let data = try Data(contentsOf: wav)
    let rate = data.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    let bits = data.subdata(in: 34..<36).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    let dataLen = data.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    expect(String(bytes: data.prefix(4), encoding: .ascii) == "RIFF" && String(bytes: data[8..<12], encoding: .ascii) == "WAVE", "a RIFF WAVE file")
    expect(rate == 16000 && bits == 16 && Int(dataLen) == data.count - 44, "16 kHz 16-bit, data size in the header (\(rate), \(bits), \(dataLen))")
    expect(abs(Double(dataLen) / 32000 - 4) < 0.1, "4 s of mono samples (\(Double(dataLen) / 32000) s)")

    let levels = try await Analyzer.loudness(loaded, video: "screen.mp4")
    func level(_ t: Double) -> Double { levels.min { abs($0.0 - t) < abs($1.0 - t) }?.1 ?? 0 }
    expect(abs(levels.count - 80) <= 2, "loudness every 50 ms (\(levels.count))")
    expect(abs(level(0.5) - -9) < 1.5, "a 0.5 sine reads about -9 dBFS (\(level(0.5)))")
    expect(abs(level(2.5) - -29) < 1.5, "a 0.05 sine reads about -29 dBFS (\(level(2.5)))")
    expect(level(1.5) < -60, "silence reads quiet (\(level(1.5)))")
    let silences = Analyzer.silences(levels, minLength: 0.5)
    expect(
      silences.count == 2 && abs(silences[0].0 - 1) < 0.15 && abs(silences[0].1 - 2) < 0.15 && abs(silences[1].0 - 3) < 0.15,
      "silences found between the tones (\(silences))")
    // Clean up voice that can't be read keeps the original voice and says so, rather than failing
    // the build (a folder in the cache file's place stands in for a broken render).
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(VoiceCleanup.fileName), withIntermediateDirectories: true)
    var cleanPlan = buildPlan(loaded)
    cleanPlan.audio = AudioSettings(cleanup: true)
    let cleaned = try await buildComposition(project: loaded, plan: cleanPlan)
    expect(cleaned.warnings.count == 1 && cleaned.warnings[0].contains("Clean up voice"), "a failed voice cleanup is a warning (\(cleaned.warnings))")
    expect(cleaned.asset.tracks(withMediaType: .audio).count == 1, "and the original voice still plays")
    try FileManager.default.removeItem(at: dir.appendingPathComponent(VoiceCleanup.fileName))
    // Cached: a second read doesn't need the video.
    try FileManager.default.removeItem(at: video)
    let cached = try await Analyzer.loudness(loaded, video: "screen.mp4")
    expect(cached.count == levels.count && abs(cached[10].1 - levels[10].1) < 0.06, "loudness is read back from loudness.json")
    expect((try? WordTiming.cachedLevels(dir))??.count == levels.count, "word timing finds the cached levels")
  }

  /// analyze() on a recording with no audio (no whisper needed) and text under a click.
  static func analyzeAndScreenText(_ root: URL) async throws {
    let dir = try folder(root, "screentext")
    let w = 1280, h = 720
    // "Save Changes" in black on white, with its left edge at 40% across and its baseline 30% down.
    try await writeVideo(to: dir.appendingPathComponent("screen.mp4"), width: w, height: h, seconds: 3) { ctx, _ in
      ctx.setFillColor(CGColor(gray: 1, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
      let text = NSAttributedString(
        string: "Save Changes", attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
      ctx.textPosition = CGPoint(x: Double(w) * 0.4, y: Double(h) * 0.7)
      CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
    }
    try writeSource(dir, width: Double(w), height: Double(h), duration: 3, captureStart: 100)
    // A click on the text, a second click 0.2 s later (same frame), one off screen, and a key press.
    try write(
      [
        #"{"type":"meta","t":100}"#, #"{"type":"click","t":101.5,"x":0.45,"y":0.29}"#, #"{"type":"click","t":101.7,"x":0.45,"y":0.29}"#,
        #"{"type":"click","t":102,"x":1.4,"y":0.5}"#, #"{"type":"key","t":102.2,"x":0.5,"y":0.5}"#,
      ].joined(separator: "\n"), dir.appendingPathComponent("events.jsonl"))
    var logged: [String] = []
    try await analyze(dir) { logged.append($0) }
    let transcript = try String(contentsOf: dir.appendingPathComponent("transcript.json"), encoding: .utf8)
    expect(transcript.contains(#""segments": []"#) && logged.contains { $0.contains("No audio") }, "no audio: an empty transcript, no whisper")
    expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("motion.json").path), "analyze writes motion.json")
    expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("loudness.json").path), "no audio, no loudness.json")
    let samples = ScreenText.load(dir)
    expect(samples.count == 1 && samples.first?.t == 1.5, "one sample: the near-duplicate and off-screen clicks are skipped (\(samples.map(\.t)))")
    expect(ScreenText.clicked(samples, at: 1.5) == "Save Changes", "the click reads the text it landed on (\(samples.first?.items.map(\.text) ?? []))")
    if let item = samples.first?.items.first(where: { $0.text == "Save Changes" }) {
      expect(abs(item.x - 0.4) < 0.02 && item.y < 0.3 && item.y + item.h > 0.27, "the text's box is where it was drawn (\(item))")
    }
    let project = try Project.load(dir)
    expect(try await ScreenText.recognize(project, limit: 0).isEmpty, "a limit of 0 reads nothing")
    // No clicks: readScreenText leaves screentext.json alone.
    try FileManager.default.removeItem(at: ScreenText.url(dir))
    try write("", dir.appendingPathComponent("events.jsonl"))
    try await readScreenText(dir)
    expect(!FileManager.default.fileExists(atPath: ScreenText.url(dir).path), "no clicks, no screentext.json")
  }

  /// Joining two takes: one video, a camera on the joined clock, and every timed file shifted.
  static func join(_ root: URL) async throws {
    let a = try folder(root, "take-a"), b = try folder(root, "take-b")
    try await barVideo(to: a.appendingPathComponent("screen.mp4"), seconds: 2)
    try addTone(a.appendingPathComponent("screen.mp4"), parts: [(0, 2, 0.3)], seconds: 2)
    try await barVideo(to: b.appendingPathComponent("screen.mp4"), seconds: 3)
    try addTone(b.appendingPathComponent("screen.mp4"), parts: [(0, 3, 0.3)], seconds: 3)
    // A's camera starts 0.5 s into the screen and is 1.5 s long, so it runs out 0.5 s early;
    // B's starts 0.3 s late (offset -0.3) and covers the rest.
    try await barVideo(to: a.appendingPathComponent("camera.mp4"), width: 320, height: 180, seconds: 1.5)
    try await barVideo(to: b.appendingPathComponent("camera.mp4"), width: 320, height: 180, seconds: 2.7)
    try writeSource(a, width: 640, height: 360, duration: 2, captureStart: 0, camera: Plan.Camera(video: "camera.mp4", offset: 0.5))
    try writeSource(b, width: 640, height: 360, duration: 3, captureStart: 0, camera: Plan.Camera(video: "camera.mp4", offset: -0.3))
    try write(#"{"type":"click","t":0.5,"x":0.1,"y":0.2}"#, a.appendingPathComponent("events.jsonl"))
    try write(#"{"type":"key","t":1,"x":0.5,"y":0.5,"label":"⌘S"}"#, b.appendingPathComponent("events.jsonl"))
    try write(#"{"segments":[{"words":[{"word":" Hello","start":0.2,"end":0.6}]}]}"#, a.appendingPathComponent("transcript.json"))
    try write(#"{"segments":[{"words":[{"word":" again","start":0.5,"end":0.9}]}]}"#, b.appendingPathComponent("transcript.json"))
    try write("[[0, 1], [1.5, 2], [1.99, 3]]", a.appendingPathComponent("motion.json"))
    try write("[[0, 4], [2.5, 5]]", b.appendingPathComponent("motion.json"))
    try write("Take one line.", a.appendingPathComponent("script.md"))
    try write("Take two line.", b.appendingPathComponent("script.md"))

    let out = root.appendingPathComponent("joined")
    let result = try await Join.run([a, b], into: out)
    expect(result.starts.count == 2 && result.starts[0] == 0 && abs(result.starts[1] - 2) < 0.02, "take B starts where A ends (\(result.starts))")
    let screenLength = await duration(out.appendingPathComponent("screen.mp4"))
    let cameraLength = await duration(out.appendingPathComponent("camera.mp4"))
    expect(abs(screenLength - 5) < 0.1, "the joined screen is both takes long (\(screenLength))")
    expect(abs(cameraLength - screenLength) < 0.1, "the camera is stretched to cover the whole screen (\(cameraLength))")
    let joined = try Project.load(out)
    let joinAt = joined.source.joins ?? []
    expect(joined.source.camera?.offset == 0 && joinAt.count == 1 && abs(joinAt[0] - 2) < 0.02, "source.json: camera on the joined clock, one join")
    expect(abs(joined.source.duration - screenLength) < 0.01 && joined.source.captureStart == 0, "source.json duration is the real video's")
    expect(joined.clicks.map(\.t) == [0.5] && joined.shortcuts.count == 1 && abs((joined.shortcuts.first?.t ?? 0) - 3) < 0.02, "events shift onto the joined clock")
    expect(joined.shortcuts.first?.label == "⌘S", "event labels survive the join")
    expect(joined.words.map(\.text) == ["Hello", "again"] && abs((joined.words.last?.start ?? 0) - 2.5) < 0.02, "transcript words shift (\(joined.words))")
    expect(joined.motion.map(\.1) == [1, 2, 3, 4, 5] && abs((joined.motion.last?.0 ?? 0) - 4.5) < 0.02, "motion samples merge in order (\(joined.motion))")
    expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("loudness.json").path), "loudness isn't written when a take lacks it")
    expect(joined.script.count == 2, "both scripts carry over (\(joined.script))")
    let audio = try await AVURLAsset(url: out.appendingPathComponent("screen.mp4")).loadTracks(withMediaType: .audio)
    expect(audio.count == 1, "the joined video keeps the audio")
    // The originals are only read.
    expect(try Project.load(a).clicks.map(\.t) == [0.5], "the takes are untouched")

    do {
      _ = try await Join.run([a], into: root.appendingPathComponent("one"))
      expect(false, "joining one take fails")
    } catch Join.JoinError.needTwo {
      expect(true, "joining one take fails")
    }
    do {
      _ = try await Join.run([a, b], into: out)
      expect(false, "joining into an existing folder fails")
    } catch Join.JoinError.exists {
      expect(true, "joining into an existing folder fails")
    }
    try writeSource(b, width: 1280, height: 720, duration: 3, captureStart: 0)
    let mismatch = root.appendingPathComponent("mismatch")
    do {
      _ = try await Join.run([a, b], into: mismatch)
      expect(false, "takes of different sizes don't join")
    } catch Join.JoinError.sizeMismatch(let name) {
      expect(name == "take-b" && !FileManager.default.fileExists(atPath: mismatch.path), "takes of different sizes don't join, and nothing is written")
    }
  }

  /// GIF export from a built composition, and publishing (captions, transcript, thumbnails) without a camera.
  static func gifAndPublish(_ root: URL) async throws {
    let dir = try folder(root, "publish")
    try await barVideo(to: dir.appendingPathComponent("screen.mp4"), seconds: 3)
    try writeSource(dir, width: 640, height: 360, duration: 3)
    try write(
      #"{"segments":[{"words":[{"word":" One","start":0.2,"end":0.5},{"word":" two.","start":0.6,"end":0.9},{"word":" Three","start":2.1,"end":2.5}]}]}"#,
      dir.appendingPathComponent("transcript.json"))
    let project = try Project.load(dir)
    var plan = buildPlan(project)
    plan.segments = [Segment(start: 0, end: 1, speed: 1), Segment(start: 2, end: 3, speed: 1)]
    plan.output = Plan.Output(width: 640, height: 360, fps: 30)
    plan.callouts = [Callout(start: 2.2, end: 2.8, text: "Part two")]
    let built = try await buildComposition(project: project, plan: plan)

    let gif = dir.appendingPathComponent("clip.gif")
    var progress = 0.0
    let frames = try await GIF.export(built, to: gif, options: GIF.Options(from: 0.5, to: 1.5, width: 320, fps: 12)) { progress = $0 }
    let src = CGImageSourceCreateWithURL(gif as CFURL, nil)
    let first = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    expect(frames == 12 && src.map(CGImageSourceGetCount) == 12, "1 s at 12 fps is 12 frames (\(frames))")
    expect(first?.width == 320 && first?.height == 180, "frames are scaled to the width (\(first?.width ?? 0)x\(first?.height ?? 0))")
    let delays = (0..<12).compactMap { i -> Double? in
      let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, i, nil) } as? [CFString: Any]
      return (props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    }
    expect(delays.count == 12 && abs(delays.reduce(0, +) - 1) < 0.001, "frame delays add up to exactly 1 s (\(delays))")
    expect(Set(delays.map { ($0 * 100).rounded() }) == [8, 9], "1/12 s alternates 8 and 9 hundredths")
    expect(abs(progress - 1) < 1e-9, "progress reaches 1")
    let wide = try await GIF.export(built, to: gif, options: GIF.Options(from: 1.9, to: 5, width: 4000, fps: 5))
    let wideFirst = CGImageSourceCreateWithURL(gif as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    expect(wide == 1 && wideFirst?.width == 640, "the end clamps to the video, and the width to the output (\(wide) frames, \(wideFirst?.width ?? 0) wide)")

    let files = try await Publish.run(project: project, plan: plan, title: "Media test")
    let names = files.map(\.lastPathComponent)
    expect(names == ["captions.srt", "transcript.txt", "thumbnail-1.png"], "publish writes captions, transcript and one thumbnail per title (\(names))")
    let transcript = try String(contentsOf: dir.appendingPathComponent("publish/transcript.txt"), encoding: .utf8)
    expect(transcript.hasPrefix("[0:00] One two.") && transcript.contains("[0:01] Three"), "the transcript is in output time (\(transcript))")
    let thumb = CGImageSourceCreateWithURL(dir.appendingPathComponent("publish/thumbnail-1.png") as CFURL, nil)
      .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    expect(thumb?.width == 1280 && thumb?.height == 720, "the thumbnail is 1280x720 (\(thumb?.width ?? 0)x\(thumb?.height ?? 0))")

    // A camera with no face in it: no thumbnails faces, no face center, and lip sync doesn't guess.
    try await barVideo(to: dir.appendingPathComponent("camera.mp4"), width: 320, height: 180, seconds: 3)
    try addTone(dir.appendingPathComponent("screen.mp4"), parts: [(0, 3, 0.3)], seconds: 3)
    var faceless = plan
    faceless.camera = Plan.Camera(video: "camera.mp4", offset: 0)
    expect(try await Publish.bestFaces(project: project, plan: faceless).isEmpty, "no face, no best frames")
    expect(try await Publish.faceCenter(project: project, plan: faceless) == nil, "no face, no face center")
    let synced = try await LipSync.measure(project: project, camera: faceless.camera!)
    expect(synced?.confident != true, "no face, no confident lip sync (\(String(describing: synced)))")
  }

  /// The export queue's success path: two queued exports both finish, one after the other, at the plan's size and length.
  static func exportQueue(_ root: URL) async throws {
    let dir = try folder(root, "export")
    try await barVideo(to: dir.appendingPathComponent("screen.mp4"), seconds: 3)
    try writeSource(dir, width: 640, height: 360, duration: 3)
    var plan = buildPlan(try Project.load(dir))
    plan.intro = nil
    plan.outro = nil
    plan.segments = [Segment(start: 0, end: 1, speed: 1), Segment(start: 1.5, end: 3, speed: 3)]
    plan.output = Plan.Output(width: 640, height: 360, fps: 30)
    let outA = dir.appendingPathComponent("a.mp4"), outB = dir.appendingPathComponent("b.mp4")
    let queue = await ExportQueue()
    var finished: [String] = []
    var bWaitedForA = false
    await MainActor.run {
      queue.onFinished = { finished.append($0.label) }
      let a = queue.enqueue(projectDir: dir, plan: plan, label: "a", url: outA)
      let b = queue.enqueue(projectDir: dir, plan: plan, label: "b", url: outB)
      bWaitedForA = a.state == .running && b.state == .queued
    }
    await queue.waitUntilIdle()
    let jobs = await MainActor.run { queue.jobs.map { ($0.label, $0.state, $0.progress) } }
    expect(bWaitedForA, "the second export waits for the first")
    expect(jobs.map(\.1) == [.done, .done] && jobs.allSatisfy { $0.2 == 1 }, "both exports finish with progress 1 (\(jobs))")
    expect(finished == ["a", "b"], "onFinished runs once per export, in order (\(finished))")
    let frames = Double(planFrames(plan))
    for out in [outA, outB] {
      let asset = AVURLAsset(url: out)
      let track = try await asset.loadTracks(withMediaType: .video).first
      let size = try await track?.load(.naturalSize)
      let length = try await track?.load(.timeRange).duration.seconds ?? 0
      expect(size == CGSize(width: 640, height: 360), "\(out.lastPathComponent) is 640x360 (\(String(describing: size)))")
      expect(abs(length - frames / 30) < 0.02, "\(out.lastPathComponent) is the plan's length (\(length) vs \(frames / 30))")
    }
  }

  /// A file in test/fixtures (see its README). media-test.sh runs from macos/.
  static func fixture(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("../test/fixtures/\(name)").standardized
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw NSError(domain: "Media", code: 6, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(url.path)"])
    }
    return url
  }

  /// A real face: thumbnail picks, face centering, the person cutout, and lip sync finding a known camera lag.
  static func faces(_ root: URL) async throws {
    let dir = try folder(root, "faces")
    let clip = try fixture("talking-head.mp4")
    try FileManager.default.copyItem(at: clip, to: dir.appendingPathComponent("screen.mp4"))
    try FileManager.default.copyItem(at: clip, to: dir.appendingPathComponent("camera.mp4"))
    let length = await duration(clip)
    try writeSource(dir, width: 640, height: 360, duration: length)
    let project = try Project.load(dir)
    var plan = buildPlan(project)
    plan.intro = nil
    plan.outro = nil
    plan.segments = [Segment(start: 0, end: length, speed: 1)]
    plan.output = Plan.Output(width: 640, height: 360, fps: 30)
    plan.camera = Plan.Camera(video: "camera.mp4", offset: 0)

    let center = try await Publish.faceCenter(project: project, plan: plan)
    expect(center.map { (0.25...0.75).contains($0.x) && (0.15...0.85).contains($0.y) } == true, "the face is found near the middle (\(String(describing: center)))")
    let picks = try await Publish.bestFaces(project: project, plan: plan)
    let times = picks.map(\.sourceTime).sorted()
    expect(picks.count == 3, "three thumbnail faces in 40 s (\(picks.count))")
    expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 3 }, "picked faces are at least 3 s apart (\(times))")
    expect(picks.allSatisfy { $0.score > 0.3 } && picks.map(\.score) == picks.map(\.score).sorted(by: >), "scores are real and best first (\(picks.map(\.score)))")
    // The person is cut out of the frame, and the thumbnail draws them over the background on the left.
    if let best = picks.first {
      let cut = Publish.cutout(best.image)
      let alpha = cut.map { img -> Double in
        let small = img.transformed(by: CGAffineTransform(scaleX: 64 / img.extent.width, y: 36 / img.extent.height))
        var px = [UInt8](repeating: 0, count: 64 * 36 * 4)
        CIContext().render(small, toBitmap: &px, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 36), format: .RGBA8, colorSpace: nil)
        return Double(stride(from: 3, to: px.count, by: 4).filter { px[$0] > 128 }.count) / Double(64 * 36)
      }
      expect(alpha.map { $0 > 0.1 && $0 < 0.8 } == true, "the cutout keeps the person and drops the room (\(alpha ?? -1) opaque)")
      let built = try await buildComposition(project: project, plan: plan)
      let withPerson = Publish.thumbnail(scene: built.scene, screen: best.image, person: best.image, title: "Life in space")
      let without = Publish.thumbnail(scene: built.scene, screen: best.image, person: nil, title: "Life in space")
      expect(withPerson?.width == 1280 && withPerson?.height == 720, "the thumbnail is 1280x720")
      let left = { (img: CGImage?) -> Data? in
        img.flatMap { $0.cropping(to: CGRect(x: 0, y: 0, width: 500, height: 720)) }.flatMap { $0.dataProvider?.data as Data? }
      }
      expect(left(withPerson) != nil && left(withPerson) != left(without), "the person is drawn on the left of the thumbnail")
    }

    // Lip sync: the clip's own camera (in sync) reads within 50 ms of 0 once lips leading the voice
    // is allowed for (it read -0.094 s before; its 10 s windows don't all agree, so it isn't
    // "confident"), and a camera file that starts 0.3 s into the same footage is found, confidently,
    // at -0.3 s.
    guard let synced = try await LipSync.measure(project: project, camera: plan.camera!) else {
      expect(false, "lip sync measures the talking head")
      return
    }
    expect(synced.strength >= 0.08 && abs(synced.offset) < 0.05, "the clip's own camera has a clear peak at 0 (\(synced))")
    try run("ffmpeg", ["-v", "error", "-y", "-ss", "0.3", "-i", clip.path, "-an", "-c:v", "libx264", "-crf", "30", dir.appendingPathComponent("late.mp4").path])
    let late = try await LipSync.measure(project: project, camera: Plan.Camera(video: "late.mp4", offset: 0))
    expect(late.map { $0.confident && abs($0.offset + 0.3) < 0.05 } == true, "a camera 0.3 s off is found (\(String(describing: late)))")
  }

  /// whisper-cli's JSON (a real capture, test/fixtures/whisper-cli.json) becomes transcript.json:
  /// words trimmed, times in seconds, blanks and [BLANK_AUDIO] dropped, and Project.load reads it back.
  /// The model itself isn't tested, and neither is running whisper-cli (Analyzer.transcribe).
  static func transcription(_ root: URL) async throws {
    let dir = try folder(root, "whisper")
    let out = dir.appendingPathComponent("transcript.json")
    try Analyzer.writeMlxTranscript(fromWhisperCpp: Data(contentsOf: try fixture("whisper-cli.json")), to: out)
    let written = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any]
    expect(
      written?["text"] as? String == " Record the screen, then edit the video by changing a plan",
      "the transcript's text joins the words (\(written?["text"] ?? "none"))")
    try writeSource(dir, width: 640, height: 360, duration: 8)
    let words = try Project.load(dir).words
    expect(
      words.map(\.text) == ["Record", "the", "screen,", "then", "edit", "the", "video", "by", "changing", "a", "plan"],
      "words are trimmed, and the empty item and [BLANK_AUDIO] are dropped (\(words.map(\.text)))")
    expect(
      words.first.map { [$0.start, $0.end] } == [0, 0.72] && words.last.map { [$0.start, $0.end] } == [5.03, 5.84],
      "offsets in ms become seconds")
    expect(words.count == 11 && words[9].start == 5.03 && words[9].end == 5.03, "a zero-length word keeps its time")
    try Analyzer.writeMlxTranscript(fromWhisperCpp: Data(#"{"transcription": []}"#.utf8), to: out)
    expect(try Project.load(dir).words.isEmpty, "no speech, no words")
    expect((try? Analyzer.writeMlxTranscript(fromWhisperCpp: Data("not json".utf8), to: out)) == nil, "unreadable whisper output fails")
  }

}
