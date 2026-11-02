import ApplicationServices
import Foundation

// Presses the first button in one process's windows whose help text (or description) matches, for
// macos/smoke-test.sh. AppleScript's `entire contents` hands back references that name the process
// rather than its PID, so with the installed copy running they reach that copy instead of the test's.
//
//   axpress <pid> help|description <text>    prints "pressed" or "missing"; text ending in * is a prefix

let args = CommandLine.arguments
guard args.count == 4, let pid = pid_t(args[1]), ["help", "description"].contains(args[2]) else {
  FileHandle.standardError.write(Data("usage: axpress <pid> help|description <text>\n".utf8))
  exit(2)
}
let attribute = args[2] == "help" ? kAXHelpAttribute : kAXDescriptionAttribute
let wanted = args[3]

func matches(_ value: String) -> Bool {
  wanted.hasSuffix("*") ? value.hasPrefix(String(wanted.dropLast())) : value == wanted
}

func string(_ element: AXUIElement, _ name: String) -> String? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
  return value as? String
}

func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
  if string(element, kAXRoleAttribute) == kAXButtonRole, let v = string(element, attribute), matches(v) { return element }
  guard depth < 40 else { return nil }
  var children: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
    let list = children as? [AXUIElement]
  else { return nil }
  for child in list {
    if let hit = find(child, depth: depth + 1) { return hit }
  }
  return nil
}

guard let button = find(AXUIElementCreateApplication(pid), depth: 0) else {
  print("missing")
  exit(0)
}
let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
guard result == .success else {
  FileHandle.standardError.write(Data("axpress: pressing failed (AXError \(result.rawValue))\n".utf8))
  exit(1)
}
print("pressed")
