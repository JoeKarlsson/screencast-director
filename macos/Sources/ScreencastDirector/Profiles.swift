import AppKit
import DirectorCore
import Foundation

/// Profiles live in ~/Library/Application Support/Screencast Director/Profiles/<name>/profile.json
/// with their fonts and logos. New recordings get the default profile; any video can switch.
final class ProfileStore: ObservableObject {
  static let shared = ProfileStore()

  @Published private(set) var names: [String] = []
  @Published var defaultName: String {
    didSet { UserDefaults.standard.set(defaultName, forKey: "defaultProfile") }
  }

  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Screencast Director/Profiles")

  init() {
    defaultName = UserDefaults.standard.string(forKey: "defaultProfile") ?? "Personal"
    refresh()
  }

  func refresh() {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // First run: seed a Personal profile with the built-in look.
    let personal = root.appendingPathComponent("Personal/profile.json")
    if !FileManager.default.fileExists(atPath: personal.path) {
      try? FileManager.default.createDirectory(at: personal.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? Data(
        #"{"name": "Personal", "style": {"background": ["#1d2b64", "#f8cdda"], "padding": 0.06, "radius": 14, "transition": 0.8}, "look": {}}"#
          .utf8
      ).write(to: personal)
    }
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    names = dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("profile.json").path) }
      .map(\.lastPathComponent).sorted()
  }

  func load(_ name: String) -> Profile? {
    try? Profile.load(root.appendingPathComponent(name))
  }

  var defaultProfile: Profile? { load(defaultName) }

  /// Saves a video's current look and style as a profile (asset paths stay absolute).
  func save(from plan: Plan, as name: String) throws {
    let dir = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var look = plan.look ?? Look()
    look.name = nil
    let profile = Profile(name: name, style: plan.style, look: look, captions: plan.captions)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(profile).write(to: dir.appendingPathComponent("profile.json"))
    refresh()
  }

  func openFolder() {
    NSWorkspace.shared.open(root)
  }

  /// Asks for a name, then saves the plan's look as a profile.
  func promptSave(from plan: Plan) {
    let alert = NSAlert()
    alert.messageText = "Save as Profile"
    alert.informativeText = "Saves this video's background, frame, fonts, colors and logo so new videos can use them."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "Profile name"
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.contains("/") else { return }
    do { try save(from: plan, as: name) } catch { NSAlert(error: error).runModal() }
  }
}
