import AVFoundation
import Foundation
import Vision

/// Text on the recorded screen around each click, read with Vision, so the AI knows what was
/// clicked ("Save", "Settings") and not just where. Kept in screentext.json.
public enum ScreenText {
  public struct Item: Codable, Equatable {
    public var text: String
    /// Box in 0...1 fractions of the screen, top-left origin.
    public var x, y, w, h: Double
  }

  public struct Sample: Codable, Equatable {
    /// Source seconds.
    public var t: Double
    /// Where the click was.
    public var x, y: Double
    public var items: [Item]
  }

  public static func url(_ dir: URL) -> URL { dir.appendingPathComponent("screentext.json") }

  public static func load(_ dir: URL) -> [Sample] {
    (try? JSONDecoder().decode([Sample].self, from: Data(contentsOf: url(dir)))) ?? []
  }

  /// Reads the text around each click (clicks closer than 0.4 s share a frame), at most `limit`.
  public static func recognize(_ project: Project, limit: Int = 300, progress: ((Double) -> Void)? = nil) async throws -> [Sample] {
    var clicks: [InputEvent] = []
    for c in project.clicks where (0...1).contains(c.x) && (0...1).contains(c.y) {
      if let last = clicks.last, c.t - last.t < 0.4 { continue }
      clicks.append(c)
    }
    clicks = Array(clicks.prefix(limit))
    guard !clicks.isEmpty else { return [] }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: project.dir.appendingPathComponent(project.source.video)))
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
    gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
    var out: [Sample] = []
    for (i, c) in clicks.enumerated() {
      progress?(Double(i) / Double(clicks.count))
      // Just before the click: what was under the pointer, before the app reacted.
      guard let frame = try? await gen.image(at: CMTime(seconds: max(0, c.t - 0.05), preferredTimescale: 600)).image else { continue }
      out.append(Sample(t: c.t, x: c.x, y: c.y, items: read(frame, around: (c.x, c.y))))
    }
    return out
  }

  /// Text in a window around a point (a crop reads small UI text better and faster than the frame).
  static func read(_ image: CGImage, around p: (Double, Double)) -> [Item] {
    let W = Double(image.width), H = Double(image.height)
    let cw = 0.26, ch = 0.14
    let cx = min(max(p.0 - cw / 2, 0), 1 - cw), cy = min(max(p.1 - ch / 2, 0), 1 - ch)
    guard let crop = image.cropping(to: CGRect(x: cx * W, y: cy * H, width: cw * W, height: ch * H)) else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: crop).perform([request])
    return (request.results ?? []).compactMap { obs in
      guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
      // Vision boxes are bottom-left origin within the crop.
      let b = obs.boundingBox
      return Item(text: text, x: cx + b.minX * cw, y: cy + (1 - b.maxY) * ch, w: b.width * cw, h: b.height * ch)
    }
  }

  /// The text at a point: the box containing it, else the nearest within a short reach. Long lines
  /// are cut to their start; a label is a hint, not a quote.
  public static func label(at x: Double, _ y: Double, in items: [Item]) -> String? {
    guard let text = rawLabel(at: x, y, in: items) else { return nil }
    return text.count > 40 ? String(text.prefix(40)) + "…" : text
  }

  static func rawLabel(at x: Double, _ y: Double, in items: [Item]) -> String? {
    if let hit = items.first(where: { x >= $0.x - 0.004 && x <= $0.x + $0.w + 0.004 && y >= $0.y - 0.006 && y <= $0.y + $0.h + 0.006 }) {
      return hit.text
    }
    func distance(_ i: Item) -> Double {
      let dx = max(i.x - x, 0, x - (i.x + i.w)), dy = max(i.y - y, 0, y - (i.y + i.h))
      return hypot(dx, dy * 0.6)
    }
    return items.filter { distance($0) < 0.03 }.min { distance($0) < distance($1) }?.text
  }

  /// What was clicked at time t, from the saved samples.
  public static func clicked(_ samples: [Sample], at t: Double) -> String? {
    guard let s = samples.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(s.t - t) < 0.45 else { return nil }
    return label(at: s.x, s.y, in: s.items)
  }

  /// Text near a screen point during a time range (for what a zoom is aimed at).
  public static func near(_ samples: [Sample], x: Double, y: Double, from a: Double, to b: Double) -> String? {
    samples.filter { $0.t >= a - 1 && $0.t <= b }.lazy.compactMap { label(at: x, y, in: $0.items) }.first
  }
}
