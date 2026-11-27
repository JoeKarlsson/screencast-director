import Foundation

// Pop-ups and titles on screen too briefly to read: a callout, a sticker (a meme GIF or picture, or
// an animation shown as one, like the note) or an overlay animation. Each stays up long enough to
// read its words, and never under `PopUp.minSeconds`, however short its text. Describe WARNs about
// each one, so `director validate` fails on it.

public enum PopUp {
  /// The shortest a pop-up or title stays on screen, in output seconds: under that it's gone before
  /// it registers, even with one word or none (a GIF).
  public static let minSeconds = 3.0
  /// Reading time a word, plus `extraSeconds` to find the text and take it in.
  public static let secondsPerWord = 0.3
  public static let extraSeconds = 0.5

  /// How long a pop-up showing `text` needs on screen.
  public static func seconds(for text: String) -> Double {
    max(minSeconds, Double(words(text)) * secondsPerWord + extraSeconds)
  }

  static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

  /// How long a label showing `text` needs on screen: a word's reading time plus finding it, and
  /// never under `Polish.minReadSeconds`.
  public static func readSeconds(for text: String) -> Double {
    max(Polish.minReadSeconds, Double(words(text)) * secondsPerWord + extraSeconds)
  }

  /// Text inside an animation that leaves before it can be read (after Lemo-Opuscar's readcheck,
  /// MIT). `probes` are the text pieces on screen, sampled `step` seconds apart from the start of a
  /// clip `duration` seconds long; each piece's longest unbroken stretch must last `readSeconds`.
  /// A counter ticking ("45h", "46h") is one piece: digits don't change which piece it is.
  /// Returns each short piece with when it first appears, its longest stretch and what it needs.
  public static func animationTextTooShort(_ probes: [(t: Double, names: [String])], step: Double, duration: Double)
    -> [(name: String, at: Double, seconds: Double, needed: Double)]
  {
    var first: [String: Double] = [:], runStart: [String: Double] = [:], longest: [String: Double] = [:]
    var previous: Set<String> = [], shown: [String: String] = [:]
    for (t, names) in probes {
      let keyed = Dictionary(names.map { ($0.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression), $0) }) { a, _ in a }
      shown.merge(keyed) { a, _ in a }
      let now = Set(keyed.keys)
      for name in now where !previous.contains(name) {
        runStart[name] = t
        if first[name] == nil { first[name] = t }
      }
      for name in now { longest[name] = max(longest[name] ?? 0, min(duration, t + step) - runStart[name]!) }
      previous = now
    }
    return first.keys.sorted { (first[$0]!, $0) < (first[$1]!, $1) }.compactMap { name in
      let needed = readSeconds(for: name), seconds = longest[name]!
      // Probes `step` apart can undercount a stretch by up to one step: only flag a sure miss
      return seconds + step + 1e-9 < needed ? (shown[name]!, first[name]!, seconds, needed) : nil
    }
  }

  /// Animation data fields that hold the words it shows (a note's big word, the text beside it and
  /// the line under it; a title's heading and subtitle).
  static let animationTextKeys = ["title", "heading", "big", "text", "small", "subtitle", "label", "name"]

  /// What's too short, one line each: what it is, where, how long it's up and how long it needs.
  /// The time is output time from the item's start to its end, summed over the stretches it plays
  /// in, so a pop-up across a cut counts what's left of it on both sides.
  public static func tooShort(_ plan: Plan) -> [String] {
    let m = mapPlan(plan), fps = plan.output.fps
    func shown(_ start: Double, _ end: Double) -> (out: Double, seconds: Double)? {
      let pieces = srcRangeToOut(m, start, end, fps: fps)
      guard let first = pieces.first else { return nil }
      return (first.startF / Double(fps), pieces.reduce(0) { $0 + $1.endF - $1.startF } / Double(fps))
    }
    var out: [String] = []
    func check(_ what: String, _ start: Double, text: String, shown: (out: Double, seconds: Double)?) {
      guard let shown else { return }
      let needed = seconds(for: text)
      // Half a frame of slack: an item that ends on a cut lands on a rounded frame.
      guard shown.seconds < needed - 0.5 / Double(fps) else { return }
      let n = words(text)
      let why = n == 0 ? "" : String(format: " (its %d word%@ need %.1f s)", n, n == 1 ? "" : "s", needed)
      out.append(
        String(
          format: "%@ at out %@ (src %@) is on screen %.1f s, too short to read; pop-ups and titles stay up at least %.0f s%@: end it later or start it sooner",
          what, fmtTime(shown.out), fmtTime(start), shown.seconds, minSeconds, why))
    }
    // A title shows from its first word through the stretch it opens (`Scene.callouts`).
    for (i, c) in plan.callouts.enumerated() {
      let text = [c.text, c.subtitle ?? ""].joined(separator: " ")
      guard words(text) > 0 else { continue }
      let opened = srcToOut(m, c.start, fps: fps).flatMap { s in
        srcRangeToOut(m, c.start, c.end, fps: fps).first { abs($0.startF - s) < 0.5 }
          .map { (out: s / Double(fps), seconds: ($0.endF - $0.startF) / Double(fps)) }
      }
      check("callout #\(i) \"\(c.text)\"", c.start, text: text, shown: opened)
    }
    for (i, a) in plan.insertList.enumerated() where a.isSticker {
      let text = [a.topText ?? "", a.bottomText ?? ""].joined(separator: " ")
      check("sticker #\(i) \((a.file as NSString).lastPathComponent)", a.start, text: text, shown: shown(a.start, a.end))
    }
    for (i, a) in plan.animationList.enumerated() where a.sticker != nil || a.isOverlay {
      var text = ""
      if case .object(let data) = a.data {
        text = animationTextKeys.compactMap { k -> String? in
          if case .string(let s)? = data[k] { return s }
          return nil
        }.joined(separator: " ")
      }
      let label = words(text) == 0 ? "" : " \"\(text.prefix(40))\""
      check("animation #\(i) (\(a.template))\(label)", a.start, text: text, shown: shown(a.start, a.end))
    }
    return out
  }
}
