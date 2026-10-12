import CoreGraphics
import Foundation

// Capture helpers, retake marks and script-aware take picking. Pure functions, checked in
// Tests/Checks.swift.

/// A point in global screen points as a 0...1 fraction of the recorded area (a display or a
/// window), rounded to four places. Points outside the area come out below 0 or above 1.
public func normalizedPoint(_ p: CGPoint, in rect: CGRect) -> (Double, Double) {
  let x = (p.x - rect.origin.x) / rect.width
  let y = (p.y - rect.origin.y) / rect.height
  return ((x * 10000).rounded() / 10000, (y * 10000).rounded() / 10000)
}

/// Source-time ranges to cut for retake marks (⌃⌥⌘M while recording). Each mark cuts the phrase
/// spoken just before it: back to the previous pause longer than `phraseGap`, the end of the
/// previous sentence, the previous mark, or `maxPhrase` seconds, whichever comes first (Whisper
/// often leaves no gaps, so the cap matters). The cut runs to the mark plus `after`, so the redo
/// that follows is kept.
public func retakeCuts(words: [Word], marks: [Double], phraseGap: Double = 0.5, maxPhrase: Double = 6, after: Double = 0.3) -> [(Double, Double)] {
  func endsSentence(_ w: Word) -> Bool { w.text.hasSuffix(".") || w.text.hasSuffix("?") || w.text.hasSuffix("!") }
  let sorted = words.sorted { $0.start < $1.start }
  var cuts: [(Double, Double)] = []
  var floor = 0.0
  for m in marks.sorted() {
    let before = sorted.filter { $0.start < m && $0.start >= floor }
    guard var first = before.last else {
      floor = m
      continue
    }
    for w in before.reversed().dropFirst() {
      if first.start - w.end > phraseGap || m - w.start > maxPhrase || endsSentence(w) { break }
      first = w
    }
    cuts.append((max(floor, first.start - 0.1), m + after))
    floor = m + after
  }
  return cuts
}

// MARK: Script takes

/// Lowercased word tokens, digits kept, punctuation dropped.
func tokens(_ s: String) -> [String] {
  s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

/// The spoken lines of a teleprompter script: Markdown headings, `**Label:**` lines, `*[...]*`
/// and `[...]` stage directions are skipped; paragraphs are split into sentences. A header block
/// above a `---` line (as in the script writer's format) is skipped too.
public func scriptLines(_ markdown: String) -> [String] {
  var text = markdown
  let parts = markdown.components(separatedBy: "\n---\n")
  if parts.count >= 3 { text = parts[1] }
  text = text.replacingOccurrences(of: #"\*\[[^\]]*\]\*|\[[^\]]*\]"#, with: " ", options: .regularExpression)
  var lines: [String] = []
  for raw in text.components(separatedBy: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("**") || line == "---" { continue }
    for sentence in line.components(separatedBy: CharacterSet(charactersIn: ".?!")) {
      let s = sentence.trimmingCharacters(in: .whitespaces)
      if tokens(s).count >= 3 { lines.append(s) }
    }
  }
  return lines
}

/// Spoken sentences from transcript words: a new sentence starts after ending punctuation or a
/// pause longer than `gap`.
func spokenSentences(_ words: [Word], gap: Double = 0.8) -> [(start: Double, end: Double, tokens: [String])] {
  var out: [(start: Double, end: Double, tokens: [String])] = []
  var ended = true
  for w in words.sorted(by: { $0.start < $1.start }) {
    let t = tokens(w.text)
    if !ended, var last = out.last, w.start - last.end <= gap {
      last.end = w.end
      last.tokens += t
      out[out.count - 1] = last
    } else {
      out.append((w.start, w.end, t))
    }
    ended = w.text.hasSuffix(".") || w.text.hasSuffix("?") || w.text.hasSuffix("!")
  }
  return out.filter { !$0.tokens.isEmpty }
}

/// Earlier takes of script lines, to cut: each spoken sentence is matched to the script line
/// that contains most of its words. When a later sentence matches the same line and covers most
/// of the earlier one's words (a restart or a full redo), the earlier one is a discarded take.
/// Two halves of one long line don't cover each other, so they both stay.
public func earlierTakeCuts(words: [Word], script: [String], contain: Double = 0.6, cover: Double = 0.7) -> [(Double, Double)] {
  let lines = script.map { Set(tokens($0)) }
  guard !lines.isEmpty else { return [] }
  let spoken = spokenSentences(words)
  let match: [Int?] = spoken.map { s in
    let set = Set(s.tokens)
    guard set.count >= 3 else { return nil }
    var best: (Int, Double)?
    for (i, line) in lines.enumerated() {
      let ratio = Double(set.intersection(line).count) / Double(set.count)
      if ratio >= contain, ratio > (best?.1 ?? 0) { best = (i, ratio) }
    }
    return best?.0
  }
  var cuts: [(Double, Double)] = []
  for (i, s) in spoken.enumerated() {
    guard let line = match[i] else { continue }
    let set = Set(s.tokens)
    let redone = spoken.indices.contains { j in
      j > i && match[j] == line && Double(set.intersection(Set(spoken[j].tokens)).count) / Double(set.count) >= cover
    }
    if redone { cuts.append((s.start - 0.1, s.end + 0.15)) }
  }
  return cuts
}
