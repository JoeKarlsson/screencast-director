import Foundation

/// "Warm voice": the chain a voice-over engineer puts on a desk-mic recording, in the order they
/// would: EQ (more chest at 110 Hz, less boxiness at 350 Hz), a gentle fast compressor for a dense,
/// close sound, a touch of asymmetric saturation for warmth, and a soft high shelf that takes back
/// the brightness the compressor and saturation add. It runs per
/// sample after the voice gain and leveler (so the compressor sees a steady level), before the
/// limiter. One instance per audio stream: filters and the compressor keep state per channel.
public final class WarmVoice {
  /// A biquad in transposed direct form II (RBJ audio EQ cookbook coefficients).
  struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1: [Double], z2: [Double]

    init(channels: Int) {
      z1 = Array(repeating: 0, count: channels)
      z2 = Array(repeating: 0, count: channels)
    }

    static func lowShelf(_ f: Double, gainDB: Double, slope: Double, rate: Double, channels: Int) -> Biquad {
      let a = pow(10, gainDB / 40), w = 2 * Double.pi * f / rate, c = cos(w)
      let alpha = sin(w) / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2), s = 2 * sqrt(a) * alpha
      let a0 = (a + 1) + (a - 1) * c + s
      var q = Biquad(channels: channels)
      q.b0 = a * ((a + 1) - (a - 1) * c + s) / a0
      q.b1 = 2 * a * ((a - 1) - (a + 1) * c) / a0
      q.b2 = a * ((a + 1) - (a - 1) * c - s) / a0
      q.a1 = -2 * ((a - 1) + (a + 1) * c) / a0
      q.a2 = ((a + 1) + (a - 1) * c - s) / a0
      return q
    }

    static func highShelf(_ f: Double, gainDB: Double, slope: Double, rate: Double, channels: Int) -> Biquad {
      let a = pow(10, gainDB / 40), w = 2 * Double.pi * f / rate, c = cos(w)
      let alpha = sin(w) / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2), s = 2 * sqrt(a) * alpha
      let a0 = (a + 1) - (a - 1) * c + s
      var q = Biquad(channels: channels)
      q.b0 = a * ((a + 1) + (a - 1) * c + s) / a0
      q.b1 = -2 * a * ((a - 1) + (a + 1) * c) / a0
      q.b2 = a * ((a + 1) + (a - 1) * c - s) / a0
      q.a1 = 2 * ((a - 1) - (a + 1) * c) / a0
      q.a2 = ((a + 1) - (a - 1) * c - s) / a0
      return q
    }

    static func peak(_ f: Double, gainDB: Double, q: Double, rate: Double, channels: Int) -> Biquad {
      let a = pow(10, gainDB / 40), w = 2 * Double.pi * f / rate, c = cos(w), alpha = sin(w) / (2 * q)
      let a0 = 1 + alpha / a
      var b = Biquad(channels: channels)
      b.b0 = (1 + alpha * a) / a0
      b.b1 = -2 * c / a0
      b.b2 = (1 - alpha * a) / a0
      b.a1 = -2 * c / a0
      b.a2 = (1 - alpha / a) / a0
      return b
    }

    mutating func run(_ x: Double, _ ch: Int) -> Double {
      let y = b0 * x + z1[ch]
      z1[ch] = b1 * x - a1 * y + z2[ch]
      z2[ch] = b2 * x - a2 * y
      return y
    }
  }

  // EQ
  static let chestHz = 110.0, chestDB = 3.0
  static let boxHz = 350.0, boxDB = -2.5
  static let airHz = 5000.0, airDB = -2.0
  // Compressor: 3:1 above -16 dBFS, 3 ms attack, 120 ms release. On a leveled voice that's about
  // 3-4 dB of reduction on average (more on loud syllables), and the makeup gives it back, so the
  // voice gets denser without getting quieter.
  static let thresholdDB = -16.0, ratio = 3.0, attack = 0.003, release = 0.12, makeupDB = 3.5
  // Saturation: a quarter of the signal through a slightly biased tanh (even harmonics read as warm).
  static let drive = 2.0, bias = 0.1, mix = 0.25

  var chest: Biquad, box: Biquad, air: Biquad
  var envelope: [Double]
  let attackCoeff: Double, releaseCoeff: Double, makeup: Double
  let satOffset: Double, satScale: Double

  public init(sampleRate: Double, channels: Int) {
    let n = max(1, channels)
    chest = .lowShelf(Self.chestHz, gainDB: Self.chestDB, slope: 0.8, rate: sampleRate, channels: n)
    box = .peak(Self.boxHz, gainDB: Self.boxDB, q: 1.0, rate: sampleRate, channels: n)
    air = .highShelf(Self.airHz, gainDB: Self.airDB, slope: 0.7, rate: sampleRate, channels: n)
    envelope = Array(repeating: 0, count: n)
    attackCoeff = exp(-1 / (Self.attack * sampleRate))
    releaseCoeff = exp(-1 / (Self.release * sampleRate))
    makeup = pow(10, Self.makeupDB / 20)
    satOffset = tanh(Self.drive * Self.bias)
    // tanh's slope at the bias point, so quiet sound passes through the saturation at unity.
    let sech = 1 / cosh(Self.drive * Self.bias)
    satScale = 1 / (Self.drive * sech * sech)
  }

  /// One sample of channel `ch`.
  public func process(_ x: Float, channel ch: Int) -> Float {
    var y = box.run(chest.run(Double(x), ch), ch)
    // Peak envelope, then gain reduction above the threshold.
    let level = abs(y)
    let coeff = level > envelope[ch] ? attackCoeff : releaseCoeff
    envelope[ch] = coeff * envelope[ch] + (1 - coeff) * level
    let envDB = 20 * log10(max(envelope[ch], 1e-9))
    let reduction = max(0, envDB - Self.thresholdDB) * (1 - 1 / Self.ratio)
    y *= pow(10, -reduction / 20) * makeup
    let sat = (tanh(Self.drive * (y + Self.bias)) - satOffset) * satScale
    return Float(air.run((1 - Self.mix) * y + Self.mix * sat, ch))
  }
}
