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

  /// Saves a video's current look and style as a profile, its files copied in beside it.
  func save(from plan: Plan, project: URL, as name: String, extras: Set<Profile.Extra>) throws {
    try library.save(from: plan, project: project, as: name, extras: extras)
    refresh()
  }

  func openFolder() {
    NSWorkspace.shared.open(library.root)
  }

  /// Asks for a name, then saves the plan's look as a profile.
  func promptSave(from plan: Plan, project: URL) {
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
        try save(from: plan, project: project, as: name, extras: Set(boxes.filter { $0.1.state == .on }.map(\.0)))
        Notices.shared.show("Saved the profile \(name).")
      } catch {
        Notices.shared.show(error, "Couldn't save the profile")
      }
    }
  }

  /// Picks a pack (a folder or a .sdpack) and installs it: profiles, themes, templates, Lotties,
  /// effects, sounds and music. Files that differ from yours are listed first, to replace or keep.
  func promptInstall() {
    let panel = NSOpenPanel()
    panel.message = "Choose a pack: a .sdpack file or a pack folder."
    panel.canChooseDirectories = true
    panel.allowedContentTypes = [.init(filenameExtension: "sdpack") ?? .zip, .folder, .zip]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    install(url)
  }

  func install(_ url: URL) {
    do {
      let (manifest, plan) = try Packs.install(url)
      refresh()
      Notices.shared.show("Installed \(manifest.name): \(plan.new.count) new file(s)\(plan.same.isEmpty ? "" : ", \(plan.same.count) already here").")
    } catch {
      // Conflicts: say which, then replace on request.
      let message = "\(error)"
      guard message.contains("--replace") else { return Notices.shared.show(error, "Couldn't install the pack") }
      let alert = NSAlert()
      alert.messageText = "Replace your files?"
      alert.informativeText = message.replacingOccurrences(of: "install again with --replace (in the app, Replace) to overwrite them", with: "Replace overwrites them")
      alert.addButton(withTitle: "Replace")
      alert.addButton(withTitle: "Cancel")
      presentAlert(alert) { [self] response in
        guard response == .alertFirstButtonReturn else { return }
        do {
          let (manifest, _) = try Packs.install(url, replace: true)
          refresh()
          Notices.shared.show("Installed \(manifest.name).")
        } catch {
          Notices.shared.show(error, "Couldn't install the pack")
        }
      }
    }
  }

  /// Asks which profiles go in, then where to save the .sdpack.
  func promptExport() {
    refresh()
    let alert = NSAlert()
    alert.messageText = "Export Profiles as a Pack"
    alert.informativeText = "The pack carries each profile with its fonts, logos, LUTs and music, and the effects and animation theme it uses."
    let boxes = names.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
    let work = NSButton(checkboxWithTitle: "Include the work sounds and music", target: nil, action: nil)
    let stack = NSStackView(views: boxes + [work])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(boxes.count + 1) * 24)
    alert.accessoryView = stack
    alert.addButton(withTitle: "Export…")
    alert.addButton(withTitle: "Cancel")
    presentAlert(alert) { [self] response in
      let chosen = boxes.filter { $0.state == .on }.map(\.title)
      guard response == .alertFirstButtonReturn, !chosen.isEmpty else { return }
      let save = NSSavePanel()
      save.nameFieldStringValue = "\(chosen.count == 1 ? chosen[0] : "My Look").sdpack"
      guard save.runModal() == .OK, let out = save.url else { return }
      do {
        try? FileManager.default.removeItem(at: out)  // the save panel already asked about replacing it
        try Packs.export(profiles: chosen, work: work.state == .on, to: out)
        NSWorkspace.shared.activateFileViewerSelecting([out])
      } catch {
        Notices.shared.show(error, "Couldn't export the pack")
      }
    }
  }
}
