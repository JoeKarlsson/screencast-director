// What the input logger writes for each event, apart from the event tap so test/logger-test.sh can
// check it with synthetic events (no Input Monitoring permission needed).

import CoreGraphics
import Foundation

// Normalize to the main display (what avfoundation "Capture screen 0" records).
func normalized(_ p: CGPoint, in b: CGRect) -> (Double, Double) {
    let x = (p.x - b.origin.x) / b.width
    let y = (p.y - b.origin.y) / b.height
    return ((x * 10000).rounded() / 10000, (y * 10000).rounded() / 10000)
}

func keyLabel(_ event: CGEvent) -> String? {
    let flags = event.flags
    let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let special: [Int64: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
    if !shortcut {
        // Named non-text keys are useful and not sensitive; text (including Space) stays anonymous.
        return code == 49 ? nil : special[code]
    }
    var label = ""
    if flags.contains(.maskControl) { label += "⌃" }
    if flags.contains(.maskAlternate) { label += "⌥" }
    if flags.contains(.maskShift) { label += "⇧" }
    if flags.contains(.maskCommand) { label += "⌘" }
    if let s = special[code] { return label + s }
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    // Read the unmodified character so ⌘⇧P shows "P", not a control code.
    event.flags = []
    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
    let base = String(utf16CodeUnits: chars, count: length).uppercased()
    return label + (base.isEmpty ? "?" : base)
}

/// The JSON object logged for an event at host time `t`, or nil for events that aren't logged (key
/// repeats, other types). Moves aren't throttled here, and secure input is checked by the caller.
func eventRecord(_ type: CGEventType, _ event: CGEvent, t: Double, bounds: CGRect) -> [String: Any]? {
    let (x, y) = normalized(event.location, in: bounds)
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
        if let label = keyLabel(event.copy()!) { obj["label"] = label }
        return obj
    default:
        return nil
    }
}

/// One line of the log.
func jsonLine(_ obj: [String: Any]) -> Data? {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
    return data + Data("\n".utf8)
}
