import DirectorCore
import Foundation

/// Runs Claude Code headless (`claude -p`) in a project folder to edit its plan.json.
enum Claude {
  /// GUI apps don't get the shell's PATH, so ask a login shell where `claude` is.
  static let executable: URL? = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "command -v claude"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : URL(fileURLWithPath: path)
  }()

  /// The bundled `director` CLI (Contents/MacOS/director), or the one next to a `swift run` build.
  static var director: URL {
    Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("director")
  }

  static var editPrompt: String {
    if let url = Bundle.main.url(forResource: "edit-prompt", withExtension: "md"), let s = try? String(contentsOf: url, encoding: .utf8) {
      return s
    }
    // Debug builds run from macos/.build: read the source copy.
    let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/edit-prompt.md")
    return (try? String(contentsOf: src, encoding: .utf8)) ?? ""
  }

  /// Streams Claude's output lines to `onOutput`; returns the exit status.
  static func edit(project: URL, instruction: String, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int32 {
    guard let claude = executable else {
      throw NSError(
        domain: "Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude Code isn't installed (no `claude` on your PATH)."])
    }
    let dir = director.path
    let system = editPrompt.replacingOccurrences(of: "{{DIRECTOR}}", with: dir)
    let planURL = project.appendingPathComponent("plan.json")
    let before = try? Plan.load(planURL)
    let p = Process()
    p.executableURL = claude
    p.currentDirectoryURL = project
    // Read the project, edit only plan.json and run the three director commands. A recording
    // folder isn't trusted: its .claude/ settings and hooks are skipped (only user settings load),
    // and Write and edits to .claude/ are denied outright.
    p.arguments = [
      "-p", instruction,
      "--append-system-prompt", system,
      "--permission-mode", "acceptEdits",
      "--setting-sources", "user",
      "--strict-mcp-config",
      "--tools", "Read,Edit,Bash",
      "--allowedTools", "Read(./**)", "Edit(./plan.json)",
      "Bash(\(dir) describe:*)", "Bash(\(dir) still:*)", "Bash(\(dir) review:*)",
      "--disallowedTools", "Write", "Edit(./.claude/**)", "Read(./.claude/**)", "WebFetch", "WebSearch",
    ]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { h in
      let data = h.availableData
      if !data.isEmpty { onOutput(String(decoding: data, as: UTF8.self)) }
    }
    try p.run()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      p.terminationHandler = { _ in c.resume() }
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    // Put back any file path Claude pointed outside the project (a prompt-injected transcript
    // could ask for that); the app's file poll then picks up the corrected plan.
    if let before, let after = try? Plan.load(planURL) {
      let (safe, reverted) = PathSafety.sanitize(after, previous: before, project: project)
      if !reverted.isEmpty, (try? safe.write(to: planURL)) != nil {
        onOutput("\nKept the previous \(reverted.joined(separator: ", ")): the edit pointed outside the project folder.\n")
      }
    }
    return p.terminationStatus
  }
}
