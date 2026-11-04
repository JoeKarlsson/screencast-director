import Foundation

/// `screencastdirector://` links that drive the running app, for what only the app can do
/// (recording needs its screen capture and input tap). An agent runs
/// `open "screencastdirector://record/start"`. Everything else is a `director` command.
public enum AppURL: Equatable {
  case startRecording, stopRecording, pauseRecording, resumeRecording, restartRecording, discardRecording, markRetake
  /// Opens a project folder in the editor.
  case open(URL)

  public static let scheme = "screencastdirector"

  /// Every link, for help text and errors.
  public static let forms = [
    "record/start", "record/stop", "record/pause", "record/resume", "record/restart", "record/discard", "record/retake",
    "open?project=<folder>",
  ]

  /// The command a link names, or nil for one this app doesn't know.
  public static func parse(_ url: URL) -> AppURL? {
    guard url.scheme == scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let route = ([parts.host ?? ""] + parts.path.split(separator: "/").map(String.init)).filter { !$0.isEmpty }
    switch route {
    case ["record", "start"]: return .startRecording
    case ["record", "stop"]: return .stopRecording
    case ["record", "pause"]: return .pauseRecording
    case ["record", "resume"]: return .resumeRecording
    case ["record", "restart"]: return .restartRecording
    case ["record", "discard"]: return .discardRecording
    case ["record", "retake"]: return .markRetake
    case ["open"]:
      guard let path = parts.queryItems?.first(where: { $0.name == "project" })?.value, !path.isEmpty else { return nil }
      return .open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL)
    default: return nil
    }
  }
}
