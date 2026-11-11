import Foundation

// How the app's Claude box runs Claude Code: its `claude -p` arguments and the session it resumes,
// here so test.sh checks them (the app runs the process, in ScreencastDirector/Claude.swift).
public enum ClaudeEdit {
  /// The director commands the edit may run (allow-rule patterns after the director's path): the ones
  /// that check the edit, and the ones that write only this project's plan (profile, template
  /// freeze/update, which copy from the user's library, and the segment edits, which keep every
  /// timed item with its clip, where a hand edit of `segments` easily leaves them behind). Not `add`
  /// (it would copy any file on disk into the project, where Read reaches it) or `template save` (it
  /// writes the library other videos use). `secrets` writes only secrets.json and blurs into the plan (its `--allow` refuses to run
  /// under SD_ONLY_PROJECT: showing a secret is the user's call),
  /// `animate-choose` only the plan. `stock` searches and downloads B-roll and GIFs into this
  /// project's broll/ (not `get-sound`, which writes the shared sound library). `lottie . list` only
  /// reads (not `lottie . add`, which copies any file in, like `add`).
  public static let directorCommands = [
    "describe:*", "still:*", "review:*", "validate:*", "profiles", "profile .:*", "template . freeze:*", "template . update:*",
    "lottie . list",
    "cut .:*", "restore .:*", "move .:*", "repeat .:*", "pauses .:*", "secrets .:*", "animate-choose .:*",
    "stock . videos:*", "stock . gifs:*", "stock . images:*", "stock . get-video:*", "stock . get-gif:*", "stock . get-image:*",
  ]

  /// Arguments for an edit in the project folder. `director` is the quoted path Claude is told to
  /// run (the allow rules match the command's text). With `resume`, the edit continues that
  /// session, so a follow-up ("a bit tighter") knows what the last ask did.
  ///
  /// A recording folder isn't trusted: no settings files load at all (a project's .claude/ hooks,
  /// and also the user's own allow rules, which would let it run any command they allow), and Write
  /// and edits to .claude/ are denied outright.
  public static func arguments(instruction: String, systemPrompt: String, director: String, resume: String?) -> [String] {
    ["-p", instruction]
      + (resume.map { ["--resume", $0] } ?? [])
      + [
        "--append-system-prompt", systemPrompt,
        "--output-format", "stream-json", "--verbose",
        "--permission-mode", "acceptEdits",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--tools", "Read,Edit,Bash",
        "--allowedTools", "Read(./**)", "Edit(./plan.json)",
      ]
      + directorCommands.map { "Bash(\(director) \($0))" }
      + ["--disallowedTools", "Write", "Edit(./.claude/**)", "Read(./.claude/**)", "WebFetch", "WebSearch"]
  }

  /// The session a `--output-format stream-json` line names (the first `system` line and the
  /// closing `result` line both do), for resuming it on the next ask.
  public static func sessionID(_ line: String) -> String? {
    guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      ["system", "result"].contains(obj["type"] as? String), let id = obj["session_id"] as? String, !id.isEmpty
    else { return nil }
    return id
  }

  /// What a running edit reports: a step it starts (a tool call, by its id), how a step ended, or
  /// what it says.
  public enum Event: Equatable, Sendable {
    case step(id: String?, text: String)
    case result(id: String, failed: Bool)
    case text(String)
  }

  /// Turns one line of `--output-format stream-json` into events (none for lines it doesn't show).
  /// Tool calls come in `assistant` lines, and their results (with `is_error`) in `user` lines.
  public static func events(_ line: String, director: String) -> [Event] {
    guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = obj["type"] as? String, ["assistant", "user"].contains(type), let msg = obj["message"] as? [String: Any],
      let content = msg["content"] as? [[String: Any]]
    else { return [] }
    return content.compactMap { c in
      switch c["type"] as? String {
      case "text" where type == "assistant": return (c["text"] as? String).map { .text($0) }
      case "tool_result":
        return (c["tool_use_id"] as? String).map { .result(id: $0, failed: c["is_error"] as? Bool ?? false) }
      case "tool_use":
        let input = c["input"] as? [String: Any] ?? [:]
        return stepText(c["name"] as? String, input, director: director).map { .step(id: c["id"] as? String, text: $0) }
      default: return nil
      }
    }
  }

  /// A tool call in words, for the steps list.
  static func stepText(_ name: String?, _ input: [String: Any], director: String) -> String? {
    switch name {
    case "Read": return "Reading \(((input["file_path"] as? String) ?? "a file").split(separator: "/").last ?? "")"
    case "Edit": return "Editing the plan"
    case "Bash":
      let cmd = (input["command"] as? String ?? "").replacingOccurrences(of: director, with: "director")
      if cmd.contains("director describe") { return "Reading the timeline" }
      if cmd.contains("director review") { return "Reviewing zooms and cuts" }
      if cmd.contains("director validate") { return "Checking the plan" }
      if cmd.contains("director still") {
        let frame = cmd.split(separator: " ").dropFirst(3).first.map(String.init) ?? ""
        return "Checking frame \(frame)"
      }
      let first = cmd.split(separator: "\n").first.map(String.init) ?? cmd
      return "Running \(first.prefix(48))"
    case let name?: return name
    case nil: return nil
    }
  }
}
