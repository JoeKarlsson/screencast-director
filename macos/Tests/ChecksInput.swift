import CoreGraphics
import Foundation

// The input log's event records (DirectorCore/InputEvents.swift, written by the app's InputTap),
// checked with synthetic events, and read back through Project.loadEvents.
func inputEventChecks() {
  let screen = CGRect(x: 0, y: 0, width: 2000, height: 1000)
  func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], repeating: Bool = false) -> CGEvent {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    // The character a US layout types, set on the event so the checks don't depend on the Mac's
    // current input source (a Greek layout turns P into Π).
    if let ch = [35: "p", 8: "c"][Int(code)] {
      let units = Array(ch.utf16)
      e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    }
    e.flags = flags
    if repeating { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
    return e
  }
  func label(_ e: CGEvent) -> String? { InputEvents.record(.keyDown, e, t: 1, bounds: screen)?["label"] as? String }

  // Privacy: plain typing, Space and ⌥ characters are logged as a key with no character.
  let typed = InputEvents.record(.keyDown, key(35), t: 1, bounds: screen)  // P
  expect(typed?["type"] as? String == "key" && typed?["label"] == nil, "a typed letter has no label")
  expect(label(key(49)) == nil, "Space has no label")
  expect(label(key(35, .maskAlternate)) == nil, "⌥ alone types a character, so no label")
  expect(label(key(35, .maskShift)) == nil, "⇧ alone types a capital, so no label")
  // Named keys and shortcuts are labeled, modifiers in ⌃⌥⇧⌘ order.
  expect(label(key(36)) == "↩" && label(key(51)) == "⌫", "named keys are labeled")
  expect(label(key(35, [.maskCommand, .maskShift])) == "⇧⌘P", "⌘⇧P is labeled with its letter (\(label(key(35, [.maskCommand, .maskShift])) ?? "nil"))")
  expect(label(key(8, [.maskControl, .maskAlternate])) == "⌃⌥C", "⌃⌥C keeps its modifiers in order")
  expect(label(key(49, .maskCommand)) == "⌘Space", "⌘Space")
  expect(InputEvents.record(.keyDown, key(35, repeating: true), t: 1, bounds: screen) == nil, "key repeats aren't logged")

  // Pointer events are normalized to the main display.
  let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 500, y: 250), mouseButton: .left)!
  let clicked = InputEvents.record(.leftMouseDown, click, t: 2, bounds: screen)
  expect(clicked?["x"] as? Double == 0.25 && clicked?["y"] as? Double == 0.25 && clicked?["button"] as? String == "left", "a click at a quarter of the screen")
  expect(normalizedPoint(CGPoint(x: 1333, y: 1), in: screen) == (0.6665, 0.001), "coordinates round to four places")
  let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 2000, y: 1000), mouseButton: .left)!
  expect(InputEvents.record(.mouseMoved, moved, t: 3, bounds: screen)?["type"] as? String == "move", "moves are logged")
  expect(InputEvents.record(.flagsChanged, moved, t: 3, bounds: screen) == nil, "other event types aren't")

  // The engine reads the log: times relative to the first frame, inside the recording.
  let log = FileManager.default.temporaryDirectory.appendingPathComponent("sd-input-\(getpid()).jsonl")
  defer { try? FileManager.default.removeItem(at: log) }
  let lines = [
    ["type": "meta", "clock": "uptime_raw", "t": 99.0],
    InputEvents.record(.leftMouseDown, click, t: 101, bounds: screen)!,
    InputEvents.record(.keyDown, key(35, [.maskCommand, .maskShift]), t: 102.5, bounds: screen)!,
    InputEvents.record(.keyDown, key(35), t: 150, bounds: screen)!,  // after the recording ends
  ].compactMap { try? InputEvents.jsonLine($0) }.reduce(Data(), +)
  try? lines.write(to: log)
  let source = Project.Source(video: "screen.mp4", width: 2000, height: 1000, duration: 10, captureStart: 100, camera: nil)
  let events = Project.loadEvents(log, source: source)
  expect(events.map(\.t) == [1, 2.5] && events.map(\.type) == [.click, .key], "the engine reads clicks and keys at their times (\(events))")
  expect(events.first?.x == 0.25 && events.last?.label == "⇧⌘P", "positions and labels come through")
}
