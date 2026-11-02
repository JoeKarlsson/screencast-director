// input-logger (logger/main.swift): writes mouse and keyboard activity as JSON lines while a recording runs.
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
    if let line = jsonLine(obj) { State.out.write(line) }
}

emit([
    "type": "meta",
    "clock": "uptime_raw",
    "t": now(),
    "epochMs": Int(Date().timeIntervalSince1970 * 1000),
    "display": ["w": State.bounds.width, "h": State.bounds.height, "scale": NSScreen.main?.backingScaleFactor ?? 1],
])

let callback: CGEventTapCallBack = { _, type, event, _ in
    let t = now()
    let isMove = [.mouseMoved, .leftMouseDragged, .rightMouseDragged].contains(type)
    // Moves at most 30 times a second.
    let throttled = isMove && t - State.lastMove < 1.0 / 30.0
    // A password field (or any app) has secure input on: log nothing, not even that a key was hit.
    let secure = type == .keyDown && IsSecureEventInputEnabled()
    if !throttled, !secure, let obj = eventRecord(type, event, t: t, bounds: State.bounds) {
        if isMove { State.lastMove = t }
        emit(obj)
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
