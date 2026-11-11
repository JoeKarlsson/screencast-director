import AVKit
import AppKit
import DirectorCore
import SwiftUI

// View state lives in ObservableObjects: @State needs Swift macro plugins, which the
// Command Line Tools don't ship.

final class EditorUI: ObservableObject {
  let timeline = TimelineUI()
  let inspector = InspectorUI()
  let transcript = TranscriptUI()
  @Published var showInspector = true
  /// The transcript beside the preview, for editing by text.
  @Published var showTranscript = false
  /// Bumped to focus the AI box (the transcript's Ask AI fills it first).
  @Published var focusAsk = 0
  /// The project whose preview has loaded. Only the first load gets the loading cover;
  /// the rebuild after each edit keeps showing the previous frame.
  @Published var frameShownFor: URL?
  /// How far the camera bubble has been dragged in the preview (points), until the drag ends.
  let bubbleDrag = BubbleDragUI()
  /// How far the captions have been dragged in the preview, until the drag ends.
  let captionDrag = BubbleDragUI()
  /// The sticker or overlay being moved, sized or turned in the preview, until the drag ends.
  let placeDrag = PlaceDragUI()
}

struct MainView: View {
  let app: AppDelegate
  @ObservedObject var library: Library
  @ObservedObject var recorder: Recorder
  @ObservedObject var setup: SetupModel
  @ObservedObject var editor: EditorUI
  let home = HomeUI()

  var body: some View {
    NavigationSplitView {
      LibrarySidebar(library: library, setup: setup, posters: PosterCache.shared)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      Group {
        if let project = library.current {
          EditorView(project: project, editor: editor)
            .id(project.dir)
            .transition(.opacity)
        } else {
          HomeView(
            library: library, setup: setup, posters: PosterCache.shared, ui: home, record: app.showRecordSetup,
            importVideo: app.importVideo, watchTour: app.watchTour
          )
          .navigationTitle("Screencast Director")
          .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.2), value: library.current?.dir)
      .overlay(alignment: .top) { NoticeBanner(notices: Notices.shared) }
    }
    .tint(Theme.accent)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(action: recorder.isRecording ? app.toggleRecording : app.showRecordSetup) {
          Label {
            Text(recorder.isRecording ? "Stop" : "Record")
          } icon: {
            Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, Theme.recording)
          }
        }
        .help(recorder.isRecording ? "Stop recording (⌃⌥⌘R)" : "New recording (⌘N; ⌃⌥⌘R from any app records right away)")
      }
    }
  }
}
