import AVFoundation
import Foundation

/// Recording preferences, stored in UserDefaults.
final class AppSettings: ObservableObject {
  private let d = UserDefaults.standard

  @Published var micID: String { didSet { d.set(micID, forKey: "micID") } }
  @Published var cameraID: String { didSet { d.set(cameraID, forKey: "cameraID") } }
  @Published var useCamera: Bool { didSet { d.set(useCamera, forKey: "useCamera") } }
  @Published var fps: Int { didSet { d.set(fps, forKey: "fps") } }
  @Published var projectsFolder: String { didSet { d.set(projectsFolder, forKey: "projectsFolder") } }

  init() {
    micID = d.string(forKey: "micID") ?? ""
    // Default to the first camera so the picker isn't blank (an external one if there is one).
    let cams = AppSettings.cameras
    cameraID = d.string(forKey: "cameraID") ?? (cams.first { $0.deviceType == .external } ?? cams.first)?.uniqueID ?? ""
    useCamera = d.bool(forKey: "useCamera")
    fps = d.object(forKey: "fps") as? Int ?? 30
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
}
