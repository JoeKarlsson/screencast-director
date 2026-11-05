import CoreGraphics
import Foundation

// What the app's input log (events.jsonl) records for each event, apart from the event tap in
// InputTap so Tests/ChecksInput.swift can check it with synthetic events (no Input Monitoring needed).
// Privacy: plain typing (and Space) is logged without characters; only ⌘ or ⌃ combos get a label
// (⌥ alone types characters).

/// A point in global screen points as a 0...1 fraction of the recorded area (a display or a
/// window), rounded to four places. Points outside the area come out below 0 or above 1.
public func normalizedPoint(_ p: CGPoint, in rect: CGRect) -> (Double, Double) {
  let x = (p.x - rect.origin.x) / rect.width
  let y = (p.y - rect.origin.y) / rect.height
  return ((x * 10000).rounded() / 10000, (y * 10000).rounded() / 10000)
}

public enum InputEvents: Sendable {
  /// The label a key press shows as a chip, or nil when it's typing (which stays anonymous).
  public static func keyLabel(_ event: CGEvent) -> String? {
    let flags = event.flags
    let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let special: [Int64: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
    // Named non-text keys are useful and not sensitive; text (including Space) stays anonymous.
    if !shortcut { return code == 49 ? nil : special[code] }
    var label = ""
    if flags.contains(.maskControl) { label += "⌃" }
    if flags.contains(.maskAlternate) { label += "⌥" }
    if flags.contains(.maskShift) { label += "⇧" }
    if flags.contains(.maskCommand) { label += "⌘" }
    if let s = special[code] { return label + s }
    // Read the unmodified character so ⌘⇧P shows "P", not a control code.
    guard let copy = event.copy() else { return label + "?" }
    copy.flags = []
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    copy.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
    let base = String(utf16CodeUnits: chars, count: length).uppercased()
    return label + (base.isEmpty ? "?" : base)
  }

  /// The JSON object logged for an event at host time `t`, positions as fractions of `bounds`, or
  /// nil for events that aren't logged (key repeats, other types). Moves aren't throttled here, and
  /// secure input is checked by the caller.
  public static func record(_ type: CGEventType, _ event: CGEvent, t: Double, bounds: CGRect) -> [String: Any]? {
    let (x, y) = normalizedPoint(event.location, in: bounds)
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
      return ["type": "move", "t": t, "x": x, "y": y]
    case .leftMouseDown, .rightMouseDown:
      return ["type": "click", "t": t, "x": x, "y": y, "button": type == .leftMouseDown ? "left" : "right"]
    case .scrollWheel:
      return ["type": "scroll", "t": t, "x": x, "y": y]
    case .keyDown:
      if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
      var obj: [String: Any] = ["type": "key", "t": t, "x": x, "y": y]
      if let label = keyLabel(event) { obj["label"] = label }
      return obj
    default:
      return nil
    }
  }

  /// One line of the log.
  public static func jsonLine(_ obj: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) + Data("\n".utf8)
  }
}

public struct Word: Codable, Equatable, Sendable {
  public var text: String
  public var start: Double
  public var end: Double
  public init(text: String, start: Double, end: Double) {
    self.text = text
    self.start = start
    self.end = end
  }
}

public enum InputKind: String, Codable, Sendable {
  case move, click, scroll, key, retake
}

public struct InputEvent: Equatable, Sendable {
  public var t: Double
  public var type: InputKind
  public var x: Double
  public var y: Double
  public var label: String?
  public init(t: Double, type: InputKind, x: Double, y: Double, label: String? = nil) {
    self.t = t
    self.type = type
    self.x = x
    self.y = y
    self.label = label
  }
}
