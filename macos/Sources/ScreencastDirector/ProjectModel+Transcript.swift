import AVFoundation
import AppKit
import DirectorCore
import Foundation
import UniformTypeIdentifiers

// Editing from the transcript, and restoring earlier versions of the plan.
extension ProjectModel {
  // MARK: Transcript editing

  var words: [Word] { project?.words ?? [] }

  /// The word being said at source time `t`, if any (binary search; words are in order).
  func wordIndex(at t: Double) -> Int? { DirectorCore.wordIndex(at: t, in: words) }

  /// The source time range the selected words cover, from the first word's start to the last's end.
  var transcriptRange: Range<Double>? { transcriptSel.flatMap { wordRange($0, in: words) } }

  /// Whether every selected word is already cut (then the action is Restore).
  var transcriptSelectionIsCut: Bool {
    guard let sel = transcriptSel, let plan else { return false }
    return wordsAreCut(sel, in: words, plan: plan)
  }

  /// Click a word: select it (shift-click extends) and seek there.
  func clickWord(_ i: Int, extend: Bool) {
    guard words.indices.contains(i) else { return }
    if extend, let sel = transcriptSel {
      transcriptSel = min(sel.lowerBound, i)...max(sel.upperBound, i)
    } else {
      transcriptSel = i...i
    }
    player.pause()
    seek(src: words[i].start)
  }

  func cutTranscriptSelection() {
    guard let r = transcriptSel.flatMap({ wordCutRange($0, in: words) }) else { return }
    apply { $0.cut(range: r) }
    status = "Cut \(fmtTime(r.upperBound - r.lowerBound)) of speech. ⌘Z puts it back."
    transcriptSel = nil
  }

  /// ⇧← and ⇧→ with words selected: grow or shrink the selection by a word at its end.
  func extendTranscriptSelection(_ step: Int) {
    guard let sel = transcriptSel else { return }
    let extended = extendWordSelection(sel, by: step, wordCount: words.count)
    transcriptSel = extended
    seek(src: words[extended.upperBound].start)
  }

  /// The range the next "over a range" action uses: selected words, else the in/out range.
  var actionRange: Range<Double>? { transcriptRange ?? markedRange }

  private func doneWithRange() {
    if transcriptSel != nil { transcriptSel = nil } else { clearInOut() }
  }

  /// Zooms in over the selected words (or in/out range), toward a click in it (else the last one).
  func zoomOverRange() {
    guard let r = actionRange, let plan else { return }
    let clicks = project?.clicks ?? []
    let inside = clicks.last { $0.t >= r.lowerBound - 1 && $0.t <= r.upperBound && (0...1).contains($0.x) && (0...1).contains($0.y) }
    let f = inside.map { (x: $0.x, y: $0.y) } ?? zoomFocus(at: r.upperBound, clicks: clicks)
    let z = Zoom(
      start: r.lowerBound, end: min(plan.source.duration, max(r.upperBound, r.lowerBound + 1.5)), x: f.x, y: f.y, scale: 1.8,
      note: transcriptSel != nil ? "from transcript" : "from in/out")
    apply { $0.zooms.append(z) }
    if let i = self.plan?.zooms.firstIndex(of: z) { select(.zoom(i), adding: false) }
    doneWithRange()
  }

  /// A title (or lower third, slate, chapter) over the range, worded from what's said in it.
  func titleOverRange(style: String) {
    guard let r = actionRange, let plan else { return }
    let said = words.filter { $0.start < r.upperBound && $0.end > r.lowerBound }
    var text = said.prefix(8).map(\.text).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
    if text.isEmpty { text = "Title" }
    if let first = text.first { text = first.uppercased() + text.dropFirst() }
    let c = Callout(
      start: r.lowerBound, end: min(plan.source.duration, max(r.upperBound, r.lowerBound + 2)), text: text,
      style: style == "title" ? nil : style, subtitle: style == "chapter" ? "Part 1" : nil)
    apply { $0.callouts.append(c) }
    if let i = self.plan?.callouts.firstIndex(of: c) { select(.callout(i), adding: false) }
    doneWithRange()
  }

  /// An annotation over the range, around a click in it (else the last one).
  func annotateRange(_ kind: String) {
    guard let r = actionRange else { return }
    addAnnotation(kind, from: r.lowerBound, to: max(r.upperBound, r.lowerBound + 1.5))
    doneWithRange()
  }

  func restoreTranscriptSelection() {
    guard let r = transcriptSel.flatMap({ wordCutRange($0, in: words) }) else { return }
    apply { $0.restore(range: r) }
    status = "Restored \(fmtTime(r.upperBound - r.lowerBound))."
    transcriptSel = nil
  }

  // MARK: Version history

  struct Version: Identifiable {
    let id: URL
    let date: Date
    let length: Double?
    let summary: String
  }

  /// Saved versions of plan.json, newest first, each with how it differs from now.
  func versions() -> [Version] {
    PlanHistory.list(planURL: planURL).map { e in
      let old = try? Plan.load(e.url)
      let length = old.map(planSeconds)
      let summary = old.flatMap { o in plan.map { PlanHistory.summary(from: $0, to: o) } } ?? "unreadable"
      return Version(id: e.url, date: e.date, length: length, summary: summary)
    }
  }

  /// Makes an earlier version current. Undoable, and the version it replaces goes into history.
  func restoreVersion(_ url: URL) {
    let old: Plan
    do { old = try Plan.load(url) } catch {
      Notices.shared.show(error, "Couldn't read that version")
      return
    }
    apply { $0 = old }
    status = "Restored the version from \(DateFormatter.localizedString(from: (PlanHistory.list(planURL: planURL).first { $0.url == url }?.date ?? Date()), dateStyle: .none, timeStyle: .medium)). ⌘Z undoes it."
  }

  /// More > Check Edit: cuts that clip a word and flashes (shots too short to read), as a notice that
  /// jumps to the first one.
  func checkEdit() {
    guard let plan else { return }
    let clipped = cutsInsideWords(plan, words: words)
    let flashed = flashes(plan, dir: dir)
    var parts: [String] = []
    if !clipped.isEmpty {
      parts.append("\(clipped.count) cut\(clipped.count == 1 ? "" : "s") clip a word (" + clipped.prefix(3).map { "“\($0.word.text)” at \(fmtTime($0.edge))" }.joined(separator: ", ") + ")")
    }
    if !flashed.isEmpty { parts.append("\(flashed.count) shot\(flashed.count == 1 ? " is" : "s are") too short to read") }
    guard let first = clipped.first?.edge else {
      Notices.shared.show(parts.isEmpty ? "No cuts clip a word, and no shots are too short." : parts.joined(separator: "; ") + ".", error: !parts.isEmpty)
      return
    }
    Notices.shared.show(parts.joined(separator: "; ") + ".", error: true, action: "Show") { [weak self] in self?.seek(src: first) }
  }
}
