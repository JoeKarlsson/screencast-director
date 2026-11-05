import AppKit
import DirectorCore
import Foundation

/// The Profiles menu's view of `ProfileLibrary` (DirectorCore), which `director profiles` shares.
final class ProfileStore: ObservableObject {
  static let shared = ProfileStore()

  let library = ProfileLibrary()
  @Published private(set) var names: [String] = []
  @Published var defaultName: String {
    didSet { ProfileLibrary.defaultName = defaultName }
  }

  init() {
    defaultName = ProfileLibrary.defaultName
    refresh()
  }

  /// Lists the profiles again and picks up a default set elsewhere (`director settings`).
  func refresh() {
    names = library.names()
    syncSetting(self, \.defaultName, ProfileLibrary.defaultName)
  }

  func load(_ name: String) throws -> Profile {
    try library.load(name)
  }

  /// Saves a video's current look and style as a profile (asset paths stay absolute).
  func save(from plan: Plan, as name: String, extras: Set<Profile.Extra>) throws {
    try library.save(from: plan, as: name, extras: extras)
    refresh()
  }

  func openFolder() {
    NSWorkspace.shared.open(library.root)
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
