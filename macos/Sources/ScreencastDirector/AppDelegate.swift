import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
  let settings = AppSettings()
  lazy var library = Library(settings: settings)
  let recorder = Recorder()
  let hotKeys = HotKeys()
  let setup = SetupModel()
  let editor = EditorUI()
  var window: NSWindow!
  var settingsWindow: NSWindow?
  var statusItem: NSStatusItem!
  var timer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenu()
    let view = MainView(
      library: library, recorder: recorder, setup: setup, editor: editor,
      toggleRecording: { [weak self] in self?.toggleRecording() },
      importVideo: { [weak self] in self?.importVideo() })
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 920), styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Screencast Director"
    window.contentView = NSHostingView(rootView: view)
    window.setFrameAutosaveName("Main")
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
    statusItem.button?.target = self
    statusItem.button?.action = #selector(toggleRecordingAction)

    installKeyMonitor()
    hotKeys.onToggle = { [weak self] in self?.toggleRecording() }
    hotKeys.register()
    NSApp.activate()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    window.makeKeyAndOrderFront(nil)
    return true
  }

  /// `open -a "Screencast Director" <project folder or video>`, or a drop on the Dock icon.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first else { return }
    if FileManager.default.fileExists(atPath: url.appendingPathComponent("source.json").path) {
      library.refresh()
      library.selection = url.standardizedFileURL
      window?.makeKeyAndOrderFront(nil)
    } else {
      Task { @MainActor in
        do {
          let dir = try await library.importVideo(url)
          library.refresh()
          library.selection = dir
          library.current?.analyzeAndPlan()
        } catch {
          NSAlert(error: error).runModal()
        }
      }
    }
  }

  @objc func toggleRecordingAction() { toggleRecording() }

  func toggleRecording() {
    Task { @MainActor in
      do {
        if recorder.isRecording {
          timer?.invalidate()
          statusItem.button?.title = ""
          statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
          guard let dir = try await recorder.stop() else { return }
          library.refresh()
          library.selection = dir
          window.makeKeyAndOrderFront(nil)
          NSApp.activate()
          library.current?.analyzeAndPlan()
        } else {
          try await recorder.start(in: settings.projectsURL, settings: settings)
          statusItem.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")
          timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recorder.startedAt else { return }
            let s = Int(Date().timeIntervalSince(start))
            self.statusItem.button?.title = String(format: " %d:%02d", s / 60, s % 60)
          }
          // Get out of the way of what's being recorded.
          window.orderOut(nil)
        }
      } catch {
        let alert = NSAlert(error: error)
        alert.messageText = "Recording failed"
        alert.informativeText =
          "\(error.localizedDescription)\n\nCheck System Settings > Privacy & Security: Screen & System Audio Recording, Microphone, Camera and Input Monitoring."
        alert.runModal()
      }
    }
  }

  func importVideo() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { @MainActor in
      do {
        let dir = try await library.importVideo(url)
        library.refresh()
        library.selection = dir
        library.current?.analyzeAndPlan()
      } catch {
        NSAlert(error: error).runModal()
      }
    }
  }

  @objc func showSettings() {
    if settingsWindow == nil {
      let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      w.title = "Settings"
      w.contentView = NSHostingView(rootView: SettingsView(settings: settings))
      w.isReleasedWhenClosed = false
      settingsWindow = w
    }
    settingsWindow?.center()
    settingsWindow?.makeKeyAndOrderFront(nil)
  }

  @objc func importAction() { importVideo() }

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

  @objc func showShortcuts() {
    if shortcutsWindow == nil {
      let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
      w.title = "Keyboard Shortcuts"
      w.contentView = NSHostingView(rootView: ShortcutsView())
      w.isReleasedWhenClosed = false
      shortcutsWindow = w
    }
    shortcutsWindow?.center()
    shortcutsWindow?.makeKeyAndOrderFront(nil)
  }

  /// Text fields keep their own undo; otherwise ⌘Z undoes plan edits (including Claude's).
  @objc func undoAction() {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canUndo == true {
      text.undoManager?.undo()
    } else {
      library.current?.undo()
    }
  }

  @objc func redoAction() {
    if let text = NSApp.keyWindow?.firstResponder as? NSTextView, text.undoManager?.canRedo == true {
      text.undoManager?.redo()
    } else {
      library.current?.redo()
    }
  }

  @objc func showSetup() {
    library.selection = nil
    setup.refresh()
    window.makeKeyAndOrderFront(nil)
  }
  @objc func refreshAction() { library.refresh() }

  private func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Screencast Director", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let rec = fileMenu.addItem(withTitle: "Start/Stop Recording", action: #selector(toggleRecordingAction), keyEquivalent: "r")
    rec.keyEquivalentModifierMask = [.control, .option, .command]
    rec.target = self
    fileMenu.addItem(withTitle: "Import Video…", action: #selector(importAction), keyEquivalent: "i").target = self
    fileMenu.addItem(withTitle: "Refresh Library", action: #selector(refreshAction), keyEquivalent: "").target = self
    fileMenu.addItem(.separator())
    fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    main.addItem(fileItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: #selector(undoAction), keyEquivalent: "z").target = self
    let redo = editMenu.addItem(withTitle: "Redo", action: #selector(redoAction), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    redo.target = self
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    main.addItem(editItem)
    let helpItem = NSMenuItem()
    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(withTitle: "Getting Started", action: #selector(showSetup), keyEquivalent: "").target = self
    helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts), keyEquivalent: "/").target = self
    helpItem.submenu = helpMenu
    main.addItem(helpItem)
    NSApp.mainMenu = main
  }
}
