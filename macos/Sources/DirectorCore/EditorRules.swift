import Foundation

// Decisions the editor app makes, kept here so macos/test.sh can check them.

/// Where to scroll the timeline after zooming from `oldPxPerSec` to `newPxPerSec`, so axis time `t`
/// (the playhead) stays where it is on screen, or lands centered when it was scrolled out of view.
/// `scrollX` is the left edge before the zoom; the result stays inside the content.
public func timelineZoomScroll(
  around t: Double, from oldPxPerSec: Double, to newPxPerSec: Double, scrollX: Double, visibleWidth: Double, minContentWidth: Double,
  axisSeconds: Double
) -> Double {
  var onScreen = t * oldPxPerSec - scrollX
  if onScreen < 0 || onScreen > visibleWidth { onScreen = visibleWidth / 2 }
  let maxX = max(0, max(minContentWidth, axisSeconds * newPxPerSec) - visibleWidth)
  return min(maxX, max(0, t * newPxPerSec - onScreen))
}

/// A word's mark on the Words row when it's zoomed out too far to read words: where it starts and
/// how wide it is in points, and whether the word is kept (cut words show faintly on the source axis).
public struct SpeechMark: Equatable, Sendable {
  public var x: Double
  public var width: Double
  public var kept: Bool
}

/// Speech marks for the Words row; on the output axis, cut words have none.
public func speechMarks(_ words: [Word], mapped: [MappedSegment], fps: Int, pxPerSec: Double, outputTime: Bool) -> [SpeechMark] {
  words.compactMap { w in
    let out = srcToOut(mapped, w.start, fps: fps)
    if outputTime && out == nil { return nil }
    let x = outputTime ? Double(out ?? 0) / Double(fps) * pxPerSec : w.start * pxPerSec
    return SpeechMark(x: x, width: max(1, (w.end - w.start) * pxPerSec), kept: out != nil)
  }
}

/// Whether an editor shortcut gets a key while a text field has focus: only plain Space (key code 49,
/// no modifiers) in an empty field, so Space plays and pauses after an edit is sent from the Claude box.
public func shortcutTakesKeyInTextField(keyCode: UInt16, hasModifiers: Bool, fieldText: String) -> Bool {
  keyCode == 49 && !hasModifiers && fieldText.isEmpty
}

/// How a Claude Code edit that exited with an error ended, with the last lines it wrote to stderr
/// (why it stopped: signed out, rate limited, a crash).
public func claudeErrorOutcome(status: Int32, errors: String) -> String {
  "Claude Code stopped with an error (exit status \(status))"
    + (errors.isEmpty ? "." : ":\n\(errors.split(separator: "\n").suffix(8).joined(separator: "\n"))")
}

/// The reply an AI edit closes with: the outcome when the AI said nothing, its words plus the outcome
/// after a failure, otherwise its words. An ask never stays on "editing…" once it's over.
public func closingReply(_ reply: String, outcome: String) -> String {
  let failed = outcome.hasPrefix("Claude Code stopped with an error") || outcome.hasPrefix("Couldn't") || outcome.contains("couldn't make")
  if reply.isEmpty { return outcome }
  return failed ? reply + "\n\n" + outcome : reply
}
