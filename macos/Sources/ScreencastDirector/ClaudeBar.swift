import AVKit
import AppKit
import DirectorCore
import SwiftUI

// MARK: AI editing

/// Ask the AI for an edit: a glass prompt box, starter ideas, and what you asked and what it did.
struct ClaudeBar: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var editor: EditorUI
  @ObservedObject var ai = AISettings.shared
  @FocusState private var focused: Bool

  static let ideas = [
    "Cut my retakes", "Tighten the pauses", "Zoom in when I click", "Add chapter cards at each new section",
    "A lower third with my name at the start", "Box what I click on", "Blur any emails or keys on screen", "Make it feel cinematic",
    "Side by side for the intro",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !project.asks.isEmpty { history }
      HStack(spacing: 10) {
        Image(systemName: "sparkles").foregroundStyle(Theme.ai).font(.system(size: 15, weight: .semibold))
        TextField("Ask \(ai.provider.shortName) to edit…", text: $project.instruction, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...4)
          .focused($focused)
          .onSubmit(project.askClaude)
          .onChange(of: editor.focusAsk) { _, _ in focused = true }
        if project.busy && project.asks.last?.running == true {
          ProgressView().controlSize(.small)
          Button(action: project.stopAsk) {
            Image(systemName: "stop.circle.fill").font(.system(size: 22)).foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("Stop. What it already changed stays, and ⌘Z undoes it.")
          .accessibilityLabel("Stop")
        } else {
          Button(action: project.askClaude) {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
              .foregroundStyle(project.instruction.isEmpty ? Color.secondary.opacity(0.5) : Theme.ai)
          }
          .buttonStyle(.plain)
          .disabled(project.busy || !project.hasPlan || project.instruction.isEmpty)
          .help("Ask \(ai.provider.shortName) (Return). ⌘Z undoes its edit.")
          .accessibilityLabel("Ask \(ai.provider.shortName)")
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .glassCard(cornerRadius: 20)
      HStack(spacing: 6) {
        // Which AI answers, and a way to set it up when it can't yet.
        Circle().fill(ai.isReady ? Theme.ok : Theme.warning).frame(width: 6, height: 6)
        Text(ai.provider == .claudeCode ? "Claude Code" : ai.provider == .anthropic ? ai.anthropicModel : ai.model)
          .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        if !ai.isReady {
          SettingsLink { Text("Set up…").font(.caption2) }.buttonStyle(.link)
        }
        Spacer()
        if project.transcriptSel != nil || project.selection != nil {
          Label("Knows your selection and playhead", systemImage: "scope").font(.caption2).foregroundStyle(.secondary)
            .help(project.askContext())
        }
      }
      .padding(.horizontal, 6)
      if project.asks.isEmpty && project.instruction.isEmpty && project.hasPlan {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(Self.ideas, id: \.self) { idea in
              Button(idea) { project.instruction = idea }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            }
          }
        }
      }
    }
  }

  /// "8 steps · 42 s", with how many failed.
  private func stepsSummary(_ ask: Ask, failed: Int) -> String {
    var parts = [ask.steps.count == 1 ? "1 step" : "\(ask.steps.count) steps"]
    if failed > 0 { parts.append("\(failed) failed") }
    if let s = ask.seconds { parts.append(String(format: "%.0f s", s)) }
    return parts.joined(separator: " · ")
  }

  private var history: some View {
    ScrollViewReader { scroll in
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(project.asks) { ask in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Spacer(minLength: 40)
                if ask.rewound {
                  Text("Rewound").font(.caption).foregroundStyle(.secondary)
                } else if !ask.running && !project.busy && project.canRewind(ask.id) {
                  Button { project.rewind(to: ask.id) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.caption)
                  }
                  .buttonStyle(.plain)
                  .foregroundStyle(.tertiary)
                  .help("Rewind to before this ask")
                  .accessibilityLabel("Rewind to before this ask")
                }
                Text(ask.instruction)
                  .padding(.horizontal, 10).padding(.vertical, 6)
                  .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.2)))
              }
              if ask.running, !ask.steps.isEmpty {
                // The last few steps, newest last, so you can see it working.
                VStack(alignment: .leading, spacing: 2) {
                  ForEach(Array(ask.steps.suffix(4).enumerated()), id: \.offset) { i, step in
                    let current = i == min(ask.steps.count, 4) - 1
                    Label(step.text, systemImage: step.failed == true ? "xmark" : current ? "circle.dotted" : "checkmark")
                      .font(.caption).foregroundStyle(step.failed == true ? Theme.error : current ? .primary : .secondary)
                  }
                }
                .padding(.leading, 20)
              } else if !ask.running, !ask.steps.isEmpty {
                // Every step it took, folded: which ones failed and how long each ran.
                DisclosureGroup {
                  VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(ask.steps.enumerated()), id: \.offset) { _, step in
                      HStack(spacing: 6) {
                        Label(step.text, systemImage: step.failed == true ? "xmark" : "checkmark")
                          .foregroundStyle(step.failed == true ? Theme.error : .secondary)
                        Spacer()
                        if let s = step.seconds { Text(String(format: "%.1f s", s)).monospacedDigit().foregroundStyle(.tertiary) }
                      }
                      .font(.caption)
                    }
                  }
                } label: {
                  let failed = ask.steps.filter { $0.failed == true }.count
                  Text(stepsSummary(ask, failed: failed))
                    .font(.caption).monospacedDigit().foregroundStyle(failed > 0 ? Theme.error : .secondary)
                }
                .help("The steps it took")
                .padding(.leading, 20)
              }
              if !ask.reply.isEmpty || ask.running {
                HStack(alignment: .top, spacing: 6) {
                  Image(systemName: "sparkles").foregroundStyle(Theme.ai).font(.caption)
                  Text(ask.reply.isEmpty ? "Working…" : ask.reply)
                    .foregroundStyle(ask.reply.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
              if !ask.changes.isEmpty { changeList(ask) }
            }
            .font(.callout)
            .opacity(ask.rewound ? 0.45 : 1)
            .id(ask.id)
          }
        }
        .padding(10)
      }
      // A floor, or the preview's layout priority squeezes it to a line.
      .frame(
        minHeight: project.asks.last?.changes.isEmpty == false ? 150 : 84,
        maxHeight: project.asks.last?.changes.isEmpty == false ? 220 : 120)
      .card(padding: 0)
      .onChange(of: project.asks.last?.reply) { _, _ in
        if let id = project.asks.last?.id { scroll.scrollTo(id, anchor: .bottom) }
      }
    }
  }
}

extension ClaudeBar {
  /// What the edit changed, each with Undo (and a click to jump there), plus Keep All.
  func changeList(_ ask: Ask) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text("\(ask.changes.count) change\(ask.changes.count == 1 ? "" : "s")").font(.caption.weight(.semibold))
        Spacer()
        Button("Keep All") { project.acceptAllChanges(in: ask.id) }.controlSize(.small)
      }
      ForEach(ask.changes) { change in
        HStack(spacing: 6) {
          Image(systemName: Self.icon(change.kind)).foregroundStyle(Theme.ai).frame(width: 14)
          Button {
            if let r = change.range { project.seek(src: r.0) }
          } label: {
            Text(change.label).lineLimit(1).truncationMode(.tail)
          }
          .buttonStyle(.plain)
          .help(change.range == nil ? change.label : "Jump to \(fmtTime(change.range!.0))")
          Spacer()
          Button("Undo") { project.rejectChange(change, in: ask.id) }.controlSize(.mini)
            .help("Put just this back the way it was")
          Button {
            project.dropChange(change.id, in: ask.id)
          } label: {
            Image(systemName: "checkmark")
          }
          .controlSize(.mini)
          .help("Keep it")
          .accessibilityLabel("Keep")
        }
        .font(.caption)
      }
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    .padding(.leading, 20)
  }

  static func icon(_ kind: String) -> String {
    switch kind {
    case "clips": return "scissors"
    case "zoom": return "plus.magnifyingglass"
    case "layout": return "rectangle.split.2x1"
    case "title": return "textformat"
    case "annotation": return "scribble"
    default: return "paintpalette"
    }
  }
}
