import AppKit
import SwiftUI

/// The app: the main window (library + editor), Settings, and the menu bar menu. AppDelegate
/// holds the models and does the recording; scenes and commands just call into it.
@main
struct ScreencastDirectorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var app

  var body: some Scene {
    Window("Screencast Director", id: "main") {
      MainView(app: app, library: app.library, recorder: app.recorder, setup: app.setup, editor: app.editor)
        .background(WindowAccessor { app.adopt($0) })
    }
    .defaultSize(width: 1440, height: 920)
    .commands { AppCommands(app: app, recorder: app.recorder, library: app.library, editor: app.editor) }

    Settings {
      SettingsView(settings: app.settings).tint(Theme.accent)
    }

    MenuBarExtra {
      StatusMenu(app: app, recorder: app.recorder, settings: app.settings, library: app.library)
    } label: {
      StatusLabel(recorder: app.recorder, clock: app.hud.model)
    }
  }
}

/// Hands the hosting NSWindow to AppDelegate once SwiftUI has put the view in it (and again if it
/// moves to a new one). Asking `view.window` right after making the view is too early.
struct WindowAccessor: NSViewRepresentable {
  let found: (NSWindow) -> Void

  final class Probe: NSView {
    var found: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { found?(window) }
    }
  }

  func makeNSView(context: Context) -> Probe {
    let v = Probe()
    v.found = found
    return v
  }
  func updateNSView(_ v: Probe, context: Context) { v.found = found }
}

struct AppCommands: Commands {
  let app: AppDelegate
  @ObservedObject var recorder: Recorder
  @ObservedObject var library: Library
  @ObservedObject var editor: EditorUI
  @Environment(\.openWindow) var openWindow

  var body: some Commands {
    let _ = app.openMainWindow = { openWindow(id: "main") }
    CommandGroup(replacing: .newItem) {
      Button("New Recording…") { app.showRecordSetup() }
        .keyboardShortcut("n")
        .disabled(recorder.isRecording)
      Button(recorder.isRecording ? "Stop Recording" : "Start Recording") { app.toggleRecording() }
        .keyboardShortcut("r", modifiers: [.control, .option, .command])
      Button(recorder.isPaused ? "Resume Recording" : "Pause Recording") {
        recorder.isPaused ? recorder.resume() : recorder.pause()
      }
      .disabled(!recorder.isRecording)
      Button("Mark Retake (cut the line I just said)") { app.markRetake() }
        .keyboardShortcut("m", modifiers: [.control, .option, .command])
        .disabled(!recorder.isRecording)
      Divider()
      Button("Import Video…") { app.importVideo() }.keyboardShortcut("i")
      Button("Join Recordings…") { library.promptJoin() }
      Button("Refresh Library") { library.refresh() }
    }
    CommandGroup(replacing: .undoRedo) {
      Button("Undo") { app.undoAction() }.keyboardShortcut("z")
      Button("Redo") { app.redoAction() }.keyboardShortcut("z", modifiers: [.command, .shift])
    }
    CommandGroup(after: .sidebar) {
      Picker("Sort Recordings By", selection: $library.sort) {
        ForEach(Library.Sort.allCases) { Text($0.label).tag($0) }
      }
      Button(editor.showInspector ? "Hide Inspector" : "Show Inspector") { withAnimation(.snappy) { editor.showInspector.toggle() } }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(library.current == nil)
    }
    CommandGroup(replacing: .help) {
      Button("Getting Started") { app.showSetup() }
      Button("Watch the Tour") { app.watchTour() }
      Button("Keyboard Shortcuts") { app.showShortcuts() }.keyboardShortcut("/")
      Divider()
      Link("Privacy", destination: URL(string: "https://github.com/JoeKarlsson/screencast-director/blob/main/docs/privacy.md")!)
    }
  }
}

/// The menu bar icon: a record button, or a red stop button with the clock while recording.
struct StatusLabel: View {
  @ObservedObject var recorder: Recorder
  @ObservedObject var clock: RecordingHUDModel

  var body: some View {
    if recorder.isRecording {
      Label(clockText(clock.elapsed), systemImage: recorder.isPaused ? "pause.circle.fill" : "stop.circle.fill")
        .labelStyle(.titleAndIcon)
        .monospacedDigit()
    } else {
      Image(systemName: "record.circle")
    }
  }
}

struct StatusMenu: View {
  let app: AppDelegate
  @ObservedObject var recorder: Recorder
  @ObservedObject var settings: AppSettings
  @ObservedObject var library: Library
  @Environment(\.openWindow) var openWindow

  var body: some View {
    if recorder.isRecording {
      Button("Stop Recording") { app.toggleRecording() }
        .keyboardShortcut("r", modifiers: [.control, .option, .command])
      Button(recorder.isPaused ? "Resume" : "Pause") { recorder.isPaused ? recorder.resume() : recorder.pause() }
      Button("Mark Retake") { app.markRetake() }
        .keyboardShortcut("m", modifiers: [.control, .option, .command])
      Divider()
      Button("Restart Recording") { app.restartRecording() }
      Button("Discard Recording") { app.discardRecording() }
    } else {
      Button("Start Recording") { app.toggleRecording() }
        .keyboardShortcut("r", modifiers: [.control, .option, .command])
      Button("New Recording…") { app.showRecordSetup() }
      Divider()
      Picker("Record", selection: Binding(get: { settings.captureWindowID == 0 ? settings.displayID : -1 }, set: { id in
        if id == -1 { app.showRecordSetup() } else {
          settings.captureWindowID = 0
          settings.displayID = id
        }
      })) {
        ForEach(DisplayChoice.all) { Text($0.name).tag($0.id) }
        if settings.captureWindowID != 0 { Text(settings.captureWindowLabel).tag(-1) } else { Text("A Window…").tag(-1) }
      }
      Picker("Microphone", selection: settings.micSelection) {
        Text("System Default").tag("")
        ForEach(AppSettings.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
      }
      Toggle("Record Camera", isOn: $settings.useCamera)
      Divider()
      let recent = Array(library.projects.prefix(5))
      if !recent.isEmpty {
        Section("Recent") {
          ForEach(recent, id: \.self) { url in
            Button(url.lastPathComponent) {
              library.selection = url
              app.showMain()
            }
          }
        }
        Divider()
      }
      Button("Open Screencast Director") {
        openWindow(id: "main")
        app.showMain()
      }
    }
    Divider()
    SettingsLink { Text("Settings…") }.keyboardShortcut(",")
    Button("Quit Screencast Director") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }
}
