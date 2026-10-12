import AVKit
import AppKit
import Combine
import DirectorCore
import SwiftUI
import UniformTypeIdentifiers

/// Holds the models and runs recording: countdown, the floating widget, stop, restart, discard.
/// The SwiftUI scenes in App.swift call into it.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  /// NSApp.delegate is SwiftUI's own object, so views and helpers reach this one here.
  nonisolated(unsafe) static weak var shared: AppDelegate?

  let settings = AppSettings.shared
  lazy var library = Library(settings: settings)
  let recorder = Recorder()
  let hotKeys = HotKeys()
  let setup = SetupModel()
  let editor = EditorUI()
  lazy var hud = RecordingHUD(recorder: recorder)
  let countdown = Countdown()
  let recordSetup = RecordSetup()
  /// The main window, once SwiftUI has made it.
  private(set) var window: NSWindow?
  /// Opens the main window when it's been closed (set from the commands, which have openWindow).
  var openMainWindow: (() -> Void)?
  private var cancellables: Set<AnyCancellable> = []

  override init() {
    super.init()
    AppDelegate.shared = self
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      ExportQueue.shared.onFinished = { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) }
    }
    installKeyMonitor()
    hotKeys.onToggle = { [weak self] in self?.toggleRecording() }
    hotKeys.onRetake = { [weak self] in self?.markRetake() }
    hotKeys.register()
    hud.model.onStop = { [weak self] in self?.toggleRecording() }
    hud.model.onRestart = { [weak self] in self?.restartRecording() }
    hud.model.onDiscard = { [weak self] in self?.discardRecording() }
    recordSetup.onStart = { [weak self] in self?.startRecording() }
    // ScreenCaptureKit stopped the stream on its own: keep what was recorded and say why.
    recorder.$lastError.compactMap { $0 }.receive(on: DispatchQueue.main).sink { [weak self] message in
      guard let self, self.recorder.isRecording else { return }
      self.stopRecording(reason: "Recording stopped: \(message). What was recorded until then is saved.")
    }
    .store(in: &cancellables)
    // `-openProject <folder>` opens a project at launch (macos/smoke-test.sh uses it, along with
    // `-projectsFolder <folder>` so a test run never sees the real library).
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-openProject"), i + 1 < args.count {
      application(NSApp, open: [URL(fileURLWithPath: args[i + 1])])
    }
  }

  /// Called each time the window's view appears in it.
  func adopt(_ w: NSWindow) {
    guard window !== w else { return }
    window = w
    w.isReleasedWhenClosed = false
    w.titlebarSeparatorStyle = .automatic
    w.toolbarStyle = .unified
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showMain() }
    return true
  }

  func showMain() {
    if let window, window.contentView != nil {
      window.makeKeyAndOrderFront(nil)
    } else {
      openMainWindow?()
    }
    NSApp.activate()
  }

  /// `open -a "Screencast Director" <project folder or video>`, or a drop on the Dock icon.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first else { return }
    if FileManager.default.fileExists(atPath: url.appendingPathComponent("source.json").path) {
      library.refresh()
      library.selection = url.standardizedFileURL
      window?.makeKeyAndOrderFront(nil)
    } else {
      importVideo(url)
    }
  }

  // MARK: Recording

  func toggleRecording() {
    if countdown.isRunning {
      countdown.cancel()
      showMain()
    } else if recorder.isRecording {
      stopRecording()
    } else {
      startRecording()
    }
  }

  func showRecordSetup() {
    guard !recorder.isRecording, !countdown.isRunning else { return }
    recordSetup.show(settings: settings)
  }

  /// Gets the window out of the way (unless the app itself is being recorded), counts down, records.
  func startRecording() {
    guard !recorder.isRecording, !countdown.isRunning else { return }
    recordSetup.close()
    if !settings.showSelfInRecordings { window?.orderOut(nil) }
    let screen = settings.recordedScreen
    countdown.run(seconds: settings.countdown, on: screen) { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        do {
          try await self.recorder.start(in: self.settings.projectsURL, settings: self.settings)
          if self.settings.showRecordingWidget { self.hud.show(on: screen) }
        } catch {
          self.showMain()
          Notices.shared.show(
            "Recording failed: \(error.localizedDescription) Check System Settings > Privacy & Security: Screen & System Audio Recording, Microphone, Camera and Input Monitoring.",
            error: true)
        }
      }
    }
  }

  func stopRecording(reason: String? = nil) {
    hud.hide()
    Task { @MainActor in
      do {
        guard let dir = try await recorder.stop() else { return }
        library.refresh()
        library.selection = dir
        showMain()
        if let reason { Notices.shared.show(reason, error: true) }
        library.current?.analyzeAndPlan { [weak self] in
          guard let self, self.settings.autoName, dir.lastPathComponent.hasPrefix("Recording ") else { return }
          self.library.suggestName(dir, autoApply: true)
        }
      } catch {
        showMain()
        Notices.shared.show(error, "Couldn't save the recording")
      }
    }
  }

  /// Throws the take away and starts over, with the countdown.
  func restartRecording() {
    hud.hide()
    Task { @MainActor in
      await recorder.cancel()
      startRecording()
    }
  }

  func discardRecording() {
    hud.hide()
    Task { @MainActor in
      await recorder.cancel()
      showMain()
      Notices.shared.show("Recording discarded.")
    }
  }

  /// ⌃⌥⌘M while recording: the phrase you just said gets cut from the draft; say it again after.
  func markRetake() {
    recorder.markRetake()
  }

  // MARK: Import

  func importVideo() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
    panel.message = "Pick a screen recording to edit. It's copied into your recordings folder."
    let open: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.importVideo(url)
    }
    if let window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: open) } else { open(panel.runModal()) }
  }

  func importVideo(_ url: URL) {
    Task { @MainActor in
      do {
        let dir = try await library.importVideo(url)
        library.refresh()
        library.selection = dir
        library.current?.analyzeAndPlan()
      } catch {
        Notices.shared.show(error, "Couldn't import \(url.lastPathComponent)")
      }
    }
  }

  // MARK: Editor keys and menus

  var keyMonitor: Any?
  var shortcutsWindow: NSWindow?

  /// Editor shortcuts (Shortcuts.swift). Keys pass through while typing in a text field, in other
  /// windows, or with no project open.
  func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window, let project = self.library.current, project.hasPlan else { return event }
      if event.window?.firstResponder is NSText { return event }
      guard let shortcut = Shortcut.all.first(where: { $0.matches(event) }) else { return event }
      shortcut.action(project, self.editor)
      return nil
    }
  }

  var tourWindow: NSWindow?

  /// The bundled tour video, in its own window.
  func watchTour() {
    guard let url = Bundle.main.url(forResource: "tour", withExtension: "mp4") else { return }
    let w = tourWindow ?? NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    w.title = "Screencast Director Tour"
    w.titlebarAppearsTransparent = true
    let view = AVPlayerView()
    view.player = AVPlayer(url: url)
    view.controlsStyle = .floating
    w.contentView = view
    w.isReleasedWhenClosed = false
    w.contentAspectRatio = NSSize(width: 16, height: 9)
    tourWindow = w
    w.center()
    w.makeKeyAndOrderFront(nil)
    view.player?.play()
  }

  func showShortcuts() {
    if shortcutsWindow == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      w.title = "Keyboard Shortcuts"
      w.contentView = NSHostingView(rootView: ShortcutsView())
      w.isReleasedWhenClosed = false
      shortcutsWindow = w
    }
    shortcutsWindow?.center()
    shortcutsWindow?.makeKeyAndOrderFront(nil)
  }

  /// Text fields keep their own undo; otherwise ⌘Z undoes plan edits (including Claude's).
  func undoAction() {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
      text.undoManager?.undo()
    } else {
      library.current?.undo()
    }
  }

  func redoAction() {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true {
      text.undoManager?.redo()
    } else {
      library.current?.redo()
    }
  }

  func showSetup() {
    library.selection = nil
    setup.refresh()
    showMain()
  }
}
