import AVFoundation
import Foundation
import MediaToolbox

/// Voice gain for preview and export: an MTAudioProcessingTap that multiplies samples by a fixed
/// gain and soft-limits peaks below -0.5 dBFS. (An audio mix's volume can't boost past 1.0, and a
/// quiet mic usually needs a boost.)
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

  /// Per-clip gains (dB) that bring each clip's speech to the target, so takes recorded louder or
  /// quieter match. A clip with too little talking gets the whole recording's gain, and each clip
  /// stays within 6 dB of it, so a whisper or a shout isn't flattened.
  public static func clipGains(_ levels: [(Double, Double)], clips: [(start: Double, end: Double)]) -> [Double] {
    let overall = normalizeGain(levels)
    return clips.map { c in
      guard let level = speechLevel(levels.filter { $0.0 >= c.start && $0.0 < c.end }.map(\.1)) else { return overall }
      return min(overall + 6, max(overall - 6, targetDB - level))
    }
  }

  final class Box {
    let gain: Float
    var isFloat = true
    init(_ gain: Float) { self.gain = gain }
  }

  public static func tap(gainDB: Double) -> MTAudioProcessingTap? {
    let box = Unmanaged.passRetained(Box(Float(pow(10, gainDB / 20))))
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: box.toOpaque(),
      init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
      finalize: { tap in Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, _, format in
        let b = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        b.isFloat = format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.pointee.mBitsPerChannel == 32
      },
      unprepare: nil,
      process: { tap, frames, _, bufferList, framesOut, flagsOut in
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
        let b = Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        guard b.isFloat, b.gain != 1 else { return }
        let g = b.gain
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
          guard let data = buffer.mData else { continue }
          let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
          let p = data.assumingMemoryBound(to: Float.self)
          for i in 0..<n {
            let y = p[i] * g
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
