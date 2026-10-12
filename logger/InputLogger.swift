// input-logger: writes mouse and keyboard activity as JSON lines while a recording runs.
//
// Timestamps use CLOCK_UPTIME_RAW, the same host clock AVFoundation stamps captured
// frames with, so events line up with the video without any guessed offset.
//
// Privacy: plain typing is logged as {"type":"key"} with no character. Only shortcut
// combos (⌘ or ⌃ held) record their label, e.g. "⌘⇧P"; ⌥ alone types characters, so it
// doesn't count. Nothing is logged while secure input (a password field) is on.
//
// Usage: input-logger <out.jsonl>    (stop with Ctrl-C or SIGTERM)

import AppKit
import Carbon
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: input-logger <out.jsonl>\n".data(using: .utf8)!)
    exit(64)
}

let outPath = CommandLine.arguments[1]
FileManager.default.createFile(atPath: outPath, contents: nil)
guard let outHandle = FileHandle(forWritingAtPath: outPath) else {
    FileHandle.standardError.write("input-logger: cannot open \(outPath)\n".data(using: .utf8)!)
    exit(73)
}

// The tap callback is a C function pointer, so its state lives in statics, not globals.
enum State {
    nonisolated(unsafe) static var out: FileHandle!
    nonisolated(unsafe) static var bounds = CGRect.zero
    nonisolated(unsafe) static var lastMove = 0.0
}
State.out = outHandle
State.bounds = CGDisplayBounds(CGMainDisplayID())

func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    State.out.write(data)
    State.out.write("\n".data(using: .utf8)!)
}

// Normalize to the main display (what avfoundation "Capture screen 0" records).
func norm(_ p: CGPoint) -> (Double, Double) {
    let b = State.bounds
    let x = (p.x - b.origin.x) / b.width
    let y = (p.y - b.origin.y) / b.height
    return ((x * 10000).rounded() / 10000, (y * 10000).rounded() / 10000)
}

emit([
    "type": "meta",
    "clock": "uptime_raw",
    "t": now(),
    "epochMs": Int(Date().timeIntervalSince1970 * 1000),
    "display": ["w": State.bounds.width, "h": State.bounds.height, "scale": NSScreen.main?.backingScaleFactor ?? 1],
])


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

let callback: CGEventTapCallBack = { _, type, event, _ in
    let t = now()
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
        if t - State.lastMove >= 1.0 / 30.0 {
            State.lastMove = t
            let (x, y) = norm(event.location)
            emit(["type": "move", "t": t, "x": x, "y": y])
        }
    case .leftMouseDown, .rightMouseDown:
        let (x, y) = norm(event.location)
        emit(["type": "click", "t": t, "x": x, "y": y, "button": type == .leftMouseDown ? "left" : "right"])
    case .scrollWheel:
        let (x, y) = norm(event.location)
        emit(["type": "scroll", "t": t, "x": x, "y": y])
    case .keyDown:
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { break }
        // A password field (or any app) has secure input on: log nothing, not even that a key was hit.
        if IsSecureEventInputEnabled() { break }
        var obj: [String: Any] = ["type": "key", "t": t]
        let (x, y) = norm(event.location)
        obj["x"] = x
        obj["y"] = y
        if let label = keyLabel(event.copy()!) { obj["label"] = label }
        emit(obj)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        break
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                  eventsOfInterest: mask, callback: callback, userInfo: nil) else {
    FileHandle.standardError.write("""
    input-logger: could not create an event tap.
    Grant your terminal app Input Monitoring (and Accessibility) in
    System Settings > Privacy & Security, then restart the terminal.

    """.data(using: .utf8)!)
    exit(77)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        try? State.out.synchronize()
        exit(0)
    }
    src.resume()
    // Keep the source alive for the life of the process.
    _ = Unmanaged.passRetained(src as AnyObject)
}

FileHandle.standardError.write("input-logger: recording input to \(outPath)\n".data(using: .utf8)!)
CFRunLoopRun()
