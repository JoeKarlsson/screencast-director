import AppKit
import DirectorCore
import ScreenCaptureKit
import SwiftUI

/// Settings (⌘,): General, Recording, AI and Sharing tabs.
struct SettingsView: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    TabView {
      GeneralSettings(settings: settings).tabItem { Label("General", systemImage: "gearshape") }
      RecordingSettings(settings: settings, windows: CaptureWindows.shared).tabItem { Label("Recording", systemImage: "record.circle") }
      AISettingsView().tabItem { Label("AI", systemImage: "sparkles") }
      Form { SharingSection() }.formStyle(.grouped).tabItem { Label("Sharing", systemImage: "link.icloud") }
    }
    // A grouped Form has no height of its own; without a frame the window collapses.
    .frame(width: 560, height: 480)
  }
}

struct GeneralSettings: View {
  @ObservedObject var settings: AppSettings

  var body: some View {
    Form {
      Section {
        LabeledContent("Recordings folder") {
          HStack {
            Text(settings.projectsFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Button("Choose…") {
              let panel = NSOpenPanel()
              panel.canChooseDirectories = true
              panel.canChooseFiles = false
              panel.canCreateDirectories = true
              panel.directoryURL = settings.projectsURL
              if panel.runModal() == .OK, let url = panel.url {
                settings.projectsFolder = url.path
                AppDelegate.shared?.library.refresh()
              }
            }
          }
        }
        Button("Show in Finder") { NSWorkspace.shared.open(settings.projectsURL) }
      }
      Section("New recordings") {
        Picker("Profile", selection: Binding(get: { ProfileStore.shared.defaultName }, set: { ProfileStore.shared.defaultName = $0 })) {
          ForEach(ProfileStore.shared.names, id: \.self) { Text($0).tag($0) }
        }
        Picker("Pause trimming", selection: $settings.pauseLevel) {
          ForEach(PauseLevel.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        Toggle("Name them from what you said", isOn: $settings.autoName)
      }
    }
    .formStyle(.grouped)
  }
}

struct RecordingSettings: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var windows: CaptureWindows

  var body: some View {
    Form {
      Section("Source") {
        CapturePicker(settings: settings, list: windows)
        if settings.captureWindowID == 0 {
          Picker("Display", selection: $settings.displayID) {
            ForEach(DisplayChoice.all) { Text($0.name).tag($0.id) }
          }
        }
        Picker("Frame rate", selection: $settings.fps) {
          Text("30 fps").tag(30)
          Text("60 fps").tag(60)
        }
        Toggle("Draw a smooth cursor (records without the real one)", isOn: $settings.smoothCursor)
        Toggle("Show this app in recordings (for recording a tour of it)", isOn: $settings.showSelfInRecordings)
      }
      Section("Microphone and camera") {
        Picker("Microphone", selection: settings.micSelection) {
          Text("System default").tag("")
          ForEach(AppSettings.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
        }
        Toggle("Record camera (for split screen and the camera bubble)", isOn: $settings.useCamera)
        Picker("Camera", selection: $settings.cameraID) {
          ForEach(AppSettings.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
        }
        .disabled(!settings.useCamera)
      }
      Section("While recording") {
        Picker("Countdown", selection: $settings.countdown) {
          Text("None").tag(0)
          Text("3 seconds").tag(3)
          Text("5 seconds").tag(5)
        }
        Toggle("Show the recording widget", isOn: $settings.showRecordingWidget)
        Text("A floating bar with the clock, mic level, camera and Pause, Restart, Discard and Stop. It never appears in the recording.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

struct AISettingsView: View {
  @ObservedObject var ai = AISettings.shared
  @ObservedObject var ui = SettingsUI()

  var body: some View {
    Form {
      Section {
        Picker("Provider", selection: $ai.provider) {
          ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
        }
        switch ai.provider {
        case .claudeCode:
          Text(Claude.executable.map { "Uses \($0.path) and your Claude login. It can check frames while it edits." }
            ?? "Install Claude Code from claude.com/claude-code, or pick an API provider.")
            .font(.caption).foregroundStyle(.secondary)
        case .anthropic:
          TextField("Model", text: $ai.anthropicModel)
          SecureField("API key", text: Binding(get: { ai.key(for: .anthropic) }, set: { ai.setKey($0, for: .anthropic) }))
          Text("Stored in your Keychain. Refusals fall back automatically to Anthropic's recommended model.")
            .font(.caption).foregroundStyle(.secondary)
        case .openAICompatible:
          Picker("Endpoint", selection: Binding(get: { EndpointPreset.all.first { $0.baseURL == ai.baseURL }?.id ?? "custom" },
            set: { id in if let p = EndpointPreset.all.first(where: { $0.id == id }) { ai.baseURL = p.baseURL } })) {
            ForEach(EndpointPreset.all) { Text($0.name).tag($0.id) }
            Text("Custom").tag("custom")
          }
          TextField("Base URL", text: $ai.baseURL)
          TextField("Model", text: $ai.model, prompt: Text(EndpointPreset.all.first { $0.baseURL == ai.baseURL }?.modelHint ?? "model name"))
          SecureField("API key (blank for Ollama)", text: Binding(get: { ai.key(for: .openAICompatible) }, set: { ai.setKey($0, for: .openAICompatible) }))
        }
      }
      if ai.provider != .claudeCode {
        Section {
          Toggle("Double-check AI edits", isOn: $ai.doubleCheck)
          Text("After an edit that changes cuts or zooms, a second request checks zoom targets and cut edges.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section {
        HStack {
          Button("Test Connection") {
            ui.testResult = "Testing…"
            Task { @MainActor in ui.testResult = await APIEditor.test(ai) }
          }
          Text(ui.testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
    }
    .formStyle(.grouped)
  }
}

final class SettingsUI: ObservableObject {
  @Published var testResult = ""
}

final class CaptureWindows: ObservableObject {
  static let shared = CaptureWindows()
  @Published private(set) var windows: [(id: Int, label: String)] = []

  func refresh() {
    Task { @MainActor in
      guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
      windows = content.windows
        .filter { $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150 }
        .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
        .map { w in
          let app = w.owningApplication?.applicationName ?? "Window"
          let title = (w.title ?? "").isEmpty ? "" : ": \(w.title!)"
          return (Int(w.windowID), String("\(app)\(title)".prefix(70)))
        }
        .sorted { $0.label < $1.label }
    }
  }
}

struct CapturePicker: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var list: CaptureWindows
  var showsDisplay = true

  var body: some View {
    Picker("Record", selection: Binding(get: { settings.captureWindowID }, set: { id in
      settings.captureWindowID = id
      settings.captureWindowLabel = list.windows.first { $0.id == id }?.label ?? ""
    })) {
      if showsDisplay { Text("Whole display").tag(0) }
      if settings.captureWindowID != 0, !list.windows.contains(where: { $0.id == settings.captureWindowID }) {
        Text(settings.captureWindowLabel).tag(settings.captureWindowID)
      }
      ForEach(list.windows, id: \.id) { Text($0.label).tag($0.id) }
    }
    .onAppear { list.refresh() }
    .help("A single window records sharper and smaller than the whole display; clicks are measured inside it.")
  }
}
