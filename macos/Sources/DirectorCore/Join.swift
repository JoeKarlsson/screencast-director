import AVFoundation
import Foundation

/// Joins several takes into one new project: one screen.mp4 (and camera.mp4 when every take has a
/// camera), with the transcript, input events, loudness and motion shifted onto the joined clock.
/// The originals are only read.
public enum Join {
  public struct Result {
    public let dir: URL
    /// Where each take starts in the joined recording (seconds).
    public let starts: [Double]
  }

  public enum JoinError: LocalizedError {
    case needTwo, exists(String), sizeMismatch(String), exportFailed(String)
    public var errorDescription: String? {
      switch self {
      case .needTwo: return "Pick at least two recordings to join."
      case .exists(let p): return "\(p) already exists."
      case .sizeMismatch(let n): return "\(n) was recorded at a different screen size; only recordings of the same size can be joined."
      case .exportFailed(let m): return "Couldn't write the joined video: \(m)"
      }
    }
  }

  public static func run(_ dirs: [URL], into out: URL, log: (String) -> Void = { _ in }) async throws -> Result {
    guard dirs.count >= 2 else { throw JoinError.needTwo }
    guard !FileManager.default.fileExists(atPath: out.path) else { throw JoinError.exists(out.path) }
    let projects = try dirs.map { try Project.load($0) }
    let first = projects[0].source
    for p in projects.dropFirst() where p.source.width != first.width || p.source.height != first.height {
      throw JoinError.sizeMismatch(p.name)
    }
    let withCamera = projects.allSatisfy { $0.source.camera != nil }

    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }
    let screen = AVMutableComposition()
    let vTrack = screen.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let aTrack = screen.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let camera = AVMutableComposition()
    let cTrack = withCamera ? camera.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
    // AVAssetTracks don't keep their assets alive; hold every asset until the exports finish.
    var assets: [AVURLAsset] = []
    var starts: [Double] = []
    var at = 0.0

    for p in projects {
      starts.append(at)
      let asset = AVURLAsset(url: p.dir.appendingPathComponent(p.source.video))
      assets.append(asset)
      guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw CompositionError.noVideo(p.source.video) }
      let range = try await v.load(.timeRange)
      let dur = range.duration.seconds
      try vTrack.insertTimeRange(range, of: v, at: t(at))
      if let a = try await asset.loadTracks(withMediaType: .audio).first {
        let ar = try await a.load(.timeRange)
        try aTrack.insertTimeRange(CMTimeRange(start: ar.start, duration: CMTimeMinimum(ar.duration, range.duration)), of: a, at: t(at))
      }
      if let cTrack, let cam = p.source.camera {
        // Camera time = screen time + offset. Keep the joined camera on the joined screen's clock
        // (offset 0), stretching its first or last frame over any part the camera didn't cover.
        let camAsset = AVURLAsset(url: p.dir.appendingPathComponent(cam.video))
        assets.append(camAsset)
        if let ct = try await camAsset.loadTracks(withMediaType: .video).first {
          let camDur = try await ct.load(.timeRange).duration.seconds
          let a = max(0, cam.offset), b = min(camDur, dur + cam.offset)
          let lead = a - cam.offset, tail = dur - (b - cam.offset)
          let sliver = 1.0 / 30
          var pos = at
          if lead > 0.001 {
            try cTrack.insertTimeRange(CMTimeRange(start: t(a), duration: t(sliver)), of: ct, at: t(pos))
            cTrack.scaleTimeRange(CMTimeRange(start: t(pos), duration: t(sliver)), toDuration: t(lead))
            pos += lead
          }
          try cTrack.insertTimeRange(CMTimeRange(start: t(a), end: t(b)), of: ct, at: t(pos))
          pos += b - a
          if tail > 0.001 {
            try cTrack.insertTimeRange(CMTimeRange(start: t(b - sliver), duration: t(sliver)), of: ct, at: t(pos))
            cTrack.scaleTimeRange(CMTimeRange(start: t(pos), duration: t(sliver)), toDuration: t(tail))
          }
        }
      }
      at += dur
    }
    let total = at
    if aTrack.segments.isEmpty { screen.removeTrack(aTrack) }

    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    do {
      log("Writing screen.mp4 (\(fmtTime(total)))...")
      try await write(screen, to: out.appendingPathComponent("screen.mp4"))
      if withCamera {
        log("Writing camera.mp4...")
        try await write(camera, to: out.appendingPathComponent("camera.mp4"))
      }
    } catch {
      try? FileManager.default.removeItem(at: out)
      throw error
    }
    withExtendedLifetime(assets) {}

    // source.json: events are written relative to the video, so captureStart is 0.
    var source = Project.Source(
      video: "screen.mp4", width: first.width, height: first.height, duration: total, captureStart: 0,
      camera: withCamera ? Plan.Camera(video: "camera.mp4", offset: 0) : nil,
      cursorHidden: projects.allSatisfy { $0.source.cursorHidden == true } ? true : nil)
    source.joins = Array(starts.dropFirst())
    if let real = try? await AVURLAsset(url: out.appendingPathComponent("screen.mp4")).load(.duration).seconds { source.duration = real }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(source).write(to: out.appendingPathComponent("source.json"))

    // events.jsonl
    var lines = [#"{"type":"meta","clock":"joined","t":0}"#]
    for (p, start) in zip(projects, starts) {
      for e in p.events {
        var obj: [String: Any] = ["type": e.type.rawValue, "t": e.t + start, "x": e.x, "y": e.y]
        if let l = e.label { obj["label"] = l }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        lines.append(String(decoding: data, as: UTF8.self))
      }
    }
    try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)

    // transcript.json: the raw Whisper words (Project.load refines them against loudness.json).
    var segments: [[String: Any]] = []
    var allText: [String] = []
    for (p, start) in zip(projects, starts) {
      let words = Project.loadWords(p.dir.appendingPathComponent("transcript.json"))
      guard !words.isEmpty else { continue }
      let text = words.map(\.text).joined(separator: " ")
      allText.append(text)
      segments.append([
        "start": words[0].start + start, "end": words[words.count - 1].end + start, "text": " " + text,
        "words": words.map { ["word": " " + $0.text, "start": $0.start + start, "end": $0.end + start] },
      ])
    }
    try JSONSerialization.data(withJSONObject: ["text": allText.joined(separator: " "), "segments": segments], options: [.prettyPrinted])
      .write(to: out.appendingPathComponent("transcript.json"))

    // loudness.json and motion.json: [[t, value]] samples, shifted. Written only when every take
    // has them; otherwise analysis measures the joined video.
    for file in ["loudness.json", "motion.json"] {
      var merged: [[Double]] = []
      var complete = true
      for (p, start) in zip(projects, starts) {
        guard let data = try? Data(contentsOf: p.dir.appendingPathComponent(file)),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
        else {
          complete = false
          break
        }
        let end = starts.first(where: { $0 > start }) ?? total
        merged += arr.filter { $0.count == 2 && $0[0] + start < end }.map { [$0[0] + start, $0[1]] }
      }
      guard complete else { continue }
      let body = merged.map { String(format: "[%.3f, %.3f]", $0[0], $0[1]) }.joined(separator: ", ")
      try "[\(body)]\n".write(to: out.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    // script.md: each take's script, in order.
    let scripts = projects.compactMap { try? String(contentsOf: $0.dir.appendingPathComponent("script.md"), encoding: .utf8) }
    if !scripts.isEmpty {
      try scripts.joined(separator: "\n\n").write(to: out.appendingPathComponent("script.md"), atomically: true, encoding: .utf8)
    }
    return Result(dir: out, starts: starts)
  }

  /// Passthrough keeps the original encoding (fast and lossless); stretched camera frames or
  /// mixed formats can need a re-encode, so fall back to that.
  static func write(_ comp: AVMutableComposition, to url: URL) async throws {
    var lastError: Error?
    for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
      try? FileManager.default.removeItem(at: url)
      guard let session = AVAssetExportSession(asset: comp, presetName: preset) else { continue }
      do {
        try await session.export(to: url, as: .mp4)
        return
      } catch {
        lastError = error
      }
    }
    throw JoinError.exportFailed(lastError?.localizedDescription ?? "no export session")
  }
}
