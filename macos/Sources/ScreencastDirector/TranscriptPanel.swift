import AppKit
import DirectorCore
import SwiftUI

/// Transcript view state: where each word sits (for drag selection), the drag's anchor, and search.
final class TranscriptUI: ObservableObject {
  /// Word frames in the transcript's coordinate space. Not published: they're read by gestures.
  var frames: [Int: CGRect] = [:]
  var dragAnchor: Int?
  @Published var search = ""
  @Published var hit = 0

  func word(at p: CGPoint) -> Int? {
    if let hit = frames.first(where: { $0.value.insetBy(dx: -2, dy: -2).contains(p) }) { return hit.key }
    // Between words: the nearest one on that line.
    let line = frames.filter { p.y >= $0.value.minY - 2 && p.y <= $0.value.maxY + 2 }
    return line.min { abs($0.value.midX - p.x) < abs($1.value.midX - p.x) }?.key
  }
}

/// The transcript as text, Descript-style: cut words struck through, sped-up words tinted, filler
/// words marked. Click a word to jump there; drag or shift-click to select, ⇧←/⇧→ to extend by a
/// word. A selection can be cut, or turned into a zoom, title, annotation, or an AI request.
struct TranscriptView: View {
  @ObservedObject var project: ProjectModel
  /// Only the current word follows playback, so the view redraws per word, not per frame.
  @ObservedObject var playhead: Playhead
  @ObservedObject var ui: TranscriptUI
  /// Set when the panel can ask the AI box to take over (it fills the box and focuses it).
  var askAI: ((String) -> Void)?

  /// Sentences: break after end punctuation or a pause over 1.5 s.
  static func sentences(_ words: [Word]) -> [[Int]] {
    var out: [[Int]] = []
    var cur: [Int] = []
    for (i, w) in words.enumerated() {
      if let last = cur.last, w.start - words[last].end > 1.5 {
        out.append(cur)
        cur = []
      }
      cur.append(i)
      if w.text.hasSuffix(".") || w.text.hasSuffix("?") || w.text.hasSuffix("!") {
        out.append(cur)
        cur = []
      }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }

  private var matches: [Int] {
    let q = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return [] }
    let words = project.words
    let parts = q.split(separator: " ").map(String.init)
    return words.indices.filter { i in
      parts.enumerated().allSatisfy { k, part in
        i + k < words.count && words[i + k].text.lowercased().trimmingCharacters(in: .punctuationCharacters).hasPrefix(part)
      }
    }
  }

  var body: some View {
    let words = project.words
    let found = matches
    VStack(alignment: .leading, spacing: 10) {
      searchBar(found)
      actionBar
      if words.isEmpty {
        Text("No transcript yet. Analyze the recording first.").foregroundStyle(.secondary)
      }
      ScrollViewReader { scroll in
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(Self.sentences(words).enumerated()), id: \.offset) { _, sentence in
            HStack(alignment: .top, spacing: 8) {
              Text(fmtTime(words[sentence[0]].start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 2)
              FlowLayout {
                ForEach(sentence, id: \.self) { i in word(i, words[i], matched: found.contains(i)).id(i) }
              }
            }
          }
        }
        .coordinateSpace(name: "transcript")
        .contentShape(Rectangle())
        .simultaneousGesture(dragSelect)
        .onChange(of: ui.hit) { _, _ in
          if found.indices.contains(ui.hit) { withAnimation { scroll.scrollTo(found[ui.hit], anchor: .center) } }
        }
        .onChange(of: playhead.word) { _, w in
          // Keep the spoken word in view while playing.
          if project.isPlaying, let w { scroll.scrollTo(w, anchor: .center) }
        }
      }
    }
  }

  private func searchBar(_ found: [Int]) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Find in transcript", text: $ui.search)
        .textFieldStyle(.plain)
        .onSubmit { next(found, 1) }
        .onChange(of: ui.search) { _, _ in ui.hit = 0 }
      if !ui.search.isEmpty {
        Text(found.isEmpty ? "None" : "\(min(ui.hit, found.count - 1) + 1) of \(found.count)").font(.caption).foregroundStyle(.secondary)
          .monospacedDigit()
        Button { next(found, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(found.isEmpty)
          .accessibilityLabel("Previous match")
        Button { next(found, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(found.isEmpty)
          .accessibilityLabel("Next match")
        Button("Select") { selectMatch(found) }.controlSize(.small).disabled(found.isEmpty)
          .help("Select this match, to cut it or add something over it")
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
  }

  private func next(_ found: [Int], _ step: Int) {
    guard !found.isEmpty else { return }
    ui.hit = (ui.hit + step + found.count) % found.count
    project.seek(src: project.words[found[ui.hit]].start)
  }

  private func selectMatch(_ found: [Int]) {
    guard found.indices.contains(ui.hit) else { return }
    let n = ui.search.split(separator: " ").count
    let i = found[ui.hit]
    project.transcriptSel = i...min(project.words.count - 1, i + n - 1)
  }

  /// What you can do with the selected words. Always shown (disabled with nothing selected), so
  /// selecting doesn't push the words down mid-drag.
  private var actionBar: some View {
    let sel = project.transcriptSel
    let text = sel.flatMap { project.words.indices.contains($0.upperBound) ? project.words[$0].map(\.text).joined(separator: " ") : nil }
    return VStack(alignment: .leading, spacing: 6) {
        Text(text.map { "“\($0)”" } ?? "Click a word to jump there. Drag or shift-click to select words.")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        FlowLayout(spacing: 6, lineSpacing: 6) {
          if project.transcriptSelectionIsCut {
            Button { project.restoreTranscriptSelection() } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
          } else {
            Button { project.cutTranscriptSelection() } label: { Label("Cut", systemImage: "scissors") }
              .help("Remove these words from the video (⌫)")
          }
          Button { project.zoomOnTranscriptSelection() } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
            .help("Zoom in while these words are said, toward where you clicked")
          Menu {
            ForEach(ChoiceTiles.calloutStyles, id: \.name) { c in
              Button { project.titleFromTranscriptSelection(style: c.name) } label: { Label(c.label, systemImage: c.icon) }
            }
          } label: {
            Label("Title", systemImage: "textformat")
          } primaryAction: {
            project.titleFromTranscriptSelection(style: "title")
          }
          .fixedSize()
          .help("Show these words as a title while they're said; the arrow has lower thirds, slates and chapters")
          Menu {
            ForEach(ChoiceTiles.annotationKinds, id: \.name) { k in
              Button { project.annotateTranscriptSelection(k.name) } label: { Label(k.label, systemImage: k.icon) }
            }
          } label: {
            Label("Annotate", systemImage: "scribble")
          }
          .fixedSize()
          .help("Spotlight, box, arrow, highlight or blur while these words are said")
          if let askAI {
            Button { askAI("For “\(text ?? "")”: ") } label: { Label("Ask AI", systemImage: "sparkles") }
              .help("Ask the AI about these words; it knows what's selected")
          }
        }
        .controlSize(.small)
        .disabled(sel == nil || !project.hasPlan)
      }
      .padding(8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(sel == nil ? 0.04 : 0.1)))
  }

  /// Drag across words to select them; a plain click (no movement) seeks, handled per word.
  private var dragSelect: some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named("transcript"))
      .onChanged { v in
        if ui.dragAnchor == nil { ui.dragAnchor = ui.word(at: v.startLocation) }
        guard let a = ui.dragAnchor, let b = ui.word(at: v.location) else { return }
        project.transcriptSel = min(a, b)...max(a, b)
      }
      .onEnded { _ in
        ui.dragAnchor = nil
        if let sel = project.transcriptSel, project.words.indices.contains(sel.lowerBound) {
          project.player.pause()
          project.seek(src: project.words[sel.lowerBound].start)
        }
      }
  }

  private func word(_ i: Int, _ w: Word, matched: Bool) -> some View {
    let speed = project.plan?.speed(at: (w.start + w.end) / 2)
    let selected = project.transcriptSel?.contains(i) ?? false
    let playing = playhead.word == i
    let filler = Rules.isFiller(w.text)
    let background: Color =
      selected ? Theme.accent.opacity(0.35) : playing ? Color.yellow.opacity(0.3) : matched ? Color.orange.opacity(0.25) : Color.clear
    return Text(w.text)
      .strikethrough(speed == nil)
      .italic(filler)
      .foregroundStyle(
        speed == nil ? Color.secondary.opacity(0.6) : (speed ?? 1) > 1.01 ? Color.orange : filler ? Color.secondary : Color.primary)
      .padding(.horizontal, 2)
      .background(RoundedRectangle(cornerRadius: 3).fill(background))
      .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("transcript")) }) { ui.frames[i] = $0 }
      .onTapGesture { project.clickWord(i, extend: NSEvent.modifierFlags.contains(.shift)) }
      .help("\(fmtTime(w.start))\(speed == nil ? ", cut" : (speed ?? 1) > 1.01 ? ", \((speed ?? 1).formatted())x" : "")\(filler ? ", filler word" : "")")
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel("\(w.text), \(fmtTime(w.start))\(speed == nil ? ", cut" : "")")
      .accessibilityAction { project.clickWord(i, extend: false) }
  }
}
