import AVFoundation
import CryptoKit
import Foundation

/// A comic effect on the voice over a stretch of the recording (source seconds): chipmunk, echo,
/// radio, tape stop... It replaces the voice there; an echo or reverb rings on past `end` over
/// what follows.
public struct VoiceEffect: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  /// One of `VoiceEffect.presets`.
  public var preset: String
  public var note: String?
  public init(start: Double, end: Double, preset: String, note: String? = nil) {
    self.start = start
    self.end = end
    self.preset = preset
    self.note = note
  }

  public struct Preset: Sendable {
    public let name: String
    public let what: String
    /// Seconds it rings on past the stretch's end.
    public let tail: Double
  }

  public static let presets: [Preset] = [
    Preset(name: "chipmunk", what: "pitched way up, same length", tail: 0),
    Preset(name: "deep", what: "pitched down like a movie monster, same length", tail: 0),
    Preset(name: "echo", what: "the words repeat and fade (\"again... again...\"), ringing on 2 s past the end", tail: 2),
    Preset(name: "cathedral", what: "a huge stone hall, ringing on 3 s past the end", tail: 3),
    Preset(name: "radio", what: "a crackly walkie-talkie", tail: 0),
    Preset(name: "phone", what: "a phone call: thin, no lows or highs", tail: 0),
    Preset(name: "robot", what: "a metallic robot", tail: 0),
    Preset(name: "alien", what: "warbling alien chatter", tail: 0),
    Preset(name: "reverse", what: "played backwards", tail: 0),
    Preset(name: "tapeStop", what: "slows to a halt like a tape machine losing power (best on the last words before a cut)", tail: 0),
    Preset(
      name: "slowmo", what: "in a slowed segment (speed below 1), the voice slows at tape speed and drops in pitch instead of keeping it",
      tail: 0),
    Preset(name: "bleep", what: "a censor bleep instead of the words", tail: 0),
  ]

  public static func preset(_ name: String) -> Preset? { presets.first { $0.name == name } }
}

extension Plan {
  /// `voiceEffects` as a plain list (empty when there are none).
  public var voiceEffectList: [VoiceEffect] {
    get { voiceEffects ?? [] }
    set { voiceEffects = newValue.isEmpty ? nil : newValue }
  }
}

/// Renders voice effects. Each played piece of an effect (its stretch within one kept segment) is
/// rendered once from the voice's audio, through Apple's audio units (AVAudioUnitTimePitch, Delay,
/// Reverb, Distortion, EQ) or a few lines of DSP, and cached in .voice-effects/ as PCM (no AAC
/// priming, so sample 0 is the stretch's start). The composition mutes the voice over the piece
/// and plays the clip in its place.
public enum VoiceEffects {
  static let sampleRate = 48000.0
  static let folder = ".voice-effects"
  /// Changes the cache key when the rendering changes.
  static let renderVersion = 1
  /// Fade at each end of the effect, so the swap with the dry voice doesn't click.
  static let edgeFade = 0.006

  /// One playing of an effect: source `start`-`end` within one mapped segment.
  public struct Piece: Equatable, Sendable {
    public var effect: VoiceEffect
    public var start: Double
    public var end: Double
    /// Output seconds where it starts, and how long its stretch plays there (the source length
    /// over the segment's speed).
    public var outStart: Double
    public var outLength: Double
    public var speed: Double
  }

  /// Where each effect plays: one piece per kept segment it overlaps, in output order. Sped-up
  /// segments mute the voice, so effects there are dropped.
  public static func pieces(_ effects: [VoiceEffect], mapped: [MappedSegment], fps: Int) -> [Piece] {
    var out: [Piece] = []
    for e in effects where VoiceEffect.preset(e.preset) != nil {
      for s in mapped where s.speed <= 1.01 {
        let a = max(e.start, s.start), b = min(e.end, s.end)
        guard b - a > 0.02 else { continue }
        out.append(
          Piece(
            effect: e, start: a, end: b, outStart: (Double(s.outStart) + (a - s.start) * Double(fps) / s.speed) / Double(fps),
            outLength: (b - a) / s.speed, speed: s.speed))
      }
    }
    return out.sorted { $0.outStart < $1.outStart }
  }

  /// The parts of `a`...`b` not covered by `muted` (all in seconds), in order.
  public static func audibleSpans(_ a: Double, _ b: Double, muted: [(Double, Double)]) -> [(Double, Double)] {
    var spans: [(Double, Double)] = []
    var from = a
    for (m0, m1) in muted.sorted(by: { $0.0 < $1.0 }) where m1 > from && m0 < b {
      if m0 > from + 0.001 { spans.append((from, m0)) }
      from = max(from, m1)
    }
    if b > from + 0.001 { spans.append((from, b)) }
    return spans
  }

  /// The rendered clip for `piece` from the voice in `source`, rendering it if it isn't cached.
  public static func rendered(_ piece: Piece, source: URL, projectDir: URL) async throws -> URL {
    guard let preset = VoiceEffect.preset(piece.effect.preset) else {
      throw DirectorError("Voice effect \"\(piece.effect.preset)\" doesn't exist")
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
    let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let key = "\(renderVersion)|\(preset.name)|\(source.path)|\(stamp)|\(attrs[.size] ?? 0)|\(Int(piece.start * 1000))|\(Int(piece.end * 1000))"
    let name = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    let dir = projectDir.appendingPathComponent(folder)
    let out = dir.appendingPathComponent("\(preset.name)-\(name).caf")
    if FileManager.default.fileExists(atPath: out.path) { return out }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dry = try await readMono(source, from: piece.start, to: piece.end)
    let wet = try process(dry, preset: preset.name)
    // A unique temp name: the preview and an export can both ask for the clip at once.
    let tmp = dir.appendingPathComponent(".\(UUID().uuidString).partial.caf")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try write(wet, to: tmp)
    try? FileManager.default.removeItem(at: out)
    try FileManager.default.moveItem(at: tmp, to: out)
    return out
  }

  /// `source`'s audio from `start` to `end` seconds as mono 48 kHz samples, sample 0 at `start`.
  static func readMono(_ source: URL, from start: Double, to end: Double) async throws -> [Float] {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw DirectorError("\(source.lastPathComponent) has no audio for the voice effect")
    }
    let reader = try AVAssetReader(asset: asset)
    // Read a little wider: buffers come whole, and each is placed by its own timestamp.
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: max(0, start - 0.1), preferredTimescale: 48000), end: CMTime(seconds: end + 0.1, preferredTimescale: 48000))
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? DirectorError("Couldn't read the voice for the voice effect") }
    let count = Int(((end - start) * sampleRate).rounded())
    var samples = [Float](repeating: 0, count: count)
    while let sb = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
      let first = Int(((CMSampleBufferGetPresentationTimeStamp(sb).seconds - start) * sampleRate).rounded())
      let bytes = CMBlockBufferGetDataLength(block)
      var chunk = [Float](repeating: 0, count: bytes / 4)
      chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
      for (i, v) in chunk.enumerated() where first + i >= 0 && first + i < count { samples[first + i] = v }
    }
    if reader.status == .failed { throw reader.error ?? DirectorError("Couldn't read the voice for the voice effect") }
    return samples
  }

  static func write(_ samples: [Float], to url: URL) throws {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
  }

  /// The stretch `dry` through `preset`: as long as `dry` plus the preset's tail, at the dry
  /// voice's loudness, faded in and out at the edges.
  public static func process(_ dry: [Float], preset: String) throws -> [Float] {
    guard let p = VoiceEffect.preset(preset) else { throw DirectorError("Voice effect \"\(preset)\" doesn't exist") }
    var input = dry
    fadeEdges(&input)
    let tail = Int(p.tail * sampleRate)
    var wet: [Float]
    switch preset {
    case "chipmunk":
      wet = try runUnits(input, tail: 0) {
        let u = AVAudioUnitTimePitch()
        u.pitch = 900
        return [u]
      }
    case "deep":
      wet = try runUnits(input, tail: 0) {
        let u = AVAudioUnitTimePitch()
        u.pitch = -700
        return [u]
      }
    case "echo":
      wet = try runUnits(input, tail: tail) {
        let u = AVAudioUnitDelay()
        u.delayTime = 0.33
        u.feedback = 50
        u.lowPassCutoff = 4500
        u.wetDryMix = 45
        return [u]
      }
    case "cathedral":
      wet = try runUnits(input, tail: tail) {
        let u = AVAudioUnitReverb()
        u.loadFactoryPreset(.cathedral)
        u.wetDryMix = 50
        return [u]
      }
    case "radio":
      wet = try runUnits(input, tail: 0) {
        let d = AVAudioUnitDistortion()
        d.loadFactoryPreset(.speechRadioTower)
        d.wetDryMix = 70
        return [bandPass(low: 500, high: 3000, peak: 1800, peakDB: 6), d]
      }
    case "phone": wet = try runUnits(input, tail: 0) { [bandPass(low: 350, high: 3400, peak: 1500, peakDB: 4)] }
    case "alien":
      wet = try runUnits(input, tail: 0) {
        let d = AVAudioUnitDistortion()
        d.loadFactoryPreset(.speechAlienChatter)
        d.wetDryMix = 100
        return [d]
      }
    case "robot": wet = robot(input)
    case "reverse": wet = input.reversed()
    case "tapeStop": wet = tapeStop(input)
    case "bleep": wet = bleep(count: input.count)
    default: wet = input  // slowmo: the composition's varispeed does it
    }
    if wet.count < dry.count + tail { wet += [Float](repeating: 0, count: dry.count + tail - wet.count) }
    wet = Array(wet.prefix(dry.count + tail))
    matchLoudness(&wet, to: dry, over: dry.count)
    fadeEdges(&wet, tail: tail)
    return wet
  }

  /// Short fades at both ends, or, with a tail, a fade-in plus the tail's last 40% fading to nothing.
  static func fadeEdges(_ x: inout [Float], tail: Int = 0) {
    let n = x.count, f = min(Int(edgeFade * sampleRate), n / 2)
    for i in 0..<f {
      let g = Float(i) / Float(f)
      x[i] *= g
      if tail == 0 { x[n - 1 - i] *= g }
    }
    if tail > 0 {
      let fadeLen = min(n, max(1, tail * 2 / 5))
      for i in 0..<fadeLen { x[n - fadeLen + i] *= 1 - Float(i) / Float(fadeLen) }
    }
  }

  /// Scales `x` so its first `count` samples have the dry stretch's RMS (within ±12 dB), so an
  /// effect doesn't jump out louder or quieter than the voice around it.
  static func matchLoudness(_ x: inout [Float], to dry: [Float], over count: Int) {
    func rms(_ v: ArraySlice<Float>) -> Double { v.isEmpty ? 0 : sqrt(v.reduce(0) { $0 + Double($1 * $1) } / Double(v.count)) }
    let want = rms(dry[...]), have = rms(x.prefix(count))
    guard want > 1e-5, have > 1e-5 else { return }
    let g = Float(min(4, max(0.25, want / have)))
    for i in x.indices { x[i] *= g }
  }

  static func bandPass(low: Float, high: Float, peak: Float, peakDB: Float) -> AVAudioUnitEQ {
    let eq = AVAudioUnitEQ(numberOfBands: 3)
    let bands: [(AVAudioUnitEQFilterType, Float, Float)] = [(.highPass, low, 0), (.lowPass, high, 0), (.parametric, peak, peakDB)]
    for (b, (type, freq, gain)) in zip(eq.bands, bands) {
      b.filterType = type
      b.frequency = freq
      b.gain = gain
      b.bandwidth = 1
      b.bypass = false
    }
    return eq
  }

  /// Runs `input` through the audio units `make` builds, in an offline engine, with `tail`
  /// samples of silence after it. The units' reported latency is dropped from the front. Stereo
  /// (the reverb refuses mono), mixed back down to mono.
  static func runUnits(_ input: [Float], tail: Int, _ make: () -> [AVAudioNode]) throws -> [Float] {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let engine = AVAudioEngine()
    let chunk: AVAudioFrameCount = 1024
    try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: chunk)
    let feed = ArrayFeed(input)
    let source = AVAudioSourceNode(format: fmt) { _, _, frames, abl -> OSStatus in
      let buffers = UnsafeMutableAudioBufferListPointer(abl)
      guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
      feed.pull(Int(frames), into: left)
      for b in buffers.dropFirst() { b.mData?.assumingMemoryBound(to: Float.self).update(from: left, count: Int(frames)) }
      return noErr
    }
    engine.attach(source)
    var last: AVAudioNode = source
    let units = make()
    for u in units {
      engine.attach(u)
      engine.connect(last, to: u, format: fmt)
      last = u
    }
    engine.connect(last, to: engine.mainMixerNode, format: fmt)
    try engine.start()
    defer { engine.stop() }
    var skip = Int((units.reduce(0) { $0 + $1.auAudioUnit.latency } * sampleRate).rounded())
    let total = input.count + tail
    var out: [Float] = []
    out.reserveCapacity(total)
    let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk)!
    while out.count < total {
      let status = try engine.renderOffline(chunk, to: rendered)
      guard status == .success else { throw DirectorError("Voice effect render stopped (\(status.rawValue))") }
      let n = Int(rendered.frameLength)
      let drop = min(skip, n)
      skip -= drop
      let l = rendered.floatChannelData![0], r = rendered.floatChannelData![1]
      for i in drop..<n where out.count < total { out.append((l[i] + r[i]) / 2) }
    }
    return out
  }

  /// Hands an array to the render callback, then silence.
  private final class ArrayFeed: @unchecked Sendable {
    let samples: [Float]
    var at = 0
    init(_ samples: [Float]) { self.samples = samples }
    func pull(_ count: Int, into dst: UnsafeMutablePointer<Float>) {
      let have = max(0, min(count, samples.count - at))
      if have > 0 { samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress! + at, count: have) } }
      if have < count { (dst + have).update(repeating: 0, count: count - have) }
      at += count
    }
  }

  /// A metallic robot: a short comb filter (a 7 ms delay fed back) for the tin-can ring, then ring
  /// modulation at 50 Hz, the classic sci-fi robot.
  static func robot(_ x: [Float]) -> [Float] {
    let d = Int(0.007 * sampleRate)
    var y = x
    if y.count > d { for i in d..<y.count { y[i] = x[i] + 0.6 * y[i - d] } }
    for i in y.indices { y[i] *= Float(sin(2 * .pi * 50 * Double(i) / sampleRate)) }
    return y
  }

  /// A tape machine losing power: playback slows from full speed to a stop across the stretch,
  /// ever lower, so it gets through only the first part of the words.
  static func tapeStop(_ x: [Float]) -> [Float] {
    let n = x.count
    var y = [Float](repeating: 0, count: n)
    var pos = 0.0
    for i in 0..<n {
      let rate = 1 - Double(i) / Double(n)
      let j = Int(pos), u = Float(pos - Double(j))
      if j + 1 < n { y[i] = x[j] + (x[j + 1] - x[j]) * u }
      pos += rate * rate
    }
    return y
  }

  /// A 1 kHz censor tone (its level is set by matchLoudness).
  static func bleep(count: Int) -> [Float] {
    (0..<count).map { Float(sin(2 * .pi * 1000 * Double($0) / sampleRate)) * 0.3 }
  }
}
