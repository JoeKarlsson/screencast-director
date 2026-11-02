import AVFoundation
import Foundation
import MediaToolbox

/// Voice gain for preview and export: an MTAudioProcessingTap that multiplies samples by a gain (fixed,
/// or a leveling curve over output time) and soft-limits peaks below -0.5 dBFS. (An audio mix's
/// volume can't boost past 1.0, and a quiet mic usually needs a boost.)
public enum AudioGain {
  /// Speech level the "Normalize voice" option aims for: RMS while talking.
  public static let targetDB = -20.0

  /// The gain (dB) that brings the median loudness of the loud (speaking) moments to the target.
  public static func normalizeGain(_ levels: [(Double, Double)]) -> Double {
    speechLevel(levels.map(\.1)).map { min(18, max(-12, targetDB - $0)) } ?? 0
  }

  /// The speaking level of a stretch: the upper half of its non-silent frames is the voice, and
  /// their median is a steady level. Nil when there's too little talking to tell.
  static func speechLevel(_ levels: [Double]) -> Double? {
    let talking = levels.filter { $0 > -50 }.sorted()
    guard talking.count > 20 else { return nil }
    return talking[talking.count * 3 / 4]
  }

  /// How much of each phrase's distance from the recording's speech level the leveler takes out.
  /// Less than 1, so a voice still rises and falls a little and doesn't sound pumped.
  static let levelingStrength = 0.7

  /// A leveling curve over source time (one gain in dB per loudness frame, the frames' own times):
  /// it rides the voice phrase by phrase toward the target, the way a voice-over engineer rides a
  /// fader. The phrase level is the energy of the talking frames within 0.4 s each side, held
  /// through pauses so room noise between words isn't pumped up; the gain corrects
  /// `levelingStrength` of that phrase's distance from the whole recording's level, stays within
  /// 9 dB of the recording's gain, and is smoothed over about half a second each way (computed
  /// ahead of time, so it starts moving just before a loud word, not after).
  public static func levelingCurve(_ levels: [(Double, Double)]) -> [(t: Double, gainDB: Double)] {
    guard levels.count > 2, let overallLevel = speechLevel(levels.map(\.1)) else { return levels.map { ($0.0, normalizeGain(levels)) } }
    let overall = min(18, max(-12, targetDB - overallLevel))
    let step = max(0.001, levels[1].0 - levels[0].0)
    let reach = max(1, Int((0.4 / step).rounded()))
    let n = levels.count
    // Running energy sums over the talking frames, for each frame's phrase level.
    var energy = [Double](repeating: 0, count: n + 1), talking = [Int](repeating: 0, count: n + 1)
    for (i, l) in levels.enumerated() {
      let speaking = l.1 > -42
      energy[i + 1] = energy[i] + (speaking ? pow(10, l.1 / 10) : 0)
      talking[i + 1] = talking[i] + (speaking ? 1 : 0)
    }
    var gains = [Double](repeating: overall, count: n)
    var held = overall
    for i in 0..<n {
      let a = max(0, i - reach), b = min(n, i + reach + 1)
      let count = talking[b] - talking[a]
      if count >= reach / 2 {
        let level = 10 * log10((energy[b] - energy[a]) / Double(count))
        let full = targetDB - level
        held = min(overall + 9, max(overall - 9, overall + levelingStrength * (full - overall)))
      }
      gains[i] = held
    }
    // Smooth twice with a centered moving average (about a triangle half a second each way).
    let half = max(1, Int((0.25 / step).rounded()))
    for _ in 0..<2 {
      var sums = [Double](repeating: 0, count: n + 1)
      for i in 0..<n { sums[i + 1] = sums[i] + gains[i] }
      gains = (0..<n).map { i in
        let a = max(0, i - half), b = min(n, i + half + 1)
        return (sums[b] - sums[a]) / Double(b - a)
      }
    }
    return zip(levels, gains).map { ($0.0, $1) }
  }

  final class Box {
    let gain: Float
    /// Linear gain per output frame (a leveling curve), or empty for the fixed gain.
    let curve: [Float]
    let fps: Double
    var isFloat = true
    var sampleRate = 48000.0
    init(_ gain: Float, curve: [Float], fps: Double) {
      self.gain = gain
      self.curve = curve
      self.fps = fps
    }
    /// The gain at output time `t` (seconds), interpolated between frames.
    func gain(at t: Double) -> Float {
      guard !curve.isEmpty else { return gain }
      let x = max(0, t * fps), i = min(curve.count - 1, Int(x))
      let j = min(curve.count - 1, i + 1)
      let u = Float(x - Double(i))
      return gain * (curve[i] + (curve[j] - curve[i]) * u)
    }
  }

  /// A tap applying `gainDB`, times `curveDB` (dB per output frame at `fps`) when given.
  public static func tap(gainDB: Double, curveDB: [Double] = [], fps: Int = 30) -> MTAudioProcessingTap? {
    let box = Unmanaged.passRetained(Box(Float(pow(10, gainDB / 20)), curve: curveDB.map { Float(pow(10, $0 / 20)) }, fps: Double(fps)))
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: box.toOpaque(),
      init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
      finalize: { tap in Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, _, format in
        let b = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        b.isFloat = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.pointee.mBitsPerChannel == 32
        b.sampleRate = format.pointee.mSampleRate
      },
      unprepare: nil,
      process: { tap, frames, _, bufferList, framesOut, flagsOut in
        var range = CMTimeRange.zero
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
        let b = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        guard b.isFloat, b.gain != 1 || !b.curve.isEmpty else { return }
        let start = range.start.isValid ? range.start.seconds : 0
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
          guard let data = buffer.mData else { continue }
          let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
          let channels = max(1, Int(buffer.mNumberChannels))
          let p = data.assumingMemoryBound(to: Float.self)
          // The gain changes slowly: look it up every 64 sample frames and interpolate between.
          var g = b.gain(at: start)
          var next = g
          for i in 0..<n {
            let frame = i / channels
            if i % (64 * channels) == 0 {
              g = next
              next = b.gain(at: start + Double(frame + 64) / b.sampleRate)
            }
            let u = Float(frame % 64) / 64
            let y = p[i] * (g + (next - g) * u)
            let a = abs(y)
            // Soft knee from 0.8 with a ceiling at 0.94 (about -0.5 dBFS), so boosted peaks round off.
            p[i] = a <= 0.8 ? y : (y < 0 ? -1 : 1) * (0.8 + 0.14 * tanh((a - 0.8) / 0.14))
          }
        }
      })
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    if status != noErr {
      box.release()
      return nil
    }
    return tap
  }
}
