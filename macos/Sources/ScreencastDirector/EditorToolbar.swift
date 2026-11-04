import AVKit
import AppKit
import DirectorCore
import SwiftUI

struct EditorToolbar: ToolbarContent {
  @ObservedObject var project: ProjectModel
  @ObservedObject var editor: EditorUI

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      ControlGroup {
        Button { project.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
          .disabled(!project.canUndo).help("Undo (⌘Z)")
        Button { project.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
          .disabled(!project.canRedo).help("Redo (⇧⌘Z)")
      }
      Menu {
        Button("Re-analyze (keep my edits)") { project.analyzeAndPlan() }
        Button("Start Over from a Fresh Draft") { project.analyzeAndPlan(force: true) }
        Button("Check Edit") { project.checkEdit() }
          .help("Look for cuts that clip a word and shots too short to read")
        Button("Version History…") { project.showHistory = true }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.planURL]) }
      } label: { Label("More", systemImage: "ellipsis.circle") }
        .help("Re-analyze, version history, Show in Finder")
      if project.hasPlan {
        Button { project.openPublish() } label: { Label("Publish", systemImage: "paperplane") }
          .disabled(project.busy)
          .help("Captions (SRT), chapters, a YouTube description draft and thumbnails")
        ExportQueueButton(queue: ExportQueue.shared)
        Menu {
          Button("Export Current Format") { project.export() }
          Divider()
          ForEach(ExportPreset.all, id: \.id) { p in Button(p.name) { project.export([p]) } }
          Divider()
          Button("All of the Above") { project.export(ExportPreset.all.map { Optional($0) }) }
          Divider()
          if let clips = project.plan?.clipList, !clips.isEmpty {
            Section("Clips") {
              Button("All Clips") { project.exportClips(clips) }
              ForEach(clips, id: \.name) { c in Button("\(c.name) (\(c.preset?.fileLabel ?? "current format"))") { project.exportClips([c]) } }
            }
            Divider()
          }
          Button("GIF (for docs)…") { project.exportGIF() }.disabled(project.busy)
          if SharingSettings.shared.config == nil {
            Button("Upload and Copy Link (set up in Settings › Sharing)") {}.disabled(true)
          } else {
            Button("Upload and Copy Link…") { project.uploadAndCopyLink() }.disabled(project.busy)
          }
        } label: {
          Label("Export", systemImage: "square.and.arrow.up")
        } primaryAction: {
          project.export()
        }
        .help("Export the video (⌘⇧E); the arrow has formats, GIF and upload")
      } else {
        Button { project.analyzeAndPlan() } label: { Label("Analyze", systemImage: "wand.and.stars").labelStyle(.titleAndIcon) }
          .disabled(project.busy)
          .help("Transcribe, measure motion and draft the edit")
      }
      Button { withAnimation(.snappy) { editor.showTranscript.toggle() } } label: { Label("Transcript", systemImage: "text.quote") }
        .help("Edit by text: select words to cut them or add a zoom, title or annotation (⌥⌘T)")
      Button { withAnimation(.snappy) { editor.showInspector.toggle() } } label: { Label("Inspector", systemImage: "sidebar.right") }
        .help("Show or hide the inspector (⌥⌘I)")
    }
  }
}
