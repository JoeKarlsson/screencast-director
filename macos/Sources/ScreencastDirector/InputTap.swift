import AppKit
import Carbon
import CoreGraphics
import DirectorCore
import Foundation

// Writes clicks, keys and cursor moves to events.jsonl while a recording runs. What each event
// records (and the privacy rule for typing) is DirectorCore's InputEvents; this adds the event tap,
// a 30 Hz cap on moves, pausing, and logging nothing while secure input (a password field) is on.
//
// Timestamps use CLOCK_UPTIME_RAW, the host clock ScreenCaptureKit stamps frames with.

enum InputTap {
  nonisolated(unsafe) private static var out: FileHandle?
  nonisolated(unsafe) private static var bounds = CGRect.zero
  nonisolated(unsafe) private static var lastMove = 0.0
  nonisolated(unsafe) private static var tap: CFMachPort?
  nonisolated(unsafe) private static var source: CFRunLoopSource?
  /// While the recording is paused, nothing is logged (the paused stretch gets cut anyway).
  nonisolated(unsafe) static var paused = false

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
    paused = false
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil
    source = nil
    try? out?.synchronize()
    try? out?.close()
    out = nil
  }

  private static func emit(_ obj: [String: Any]) {
    guard let out, let line = try? InputEvents.jsonLine(obj) else { return }
    out.write(line)
  }

  private static func handle(_ type: CGEventType, _ event: CGEvent) {
    let t = now()
    if paused, type != .tapDisabledByTimeout, type != .tapDisabledByUserInput { return }
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
      guard t - lastMove >= 1.0 / 30 else { return }
      lastMove = t
    case .keyDown:
      // A password field (or any app) has secure input on: log nothing, not even that a key was hit.
      if IsSecureEventInputEnabled() { return }
    default:
      break
    }
    guard let obj = InputEvents.record(type, event, t: t, bounds: bounds) else { return }
    // The app's own hotkeys (record, retake) aren't part of the demo; don't show them as chips.
    if let label = obj["label"] as? String, label == "⌃⌥⌘R" || label == "⌃⌥⌘M" { return }
    emit(obj)
  }
}
