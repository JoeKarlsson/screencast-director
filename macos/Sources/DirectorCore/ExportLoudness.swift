import AVFoundation
import Foundation

/// The last step of every export: the finished mix brought to streaming loudness, -14 LUFS
/// integrated with the true peak at or under -1 dBTP, so every video plays back at the same level.
/// AudioGain levels speech phrase by phrase; this measures and sets the whole mix once.
///
/// ffmpeg's two-pass `loudnorm` (pass one measures, pass two applies those numbers, linearly when
/// the peaks allow), then a limiter oversampled to 192 kHz, since AAC encoding adds peaks between
/// samples that loudnorm can't see. If the encoded file still peaks over the ceiling, the sound is
/// encoded again with the limiter lower, up to three times. The picture is stream-copied, never
/// re-encoded. Ported from Lemo-Opuscar's core/render/mux.sh (MIT).
public enum ExportLoudness {
  public static let targetLUFS = -14.0
  /// What the final file's true peak must stay at or under.
  public static let ceilingDBTP = -1.0
  /// loudnorm's own true-peak target, a little under the ceiling.
  static let loudnormTP = -1.2
  /// The limiter's first ceiling in dBFS, under the ceiling to leave room for the AAC encode.
  static let firstLimit = -1.6
  static let retries = 3

  public struct Measurement: Equatable, Sendable {
    public var integrated: Double
    public var truePeak: Double
    public var range: Double

    public var text: String { String(format: "%.1f LUFS, true peak %+.1f dBTP, range %.1f LU", integrated, truePeak, range) }
  }

  public struct Report: Sendable {
    /// The mix as AVFoundation exported it, and the finished file. nil when nothing was measured.
    public var before: Measurement?
    public var after: Measurement?
    /// loudnorm's mode in the last pass: "linear" (one gain for the whole mix) or "dynamic".
    public var mode: String?
    public var warnings: [String] = []

    public var summary: String? {
      guard let after else { return nil }
      return "Sound mastered to \(after.text)" + (before.map { " (was \($0.text)" + (mode.map { "; \($0) normalization)" } ?? ")") } ?? "")
    }
  }

  /// Normalizes `input`'s sound into `output` (written beside it under a temporary name and renamed
  /// when finished, so a failure or cancel never leaves a partial file at `output`). `input` is
  /// left in place for the caller to remove. With no sound, silent sound or no ffmpeg, `input` is
  /// moved to `output` as it is and the report says why.
  public static func normalize(_ input: URL, to output: URL, progress: ((Double) -> Void)? = nil) async throws -> Report {
    var report = Report()
    guard try await !AVURLAsset(url: input).loadTracks(withMediaType: .audio).isEmpty else {
      try place(input, at: output)
      return report
    }
    guard let ffmpeg = Tools.ffmpeg else {
      report.warnings.append("The sound isn't mastered to \(Int(targetLUFS)) LUFS: that needs ffmpeg (brew install ffmpeg).")
      try place(input, at: output)
      return report
    }

    // Pass one: measure.
    var measured = try loudnorm(try await run(ffmpeg, ["-i", input.path, "-vn", "-af", measureFilter(pre: ""), "-f", "null", "-"]))
    progress?(0.3)
    guard let firstI = measured["input_i"].flatMap(Double.init), firstI.isFinite else {
      report.warnings.append("The sound is silent (or quieter than -70 LUFS), so it isn't mastered to \(Int(targetLUFS)) LUFS.")
      try place(input, at: output)
      return report
    }
    // loudnorm takes a measured loudness of 0 LUFS at most; a hotter mix is clipping. Turn it down
    // to about the target first, and measure again.
    var pre = ""
    if firstI > 0 {
      pre = String(format: "volume=%.2fdB,", -(firstI - targetLUFS))
      report.warnings.append(String(format: "The mix measures %+.1f LUFS, so it's almost certainly clipping; it was turned down before mastering.", firstI))
      measured = try loudnorm(try await run(ffmpeg, ["-i", input.path, "-vn", "-af", measureFilter(pre: pre), "-f", "null", "-"]))
    }
    guard let values = measuredValues(measured) else {
      throw DirectorError("couldn't measure the sound's loudness for mastering: \(measured)")
    }
    report.before = try await measure(input, ffmpeg: ffmpeg)

    // Pass two: apply, limit, encode; again with a lower limit while the encoded peak is over.
    let partial = output.deletingLastPathComponent().appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).mastering.mp4")
    defer { try? FileManager.default.removeItem(at: partial) }
    var limit = firstLimit
    var attempt = 0
    while true {
      let log = try await run(ffmpeg, encodeArguments(input, partial, filter: applyFilter(pre: pre, values, limit: limit)))
      report.mode = (try? loudnorm(log))?["normalization_type"]
      let after = try await measure(partial, ffmpeg: ffmpeg)
      report.after = after
      progress?(0.6 + 0.4 * Double(attempt + 1) / Double(retries + 1))
      guard after.truePeak > ceilingDBTP, attempt < retries else { break }
      attempt += 1
      limit -= after.truePeak - ceilingDBTP + 0.3
    }
    if let after = report.after {
      if after.truePeak > ceilingDBTP {
        report.warnings.append(String(format: "The true peak is still %+.1f dBTP after %d tries, over the %.0f dBTP ceiling.", after.truePeak, retries, ceilingDBTP))
      }
      if abs(after.integrated - targetLUFS) > 1 {
        report.warnings.append(String(format: "The sound measures %.1f LUFS, off the %.0f LUFS target: the mix probably has very hot peaks.", after.integrated, targetLUFS))
      }
    }
    let stamped = output.deletingLastPathComponent().appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).stamping.mp4")
    defer { try? FileManager.default.removeItem(at: stamped) }
    try await copyMetadata(from: input, partial, to: stamped)
    try place(stamped, at: output)
    return report
  }

  /// ffmpeg neither reads nor writes the MP4 description AVFoundation stamps the export with
  /// (Provenance), so the mastered file is copied once more, untouched, with the input's metadata.
  static func copyMetadata(from source: URL, _ file: URL, to out: URL) async throws {
    try? FileManager.default.removeItem(at: out)
    guard let session = AVAssetExportSession(asset: AVURLAsset(url: file), presetName: AVAssetExportPresetPassthrough) else {
      throw DirectorError("Can't create an export session.")
    }
    session.metadata = try await AVURLAsset(url: source).load(.metadata)
    session.shouldOptimizeForNetworkUse = true
    try await session.export(to: out, as: .mp4)
  }

  static func measureFilter(pre: String) -> String {
    "\(pre)loudnorm=I=\(targetLUFS):TP=\(loudnormTP):LRA=11:print_format=json"
  }

  struct Values: Equatable {
    var i, tp, lra, thresh, offset: Double
  }

  /// loudnorm's pass-one numbers, or nil when any is missing or not finite (silence reads -inf).
  static func measuredValues(_ json: [String: String]) -> Values? {
    let keys = ["input_i", "input_tp", "input_lra", "input_thresh", "target_offset"]
    let v = keys.compactMap { json[$0].flatMap(Double.init) }.filter(\.isFinite)
    guard v.count == keys.count else { return nil }
    return Values(i: v[0], tp: v[1], lra: v[2], thresh: v[3], offset: v[4])
  }

  /// Pass two. Linear normalization falls back to dynamic when the target loudness range is under
  /// the mix's, so the target range is never set under it: a mix keeps its dynamics unless its
  /// peaks need them squeezed. Then the limiter at 192 kHz (to catch peaks between samples), its
  /// 10 ms look-ahead taken back (latency) so the sound stays on its frames, and back to 48 kHz.
  static func applyFilter(pre: String, _ m: Values, limit: Double) -> String {
    let lra = min(50, max(11, m.lra))
    return String(
      format: "%@loudnorm=I=%.1f:TP=%.1f:LRA=%.1f:measured_I=%.2f:measured_TP=%.2f:measured_LRA=%.2f:measured_thresh=%.2f:offset=%.2f:linear=true:print_format=json,"
        + "aresample=192000,alimiter=limit=%.4f:attack=10:release=200:level=disabled:latency=1,aresample=48000",
      pre, targetLUFS, loudnormTP, lra, m.i, m.tp, m.lra, m.thresh, m.offset, pow(10, limit / 20))
  }

  /// The picture is copied; only the sound is encoded.
  static func encodeArguments(_ input: URL, _ output: URL, filter: String) -> [String] {
    ["-y", "-i", input.path, "-map", "0:v", "-map", "0:a:0", "-c:v", "copy", "-af", filter, "-c:a", "aac_at", "-b:a", "256k", "-f", "mp4", output.path]
  }

  /// Integrated loudness, true peak and loudness range of a file's sound, from ffmpeg's ebur128.
  static func measure(_ url: URL, ffmpeg: URL) async throws -> Measurement {
    let log = try await run(ffmpeg, ["-i", url.path, "-vn", "-af", "ebur128=peak=true", "-f", "null", "-"])
    guard let m = ebur128Summary(log) else { throw DirectorError("couldn't read ffmpeg's loudness summary of \(url.lastPathComponent)") }
    return m
  }

  /// The I, LRA and Peak lines after "Summary:" in ebur128's log.
  static func ebur128Summary(_ log: String) -> Measurement? {
    guard let start = log.range(of: "Summary:", options: .backwards) else { return nil }
    var found: [String: Double] = [:]
    for line in log[start.upperBound...].split(separator: "\n") {
      let parts = line.split(separator: " ")
      guard parts.count >= 2, ["I:", "LRA:", "Peak:"].contains(parts[0]), found[String(parts[0])] == nil else { continue }
      found[String(parts[0])] = parts[1] == "-inf" ? -.infinity : Double(parts[1])
    }
    guard let i = found["I:"], let lra = found["LRA:"], let peak = found["Peak:"] else { return nil }
    return Measurement(integrated: i, truePeak: peak, range: lra)
  }

  /// loudnorm's JSON block, the last {...} in the log.
  static func loudnorm(_ log: String) throws -> [String: String] {
    guard let open = log.range(of: "{", options: .backwards), let close = log.range(of: "}", options: .backwards), open.lowerBound < close.lowerBound,
      let json = try JSONSerialization.jsonObject(with: Data(log[open.lowerBound..<close.upperBound].utf8)) as? [String: String]
    else { throw DirectorError("ffmpeg's loudnorm printed no measurements: \(log.suffix(400))") }
    return json
  }

  /// Runs ffmpeg and returns its log (stderr). Cancelling the task stops it.
  static func run(_ ffmpeg: URL, _ args: [String]) async throws -> String {
    let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("sd-ffmpeg-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { throw DirectorError("couldn't create \(logURL.path)") }
    defer { try? FileManager.default.removeItem(at: logURL) }
    let handle = try FileHandle(forWritingTo: logURL)
    defer { try? handle.close() }
    let proc = Process()
    proc.executableURL = ffmpeg
    // Only local files: the input is our own export, and it mustn't make ffmpeg open anything else.
    proc.arguments = ["-hide_banner", "-nostdin", "-nostats", "-protocol_whitelist", "file"] + args
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = handle
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        proc.terminationHandler = { _ in done.resume() }
        do {
          try proc.run()
        } catch {
          proc.terminationHandler = nil
          done.resume(throwing: error)
        }
      }
    } onCancel: {
      if proc.isRunning { proc.terminate() }
    }
    try Task.checkCancellation()
    let log = try String(contentsOf: logURL, encoding: .utf8)
    guard proc.terminationStatus == 0 else { throw DirectorError("ffmpeg failed while mastering the sound: \(log.suffix(400))") }
    return log
  }

  /// Moves a finished file into place, replacing what was there.
  static func place(_ file: URL, at url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    try FileManager.default.moveItem(at: file, to: url)
  }
}
