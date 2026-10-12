import Foundation

/// A recording folder: screen.mp4, source.json, events.jsonl, transcript.json, motion.json, plan.json.
/// Same files as the Node CLI (scripts/project.ts), so either tool can work on either's projects.
public struct Project {
  public struct Source: Codable {
    public var video: String
    public var width: Double
    public var height: Double
    public var duration: Double
    /// Host-clock time of the first video frame; absent for imported videos.
    public var captureStart: Double?
    public var camera: Plan.Camera?

    public init(video: String, width: Double, height: Double, duration: Double, captureStart: Double?, camera: Plan.Camera?) {
      self.video = video
      self.width = width
      self.height = height
      self.duration = duration
      self.captureStart = captureStart
      self.camera = camera
    }
  }

  public let dir: URL
  public var source: Source
  public var words: [Word]
  public var events: [InputEvent]
  /// (time, mean frame-to-frame luma difference) samples at 10 fps.
  public var motion: [(Double, Double)]
  /// Spoken lines of the teleprompter script (script.md, copied from Followspot when you record
  /// with it open). Empty when there's no script.
  public var script: [String] = []

  public var planURL: URL { dir.appendingPathComponent("plan.json") }
  /// Retake marks (⌃⌥⌘M while recording), in seconds into the video.
  public var retakes: [Double] { events.filter { $0.type == .retake }.map(\.t) }
  public var name: String { dir.lastPathComponent }

  public init(dir: URL, source: Source, words: [Word] = [], events: [InputEvent] = [], motion: [(Double, Double)] = []) {
    self.dir = dir
    self.source = source
    self.words = words
    self.events = events
    self.motion = motion
  }

  public static func load(_ dir: URL) throws -> Project {
    let source = try JSONDecoder().decode(Source.self, from: Data(contentsOf: dir.appendingPathComponent("source.json")))
    var p = Project(dir: dir, source: source)
    p.words = loadWords(dir.appendingPathComponent("transcript.json"))
    p.events = loadEvents(dir.appendingPathComponent("events.jsonl"), source: source)
    if let data = try? Data(contentsOf: dir.appendingPathComponent("motion.json")),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
    {
      p.motion = arr.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }
    if let md = try? String(contentsOf: dir.appendingPathComponent("script.md"), encoding: .utf8) {
      p.script = scriptLines(md)
    }
    return p
  }

  /// Reads mlx-whisper style JSON: {"segments": [{"words": [{"word", "start", "end"}]}]}.
  static func loadWords(_ url: URL) -> [Word] {
    guard let data = try? Data(contentsOf: url),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let segs = obj["segments"] as? [[String: Any]]
    else { return [] }
    return segs.flatMap { seg -> [Word] in
      (seg["words"] as? [[String: Any]] ?? []).compactMap { w in
        guard let text = (w["word"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
          let start = (w["start"] as? NSNumber)?.doubleValue, let end = (w["end"] as? NSNumber)?.doubleValue
        else { return nil }
        return Word(text: text, start: start, end: end)
      }
    }
  }

  static func loadEvents(_ url: URL, source: Source) -> [InputEvent] {
    guard let start = source.captureStart, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
      guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let typeName = obj["type"] as? String, let type = InputKind(rawValue: typeName),
        let t = (obj["t"] as? NSNumber)?.doubleValue
      else { return nil }
      let rel = t - start
      guard rel >= 0, rel <= source.duration else { return nil }
      return InputEvent(
        t: rel, type: type, x: (obj["x"] as? NSNumber)?.doubleValue ?? 0, y: (obj["y"] as? NSNumber)?.doubleValue ?? 0,
        label: obj["label"] as? String)
    }
  }

  public var clicks: [InputEvent] { events.filter { $0.type == .click } }
  public var shortcuts: [InputEvent] {
    events.filter { e in e.type == .key && (e.label.map { $0.contains("⌘") || $0.contains("⌃") || $0.contains("⌥") } ?? false) }
  }
}

public func fmtTime(_ t: Double) -> String {
  let m = Int(t / 60)
  let s = t - Double(m) * 60
  let str = String(format: "%.1f", s)
  return "\(m):\(s < 10 ? "0" : "")\(str)"
}
