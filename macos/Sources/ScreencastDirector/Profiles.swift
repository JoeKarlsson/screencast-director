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
        ##"{"name": "Personal", "style": {"background": ["#1d2b64", "#f8cdda"], "padding": 0, "radius": 14, "transition": 0.8}, "look": {}}"##
          .utf8
      ).write(to: personal)
    }
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    names = dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("profile.json").path) }
      .map(\.lastPathComponent).sorted()
  }

  func load(_ name: String) throws -> Profile {
    try Profile.load(root.appendingPathComponent(name))
  }

  /// The default profile, or nil when there's no profile by that name. One that's there but can't
  /// be read throws, so a broken profile.json isn't silently skipped.
  func defaultProfile() throws -> Profile? {
    let file = root.appendingPathComponent(defaultName).appendingPathComponent("profile.json")
    return FileManager.default.fileExists(atPath: file.path) ? try load(defaultName) : nil
  }

  /// Saves a video's current look and style as a profile (asset paths stay absolute).
  func save(from plan: Plan, as name: String, extras: Set<Profile.Extra>) throws {
    let dir = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let profile = Profile.saved(from: plan, name: name, extras: extras)
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
    // Effects and the default layout always come along; these are a choice, since not every video
    // with the look wants the same track or voice processing.
    let boxes: [(Profile.Extra, NSButton)] = [
      (.music, NSButton(checkboxWithTitle: "Include the music", target: nil, action: nil)),
      (.voice, NSButton(checkboxWithTitle: "Include the voice settings", target: nil, action: nil)),
      (.camera, NSButton(checkboxWithTitle: "Include the camera color and bubble", target: nil, action: nil)),
    ].filter { extra, _ in
      switch extra {
      case .music: return plan.music != nil
      case .voice: return plan.audio != nil
      case .camera: return plan.camera != nil
      }
    }
    let stack = NSStackView(views: [field] + boxes.map(\.1))
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.frame = NSRect(x: 0, y: 0, width: 260, height: 24 + CGFloat(boxes.count) * 24)
    alert.accessoryView = stack
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    presentAlert(alert) { [self] response in
      guard response == .alertFirstButtonReturn else { return }
      let name = field.stringValue.trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !name.contains("/") else { return }
      do {
        try save(from: plan, as: name, extras: Set(boxes.filter { $0.1.state == .on }.map(\.0)))
        Notices.shared.show("Saved the profile \(name).")
      } catch {
        Notices.shared.show(error, "Couldn't save the profile")
      }
    }
  }
}
