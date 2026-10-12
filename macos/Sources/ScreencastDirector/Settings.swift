import AVFoundation
import AppKit
import SwiftUI
import DirectorCore
import Foundation

/// Recording preferences, stored in UserDefaults.
final class AppSettings: ObservableObject {
  private let d = UserDefaults.standard

  @Published var micID: String { didSet { d.set(micID, forKey: "micID") } }
  @Published var cameraID: String { didSet { d.set(cameraID, forKey: "cameraID") } }
  @Published var useCamera: Bool { didSet { d.set(useCamera, forKey: "useCamera") } }
  @Published var fps: Int { didSet { d.set(fps, forKey: "fps") } }
  @Published var projectsFolder: String { didSet { d.set(projectsFolder, forKey: "projectsFolder") } }
  /// Off by default: this app's windows stay out of recordings. Turn on to record a tour of the app itself.
  @Published var showSelfInRecordings: Bool { didSet { d.set(showSelfInRecordings, forKey: "showSelfInRecordings") } }
  /// 0 records the whole display; otherwise the ScreenCaptureKit window ID to record.
  @Published var captureWindowID: Int { didSet { d.set(captureWindowID, forKey: "captureWindowID") } }
  /// "App: window title", for messages when the window has closed.
  @Published var captureWindowLabel: String { didSet { d.set(captureWindowLabel, forKey: "captureWindowLabel") } }
  @Published var pauseLevel: PauseLevel { didSet { d.set(pauseLevel.rawValue, forKey: "pauseLevel") } }
  @Published var autoName: Bool { didSet { d.set(autoName, forKey: "autoName") } }
  @Published var smoothCursor: Bool { didSet { d.set(smoothCursor, forKey: "smoothCursor") } }
  /// The display to record when not recording a window; 0 is the main display.
  @Published var displayID: Int { didSet { d.set(displayID, forKey: "displayID") } }
  /// Seconds of 3-2-1 before recording starts; 0 starts right away.
  @Published var countdown: Int { didSet { d.set(countdown, forKey: "countdown") } }
  /// The floating widget with the clock, mic level and controls while recording.
  @Published var showRecordingWidget: Bool { didSet { d.set(showRecordingWidget, forKey: "showRecordingWidget") } }
  static let shared = AppSettings()

  init() {
    micID = d.string(forKey: "micID") ?? ""
    // Default to the first camera so the picker isn't blank (an external one if there is one).
    let cams = AppSettings.cameras
    cameraID = d.string(forKey: "cameraID") ?? (cams.first { $0.deviceType == .external } ?? cams.first)?.uniqueID ?? ""
    useCamera = d.bool(forKey: "useCamera")
    fps = d.object(forKey: "fps") as? Int ?? 30
    showSelfInRecordings = d.bool(forKey: "showSelfInRecordings")
    // Window IDs don't survive a relaunch of the recorded app, so start each session on the display.
    captureWindowID = 0
    captureWindowLabel = ""
    pauseLevel = PauseLevel(rawValue: d.string(forKey: "pauseLevel") ?? "") ?? .normal
    autoName = d.object(forKey: "autoName") as? Bool ?? true
    smoothCursor = d.object(forKey: "smoothCursor") as? Bool ?? true
    displayID = d.integer(forKey: "displayID")
    countdown = d.object(forKey: "countdown") as? Int ?? 3
    showRecordingWidget = d.object(forKey: "showRecordingWidget") as? Bool ?? true
    projectsFolder =
      d.string(forKey: "projectsFolder")
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Screencast Director").path
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
