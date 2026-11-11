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
  let brollRecorder = BrollRecorder()
  /// The main window, once SwiftUI has made it.
  private(set) var window: NSWindow?
  /// Opens the main window when it's been closed (set from the commands, which have openWindow).
  var openMainWindow: (() -> Void)?
  private var cancellables: Set<AnyCancellable> = []

  override init() {
    super.init()
    AppDelegate.shared = self
  }

  /// Scans a finished export's pixels for shots under a second (the plan check misses some, like a
  /// punch-in sliver) and banners the first, with a button that seeks to it in the open project.
  /// The scan is nonisolated async work, so it runs off the main thread.
  @MainActor
  private func scanForShortShots(_ job: ExportQueue.Job) {
    Task { @MainActor [weak self] in
      let shots: [ShotScan.ShortShot]
      do {
        shots = try await ShotScan.shortShots(in: job.url)
      } catch {
        Notices.shared.show(error, "Couldn't check \(job.url.lastPathComponent) for short shots")
        return
      }
      guard let first = shots.first else { return }
      let more = shots.count > 1 ? " (\(shots.count) in all)" : ""
      Notices.shared.show("\(job.url.lastPathComponent) has a \(ShotScan.describe(first))\(more).", error: true, action: "Show") {
        guard let model = self?.library.current, model.dir.standardizedFileURL == job.projectDir.standardizedFileURL else { return }
        model.seek(outFrame: first.start * Double(model.fps))
      }
    }
  }

  /// Picks up settings changed outside the app (`director settings set`) each time it comes forward.
  func applicationDidBecomeActive(_ notification: Notification) {
    reloadSettings()
  }

  func reloadSettings() {
    let folder = settings.projectsFolder
    settings.reload()
    AISettings.shared.reload()
    SharingSettings.shared.reload()
    ProfileStore.shared.refresh()
    if settings.projectsFolder != folder { library.refresh() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      ExportQueue.shared.onFinished = { [weak self] job in
        NSWorkspace.shared.activateFileViewerSelecting([job.url])
        self?.scanForShortShots(job)
      }
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
  /// Also `open "screencastdirector://record/start"` and the other `AppURL` links.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first else { return }
    if url.scheme == AppURL.scheme {
      handle(url)
    } else if FileManager.default.fileExists(atPath: url.appendingPathComponent("source.json").path) {
      library.refresh()
      library.selection = url.standardizedFileURL
      window?.makeKeyAndOrderFront(nil)
    } else {
      importVideo(url)
    }
  }

  /// A `screencastdirector://` link: recording controls an agent can reach, since only the app records.
  private func handle(_ url: URL) {
    guard let command = AppURL.parse(url) else {
      showMain()
      Notices.shared.show("Unknown link \(url.absoluteString). Try \(AppURL.forms.map { "\(AppURL.scheme)://\($0)" }.joined(separator: ", ")).", error: true)
      return
    }
    // A link can arrive before the app comes forward; use the settings as they are now.
    reloadSettings()
    let recording = recorder.isRecording
    switch command {
    case .startRecording: startRecording()
    case .stopRecording where recording: stopRecording()
    case .pauseRecording: recorder.pause()
    case .resumeRecording: recorder.resume()
    case .restartRecording where recording: restartRecording()
    case .discardRecording where recording: discardRecording()
    case .markRetake: markRetake()
    case .stopRecording, .restartRecording, .discardRecording:
      Notices.shared.show("Nothing is recording (from \(url.absoluteString)).", error: true)
    case .open(let dir):
      guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("source.json").path) else {
        showMain()
        Notices.shared.show("No recording at \(dir.path).", error: true)
        return
      }
      // Opening a project builds its preview and renders its animations, and a link can come from a
      // web page: a folder outside the projects folder (one just downloaded, say) needs a yes first.
      if !PathSafety.url(dir, isInside: settings.projectsURL), !confirmOpen(dir) { return }
      library.refresh()
      library.selection = dir
      showMain()
    }
  }

  /// Asks before a link opens a project from outside the projects folder.
  private func confirmOpen(_ dir: URL) -> Bool {
    showMain()
    let alert = NSAlert()
    alert.messageText = "Open \(dir.lastPathComponent)?"
    alert.informativeText = "A link asked to open \(dir.path), which isn't in your projects folder. Opening it builds its preview and runs its animations. Open it only if you know where it came from."
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: Recording

  func toggleRecording() {
    if countdown.isRunning {
      countdown.cancel()
      RecordingStatus.post(.idle, message: "The countdown was cancelled.")
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
    RecordingStatus.post(.countdown)
    countdown.run(seconds: settings.countdown, on: screen) { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        do {
          try await self.recorder.start(in: self.settings.projectsURL, settings: self.settings)
          RecordingStatus.post(.recording, project: self.recorder.dir)
          if self.settings.showRecordingWidget { self.hud.show(on: screen) }
        } catch {
          self.showMain()
          let why =
            "Recording failed: \(error.localizedDescription) Check System Settings > Privacy & Security: Screen & System Audio Recording, Microphone, Camera and Input Monitoring."
          RecordingStatus.post(.failed, message: why)
          Notices.shared.show(why, error: true)
        }
      }
    }
  }

  func stopRecording(reason: String? = nil) {
    hud.hide()
    if recorder.isRecording { RecordingStatus.post(.saving, project: recorder.dir, message: reason) }
    Task { @MainActor in
      do {
        guard let dir = try await recorder.stop() else { return }
        RecordingStatus.post(.drafting, project: dir, message: reason)
        library.refresh()
        library.selection = dir
        showMain()
        if let reason { Notices.shared.show(reason, error: true) }
        library.current?.analyzeAndPlan { [weak self] in
          // Ready once it's drafted and named, so an agent never works on a folder about to move.
          let finish = {
            let drafted = FileManager.default.fileExists(atPath: dir.appendingPathComponent("plan.json").path)
            RecordingStatus.post(
              drafted ? .ready : .failed, keepingProjectOr: dir,
              message: drafted ? nil : "Saved, but the draft failed; the app shows why.")
          }
          guard let self, self.settings.autoName, dir.lastPathComponent.hasPrefix("Recording ") else { return finish() }
          self.library.suggestName(dir, autoApply: true, then: finish)
        }
      } catch {
        showMain()
        RecordingStatus.post(.failed, message: "Couldn't save the recording: \(error.localizedDescription)")
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
      RecordingStatus.post(.idle, message: "The recording was discarded (it's in the Trash).")
      showMain()
      Notices.shared.show("Recording discarded. It's in the Trash if you want it back.")
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
    let withCamera = NSButton(checkboxWithTitle: "I also have a camera video of this take", target: nil, action: nil)
    panel.accessoryView = withCamera
    panel.isAccessoryViewDisclosed = true
    let open: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      guard withCamera.state == .on else { self?.importVideo(url); return }
      // A second panel for the camera; the sheet has to close before the next one opens.
      DispatchQueue.main.async {
        let cam = NSOpenPanel()
        cam.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        cam.message = "Pick the camera video. Analysis lines it up with your voice."
        presentPanel(cam) { r in
          guard r == .OK, let camURL = cam.url else { return }
          self?.importVideo(url, camera: camURL)
        }
      }
    }
    presentPanel(panel, then: open)
  }

  func importVideo(_ url: URL, camera: URL? = nil) {
    Task { @MainActor in
      do {
        let dir = try await library.importVideo(url, camera: camera)
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
  var clickMonitor: Any?
  var shortcutsWindow: NSWindow?

  /// Editor shortcuts (Shortcuts.swift). Keys pass through while typing in a text field, in other
  /// windows, or with no project open; Space still plays when the focused field is empty (the
  /// Claude box keeps focus after an edit is sent).
  func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window, let project = self.library.current, project.hasPlan else { return event }
      if let text = event.window?.firstResponder as? NSText {
        let modified = !event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty
        guard shortcutTakesKeyInTextField(keyCode: event.keyCode, hasModifiers: modified, fieldText: text.string) else { return event }
      }
      guard let shortcut = Shortcut.all.first(where: { $0.matches(event) }) else { return event }
      shortcut.action(project, self.editor)
      return nil
    }
    // Clicking the preview, timeline or anything else that isn't text takes focus out of a text
    // field, so the shortcuts work again.
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      guard let self, let window = event.window, window === self.window, let text = window.firstResponder as? NSText else { return event }
      // A single-line field edits through a shared field editor whose delegate is the field itself.
      let field = (text.delegate as? NSView) ?? text
      if !field.convert(field.bounds, to: nil).contains(event.locationInWindow) { window.makeFirstResponder(nil) }
      return event
    }
  }

  var tourWindow: NSWindow?

  /// The bundled tour video, in its own window.
  func watchTour() {
    guard let url = Bundle.main.url(forResource: "tour", withExtension: "mp4") else {
      Notices.shared.show("The tour video is missing from the app. Reinstall it to watch the tour.", error: true)
      return
    }
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
