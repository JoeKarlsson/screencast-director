import ApplicationServices
import Foundation

// Accessibility actions on one process, by PID, for macos/smoke-test.sh. AppleScript's
// `entire contents` hands back references that name the process rather than its PID, so with the
// installed copy running they reach that copy instead of the test's.
//
//   axpress <pid> help|description <text>   press the first button whose help or description matches
//                                           (text ending in * is a prefix); prints "pressed" or "missing"
//   axpress <pid> focus-field <placeholder>  focus the text field with that placeholder (* for a prefix);
//                                           prints "focused" or "missing"
//   axpress <pid> field-value <placeholder>  print that text field's text
//   axpress <pid> click-title               a real mouse click on the middle of the first window's title bar
//   axpress <pid> drag <x1> <y1> <x2> <y2>  a real mouse drag between two screen points, in small steps
//   axpress <pid> window-id                 print the window number of its largest on-screen window
//                                           (for `screencapture -l`), or exit 1 when it has none yet
//   axpress <pid> focused                   print the focused element: role, placeholder, help and value
//   axpress <pid> key <code>                press and release a key (virtual key code) in this process only

let args = CommandLine.arguments
func usage() -> Never {
  FileHandle.standardError.write(
    Data(
      "usage: axpress <pid> help|description <text> | focus-field|field-value <placeholder> | click-title | drag <x1> <y1> <x2> <y2> | window-id | focused | key <code> [cmd]\n"
        .utf8))
  exit(2)
}
guard args.count >= 3, let pid = pid_t(args[1]) else { usage() }
let app = AXUIElementCreateApplication(pid)

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
  return value as? T
}

func first(_ element: AXUIElement, depth: Int = 0, where test: (AXUIElement) -> Bool) -> AXUIElement? {
  if test(element) { return element }
  guard depth < 40, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) else { return nil }
  for child in children {
    if let hit = first(child, depth: depth + 1, where: test) { return hit }
  }
  return nil
}

func matches(_ value: String, _ wanted: String) -> Bool {
  wanted.hasSuffix("*") ? value.hasPrefix(String(wanted.dropLast())) : value == wanted
}

func textField(_ placeholder: String) -> AXUIElement? {
  first(app) { e in
    [kAXTextFieldRole, kAXTextAreaRole].contains(attribute(e, kAXRoleAttribute) as String? ?? "")
      && matches(attribute(e, kAXPlaceholderValueAttribute) as String? ?? "", placeholder)
  }
}

func check(_ result: AXError, _ what: String) {
  guard result == .success else {
    FileHandle.standardError.write(Data("axpress: \(what) failed (AXError \(result.rawValue))\n".utf8))
    exit(1)
  }
}

switch args[2] {
case "help", "description":
  guard args.count == 4 else { usage() }
  let name = args[2] == "help" ? kAXHelpAttribute : kAXDescriptionAttribute
  let wanted = args[3]
  let button = first(app) { e in
    guard attribute(e, kAXRoleAttribute) as String? == kAXButtonRole, let v: String = attribute(e, name) else { return false }
    return matches(v, wanted)
  }
  guard let button else {
    print("missing")
    exit(0)
  }
  check(AXUIElementPerformAction(button, kAXPressAction as CFString), "pressing")
  print("pressed")
case "focus-field":
  guard args.count == 4 else { usage() }
  guard let field = textField(args[3]) else {
    print("missing")
    exit(0)
  }
  check(AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue), "focusing")
  print("focused")
case "field-value":
  guard args.count == 4, let field = textField(args[3]) else { usage() }
  print(attribute(field, kAXValueAttribute) as String? ?? "")
case "click-title":
  guard let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute), let window = windows.first,
    let positionValue: AXValue = attribute(window, kAXPositionAttribute), let sizeValue: AXValue = attribute(window, kAXSizeAttribute)
  else {
    FileHandle.standardError.write(Data("axpress: no window to click\n".utf8))
    exit(1)
  }
  var origin = CGPoint.zero, size = CGSize.zero
  AXValueGetValue(positionValue, .cgPoint, &origin)
  AXValueGetValue(sizeValue, .cgSize, &size)
  let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + 12)
  for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(50_000)
  }
  print("clicked")
case "drag":
  guard args.count == 7, let x1 = Double(args[3]), let y1 = Double(args[4]), let x2 = Double(args[5]), let y2 = Double(args[6])
  else { usage() }
  func post(_ type: CGEventType, _ x: Double, _ y: Double) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
      .post(tap: .cghidEventTap)
    usleep(30_000)
  }
  post(.leftMouseDown, x1, y1)
  for i in 1...20 {
    let f = Double(i) / 20
    post(.leftMouseDragged, x1 + (x2 - x1) * f, y1 + (y2 - y1) * f)
  }
  usleep(200_000)
  post(.leftMouseUp, x2, y2)
  print("dragged")
case "key":
  // Straight to this process, not to whatever app is in front (System Events' `key code` goes to
  // the frontmost app, and with the installed copy open that's a race). `cmd` holds ⌘ (⌘Z).
  guard args.count == 4 || (args.count == 5 && args[4] == "cmd"), let code = CGKeyCode(args[3]) else { usage() }
  let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: true)
  if args.count == 5 { event?.flags = .maskCommand }
  event?.postToPid(pid)
  usleep(30_000)
  print("sent")
case "focused":
  guard let element: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) else {
    print("nothing")
    exit(0)
  }
  let parts = [kAXRoleAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute, kAXValueAttribute].map { name -> String in
    let value: String? = attribute(element, name)
    return value ?? "-"
  }
  print(parts.joined(separator: " | "))
case "window-id":
  let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
  let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
  func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
  }
  guard let window = mine.max(by: { area($0) < area($1) }), let number = window[kCGWindowNumber as String] as? Int else { exit(1) }
  print(number)
default:
  usage()
}
