import AVFoundation
import Foundation
import MediaToolbox

/// `music.carve`: dips the music in the few bands the voice occupies, only while the voice talks, so it
/// sits in front without the whole track dropping (ported from HyperFrames' voiceover carve, Apache 2.0,
/// at its default strength). The bands come from the voice's average spectrum over its speech, ranked by
/// power with a bias toward 2 kHz, where a bed masks speech most.
public enum MusicCarve: Sendable {
  public struct Band: Codable, Equatable, Sendable {
    public var hz: Double
    public var gainDB: Double
    public var q: Double
  }

  /// Third-octave centres spanning the range speech occupies.
  static let centers: [Double] = [160, 250, 400, 630, 1000, 1600, 2500, 4000, 6000]
  // HyperFrames' profile at strength 0.25: 6 dB deepest cut, 3 bands, Q 1.4, bias 0.7.
  static let maxCutDB = 6.0, bandCount = 3, q = 1.4, bias = 0.7
  /// How far the bias may move a band in the ranking, in dB (speech falls 20-30 dB across these bands).
  static let biasAuthorityDB = 30.0
  /// The cut follows the talking: in over 0.05 s, out over 0.25 s.
  static let attack = 0.05, release = 0.25
  /// While carving, the whole track drops this much under the voice instead of `MusicDuck.defaultDuckDB`.
  public static let duckDB = -10.0

  /// The bands to dip, ascending, from `power` (the voice's spectrum, `freqs` Hz per bin).
  static func bands(freqs: [Double], power: [Double]) -> [Band] {
    let scored: [(hz: Double, db: Double)] = centers.compactMap { c in
      let lo = c / pow(2, 1.0 / 6), hi = c * pow(2, 1.0 / 6)
      let inBand = zip(freqs, power).filter { $0.0 >= lo && $0.0 < hi }.map(\.1)
      let p = inBand.reduce(0, +) / Double(max(1, inBand.count))
      guard p > 0 else { return nil }
      let octaves = log2(c / 2000)
      return (c, 10 * log10(p) - bias * biasAuthorityDB * (1 - exp(-octaves * octaves / 2)))
    }.sorted { $0.db > $1.db }
    let picked = scored.prefix(bandCount)
    guard let top = picked.first?.db else { return [] }
    return picked.map { b in
      // A band 3 dB under the strongest gets half its cut, never less than half the deepest.
      let depth = min(maxCutDB, max(maxCutDB / 2, maxCutDB * pow(10, (b.db - top) / 10)))
      return Band(hz: b.hz, gainDB: -depth, q: q)
    }.sorted { $0.hz < $1.hz }
  }

  /// The voice's bands, from the samples (16 kHz mono) of the 50 ms `levels` frames above the silence
  /// threshold. Empty with no speech.
  static func bands(voice: [Float], levels: [(Double, Double)]) throws -> [Band] {
    let threshold = Analyzer.silenceThreshold(levels)
    let rate = AudioSpectrum.rate
    // The talking samples, joined end to end.
    var speech: [Float] = []
    for (t, db) in levels where db > threshold {
      let a = Int(t * rate), b = min(voice.count, a + Int(0.05 * rate))
      if a < b { speech += voice[a..<b] }
    }
    let spectrum = try AudioSpectrum(size: 4096)
    guard speech.count >= spectrum.size else { return [] }
    var acc = [Double](repeating: 0, count: spectrum.size / 2 + 1)
    var frames = 0
    for start in stride(from: 0, through: speech.count - spectrum.size, by: spectrum.size / 2) {
      for (k, p) in spectrum.power(speech, start: start).enumerated() { acc[k] += Double(p) }
      frames += 1
    }
    let freqs = (0..<acc.count).map { Double($0) * rate / Double(spectrum.size) }
    return bands(freqs: freqs, power: acc.map { $0 / Double(frames) })
  }

  /// The project's voice bands, measured once and cached in `.render/carve-bands.json`.
  public static func bands(_ project: Project, video: String, levels: [(Double, Double)]) async throws -> [Band] {
    let render = try PathSafety.ownedFolder(".render", in: project.dir)
    let cache = render.appendingPathComponent("carve-bands.json")
    if let data = try? Data(contentsOf: cache), let cached = try? JSONDecoder().decode([Band].self, from: data) { return cached }
    let voice = try await AudioSpectrum.samples16k(project.dir.appendingPathComponent(video), scratch: render)
    let found = try bands(voice: voice, levels: levels)
    try JSONEncoder().encode(found).write(to: cache)
    return found
  }

  /// How deep the cut is at each output frame (0 none, 1 full), following `speech` (output seconds,
  /// `MusicDuck.speech`).
  static func depth(speech: [(Double, Double)], frames: Int, fps: Int) -> [Float] {
    var out = [Float](repeating: 0, count: max(0, frames))
    let rate = Double(fps)
    // Each span only touches its own frames, from the attack before it to the release after.
    for (a, b) in speech {
      let first = max(0, Int(((a - attack) * rate).rounded(.up))), last = min(frames - 1, Int(((b + release) * rate).rounded(.down)))
      guard first <= last else { continue }
      for f in first...last {
        let t = Double(f) / rate
        out[f] = max(out[f], Float(t < a ? 1 - (a - t) / attack : t <= b ? 1 : 1 - (t - b) / release))
      }
    }
    return out
  }

  final class Box {
    let bands: [Band]
    let depth: [Float]
    let fps: Double
    var filters: [WarmVoice.Biquad] = []
    var applied: Float = -1
    var isFloat = true
    var sampleRate = 48000.0
    var channels = 1
    init(bands: [Band], depth: [Float], fps: Double) {
      self.bands = bands
      self.depth = depth
      self.fps = fps
    }
    func depth(at t: Double) -> Float { depth.isEmpty ? 0 : depth[min(depth.count - 1, max(0, Int(t * fps)))] }
    /// Sets the filters to `share` of their cut, keeping their state so nothing clicks.
    func set(_ share: Float) {
      guard abs(share - applied) > 0.01 else { return }
      applied = share
      filters = bands.enumerated().map { i, b in
        var f = WarmVoice.Biquad.peak(b.hz, gainDB: b.gainDB * Double(share), q: b.q, rate: sampleRate, channels: channels)
        if i < filters.count { (f.z1, f.z2) = (filters[i].z1, filters[i].z2) }
        return f
      }
    }
  }

  /// The music's tap: `bands` cut by `depth` (per output frame at `fps`). Nil with no bands.
  public static func tap(bands: [Band], speech: [(Double, Double)], frames: Int, fps: Int) throws -> MTAudioProcessingTap? {
    guard !bands.isEmpty else { return nil }
    let box = Unmanaged.passRetained(Box(bands: bands, depth: depth(speech: speech, frames: frames, fps: fps), fps: Double(fps)))
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: box.toOpaque(),
      init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
      finalize: { tap in Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, _, format in
        let b = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        b.isFloat = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.pointee.mBitsPerChannel == 32
        b.sampleRate = format.pointee.mSampleRate
        b.channels = max(1, Int(format.pointee.mChannelsPerFrame))
        b.applied = -1
        b.filters = []
        b.set(0)
      },
      unprepare: nil,
      process: { tap, frames, _, bufferList, framesOut, flagsOut in
        var range = CMTimeRange.zero
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
        let b = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        guard b.isFloat else { return }
        let start = range.start.isValid ? range.start.seconds : 0
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        // Filters are per channel; buffers may be interleaved or one per channel. Process in 64-frame
        // blocks so the cut's depth can follow the talking.
        let perBuffer = buffers.map { max(1, Int($0.mNumberChannels)) }
        let frameCount = Int(buffers.first.map { $0.mDataByteSize } ?? 0) / MemoryLayout<Float>.size / (perBuffer.first ?? 1)
        var frame = 0
        while frame < frameCount {
          b.set(b.depth(at: start + Double(frame) / b.sampleRate))
          let end = min(frameCount, frame + 64)
          // Run even at no cut (the filters are then flat), so their state stays current.
          for (bi, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let p = data.assumingMemoryBound(to: Float.self), ch = perBuffer[bi]
            for f in frame..<end {
              for c in 0..<ch {
                var y = Double(p[f * ch + c])
                let channel = buffers.count > 1 ? bi : c
                for i in b.filters.indices { y = b.filters[i].run(y, channel) }
                p[f * ch + c] = Float(y)
              }
            }
          }
          frame = end
        }
      })
    var tap: MTAudioProcessingTap?
    guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
      box.release()
      throw DirectorError("Couldn't set up the music carve")
    }
    return tap
  }
}
