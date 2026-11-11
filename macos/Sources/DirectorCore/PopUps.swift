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
