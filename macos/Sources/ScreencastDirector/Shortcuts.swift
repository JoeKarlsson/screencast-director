import AppKit
import DirectorCore
import SwiftUI

/// Editor keyboard shortcuts. Defaults match Screen Studio's (read from its action table), so the
/// same muscle memory works: Space, J/K/L, arrows, C to split, Backspace to remove, S for speed,
/// 1-4 for camera layouts, = and - for zoom level. Z (add zoom) and T (add title) are our own,
/// since Screen Studio has no default key for those.
struct Shortcut {
  enum Key: Equatable {
    case char(String)
    case code(UInt16)
  }

  let group: String
  let keys: String
  let title: String
  let key: Key
  let modifiers: NSEvent.ModifierFlags
  let action: (ProjectModel, EditorUI) -> Void

  static let all: [Shortcut] = [
    // Playback
    .init(group: "Playback", keys: "Space", title: "Play / Pause", key: .code(49), modifiers: []) { p, _ in p.togglePlay() },
    .init(group: "Playback", keys: "L", title: "Play, or play faster", key: .char("l"), modifiers: []) { p, _ in p.shuttleForward() },
    .init(group: "Playback", keys: "J", title: "Play backward, or faster", key: .char("j"), modifiers: []) { p, _ in p.shuttleBackward() },
    .init(group: "Playback", keys: "K", title: "Stop", key: .char("k"), modifiers: []) { p, _ in p.stop() },
    .init(group: "Playback", keys: "←", title: "Back one frame", key: .code(123), modifiers: []) { p, _ in p.step(frames: -1) },
    .init(group: "Playback", keys: "→", title: "Forward one frame", key: .code(124), modifiers: []) { p, _ in p.step(frames: 1) },
    .init(group: "Playback", keys: "⇧←", title: "Back one second (shrink a transcript selection)", key: .code(123), modifiers: .shift) { p, _ in
      if p.transcriptSel != nil { p.extendTranscriptSelection(-1) } else { p.step(frames: -Double(p.fps)) }
    },
    .init(group: "Playback", keys: "⇧→", title: "Forward one second (grow a transcript selection)", key: .code(124), modifiers: .shift) { p, _ in
      if p.transcriptSel != nil { p.extendTranscriptSelection(1) } else { p.step(frames: Double(p.fps)) }
    },
    .init(group: "Playback", keys: "⌘←", title: "Go to start", key: .code(123), modifiers: .command) { p, _ in p.goToStart() },
    .init(group: "Playback", keys: "⌘→", title: "Go to end", key: .code(124), modifiers: .command) { p, _ in p.goToEnd() },
    .init(group: "Timeline", keys: "⌘=", title: "Zoom timeline in", key: .char("="), modifiers: .command) { p, e in
      e.timeline.zoom(by: 1.4, around: e.timeline.outputTime ? p.outFrame / Double(p.fps) : p.playheadSrc)
    },
    .init(group: "Timeline", keys: "⌘-", title: "Zoom timeline out", key: .char("-"), modifiers: .command) { p, e in
      e.timeline.zoom(by: 1 / 1.4, around: e.timeline.outputTime ? p.outFrame / Double(p.fps) : p.playheadSrc)
    },
    // Clips
    .init(group: "Clips", keys: "C", title: "Split at playhead", key: .char("c"), modifiers: []) { p, _ in p.splitAtPlayhead() },
    .init(group: "Clips", keys: "⌫", title: "Remove the selection, or restore a cut", key: .code(51), modifiers: []) { p, _ in
      p.deleteSelection()
    },
    .init(group: "Clips", keys: "X", title: "Remove from previous cut to playhead", key: .char("x"), modifiers: []) { p, _ in
      p.removeToPreviousCut()
    },
    .init(group: "Clips", keys: "S", title: "Change clip speed", key: .char("s"), modifiers: []) { p, _ in p.cycleSpeed() },
    .init(group: "Clips", keys: "Esc", title: "Deselect", key: .code(53), modifiers: []) { p, _ in
      p.selection = nil
      p.multi = []
      p.transcriptSel = nil
    },
    .init(group: "Project", keys: "⌥⌘T", title: "Show or hide the transcript", key: .char("t"), modifiers: [.command, .option]) { _, e in
      withAnimation(.snappy) { e.showTranscript.toggle() }
    },
    // Zooms
    .init(group: "Zoom", keys: "Z", title: "Add zoom at playhead", key: .char("z"), modifiers: []) { p, _ in p.addZoom() },
    .init(group: "Zoom", keys: "=", title: "Increase zoom level", key: .char("="), modifiers: []) { p, _ in p.nudgeZoom(0.2) },
    .init(group: "Zoom", keys: "-", title: "Decrease zoom level", key: .char("-"), modifiers: []) { p, _ in p.nudgeZoom(-0.2) },
    .init(group: "Zoom", keys: "⌘D", title: "Duplicate zoom", key: .char("d"), modifiers: .command) { p, _ in p.duplicateZoom() },
    // Layouts
    .init(group: "Camera layout", keys: "⌃L", title: "Add layout at playhead", key: .char("l"), modifiers: .control) { p, _ in
      p.addLayout(.pip)
    },
    .init(group: "Camera layout", keys: "1", title: "Camera bubble", key: .char("1"), modifiers: []) { p, _ in p.setLayoutMode(.pip) },
    .init(group: "Camera layout", keys: "2", title: "Camera only", key: .char("2"), modifiers: []) { p, _ in p.setLayoutMode(.camera) },
    .init(group: "Camera layout", keys: "3", title: "Hide camera", key: .char("3"), modifiers: []) { p, _ in p.setLayoutMode(.screen) },
    .init(group: "Camera layout", keys: "4", title: "Side by side", key: .char("4"), modifiers: []) { p, _ in p.setLayoutMode(.side) },
    // Other
    .init(group: "Titles", keys: "T", title: "Add title at playhead", key: .char("t"), modifiers: []) { p, _ in p.addCallout() },
    .init(group: "Markers and ranges", keys: "M", title: "Add a marker at the playhead", key: .char("m"), modifiers: []) { p, _ in p.addMarker() },
    .init(group: "Markers and ranges", keys: ";", title: "Previous marker", key: .char(";"), modifiers: []) { p, _ in p.jumpMarker(-1) },
    .init(group: "Markers and ranges", keys: "'", title: "Next marker", key: .char("'"), modifiers: []) { p, _ in p.jumpMarker(1) },
    .init(group: "Markers and ranges", keys: "I", title: "Mark in", key: .char("i"), modifiers: []) { p, _ in p.markIn() },
    .init(group: "Markers and ranges", keys: "O", title: "Mark out", key: .char("o"), modifiers: []) { p, _ in p.markOut() },
    .init(group: "Markers and ranges", keys: "⌥X", title: "Clear in and out", key: .char("x"), modifiers: .option) { p, _ in p.clearInOut() },
    .init(group: "Timeline", keys: "⌘A", title: "Select every zoom, layout, title and annotation", key: .char("a"), modifiers: .command) { p, _ in
      p.selectAllItems()
    },
    .init(group: "Titles", keys: "A", title: "Add a box at playhead", key: .char("a"), modifiers: []) { p, _ in p.addAnnotation("box") },
    .init(group: "Timeline", keys: "⌥←", title: "Nudge selection back a frame", key: .code(123), modifiers: .option) { p, _ in
      p.nudgeSelection(frames: -1)
    },
    .init(group: "Timeline", keys: "⌥→", title: "Nudge selection forward a frame", key: .code(124), modifiers: .option) { p, _ in
      p.nudgeSelection(frames: 1)
    },
    .init(group: "Project", keys: "⌘⇧E", title: "Export", key: .char("e"), modifiers: [.command, .shift]) { p, _ in p.export() },
    .init(group: "Project", keys: "⌘⇧O", title: "Show in Finder", key: .char("o"), modifiers: [.command, .shift]) { p, _ in
      NSWorkspace.shared.activateFileViewerSelecting([p.planURL])
    },
    .init(group: "Project", keys: "⌘1", title: "Background & frame inspector", key: .char("1"), modifiers: .command) { _, e in e.inspector.tab = .style },
  ]

  func matches(_ event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
    switch key {
    case .code(let c):
      return event.keyCode == c && mods == modifiers
    case .char(let ch):
      // ⌘⇧E arrives as "e" with ⇧ in the flags; compare unshifted characters.
      return event.charactersIgnoringModifiers?.lowercased() == ch && mods == modifiers
    }
  }
}

/// ⌘/ shows every shortcut, as in Screen Studio.
struct ShortcutsView: View {
  var body: some View {
    let groups = Shortcut.all.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Keyboard Shortcuts").font(.title2.bold())
        Text(
          "Recording: ⌃⌥⌘R from any app. Retake (cut the line you just said, then say it again): ⌃⌥⌘M. Undo/Redo: ⌘Z / ⇧⌘Z. "
            + "Single-letter keys work when you're not typing in a text field.")
          .font(.callout).foregroundStyle(.secondary)
        ForEach(groups, id: \.self) { g in
          VStack(alignment: .leading, spacing: 4) {
            Text(g).font(.headline)
            ForEach(Shortcut.all.filter { $0.group == g }, id: \.title) { s in
              HStack {
                Text(s.title)
                Spacer()
                Text(s.keys).font(.system(.body, design: .monospaced))
                  .padding(.horizontal, 6).padding(.vertical, 1)
                  .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
              }
            }
          }
        }
      }
      .padding(22)
    }
    .frame(width: 440, height: 620)
  }
}
