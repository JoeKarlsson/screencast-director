import Foundation

// How the app's Claude box runs Claude Code: its `claude -p` arguments and the session it resumes,
// here so test.sh checks them (the app runs the process, in ScreencastDirector/Claude.swift).
public enum ClaudeEdit {
  /// The director commands the edit may run (allow-rule patterns after the director's path): the ones
  /// that check the edit, and the ones that write only this project's plan (profile, template
  /// freeze/update, which copy from the user's library, and the segment edits, which keep every
  /// timed item with its clip, where a hand edit of `segments` easily leaves them behind). Not `add`
  /// (it would copy any file on disk into the project, where Read reaches it) or `template save` (it
  /// writes the library other videos use). `secrets` writes only secrets.json and blurs into the plan,
  /// `animate-choose` only the plan. `stock` searches and downloads B-roll and GIFs into this
  /// project's broll/ (not `get-sound`, which writes the shared sound library).
  public static let directorCommands = [
    "describe:*", "still:*", "review:*", "validate:*", "profiles", "profile .:*", "template . freeze:*", "template . update:*",
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
}
