import AVKit
import AppKit
import DirectorCore
import ScreenCaptureKit
import SwiftUI

// View state lives in ObservableObjects: @State needs Swift macro plugins, which the
// Command Line Tools don't ship.

final class EditorUI {
  let timeline = TimelineUI()
  let inspector = InspectorUI()
}

struct MainView: View {
  @ObservedObject var library: Library
  @ObservedObject var recorder: Recorder
  @ObservedObject var setup: SetupModel
  let editor: EditorUI
  let toggleRecording: () -> Void
  let importVideo: () -> Void
  let watchTour: () -> Void

  var body: some View {
    NavigationSplitView {
      List(selection: $library.selection) {
        Section("Recordings") {
          ForEach(library.filtered, id: \.self) { url in
            Label(url.lastPathComponent, systemImage: "film").tag(url as URL?)
              .contextMenu {
                Button("Rename…") { library.promptRename(url) }
                Button("Suggest a Name with \(AISettings.shared.provider.shortName)") { library.suggestName(url) }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
              }
          }
        }
      }
      .searchable(text: $library.search, placement: .sidebar, prompt: "Search names and what you said")
      .safeAreaInset(edge: .bottom) {
        if !library.status.isEmpty {
          Text(library.status).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
        Button {
          library.selection = nil
        } label: {
          Label(setup.allRequiredOK ? "Getting Started" : "Finish Setup", systemImage: setup.allRequiredOK ? "questionmark.circle" : "exclamationmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(setup.allRequiredOK ? Color.secondary : Color.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    } detail: {
      if let project = library.current {
        EditorView(project: project, editor: editor)
      } else {
        SetupView(setup: setup, record: toggleRecording, importVideo: importVideo, watchTour: watchTour)
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button(action: importVideo) { Label("Import Video…", systemImage: "square.and.arrow.down") }
          .help("Import a video you already recorded")
        Button(action: toggleRecording) {
          Label(recorder.isRecording ? "Stop" : "Record", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
        }
        .help("Start or stop recording (⌃⌥⌘R from any app)")
      }
    }
  }
}

struct PlayerView: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let v = AVPlayerView()
    v.controlsStyle = .none
    v.player = player
    return v
  }
  func updateNSView(_ v: AVPlayerView, context: Context) {
    if v.player !== player { v.player = player }
  }
}

struct EditorView: View {
  @ObservedObject var project: ProjectModel
  let editor: EditorUI

  var body: some View {
    HSplitView {
      VStack(spacing: 10) {
        header
        PlayerView(player: project.player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .onTapGesture(perform: project.togglePlay)
        TimelineView(project: project, ui: editor.timeline)
        claudeBar
      }
      .padding(12)
      .frame(minWidth: 560)
      InspectorView(project: project, ui: editor.inspector)
    }
    .sheet(isPresented: $project.showPublish) { PublishView(project: project) }
    .sheet(isPresented: $project.showHistory) { VersionHistoryView(project: project) }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Text(project.name).font(.headline).lineLimit(1)
      Text(project.status).foregroundStyle(.secondary).lineLimit(1)
      if project.busy { ProgressView().controlSize(.small) }
      Spacer()
      Button { project.undo() } label: { Image(systemName: "arrow.uturn.backward") }
        .disabled(!project.canUndo).help("Undo (⌘Z)")
      Button { project.redo() } label: { Image(systemName: "arrow.uturn.forward") }
        .disabled(!project.canRedo).help("Redo (⇧⌘Z)")
      Menu {
        Button("Re-analyze (keep my edits)") { project.analyzeAndPlan() }
        Button("Start Over from a Fresh Draft") { project.analyzeAndPlan(force: true) }
        Button("Version History…") { project.showHistory = true }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.planURL]) }
      } label: { Image(systemName: "ellipsis.circle") }
        .menuIndicator(.hidden)
        .fixedSize()
      if project.hasPlan {
        Button("Publish…") { project.openPublish() }
          .disabled(project.busy)
          .help("Captions (SRT), chapters, a YouTube description draft and thumbnails")
        Menu {
          Button("Export Current Format") { project.export() }
          Divider()
          ForEach(ExportPreset.all, id: \.id) { p in Button(p.name) { project.export([p]) } }
          Divider()
          Button("All of the Above") { project.export(ExportPreset.all.map { Optional($0) }) }
          Divider()
          Button("GIF (for docs)…") { project.exportGIF() }.disabled(project.busy)
          Button("Upload and Copy Link…") { project.uploadAndCopyLink() }.disabled(project.busy)
        } label: {
          Text("Export")
        } primaryAction: {
          project.export()
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        ExportQueueButton(queue: ExportQueue.shared)
      } else {
        Button("Analyze") { project.analyzeAndPlan() }
          .buttonStyle(.borderedProminent)
          .disabled(project.busy)
      }
    }
  }

  private var claudeBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Image(systemName: "sparkles").foregroundStyle(.orange)
        TextField("Ask \(AISettings.shared.provider.shortName) to edit: \"cut my retakes, zoom in when I mention the config, side-by-side for the intro\"", text: $project.instruction)
          .textFieldStyle(.roundedBorder)
          .onSubmit(project.askClaude)
        Button("Ask \(AISettings.shared.provider.shortName)", action: project.askClaude)
          .disabled(project.busy || !project.hasPlan || project.instruction.isEmpty)
      }
      if !project.claudeLog.isEmpty {
        ScrollView {
          Text(project.claudeLog).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 90)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
      }
    }
  }
}

struct SettingsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var ai = AISettings.shared
  @ObservedObject var ui = SettingsUI()

  var body: some View {
    Form {
      Section("AI editing") {
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
        if ai.provider != .claudeCode {
          Toggle("Double-check AI edits", isOn: $ai.doubleCheck)
          Text("After an edit that changes cuts or zooms, a second request checks zoom targets and cut edges.")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Test") {
            ui.testResult = "Testing…"
            Task { @MainActor in ui.testResult = await APIEditor.test(ai) }
          }
          Text(ui.testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      SharingSection()
      Picker("Microphone", selection: $settings.micID) {
        Text("System default").tag("")
        ForEach(AppSettings.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
      }
      Picker("Profile for new recordings", selection: Binding(get: { ProfileStore.shared.defaultName }, set: { ProfileStore.shared.defaultName = $0 })) {
        ForEach(ProfileStore.shared.names, id: \.self) { Text($0).tag($0) }
      }
      Toggle("Record camera (for split screen and the camera bubble)", isOn: $settings.useCamera)
      Picker("Camera", selection: $settings.cameraID) {
        ForEach(AppSettings.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
      }
      .disabled(!settings.useCamera)
      Picker("Frame rate", selection: $settings.fps) {
        Text("30 fps").tag(30)
        Text("60 fps").tag(60)
      }
      Toggle("Name new recordings from what you said", isOn: $settings.autoName)
      Toggle("Draw a smooth cursor (records without the real one)", isOn: $settings.smoothCursor)
      Picker("Pause trimming for new recordings", selection: $settings.pauseLevel) {
        ForEach(PauseLevel.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      CapturePicker(settings: settings, list: CaptureWindows.shared)
      Toggle("Show this app in recordings (for recording a tour of it)", isOn: $settings.showSelfInRecordings)
      LabeledContent("Recordings folder") { Text(settings.projectsFolder).lineLimit(1).truncationMode(.middle) }
    }
    .formStyle(.grouped)
    // A grouped Form has no height of its own; without this the window collapses to its title bar.
    .frame(width: 600, height: 640)
  }
}

final class SettingsUI: ObservableObject {
  @Published var testResult = ""
}

/// Windows that can be recorded on their own, refreshed each time Settings shows the picker.
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

  var body: some View {
    Picker("Record", selection: Binding(get: { settings.captureWindowID }, set: { id in
      settings.captureWindowID = id
      settings.captureWindowLabel = list.windows.first { $0.id == id }?.label ?? ""
    })) {
      Text("Whole display").tag(0)
      if settings.captureWindowID != 0, !list.windows.contains(where: { $0.id == settings.captureWindowID }) {
        Text(settings.captureWindowLabel).tag(settings.captureWindowID)
      }
      ForEach(list.windows, id: \.id) { Text($0.label).tag($0.id) }
    }
    .onAppear { list.refresh() }
    .help("A single window records sharper and smaller than the whole display; clicks are measured inside it.")
  }
}

struct PublishView: View {
  @ObservedObject var project: ProjectModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Publish").font(.title2.bold())
        Spacer()
        if project.busy { ProgressView().controlSize(.small) }
        Text(project.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      TextField("Video title (used on thumbnails and in the description)", text: $project.publishTitle)
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("Make Captions, Chapters & Thumbnails", action: project.makePublishKit)
        Button("Draft YouTube Description with \(AISettings.shared.provider.shortName)", action: project.draftDescription)
        Spacer()
        Button("Show in Finder") {
          try? FileManager.default.createDirectory(at: project.publishDir, withIntermediateDirectories: true)
          NSWorkspace.shared.open(project.publishDir)
        }
      }
      .disabled(project.busy)

      let thumbs = project.publishFiles.filter { $0.pathExtension == "png" }
      if !thumbs.isEmpty {
        Text("Thumbnails: your clearest smiling camera frames, with the title in your profile's style").font(.headline)
        ScrollView(.horizontal) {
          HStack(spacing: 10) {
            ForEach(thumbs, id: \.self) { url in
              if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fit).frame(height: 150)
                  .clipShape(RoundedRectangle(cornerRadius: 8))
                  .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                  .help(url.lastPathComponent)
              }
            }
          }
        }
      }
      let other = project.publishFiles.filter { $0.pathExtension != "png" }
      if !other.isEmpty {
        Text("Files").font(.headline)
        ForEach(other, id: \.self) { url in
          HStack {
            Text(url.lastPathComponent).font(.system(.body, design: .monospaced))
            Spacer()
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString((try? String(contentsOf: url, encoding: .utf8)) ?? "", forType: .string)
            }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
        }
      }
      if !project.descriptionText.isEmpty {
        Text("Description draft").font(.headline)
        ScrollView {
          Text(project.descriptionText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 140)
      }
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button("Done") { project.showPublish = false }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 760, height: 620)
  }
}
