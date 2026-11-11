import Foundation

// The Claude box's `claude -p` arguments and the session a follow-up ask resumes. Called from
// Checks.main; run with macos/test.sh.

func claudeEditChecks() {
  let fresh = ClaudeEdit.arguments(instruction: "cut the intro", systemPrompt: "rules", director: "'/A/director'", resume: nil)
  expect(Array(fresh.prefix(2)) == ["-p", "cut the intro"], "the instruction is the prompt")
  expect(!fresh.contains("--resume"), "a first ask starts a new session")
  expect(fresh.contains("Bash('/A/director' validate:*)"), "the edit may run director validate")
  expect(!fresh.contains { $0.contains(" add") || $0.contains("template . save") }, "the edit may not run add, lottie add or template save")
  expect(fresh.contains("Bash('/A/director' lottie . list)"), "the edit may list the Lottie files it can play")
  for command in ["cut", "restore", "move", "repeat", "pauses"] {
    expect(fresh.contains("Bash('/A/director' \(command) .:*)"), "the edit may run director \(command) on its own project")
  }
  expect(
    fresh.contains("Bash('/A/director' stock . get-gif:*)") && fresh.contains("Bash('/A/director' stock . gifs:*)"),
    "the edit may find and download GIFs into its own project")
  expect(!fresh.contains { $0.contains("get-sound") }, "the edit may not download into the shared sound library")
  expect(fresh.contains("Edit(./plan.json)") && !fresh.contains("Edit(./**)"), "the edit may change only plan.json")
  expect(fresh.firstIndex(of: "--setting-sources").map { fresh[$0 + 1] } == "", "no settings files load")
  expect(fresh.firstIndex(of: "--disallowedTools").map { fresh[($0 + 1)...].contains("Write") } == true, "Write is denied")

  let followUp = ClaudeEdit.arguments(instruction: "a bit tighter", systemPrompt: "rules", director: "'/A/director'", resume: "abc-123")
  expect(followUp.firstIndex(of: "--resume").map { followUp[$0 + 1] } == "abc-123", "a follow-up resumes the last session")

  expect(ClaudeEdit.sessionID(#"{"type":"system","subtype":"init","session_id":"s-1"}"#) == "s-1", "the init line names the session")
  expect(ClaudeEdit.sessionID(#"{"type":"result","session_id":"s-2","is_error":false}"#) == "s-2", "the result line names the session")
  expect(ClaudeEdit.sessionID(#"{"type":"assistant","session_id":"s-3"}"#) == nil, "other lines are ignored")
  expect(ClaudeEdit.sessionID("not json") == nil, "a partial line is ignored")

  // The steps list: tool calls by id, and whether each failed (from the user line's tool_result).
  let call = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"/d/director validate ."}}]}}"#
  expect(ClaudeEdit.events(call, director: "/d/director") == [.text("Looking."), .step(id: "t1", text: "Checking the plan")], "a tool call is a step with its id")
  let failed = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"exit 1"}]}}"#
  let worked = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#
  expect(ClaudeEdit.events(failed, director: "/d/director") == [.result(id: "t1", failed: true)], "a failed tool result marks its step failed")
  expect(ClaudeEdit.events(worked, director: "/d/director") == [.result(id: "t2", failed: false)], "a tool result without is_error worked")
  expect(ClaudeEdit.events(#"{"type":"user","message":{"content":[{"type":"text","text":"the prompt"}]}}"#, director: "") == [], "the user's own text isn't the AI's reply")
  editPromptCoverageChecks()
}

/// The Claude box only knows the plan fields its prompt names, so a new field must be added there
/// (Resources/edit-prompt.md): every top-level field in backticks, and every field of the timed
/// items on that item's line.
func editPromptCoverageChecks() {
  guard let prompt = try? String(contentsOfFile: "Resources/edit-prompt.md", encoding: .utf8) else {
    expect(false, "Resources/edit-prompt.md is readable from macos/")
    return
  }
  func fields(_ value: Any) -> [String] {
    Mirror(reflecting: value).children.compactMap { $0.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 } }
  }
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 30, captureStart: nil, camera: nil)
  let plan = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp/sd-prompt"), source: src))
  // The recording, the output size and the plan's version aren't the AI's to change.
  for key in fields(plan) where !["version", "source", "output"].contains(key) {
    expect(prompt.contains("`\(key)`") || prompt.contains("`\(key)."), "edit-prompt.md names the plan field `\(key)`")
  }
  let items: [(line: String, value: Any)] = [
    ("`zooms`", Zoom(start: 0, end: 1, x: 0, y: 0, scale: 1)),
    ("`camera.punchIns`", PunchIn(start: 0, end: 1, scale: 2)),
    ("`layouts`", LayoutRange(start: 0, end: 1, mode: .pip)),
    ("`callouts`", Callout(start: 0, end: 1, text: "")),
    ("`annotations`", Annotation(start: 0, end: 1, kind: "box", x: 0, y: 0, w: 1, h: 1)),
    ("`inserts`", Insert(start: 0, end: 1, file: "")),
  ]
  for item in items {
    guard let line = prompt.split(separator: "\n").first(where: { $0.hasPrefix("- \(item.line)") }) else {
      expect(false, "edit-prompt.md has a line for \(item.line)")
      continue
    }
    for key in fields(item.value) {
      expect(line.range(of: "\\b\(key)\\b", options: .regularExpression) != nil, "edit-prompt.md's \(item.line) line names `\(key)`")
    }
  }
}
