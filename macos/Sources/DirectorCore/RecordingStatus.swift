import Foundation

/// What the app's recorder is doing, written to <support folder>/recording.json at each step so an
/// agent that started a recording with a `screencastdirector://` link can tell whether it started,
/// and when the new recording is saved and drafted (`director status`).
public struct RecordingStatus: Codable, Equatable {
  public enum State: String, Codable, CaseIterable {
    /// Nothing recording (the last one was discarded, or none yet).
    case idle
    case countdown, recording, paused
    /// Stopped; the files are being finished.
    case saving
    /// Saved; the app is transcribing and drafting it.
    case drafting
    /// Drafted: `project` is ready to edit.
    case ready
    /// It didn't start or didn't save; `message` says why.
    case failed
  }

  public var state: State
  /// The recording's folder, once there is one.
  public var project: String?
  public var message: String?
  /// The app's process, so a status left by an app that quit or crashed can be told apart.
  public var pid: Int32
  public var updated: Date

  public init(state: State, project: URL? = nil, message: String? = nil, pid: Int32 = getpid(), updated: Date = Date()) {
    self.state = state
    self.project = project?.standardizedFileURL.path
    self.message = message
    self.pid = pid
    self.updated = updated
  }

  public static var file: URL { AppPreferences.supportFolder.appendingPathComponent("recording.json") }

  public func write(to url: URL = RecordingStatus.file) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    try enc.encode(self).write(to: url, options: .atomic)
  }

  /// The last status the app wrote, or nil when it never wrote one.
  public static func read(from url: URL = RecordingStatus.file) throws -> RecordingStatus? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try dec.decode(RecordingStatus.self, from: Data(contentsOf: url))
  }

  /// Follows a recording's folder to its new name, when the status names it (the app names new
  /// recordings after drafting them).
  public static func projectMoved(from old: URL, to new: URL, file: URL = RecordingStatus.file) throws {
    guard var status = try read(from: file), status.project == old.standardizedFileURL.path else { return }
    status.project = new.standardizedFileURL.path
    status.updated = Date()
    try status.write(to: file)
  }

  /// Whether the app that wrote this is still running.
  public var appRunning: Bool { kill(pid, 0) == 0 }

  /// A status that can't change any more because the app that wrote it is gone mid-recording.
  public var abandoned: Bool { !appRunning && [.countdown, .recording, .paused, .saving, .drafting].contains(state) }
}
