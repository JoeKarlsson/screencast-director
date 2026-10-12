import AVFoundation
import AudioToolbox
import Foundation

/// "Clean up voice": renders the recording's audio once through Apple's voice isolation
/// (AUSoundIsolation, the same model as FaceTime's Voice Isolation) plus an 80 Hz high-pass, and
/// caches it as voice-clean.m4a. The composition then takes its audio from that file with the same
/// timing as screen.mp4. If the unit isn't available, a high-pass and a gentle downward expander
/// (quiet room noise between words drops by up to 12 dB) stand in for it.
public enum VoiceCleanup {
  public static let fileName = "voice-clean.m4a"
  static let sampleRate = 48000.0

  public enum Method: String { case isolation, filter }

  /// Whether this Mac has the voice isolation unit.
  public static var hasIsolation: Bool { isolationDescription.flatMap { AudioComponentFindNext(nil, [$0]) } != nil }

  private static var isolationDescription: AudioComponentDescription? {
    AudioComponentDescription(
      componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
  }

  /// The cleaned voice for `video`, rendered now if it's missing or older than the recording.
  public static func cleaned(_ project: Project, video: String) async throws -> URL {
    let src = project.dir.appendingPathComponent(video)
    let out = project.dir.appendingPathComponent(fileName)
    if let a = modified(out), let b = modified(src), a >= b { return out }
    let levels = try? await Analyzer.loudness(project, video: video)
    try await render(source: src, to: out, method: hasIsolation ? .isolation : .filter, levels: levels ?? [])
    return out
  }

  private static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  /// Renders `source`'s audio to `out` (AAC, mono, 48 kHz). Sample 0 of the output is time 0 of the
  /// source, whatever the unit's latency or the audio track's start time.
  public static func render(source: URL, to out: URL, method: Method, levels: [(Double, Double)]) async throws {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw NSError(domain: "VoiceCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(source.lastPathComponent) has no audio."])
    }
    let duration = try await asset.load(.duration).seconds
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "VoiceCleanup", code: 2) }

    let feed = Feed(output: output)
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let engine = AVAudioEngine()
    let chunk: AVAudioFrameCount = 4096
    try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: chunk)
    let sourceNode = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
      let buffers = UnsafeMutableAudioBufferListPointer(abl)
      guard let dst = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
      feed.pull(Int(frames), into: dst)
      return noErr
    }
    engine.attach(sourceNode)
    var last: AVAudioNode = sourceNode
    var latency = 0.0
    if method == .isolation, let desc = isolationDescription {
      let iso = AVAudioUnitEffect(audioComponentDescription: desc)
      AudioUnitSetParameter(iso.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent), kAudioUnitScope_Global, 0, 100, 0)
      AudioUnitSetParameter(
        iso.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate), kAudioUnitScope_Global, 0,
        AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
      engine.attach(iso)
      engine.connect(last, to: iso, format: fmt)
      last = iso
    }
    // Rumble from desks, fans and handling sits under 80 Hz; voices don't.
    let eq = AVAudioUnitEQ(numberOfBands: 1)
    eq.bands[0].filterType = .highPass
    eq.bands[0].frequency = 80
    eq.bands[0].bypass = false
    engine.attach(eq)
    engine.connect(last, to: eq, format: fmt)
    engine.connect(eq, to: engine.mainMixerNode, format: fmt)
    try engine.start()
    defer { engine.stop() }
    for node in [last, eq] as [AVAudioNode] { latency += node.auAudioUnit.latency }

    // A unique temp name: the preview and an export can both ask for the file at once.
    let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial.m4a")
    defer { try? FileManager.default.removeItem(at: tmp) }
    do {
      let file = try AVAudioFile(
        forWriting: tmp,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 160_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
      let total = Int((duration * sampleRate).rounded())
      var skip = Int((latency * sampleRate).rounded())
      let expander = method == .filter ? Expander(threshold: Analyzer.silenceThreshold(levels) - 3) : nil
      let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk)!
      let keep = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
      var written = 0
      while written < total {
        try Task.checkCancellation()
        let status = try engine.renderOffline(chunk, to: rendered)
        guard status == .success else {
          throw NSError(domain: "VoiceCleanup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio render stopped (\(status.rawValue))."])
        }
        let n = Int(rendered.frameLength)
        let drop = min(skip, n)
        skip -= drop
        let count = min(n - drop, total - written)
        guard count > 0 else { continue }
        let src = rendered.floatChannelData![0] + drop
        let dst = keep.floatChannelData![0]
        dst.update(from: src, count: count)
        expander?.process(dst, count: count)
        keep.frameLength = AVAudioFrameCount(count)
        try file.write(from: keep)
        written += count
      }
    }  // closes the file
    if let error = feed.error { throw error }
    try? FileManager.default.removeItem(at: out)
    try FileManager.default.moveItem(at: tmp, to: out)
  }

  /// Hands the reader's samples to the render callback, padding the start to the track's first
  /// timestamp and the end with silence (which flushes the unit's latency).
  private final class Feed: @unchecked Sendable {
    let output: AVAssetReaderTrackOutput
    var pending: [Float] = []
    var start = 0
    var started = false
    var done = false
    var error: Error?
    init(output: AVAssetReaderTrackOutput) { self.output = output }

    func pull(_ count: Int, into dst: UnsafeMutablePointer<Float>) {
      while pending.count - start < count && !done {
        guard let sb = output.copyNextSampleBuffer() else {
          done = true
          break
        }
        if !started {
          started = true
          let lead = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * VoiceCleanup.sampleRate).rounded())
          if lead > 0 { pending += [Float](repeating: 0, count: lead) }
        }
        guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
        let bytes = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: bytes / 4)
        samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
        if start > 0 {
          pending.removeFirst(start)
          start = 0
        }
        pending += samples
      }
      let have = min(count, pending.count - start)
      pending.withUnsafeBufferPointer { dst.update(from: $0.baseAddress! + start, count: have) }
      if have < count { (dst + have).update(repeating: 0, count: count - have) }
      start += have
    }
  }

  /// Downward expander for the fallback: below the threshold, every dB quieter becomes 2 dB quieter,
  /// down to -12 dB. Opens in 5 ms, closes over 150 ms so word endings don't get clipped. The
  /// threshold sits a little under the speech threshold, so only the room between words drops.
  final class Expander {
    let threshold: Double
    var env = 0.0
    var gainDB = 0.0
    let detect = 1 - exp(-1 / (0.020 * VoiceCleanup.sampleRate))
    let attack = 1 - exp(-1 / (0.005 * VoiceCleanup.sampleRate))
    let release = 1 - exp(-1 / (0.150 * VoiceCleanup.sampleRate))
    init(threshold: Double) { self.threshold = threshold }

    func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
      for i in 0..<count {
        // Average power over ~20 ms (not a peak follower), so the level matches the RMS the threshold
        // was measured in. Opening and closing speed is in the gain smoothing below.
        env += detect * (Double(x[i] * x[i]) - env)
        let level = 10 * log10(max(env, 1e-12))
        let target = level < threshold ? max(-12, (level - threshold)) : 0
        gainDB += (target > gainDB ? attack : release) * (target - gainDB)
        x[i] *= Float(pow(10, gainDB / 20))
      }
    }
  }
}
