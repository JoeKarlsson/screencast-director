import DirectorCore
import Foundation

/// Runs Claude Code headless (`claude -p`) in a project folder to edit its plan.json.
enum Claude {
  /// GUI apps don't get the shell's PATH, so ask a login shell where `claude` is, then try the
  /// installers' usual folders (a PATH set in .zshrc never reaches a non-interactive shell).
  static let executable: URL? = {
    loginShellClaude() ?? ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
      .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }()

  private static func loginShellClaude() -> URL? {
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
  }

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

  /// What a running edit reports: a step it's taking (tool use), or what it says.
  enum Event {
    case step(String)
    case text(String)
  }

  /// Turns one line of `--output-format stream-json` into events (none for lines it doesn't show).
  static func events(_ line: String, director: String) -> [Event] {
    guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      obj["type"] as? String == "assistant", let msg = obj["message"] as? [String: Any],
      let content = msg["content"] as? [[String: Any]]
    else { return [] }
    return content.compactMap { c in
      switch c["type"] as? String {
      case "text": return (c["text"] as? String).map { .text($0) }
      case "tool_use":
        let input = c["input"] as? [String: Any] ?? [:]
        switch c["name"] as? String {
        case "Read": return .step("Reading \(((input["file_path"] as? String) ?? "a file").split(separator: "/").last ?? "")")
        case "Edit": return .step("Editing the plan")
        case "Bash":
          let cmd = (input["command"] as? String ?? "").replacingOccurrences(of: director, with: "director")
          if cmd.contains("director describe") { return .step("Reading the timeline") }
          if cmd.contains("director review") { return .step("Reviewing zooms and cuts") }
          if cmd.contains("director still") {
            let frame = cmd.split(separator: " ").dropFirst(3).first.map(String.init) ?? ""
            return .step("Checking frame \(frame)")
          }
          let first = cmd.split(separator: "\n").first.map(String.init) ?? cmd
          return .step("Running \(first.prefix(48))")
        case let name?: return .step(name)
        case nil: return nil
        }
      default: return nil
      }
    }
  }

  /// How an edit ended: Claude Code's exit status and the end of what it wrote to stderr (why it
  /// stopped, when it fails before saying anything: not signed in, rate limited, a crash).
  struct Outcome {
    var status: Int32
    var errors: String
  }

  /// Claude processes still running, so quitting the app can stop them instead of leaving them
  /// editing a plan in the background.
  private static let running = RunningProcesses()

  static func stopAll() { running.terminateAll() }

  /// Runs the edit, reporting steps and text as it goes. Cancelling the calling task stops Claude.
  static func edit(project: URL, instruction: String, onEvent: @escaping @Sendable (Event) -> Void) async throws -> Outcome {
    guard let claude = executable else {
      throw NSError(
        domain: "Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude Code isn't installed (no `claude` on your PATH)."])
    }
    // Quoted, since the app's path has spaces. Claude quotes the path in the command it runs, and
    // the allow rules below match the command's text, so the rules and the prompt use this same form.
    let dir = "'\(director.path)'"
    let system = editPrompt.replacingOccurrences(of: "{{DIRECTOR}}", with: dir)
    let planURL = project.appendingPathComponent("plan.json")
    let before = try? Plan.load(planURL)
    let p = Process()
    p.executableURL = claude
    p.currentDirectoryURL = project
    // Read the project, edit only plan.json and run the three director commands. A recording
    // folder isn't trusted: no settings files load at all (a project's .claude/ hooks, and also the
    // user's own allow rules, which would let it run any command they allow), and Write and edits
    // to .claude/ are denied outright.
    p.arguments = [
      "-p", instruction,
      "--append-system-prompt", system,
      "--output-format", "stream-json", "--verbose",
      "--permission-mode", "acceptEdits",
      "--setting-sources", "",
      "--strict-mcp-config",
      "--tools", "Read,Edit,Bash",
      "--allowedTools", "Read(./**)", "Edit(./plan.json)",
      "Bash(\(dir) describe:*)", "Bash(\(dir) still:*)", "Bash(\(dir) review:*)",
      "--disallowedTools", "Write", "Edit(./.claude/**)", "Read(./.claude/**)", "WebFetch", "WebSearch",
    ]
    let pipe = Pipe()
    p.standardOutput = pipe
    let errPipe = Pipe()
    p.standardError = errPipe
    // stream-json is one JSON object per line; a read can end mid-line, so keep the remainder.
    let buffer = LineBuffer()
    pipe.fileHandleForReading.readabilityHandler = { h in
      let data = h.availableData
      guard !data.isEmpty else { return }
      for line in buffer.append(data) {
        for e in events(line, director: dir) { onEvent(e) }
      }
    }
    let errors = TailBuffer(limit: 4000)
    errPipe.fileHandleForReading.readabilityHandler = { h in errors.append(h.availableData) }
    // Watch for the exit before starting, so a Claude that exits at once is still noticed.
    let exited = ExitSignal()
    p.terminationHandler = { _ in exited.fire() }
    try p.run()
    running.add(p)
    defer { running.remove(p) }
    await withTaskCancellationHandler {
      await exited.wait()
    } onCancel: {
      p.terminate()
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    errors.append(errPipe.fileHandleForReading.readDataToEndOfFile())
    // Put back any file path Claude pointed outside the project (a prompt-injected transcript
    // could ask for that); the app's file poll then picks up the corrected plan.
    if let before, let after = try? Plan.load(planURL) {
      let (safe, reverted) = PathSafety.sanitize(after, previous: before, project: project)
      if !reverted.isEmpty, (try? safe.write(to: planURL)) != nil {
        onEvent(.text("Kept the previous \(reverted.joined(separator: ", ")): the edit pointed outside the project folder."))
      }
    }
    return Outcome(status: p.terminationStatus, errors: errors.text)
  }
}

/// Resumes its waiter once the process has exited, whether that happens before or after the wait.
final class ExitSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiter: CheckedContinuation<Void, Never>?

  func fire() {
    lock.lock()
    fired = true
    let w = waiter
    waiter = nil
    lock.unlock()
    w?.resume()
  }

  func wait() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      lock.lock()
      if fired {
        lock.unlock()
        c.resume()
      } else {
        waiter = c
        lock.unlock()
      }
    }
  }
}

/// The last `limit` bytes written, as text.
final class TailBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private let limit: Int
  init(limit: Int) { self.limit = limit }

  func append(_ d: Data) {
    lock.lock()
    data.append(d)
    if data.count > limit { data = data.suffix(limit) }
    lock.unlock()
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

final class RunningProcesses: @unchecked Sendable {
  private let lock = NSLock()
  private var all: [ObjectIdentifier: Process] = [:]

  func add(_ p: Process) {
    lock.lock()
    all[ObjectIdentifier(p)] = p
    lock.unlock()
  }

  func remove(_ p: Process) {
    lock.lock()
    all[ObjectIdentifier(p)] = nil
    lock.unlock()
  }

  func terminateAll() {
    lock.lock()
    let list = Array(all.values)
    lock.unlock()
    for p in list where p.isRunning { p.terminate() }
  }
}

/// Splits streamed bytes into complete lines.
final class LineBuffer: @unchecked Sendable {
  private var pending = Data()
  private let lock = NSLock()

  func append(_ data: Data) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    pending.append(data)
    var lines: [String] = []
    while let nl = pending.firstIndex(of: 0x0A) {
      lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
      pending.removeSubrange(pending.startIndex...nl)
    }
    return lines
  }
}
