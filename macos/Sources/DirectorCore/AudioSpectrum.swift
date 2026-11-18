import Accelerate
import Foundation

/// Power spectra of Hann-windowed frames, for the music carve and the beat tracker (both ported from
/// HyperFrames, Apache 2.0). One instance per frame size; not thread-safe.
public final class AudioSpectrum {
  let size: Int
  let window: [Float]
  private let dft: vDSP.DiscreteFourierTransform<Float>
  private var re: [Float], outRe: [Float], outIm: [Float]
  private let zeros: [Float]

  init(size: Int) throws {
    self.size = size
    window = (0..<size).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(size)) }
    dft = try vDSP.DiscreteFourierTransform(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    re = Array(repeating: 0, count: size)
    outRe = re
    outIm = re
    zeros = re
  }

  /// Power of bins 0...size/2 of the frame of `samples` starting at `start` (zero past either end).
  func power(_ samples: [Float], start: Int) -> [Float] {
    for i in 0..<size {
      let at = start + i
      re[i] = at >= 0 && at < samples.count ? samples[at] * window[i] : 0
    }
    dft.transform(inputReal: re, inputImaginary: zeros, outputReal: &outRe, outputImaginary: &outIm)
    return (0...size / 2).map { outRe[$0] * outRe[$0] + outIm[$0] * outIm[$0] }
  }

  /// The audio track of `url` as 16 kHz mono samples (empty when it has no audio), via a scratch WAV
  /// in `scratch`.
  public static func samples16k(_ url: URL, scratch: URL) async throws -> [Float] {
    let wav = scratch.appendingPathComponent("spectrum-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    guard try await Analyzer.extractAudio(url, to: wav) else { return [] }
    // 16-bit PCM after a 44-byte header.
    return try Data(contentsOf: wav).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Float($0) / 32768 }
  }

  public static let rate = 16000.0
}
