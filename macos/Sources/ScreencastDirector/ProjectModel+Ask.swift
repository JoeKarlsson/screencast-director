import AVFoundation
import AppKit
import DirectorCore
import Foundation
import UniformTypeIdentifiers

// Asking the AI to edit: the request with its context, the run, its reviewable changes and the
// saved history of asks.

/// One request to the AI editor and its reply (streamed in while it runs), the steps it took,
/// and what it changed (each can be undone on its own until accepted).
struct Ask: Identifiable {
  let id = UUID()
  let instruction: String
  var reply = ""
  var running = true
  var steps: [AskStep] = []
  var changes: [PlanChange] = []
  var started = Date()
  /// How long it took, once it's over.
  var seconds: Double?
}

/// One thing the AI did while editing (a tool call), whether it failed, and how long it took.
struct AskStep: Codable {
  var text: String
  var id: String?
  var failed: Bool?
  var seconds: Double?
  var started = Date()
}

/// What's kept of an ask in .history/asks.json. `steps` is the plain text older versions saved;
/// `log` has each step's outcome too.
struct SavedAsk: Codable {
  var instruction: String
  var reply: String
  var steps: [String]?
  var log: [AskStep]?
  var seconds: Double?
}

extension ProjectModel {
  /// Where you are in the editor, so "zoom here" or "cut this" mean something to the AI.
  func askContext() -> String {
    editorContext(
      plan: plan, words: words, playhead: playheadSrc, selection: TimelineSelection(primary: selection, others: multi), wordSelection: transcriptSel,
      marked: markedRange)
  }

  func askClaude() {
    let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !busy else { return }
    flushWrite()
    asks.append(Ask(instruction: text))
    // Everything below writes to this ask by its index, never "the newest one": a reply or wrap-up
    // that lands after another request has started must not end up on it.
    let n = asks.count - 1
    planBeforeAsk = plan
    let ai = AISettings.shared
    let request = "\(text)\n\n(Where I am in the editor, for words like \"here\" or \"this\":\n\(askContext()))"
    if ai.provider != .claudeCode {
      run("\(ai.provider.shortName) is editing…") { [self] in
        var outcome = ""
        defer { finishAsk(n, outcome) }
        do {
          try await readScreenTextIfNeeded()
          guard let plan, let project else {
            outcome = "There was no plan to edit."
            return
          }
          asks[n].steps.append(AskStep(text: "Sending the timeline to \(ai.provider.shortName)"))
          let (summary, newPlan) = try await APIEditor.edit(project: project, plan: plan, instruction: request, settings: ai)
          apply { $0 = newPlan }
          asks[n].reply = summary
          instruction = ""
          status = "Edited by \(ai.provider == .anthropic ? ai.anthropicModel : ai.model). ⌘Z undoes it."
        } catch {
          outcome = Task.isCancelled ? "Stopped." : "\(ai.provider.shortName) couldn't make the edit: \(error.localizedDescription)"
          throw error
        }
      }
      return
    }
    aiEditing = true
    run("Claude is editing…") { [self] in
      var outcome = ""
      defer { finishAsk(n, outcome) }
      do {
        try await readScreenTextIfNeeded()
        let result = try await Claude.edit(project: dir, instruction: request, resume: claudeSession) { event in
          Task { @MainActor in
            guard self.asks.indices.contains(n) else { return }
            switch event {
            case .step(let id, let text): self.asks[n].steps.append(AskStep(text: text, id: id))
            case .result(let id, let failed):
              if let i = self.asks[n].steps.lastIndex(where: { $0.id == id }) {
                self.asks[n].steps[i].failed = failed
                self.asks[n].steps[i].seconds = Date().timeIntervalSince(self.asks[n].steps[i].started)
              }
            case .text(let t):
              let reply = self.asks[n].reply
              self.asks[n].reply = reply + (reply.isEmpty ? "" : "\n\n") + t
            }
          }
        }
        instruction = ""
        // A failed resume (the session expired) mustn't fail every ask after it.
        claudeSession = result.status == 0 ? result.session : nil
        if Task.isCancelled {
          status = "Stopped. ⌘Z undoes anything it changed."
          outcome = "Stopped. What it already changed stays, and ⌘Z undoes it."
        } else if result.status != 0 {
          status = "Claude Code stopped with an error."
          // Its own words say why (signed out, rate limited, a crash); they used to be thrown away.
          outcome = claudeErrorOutcome(status: result.status, errors: result.errors)
        } else {
          status = "Claude finished. ⌘Z undoes its edit."
          outcome = "Claude finished without saying anything."
        }
      } catch {
        outcome = Task.isCancelled ? "Stopped." : "Couldn't run Claude Code: \(error.localizedDescription)"
        throw error
      }
    }
  }

  /// Closes out ask `n`. `outcome` is how it ended; it becomes the reply when Claude said nothing,
  /// and is added to it after an error, so an ask never shows "editing…" once it's over.
  private func finishAsk(_ n: Int, _ outcome: String) {
    guard asks.indices.contains(n) else { return }
    asks[n].running = false
    asks[n].seconds = Date().timeIntervalSince(asks[n].started)
    asks[n].reply = closingReply(asks[n].reply, outcome: outcome)
    saveAsks()
    // Claude Code writes plan.json itself and the watcher picks it up within a second; compare then.
    let old = planBeforeAsk
    planBeforeAsk = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
      // A newer ask that started meanwhile owns aiEditing now.
      let latest = asks.count - 1 == n
      let wasEditing = aiEditing && latest
      if latest { aiEditing = false }
      guard let old, let new = plan else { return }
      if wasEditing, old != new {
        undoStack.append(old)
        redoStack.removeAll()
      }
      let ranges = changedRanges(from: old, to: new)
      if !ranges.isEmpty { aiChange = (UUID(), ranges) }
      if asks.indices.contains(n) { asks[n].changes = planChanges(from: old, to: new) }
      reportNewProblems(n, before: old, after: new)
    }
  }

  /// Adds what `director validate` finds in the edited plan that wasn't wrong before it (an ignored
  /// key, an overlap, a flash), so a bad edit says so instead of quietly doing nothing.
  private func reportNewProblems(_ n: Int, before: Plan, after: Plan) {
    guard let project, before != after, asks.indices.contains(n) else { return }
    let known = Set(PlanCheck.check(before, project: project, templates: nil).problems)
    let raw = try? Data(contentsOf: planURL)
    let new = PlanCheck.check(after, project: project, templates: nil, raw: raw).problems.filter { !known.contains($0) }
    guard !new.isEmpty else { return }
    let count = new.count == 1 ? "a problem" : "\(new.count) problems"
    asks[n].reply += "\n\nThe edit left \(count) in the plan:\n" + new.map { "• \($0)" }.joined(separator: "\n")
    saveAsks()
  }

  /// The app is quitting: stop any Claude still editing (or it carries on in the background,
  /// changing the plan with nobody watching) and record that the ask was stopped.
  func stopForQuit() {
    guard asks.last?.running == true else { return }
    Claude.stopAll()
    let n = asks.count - 1
    asks[n].running = false
    asks[n].reply += (asks[n].reply.isEmpty ? "" : "\n\n") + "Stopped when the app quit. What it already changed stays."
    saveAsks()
  }

  /// Recordings analyzed before screen text existed get it once, before their first AI edit, so the
  /// timeline says what each click landed on.
  private func readScreenTextIfNeeded() async throws {
    guard project?.clicks.isEmpty == false, !FileManager.default.fileExists(atPath: ScreenText.url(dir).path) else { return }
    if !asks.isEmpty { asks[asks.count - 1].steps.append(AskStep(text: "Reading text on screen")) }
    try await readScreenText(dir)
  }

  /// Undoes one change from an AI edit (itself undoable) and drops it from the list.
  func rejectChange(_ change: PlanChange, in askID: UUID) {
    apply { change.revert(&$0) }
    dropChange(change.id, in: askID)
  }

  func dropChange(_ id: UUID, in askID: UUID) {
    guard let i = asks.firstIndex(where: { $0.id == askID }) else { return }
    asks[i].changes.removeAll { $0.id == id }
  }

  func acceptAllChanges(in askID: UUID) {
    guard let i = asks.firstIndex(where: { $0.id == askID }) else { return }
    asks[i].changes = []
  }

  private var asksURL: URL { PlanHistory.directory(for: planURL).appendingPathComponent("asks.json") }

  func loadAsks() {
    guard let data = try? Data(contentsOf: asksURL), let saved = try? JSONDecoder().decode([SavedAsk].self, from: data) else { return }
    asks = saved.map { s in
      // Older versions could save the "is editing…" status as the reply of an edit that never
      // finished, which then looked stuck forever.
      let lost = s.reply.hasSuffix(" is editing…")
      return Ask(
        instruction: s.instruction, reply: lost ? "This edit didn't finish, and its reply was lost. Ask again if the change isn't there." : s.reply,
        running: false, steps: s.log ?? (s.steps ?? []).map { AskStep(text: $0) }, seconds: s.seconds)
    }
  }

  /// Keeps the last 50 asks with the project, so the history survives switching recordings.
  private func saveAsks() {
    let saved = asks.filter { !$0.running }.suffix(50).map {
      SavedAsk(instruction: $0.instruction, reply: $0.reply, log: $0.steps, seconds: $0.seconds)
    }
    try? FileManager.default.createDirectory(at: asksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(Array(saved)).write(to: asksURL, options: .atomic)
  }
}
