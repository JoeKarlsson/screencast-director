import AVFoundation
import CoreVideo
import Foundation

public enum AnalyzerError: LocalizedError {
  case noVideoTrack
  case whisperMissing
  case whisperFailed(String)

  public var errorDescription: String? {
    switch self {
    case .noVideoTrack: return "The recording has no video track."
    case .whisperMissing: return "No whisper-cli or Whisper model found."
    case .whisperFailed(let msg): return "Transcription failed: \(msg)"
    }
  }
}

public enum Analyzer {
  /// Mean frame-to-frame luma difference (0-255) at ~10 fps, comparable to the Node CLI's
  /// ffmpeg tblend + signalstats measurement. Samples every 4th pixel of each sampled frame.
  public static func measureMotion(_ url: URL, progress: ((Double) -> Void)? = nil) async throws -> [(Double, Double)] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalyzerError.noVideoTrack }
    let duration = try await asset.load(.duration).seconds
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
    reader.add(output)
    reader.startReading()

    var samples: [(Double, Double)] = []
    var prev: [UInt8] = []
    var nextT = 0.0
    while let buf = output.copyNextSampleBuffer() {
      let t = CMSampleBufferGetPresentationTimeStamp(buf).seconds
      guard t >= nextT, let px = CMSampleBufferGetImageBuffer(buf) else { continue }
      nextT = t + 0.1
      CVPixelBufferLockBaseAddress(px, .readOnly)
      let w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
      let base = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
      let step = max(1, w / 480)
      var cur: [UInt8] = []
      cur.reserveCapacity((w / step + 1) * (h / step + 1))
      var y = 0
      while y < h {
        let row = base + y * stride
        var x = 0
        while x < w {
          cur.append(row[x])
          x += step
        }
        y += step
      }
      CVPixelBufferUnlockBaseAddress(px, .readOnly)
      if prev.count == cur.count {
        var sum = 0
        for i in cur.indices { sum += abs(Int(cur[i]) - Int(prev[i])) }
        samples.append(((t * 10).rounded() / 10, Double(sum) / Double(cur.count)))
      }
      prev = cur
      if duration > 0 { progress?(min(1, t / duration)) }
    }
    if reader.status == .failed, let err = reader.error { throw err }
    return samples
  }

  public static func writeMotion(_ samples: [(Double, Double)], to url: URL) throws {
    let body = samples.map { String(format: "[%.2f, %.3f]", $0.0, $0.1) }.joined(separator: ", ")
    try "[\(body)]\n".write(to: url, atomically: true, encoding: .utf8)
  }

  /// Writes the first audio track as 16 kHz mono 16-bit WAV (what whisper.cpp wants). Returns false if there's no audio.
  public static func extractAudio(_ url: URL, to wav: URL) async throws -> Bool {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return false }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    reader.add(output)
    reader.startReading()
    var pcm = Data()
    while let buf = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
      var length = 0
      var ptr: UnsafeMutablePointer<CChar>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
      if let ptr { pcm.append(UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: length) }
    }
    if reader.status == .failed, let err = reader.error { throw err }

    var header = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
    header.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
    header.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    header.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    try (header + pcm).write(to: wav)
    return true
  }

  /// Transcribes with whisper.cpp's whisper-cli at one word per segment, then writes
  /// mlx-whisper style JSON so both tools share a transcript format.
  public static func transcribe(wav: URL, whisperCLI: URL, model: URL, to out: URL) throws {
    let prefix = wav.deletingPathExtension()
    let proc = Process()
    proc.executableURL = whisperCLI
    proc.arguments = ["-m", model.path, "-f", wav.path, "-ml", "1", "-sow", "-oj", "-of", prefix.path, "-np"]
    let errPipe = Pipe()
    proc.standardError = errPipe
    proc.standardOutput = FileHandle.nullDevice
    try proc.run()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
      throw AnalyzerError.whisperFailed(String(decoding: errData.suffix(400), as: UTF8.self))
    }
    let json = prefix.appendingPathExtension("json")
    let data = try Data(contentsOf: json)
    try? FileManager.default.removeItem(at: json)
    try writeMlxTranscript(fromWhisperCpp: data, to: out)
  }

  static func writeMlxTranscript(fromWhisperCpp data: Data, to out: URL) throws {
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    let items = obj["transcription"] as? [[String: Any]] ?? []
    var words: [[String: Any]] = []
    for item in items {
      guard let text = item["text"] as? String, let offsets = item["offsets"] as? [String: Any],
        let from = (offsets["from"] as? NSNumber)?.doubleValue, let to = (offsets["to"] as? NSNumber)?.doubleValue
      else { continue }
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      // Skip blanks and whisper.cpp's bracketed annotations like [BLANK_AUDIO].
      if trimmed.isEmpty || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) { continue }
      words.append(["word": " " + trimmed, "start": from / 1000, "end": to / 1000])
    }
    let text = words.compactMap { $0["word"] as? String }.joined()
    let result: [String: Any] = ["text": text, "segments": [["words": words]]]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]).write(to: out)
  }
}

extension Analyzer {
  /// Loudness in dBFS every 50 ms of the recording's audio, for finding real silences
  /// (Whisper's word timings run straight through short pauses). Cached in loudness.json.
  public static func loudness(_ project: Project, video: String) async throws -> [(Double, Double)] {
    let cache = project.dir.appendingPathComponent("loudness.json")
    if let data = try? Data(contentsOf: cache), let arr = try? JSONSerialization.jsonObject(with: data) as? [[Double]] {
      return arr.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }
    let wav = project.dir.appendingPathComponent(".render/loudness.wav")
    try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard try await extractAudio(project.dir.appendingPathComponent(video), to: wav) else { return [] }
    let data = try Data(contentsOf: wav)
    try? FileManager.default.removeItem(at: wav)
    // 16 kHz mono 16-bit PCM after a 44-byte header; 800 samples = 50 ms.
    let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    var out: [(Double, Double)] = []
    var i = 0
    while i + 800 <= samples.count {
      var sum = 0.0
      for s in samples[i..<(i + 800)] {
        let v = Double(s) / 32768
        sum += v * v
      }
      let rms = (sum / 800).squareRoot()
      out.append((Double(i) / 16000, 20 * log10(max(rms, 1e-6))))
      i += 800
    }
    let body = out.map { String(format: "[%.2f, %.1f]", $0.0, $0.1) }.joined(separator: ", ")
    try "[\(body)]\n".write(to: cache, atomically: true, encoding: .utf8)
    return out
  }

  /// Silent stretches: quieter than the room's noise floor plus 12 dB.
  /// Quieter than this is silence: the room's noise floor (quietest 10%) plus 12 dB, at most -30 dBFS.
  public static func silenceThreshold(_ levels: [(Double, Double)]) -> Double {
    guard !levels.isEmpty else { return -45 }
    let sorted = levels.map(\.1).sorted()
    return min(sorted[sorted.count / 10] + 12, -30)
  }

  public static func silences(_ levels: [(Double, Double)], minLength: Double) -> [(Double, Double)] {
    guard !levels.isEmpty else { return [] }
    let threshold = silenceThreshold(levels)
    var out: [(Double, Double)] = []
    var start: Double?
    for (t, db) in levels {
      if db < threshold {
        if start == nil { start = t }
      } else if let s = start {
        if t - s >= minLength { out.append((s, t)) }
        start = nil
      }
    }
    if let s = start, let last = levels.last, last.0 + 0.05 - s >= minLength { out.append((s, last.0 + 0.05)) }
    return out
  }
}
