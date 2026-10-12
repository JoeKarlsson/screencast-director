import AVFoundation
import AppKit
import DirectorCore
import Foundation

/// The projects folder: one subfolder per recording.
final class Library: ObservableObject {
  @Published private(set) var projects: [URL] = []
  @Published var selection: URL? {
    didSet { if selection != oldValue { open(selection) } }
  }
  @Published private(set) var current: ProjectModel?

  let settings: AppSettings

  init(settings: AppSettings) {
    self.settings = settings
    refresh()
  }

  func refresh() {
    let root = settings.projectsURL
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
    projects =
      dirs
      .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("source.json").path) }
      .sorted {
        let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return a > b
      }
  }

  private func open(_ url: URL?) {
    current?.close()
    current = url.map { ProjectModel(dir: $0) }
  }

  /// Copies a video in as a new project (no input log, so zooms come from Claude, not clicks).
  func importVideo(_ video: URL) async throws -> URL {
    let dir = settings.projectsURL.appendingPathComponent(video.deletingPathExtension().lastPathComponent)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = "screen." + video.pathExtension.lowercased()
    try FileManager.default.copyItem(at: video, to: dir.appendingPathComponent(name))
    let asset = AVURLAsset(url: dir.appendingPathComponent(name))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CompositionError.noVideo(name) }
    let size = try await track.load(.naturalSize)
    let source = Project.Source(
      video: name, width: size.width, height: size.height, duration: try await asset.load(.duration).seconds, captureStart: nil, camera: nil)
    try JSONEncoder().encode(source).write(to: dir.appendingPathComponent("source.json"))
    return dir
  }
}
