import Foundation

/// Finds whisper-cli and a Whisper model. Also reuses models other apps on this Mac (Followspot, Screen Studio) have downloaded.
public enum Tools {
  static let home = FileManager.default.homeDirectoryForCurrentUser

  public static var modelsDir: URL {
    home.appendingPathComponent("Library/Application Support/Screencast Director/models")
  }

  /// Bundled next to the running binary (the app's Contents/Helpers or MacOS), else Homebrew.
  public static var whisperCLI: URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let candidates = [
      exe.appendingPathComponent("whisper-cli"),
      exe.deletingLastPathComponent().appendingPathComponent("Helpers/whisper-cli"),
      URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
      URL(fileURLWithPath: "/usr/local/bin/whisper-cli"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// Best installed model, most accurate first.
  public static var model: URL? {
    let dirs = [
      modelsDir,
      home.appendingPathComponent("Library/Application Support/Followspot/models"),
    ]
    let names = ["large-v3-turbo", "large-v3", "medium.en", "medium", "small.en", "small", "base.en"]
    for name in names {
      for dir in dirs {
        let url = dir.appendingPathComponent("ggml-\(name).bin")
        if FileManager.default.fileExists(atPath: url.path) { return url }
      }
    }
    let screenStudio = home.appendingPathComponent("Library/Application Support/Screen Studio/models/ggml-medium.bin")
    return FileManager.default.fileExists(atPath: screenStudio.path) ? screenStudio : nil
  }
}

/// analyze = transcript.json + motion.json, the inputs the planner needs.
public func analyze(_ dir: URL, log: @escaping (String) -> Void = { _ in }) async throws {
  let source = try JSONDecoder().decode(Project.Source.self, from: Data(contentsOf: dir.appendingPathComponent("source.json")))
  let video = dir.appendingPathComponent(source.video)
  let work = dir.appendingPathComponent(".render")
  try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

  let wav = work.appendingPathComponent("audio.wav")
  if try await Analyzer.extractAudio(video, to: wav) {
    guard let cli = Tools.whisperCLI, let model = Tools.model else { throw AnalyzerError.whisperMissing }
    log("Transcribing with \(model.lastPathComponent)...")
    try Analyzer.transcribe(wav: wav, whisperCLI: cli, model: model, to: dir.appendingPathComponent("transcript.json"))
  } else {
    log("No audio track; skipping transcription.")
    try #"{"segments": []}"#.write(to: dir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
  }
  log("Measuring screen motion...")
  let motion = try await Analyzer.measureMotion(video)
  try Analyzer.writeMotion(motion, to: dir.appendingPathComponent("motion.json"))
}
