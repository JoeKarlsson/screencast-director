import AVKit
import AppKit
import SwiftUI

// View state lives in ObservableObjects: @State needs Swift macro plugins, which the
// Command Line Tools don't ship.

struct MainView: View {
  @ObservedObject var library: Library
  @ObservedObject var recorder: Recorder
  let toggleRecording: () -> Void
  let importVideo: () -> Void

  var body: some View {
    NavigationSplitView {
      List(selection: $library.selection) {
        ForEach(library.projects, id: \.self) { url in
          Text(url.lastPathComponent).tag(url as URL?)
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } detail: {
      if let project = library.current {
        ProjectView(project: project)
      } else {
        VStack(spacing: 12) {
          Text("Record your screen, then tell Claude how to edit it.").font(.title3)
          Text("⌃⌥⌘R starts and stops a recording from any app.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Button(action: importVideo) { Label("Import Video…", systemImage: "square.and.arrow.down") }
        Button(action: toggleRecording) {
          Label(recorder.isRecording ? "Stop" : "Record", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
        }
        .tint(.red)
      }
    }
  }
}

struct PlayerView: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let v = AVPlayerView()
    v.controlsStyle = .floating
    v.player = player
    return v
  }
  func updateNSView(_ v: AVPlayerView, context: Context) {
    if v.player !== player { v.player = player }
  }
}

struct ProjectView: View {
  @ObservedObject var project: ProjectModel

  var body: some View {
    VSplitView {
      PlayerView(player: project.player)
        .frame(minHeight: 280)
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(project.name).font(.headline)
          Spacer()
          Text(project.status).foregroundStyle(.secondary).lineLimit(1)
          Image(systemName: project.previewReady ? "play.circle" : "hourglass")
            .foregroundStyle(.secondary)
            .help(project.previewReady ? "Preview ready" : "Building preview")
            .accessibilityLabel(project.previewReady ? "Preview ready" : "Building preview")
          if project.busy { ProgressView().controlSize(.small) }
        }
        HStack {
          Button(project.hasPlan ? "Re-analyze" : "Analyze & Plan") { project.analyzeAndPlan() }
          Button("Reset Plan") { project.analyzeAndPlan(force: true) }.disabled(!project.hasPlan)
          Button("Export") { project.export() }.disabled(!project.hasPlan)
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.planURL]) }
        }
        .disabled(project.busy)
        HStack {
          TextField("Tell Claude how to edit: \"cut my retakes and zoom in when I mention the config\"", text: $project.instruction)
            .onSubmit { project.askClaude() }
          Button("Ask Claude") { project.askClaude() }
            .disabled(project.busy || !project.hasPlan || project.instruction.isEmpty)
        }
        if !project.claudeLog.isEmpty {
          ScrollView {
            Text(project.claudeLog).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 120)
        }
        ScrollView(.vertical) {
          Text(project.timeline).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
      }
      .padding(12)
      .frame(minHeight: 220)
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
      Toggle("Record camera", isOn: $settings.useCamera)
      Picker("Camera", selection: $settings.cameraID) {
        ForEach(AppSettings.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
      }
      .disabled(!settings.useCamera)
      Picker("Frame rate", selection: $settings.fps) {
        Text("30 fps").tag(30)
        Text("60 fps").tag(60)
      }
      LabeledContent("Projects folder") { Text(settings.projectsFolder).lineLimit(1).truncationMode(.middle) }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .padding()
  }
}
