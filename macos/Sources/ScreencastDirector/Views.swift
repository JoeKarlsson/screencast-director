import AVKit
import AppKit
import DirectorCore
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

  var body: some View {
    NavigationSplitView {
      List(selection: $library.selection) {
        Section("Recordings") {
          ForEach(library.projects, id: \.self) { url in
            Label(url.lastPathComponent, systemImage: "film").tag(url as URL?)
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
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
        SetupView(setup: setup, record: toggleRecording, importVideo: importVideo)
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
        } label: {
          Text("Export")
        } primaryAction: {
          project.export()
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .disabled(project.busy)
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
        HStack {
          Button("Test") {
            ui.testResult = "Testing…"
            Task { @MainActor in ui.testResult = await APIEditor.test(ai) }
          }
          Text(ui.testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
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
