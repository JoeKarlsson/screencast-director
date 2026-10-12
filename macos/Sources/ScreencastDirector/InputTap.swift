import AppKit
import CoreGraphics
import DirectorCore
import Foundation

// In-process version of logger/InputLogger.swift: writes clicks, keys and cursor moves as
// JSON lines while a recording runs. Same format, same privacy rule: plain typing (and Space)
// is logged without characters; only shortcut combos get a label.
//
// Timestamps use CLOCK_UPTIME_RAW, the host clock ScreenCaptureKit stamps frames with.

enum InputTap {
  nonisolated(unsafe) private static var out: FileHandle?
  nonisolated(unsafe) private static var bounds = CGRect.zero
  nonisolated(unsafe) private static var lastMove = 0.0
  nonisolated(unsafe) private static var tap: CFMachPort?
  nonisolated(unsafe) private static var source: CFRunLoopSource?

  /// Input Monitoring is needed for keys; without it, start() still logs nothing and returns false.
  static var hasPermission: Bool { CGPreflightListenEventAccess() }
  static func requestPermission() { _ = CGRequestListenEventAccess() }

  static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

  /// `capture` is the recorded area in global points (a display's bounds or a window's frame);
  /// positions are logged as 0...1 fractions of it.
  @discardableResult
  static func start(writingTo url: URL, capture: CGRect) -> Bool {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    out = FileHandle(forWritingAtPath: url.path)
    bounds = capture
    emit([
      "type": "meta", "clock": "uptime_raw", "t": now(), "epochMs": Int(Date().timeIntervalSince1970 * 1000),
      "display": ["w": bounds.width, "h": bounds.height],
    ])
    let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard
      let t = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
        callback: { _, type, event, _ in
          InputTap.handle(type, event)
          return Unmanaged.passUnretained(event)
        }, userInfo: nil)
    else { return false }
    tap = t
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
  }

  /// Marks a retake: the phrase just before this moment gets cut, and the redo after it stays.
  static func markRetake() {
    emit(["type": "retake", "t": now()])
  }

  static func stop() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil
    source = nil
    try? out?.synchronize()
    try? out?.close()
    out = nil
  }

  private static func emit(_ obj: [String: Any]) {
    guard let out, let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    out.write(data + Data("\n".utf8))
  }

  private static func norm(_ p: CGPoint) -> (Double, Double) {
    normalizedPoint(p, in: bounds)
  }

  private static func handle(_ type: CGEventType, _ event: CGEvent) {
    let t = now()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
      guard t - lastMove >= 1.0 / 30 else { return }
      lastMove = t
      let (x, y) = norm(event.location)
      emit(["type": "move", "t": t, "x": x, "y": y])
    case .leftMouseDown, .rightMouseDown:
      let (x, y) = norm(event.location)
      emit(["type": "click", "t": t, "x": x, "y": y, "button": type == .leftMouseDown ? "left" : "right"])
    case .scrollWheel:
      let (x, y) = norm(event.location)
      emit(["type": "scroll", "t": t, "x": x, "y": y])
    case .keyDown:
      if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
      let label = keyLabel(event)
      // The app's own hotkeys (record, retake) aren't part of the demo; don't show them as chips.
      if label == "⌃⌥⌘R" || label == "⌃⌥⌘M" { return }
      let (x, y) = norm(event.location)
      var obj: [String: Any] = ["type": "key", "t": t, "x": x, "y": y]
      if let label { obj["label"] = label }
      emit(obj)
    default:
      break
    }
  }

  static func keyLabel(_ event: CGEvent) -> String? {
    let flags = event.flags
    let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let special: [Int64: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
    if !shortcut { return code == 49 ? nil : special[code] }
    var label = ""
    if flags.contains(.maskControl) { label += "⌃" }
    if flags.contains(.maskAlternate) { label += "⌥" }
    if flags.contains(.maskShift) { label += "⇧" }
    if flags.contains(.maskCommand) { label += "⌘" }
    if let s = special[code] { return label + s }
    guard let copy = event.copy() else { return label + "?" }
    copy.flags = []
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    copy.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
    let base = String(utf16CodeUnits: chars, count: length).uppercased()
    return label + (base.isEmpty ? "?" : base)
  }
}
