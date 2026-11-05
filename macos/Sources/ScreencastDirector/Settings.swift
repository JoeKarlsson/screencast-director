import AVFoundation
import AppKit
import SwiftUI
import DirectorCore
import Foundation

/// Sets a published setting only when the saved value differs, so a reload doesn't redraw views
/// or move a picker that didn't change.
func syncSetting<O: AnyObject, T: Equatable>(_ object: O, _ key: ReferenceWritableKeyPath<O, T>, _ value: T) {
  if object[keyPath: key] != value { object[keyPath: key] = value }
}

/// Recording preferences, stored in UserDefaults.
final class AppSettings: ObservableObject {
  private let d = UserDefaults.standard

  @Published var micID: String { didSet { if !loading { d.set(micID, forKey: "micID") } } }
  @Published var cameraID: String { didSet { if !loading { d.set(cameraID, forKey: "cameraID") } } }
  @Published var useCamera: Bool { didSet { if !loading { d.set(useCamera, forKey: "useCamera") } } }
  @Published var fps: Int { didSet { if !loading { d.set(fps, forKey: "fps") } } }
  @Published var projectsFolder: String { didSet { if !loading { d.set(projectsFolder, forKey: "projectsFolder") } } }
  /// Off by default: this app's windows stay out of recordings. Turn on to record a tour of the app itself.
  @Published var showSelfInRecordings: Bool { didSet { if !loading { d.set(showSelfInRecordings, forKey: "showSelfInRecordings") } } }
  /// 0 records the whole display; otherwise the ScreenCaptureKit window ID to record.
  @Published var captureWindowID: Int { didSet { if !loading { d.set(captureWindowID, forKey: "captureWindowID") } } }
  /// "App: window title", for messages when the window has closed.
  @Published var captureWindowLabel: String { didSet { if !loading { d.set(captureWindowLabel, forKey: "captureWindowLabel") } } }
  @Published var pauseLevel: PauseLevel { didSet { if !loading { d.set(pauseLevel.rawValue, forKey: "pauseLevel") } } }
  /// New recordings start with Normalize voice and Warm voice on.
  @Published var polishVoice: Bool { didSet { if !loading { d.set(polishVoice, forKey: "polishVoice") } } }
  @Published var autoName: Bool { didSet { if !loading { d.set(autoName, forKey: "autoName") } } }
  @Published var smoothCursor: Bool { didSet { if !loading { d.set(smoothCursor, forKey: "smoothCursor") } } }
  /// The display to record when not recording a window; 0 is the main display.
  @Published var displayID: Int { didSet { if !loading { d.set(displayID, forKey: "displayID") } } }
  /// Seconds of 3-2-1 before recording starts; 0 starts right away.
  @Published var countdown: Int { didSet { if !loading { d.set(countdown, forKey: "countdown") } } }
  /// The floating widget with the clock, mic level and controls while recording.
  @Published var showRecordingWidget: Bool { didSet { if !loading { d.set(showRecordingWidget, forKey: "showRecordingWidget") } } }
  /// How loud the editor's preview plays (0...1), and whether it's muted. Exports aren't affected.
  @Published var previewVolume: Float { didSet { if !loading { d.set(previewVolume, forKey: "previewVolume") } } }
  @Published var previewMuted: Bool { didSet { if !loading { d.set(previewMuted, forKey: "previewMuted") } } }
  static let shared = AppSettings()
  /// Set while `reload` reads the saved values, so reading them doesn't write them back.
  private var loading = false

  init() {
    micID = ""
    cameraID = ""
    useCamera = false
    fps = 30
    showSelfInRecordings = false
    // Window IDs don't survive a relaunch of the recorded app, so start each session on the display.
    captureWindowID = 0
    captureWindowLabel = ""
    pauseLevel = .normal
    polishVoice = false
    autoName = true
    smoothCursor = true
    displayID = 0
    countdown = 3
    showRecordingWidget = true
    previewVolume = 1
    previewMuted = false
    projectsFolder = ""
    reload()
  }

  /// Reads the saved settings again: at launch, and whenever the app comes to the front, so a
  /// change from `director settings set` takes effect without a restart.
  func reload() {
    loading = true
    defer { loading = false }
    func sync<T: Equatable>(_ key: ReferenceWritableKeyPath<AppSettings, T>, _ value: T) { syncSetting(self, key, value) }
    sync(\.micID, d.string(forKey: "micID") ?? "")
    // Default to the first camera so the picker isn't blank (an external one if there is one).
    sync(\.cameraID, d.string(forKey: "cameraID") ?? {
      let cams = AppSettings.cameras
      return (cams.first { $0.deviceType == .external } ?? cams.first)?.uniqueID ?? ""
    }())
    sync(\.useCamera, d.bool(forKey: "useCamera"))
    sync(\.fps, d.object(forKey: "fps") as? Int ?? 30)
    sync(\.showSelfInRecordings, d.bool(forKey: "showSelfInRecordings"))
    sync(\.pauseLevel, PauseLevel(rawValue: d.string(forKey: "pauseLevel") ?? "") ?? .normal)
    sync(\.polishVoice, d.bool(forKey: "polishVoice"))
    sync(\.autoName, d.object(forKey: "autoName") as? Bool ?? true)
    sync(\.smoothCursor, d.object(forKey: "smoothCursor") as? Bool ?? true)
    sync(\.displayID, d.integer(forKey: "displayID"))
    sync(\.countdown, d.object(forKey: "countdown") as? Int ?? 3)
    sync(\.showRecordingWidget, d.object(forKey: "showRecordingWidget") as? Bool ?? true)
    sync(\.previewVolume, d.object(forKey: "previewVolume") as? Float ?? 1)
    sync(\.previewMuted, d.bool(forKey: "previewMuted"))
    sync(
      \.projectsFolder,
      d.string(forKey: "projectsFolder")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Screencast Director").path)
  }

  var projectsURL: URL { URL(fileURLWithPath: projectsFolder) }

  static var microphones: [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
  }

  static var cameras: [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
    ).devices
  }

  var cameraDevice: AVCaptureDevice? {
    AppSettings.cameras.first { $0.uniqueID == cameraID } ?? AppSettings.cameras.first
  }

  /// The camera pickers' selection: the camera a recording would use. When the saved camera isn't
  /// connected that's the fallback, so the picker never shows blank; the saved choice is kept, so
  /// plugging that camera back in picks it again.
  var cameraSelection: Binding<String> {
    Binding(get: { self.cameraDevice?.uniqueID ?? "" }, set: { self.cameraID = $0 })
  }

  /// The mic a recording uses: the picked one if it's connected, otherwise the system default.
  var microphoneDevice: AVCaptureDevice? {
    AppSettings.microphones.first { $0.uniqueID == micID } ?? AVCaptureDevice.default(for: .audio)
  }

  /// The screen being recorded: the picked display, or the one holding the picked window.
  var recordedScreen: NSScreen? {
    let id = displayID != 0 ? CGDirectDisplayID(displayID) : CGMainDisplayID()
    return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
      ?? NSScreen.main
  }

  /// The mic picker's selection: "" (system default) when the saved mic isn't connected, so the
  /// picker never shows blank.
  var micSelection: Binding<String> {
    Binding(
      get: { AppSettings.microphones.contains { $0.uniqueID == self.micID } ? self.micID : "" },
      set: { self.micID = $0 })
  }
}
