import AppKit
import DirectorCore
import SwiftUI

// Views for the export queue, version history and transcript editing. View state lives in
// ObservableObjects (no @State: the Command Line Tools have no macro plugins).

/// The Export button's companion: a progress ring while exports run, a tray once some are done,
/// nothing before the first export. The queue is in its popover.
struct ExportQueueButton: View {
  @ObservedObject var queue: ExportQueue

  var body: some View {
    if !queue.jobs.isEmpty {
      Button {
        queue.showList.toggle()
      } label: {
        if queue.activeCount > 0 {
          // Jobs publish their own progress; poll them while something runs.
          SwiftUI.TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let running = queue.jobs.filter { !$0.isFinished }
            let progress = running.isEmpty ? 0 : running.map(\.progress).reduce(0, +) / Double(running.count)
            ZStack {
              Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
              Circle().trim(from: 0, to: max(0.03, progress)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
              Text("\(queue.activeCount)").font(.system(size: 8, weight: .bold)).monospacedDigit()
            }
            .frame(width: 17, height: 17)
          }
        } else {
          Label("Exports", systemImage: "checkmark.circle")
        }
      }
      .help(queue.activeCount > 0 ? "\(queue.activeCount) exporting" : "Exports")
      .accessibilityLabel("Exports")
      .popover(isPresented: $queue.showList, arrowEdge: .bottom) { ExportQueueList(queue: queue) }
    }
  }
}

struct ExportQueueList: View {
  @ObservedObject var queue: ExportQueue

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Exports").font(.headline)
        Spacer()
        Button("Clear Finished", action: queue.clearFinished).controlSize(.small)
          .disabled(!queue.jobs.contains { $0.isFinished })
      }
      if queue.jobs.isEmpty {
        Text("Nothing exported yet. Exports run in the background, so you can keep editing.")
          .font(.callout).foregroundStyle(.secondary)
      }
      ForEach(queue.jobs) { job in ExportJobRow(job: job, queue: queue) }
    }
    .padding(14)
    .frame(width: 380)
  }
}

struct ExportJobRow: View {
  @ObservedObject var job: ExportQueue.Job
  let queue: ExportQueue

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(job.label).lineLimit(1).truncationMode(.middle)
        Spacer()
        switch job.state {
        case .queued, .running:
          Button("Cancel") { queue.cancel(job) }.controlSize(.small)
        case .done:
          Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }.controlSize(.small)
        default:
          EmptyView()
        }
      }
      switch job.state {
      case .queued: Text("Waiting").font(.caption).foregroundStyle(.secondary)
      case .running: ProgressView(value: job.progress)
      case .done: Text("Done: \(job.url.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
      case .failed(let why): Text("Failed: \(why)").font(.caption).foregroundStyle(.red)
      case .cancelled: Text("Cancelled").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

/// Earlier versions of the plan, each with when it was saved, its length and how it differs from now.
struct VersionHistoryView: View {
  @ObservedObject var project: ProjectModel

  var body: some View {
    let versions = project.versions()
    VStack(alignment: .leading, spacing: 12) {
      Text("Version History").font(.title2.bold())
      Text("The last \(PlanHistory.keep) saved versions of this edit. Restoring one is undoable.")
        .font(.callout).foregroundStyle(.secondary)
      if versions.isEmpty {
        Text("No earlier versions yet. One is saved every time the edit changes.").foregroundStyle(.secondary)
      }
      ScrollView {
        VStack(spacing: 6) {
          ForEach(versions) { v in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(v.date.formatted(date: .abbreviated, time: .standard))
                Text("\(v.length.map(fmtTime) ?? "?") long. Differs from now: \(v.summary)")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Restore") {
                project.restoreVersion(v.id)
                project.showHistory = false
              }
              .disabled(v.summary == "same")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
          }
        }
      }
      HStack {
        Spacer()
        Button("Done") { project.showHistory = false }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 520, height: 520)
  }
}

/// Lays words out left to right, wrapping like text.
struct FlowLayout: Layout {
  var spacing: CGFloat = 3
  var lineSpacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 300
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
    for v in subviews {
      let s = v.sizeThatFits(.unspecified)
      if x > 0 && x + s.width > width {
        x = 0
        y += line + lineSpacing
        line = 0
      }
      x += s.width + spacing
      line = max(line, s.height)
    }
    return CGSize(width: width, height: y + line)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
    for v in subviews {
      let s = v.sizeThatFits(.unspecified)
      if x > bounds.minX && x + s.width > bounds.maxX {
        x = bounds.minX
        y += line + lineSpacing
        line = 0
      }
      v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
      x += s.width + spacing
      line = max(line, s.height)
    }
  }
}

/// The transcript as text: cut words struck through, sped-up words tinted. Click a word to jump
/// there; shift-click to select a run, then Cut (or ⌫) removes it from the edit.
struct TranscriptView: View {
  @ObservedObject var project: ProjectModel

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

  var body: some View {
    let words = project.words
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        if project.transcriptSel != nil {
          if project.transcriptSelectionIsCut {
            Button("Restore", action: project.restoreTranscriptSelection)
          } else {
            Button("Cut", action: project.cutTranscriptSelection)
          }
          Button("Deselect") { project.transcriptSel = nil }
        } else {
          Text("Click a word to jump there. Shift-click to select a run, then Cut.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if words.isEmpty {
        Text("No transcript yet. Analyze the recording first.").foregroundStyle(.secondary)
      }
      ForEach(Array(Self.sentences(words).enumerated()), id: \.offset) { _, sentence in
        FlowLayout {
          ForEach(sentence, id: \.self) { i in word(i, words[i]) }
        }
      }
    }
  }

  private func word(_ i: Int, _ w: Word) -> some View {
    let speed = project.plan?.speed(at: (w.start + w.end) / 2)
    let selected = project.transcriptSel?.contains(i) ?? false
    let playing = project.playheadSrc >= w.start && project.playheadSrc < w.end
    return Text(w.text)
      .strikethrough(speed == nil)
      .foregroundStyle(speed == nil ? Color.secondary.opacity(0.6) : (speed ?? 1) > 1.01 ? Color.orange : Color.primary)
      .padding(.horizontal, 2)
      .background(
        RoundedRectangle(cornerRadius: 3).fill(
          selected ? Theme.accent.opacity(0.35) : playing ? Color.yellow.opacity(0.25) : Color.clear))
      .onTapGesture { project.clickWord(i, extend: NSEvent.modifierFlags.contains(.shift)) }
      .help("\(fmtTime(w.start))\(speed == nil ? ", cut" : (speed ?? 1) > 1.01 ? ", \((speed ?? 1).formatted())x" : "")")
  }
}
