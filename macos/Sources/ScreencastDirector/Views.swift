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
      Button(project.hasPlan ? "Export" : "Analyze") {
        if project.hasPlan { project.export() } else { project.analyzeAndPlan() }
      }
      .buttonStyle(.borderedProminent)
      .disabled(project.busy)
    }
  }

  private var claudeBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Image(systemName: "sparkles").foregroundStyle(.orange)
        TextField("Ask Claude to edit: \"cut my retakes, zoom in when I mention the config, side-by-side for the intro\"", text: $project.instruction)
          .textFieldStyle(.roundedBorder)
          .onSubmit(project.askClaude)
        Button("Ask Claude", action: project.askClaude)
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

  var body: some View {
    Form {
      Picker("Microphone", selection: $settings.micID) {
        Text("System default").tag("")
        ForEach(AppSettings.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
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
    .frame(width: 520)
    .padding()
  }
}
