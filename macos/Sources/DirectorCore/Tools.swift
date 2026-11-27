import Foundation

/// Finds whisper-cli and a Whisper model. Also reuses models other apps on this Mac (Followspot, Screen Studio) have downloaded.
public enum Tools: Sendable {
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

  /// Homebrew's ffmpeg, which masters every export's loudness (ExportLoudness) and turns GIFs and
  /// WebM stock clips into MP4 B-roll.
  public static var ffmpeg: URL? {
    ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// One command-line tool Setup checks for. `command` is what Copy Command copies when it's missing.
  public struct Check: Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let ok: Bool
    public let command: String
  }

  /// Setup's tool rows, all required: Whisper (whisper-cli and a model) and ffmpeg.
  public static func setupChecks(whisperCLI: URL?, model: URL?, ffmpeg: URL?) -> [Check] {
    let installWhisper = "brew install whisper-cpp"
    let modelPath = modelsDir.appendingPathComponent("ggml-large-v3-turbo.bin").path
    let downloadModel = "curl -L --create-dirs -o '\(modelPath)' https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    let installFFmpeg = "brew install ffmpeg"
    let whisperDetail: String
    if let whisperCLI, let model {
      whisperDetail = "\(model.lastPathComponent) via \(whisperCLI.path)"
    } else if whisperCLI == nil {
      whisperDetail = "Install whisper.cpp: \(installWhisper)"
    } else {
      whisperDetail = "No Whisper model found. Copy the command and run it in Terminal to download one (1.6 GB)."
    }
    return [
      Check(
        id: "whisper", title: "Transcription (Whisper)", detail: whisperDetail, ok: whisperCLI != nil && model != nil,
        command: whisperCLI == nil ? installWhisper : downloadModel),
      Check(
        id: "ffmpeg", title: "ffmpeg", detail: ffmpeg?.path ?? "Masters each export's loudness. Install it: \(installFFmpeg)",
        ok: ffmpeg != nil, command: installFFmpeg),
    ]
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
  let work = try PathSafety.ownedFolder(".render", in: dir)

  let wav = work.appendingPathComponent("audio.wav")
  let hasAudio = try await Analyzer.extractAudio(video, to: wav)
  if hasAudio {
    guard let cli = Tools.whisperCLI, let model = Tools.model else { throw AnalyzerError.whisperMissing }
    log("Transcribing with \(model.lastPathComponent)...")
    try Analyzer.transcribe(wav: wav, whisperCLI: cli, model: model, to: dir.appendingPathComponent("transcript.json"))
  } else {
    log("No audio track; skipping transcription.")
    try #"{"segments": []}"#.write(to: dir.appendingPathComponent("transcript.json"), atomically: true, encoding: .utf8)
  }
  // Loudness feeds pause trimming, normalizing and word-timing refinement; measure it fresh now.
  try? FileManager.default.removeItem(at: dir.appendingPathComponent("loudness.json"))
  // The music carve's voice bands come from the same audio.
  try? FileManager.default.removeItem(at: dir.appendingPathComponent(".render/carve-bands.json"))
  if hasAudio { _ = try await Analyzer.loudness(Project(dir: dir, source: source), video: source.video) }
  log("Measuring screen motion...")
  let motion = try await Analyzer.measureMotion(video)
  try SampleSeries.write(motion, to: dir.appendingPathComponent("motion.json"), decimals: 3)
  try await readScreenText(dir, log: log)
}

/// Reads the text around each click into screentext.json (see ScreenText).
public func readScreenText(_ dir: URL, log: @escaping (String) -> Void = { _ in }) async throws {
  let project = try Project.load(dir)
  guard !project.clicks.isEmpty else { return }
  log("Reading text on screen at \(project.clicks.count) clicks...")
  let samples = try await ScreenText.recognize(project)
  let enc = JSONEncoder()
  enc.outputFormatting = [.withoutEscapingSlashes]
  try enc.encode(samples).write(to: ScreenText.url(dir), options: .atomic)
}
