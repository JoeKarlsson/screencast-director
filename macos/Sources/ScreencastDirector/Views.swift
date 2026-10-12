import AVKit
import AppKit
import DirectorCore
import SwiftUI

// View state lives in ObservableObjects: @State needs Swift macro plugins, which the
// Command Line Tools don't ship.

final class EditorUI: ObservableObject {
  let timeline = TimelineUI()
  let inspector = InspectorUI()
  @Published var showInspector = true
}

struct MainView: View {
  let app: AppDelegate
  @ObservedObject var library: Library
  @ObservedObject var recorder: Recorder
  @ObservedObject var setup: SetupModel
  @ObservedObject var editor: EditorUI

  var body: some View {
    NavigationSplitView {
      LibrarySidebar(library: library, setup: setup, posters: PosterCache.shared)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      Group {
        if let project = library.current {
          EditorView(project: project, editor: editor)
        } else {
          SetupView(setup: setup, record: app.showRecordSetup, importVideo: app.importVideo, watchTour: app.watchTour)
            .navigationTitle("Screencast Director")
        }
      }
      .overlay(alignment: .top) { NoticeBanner(notices: Notices.shared) }
    }
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

// MARK: Library

/// Recordings with a poster frame, length, date and how far along each one is.
struct LibrarySidebar: View {
  @ObservedObject var library: Library
  @ObservedObject var setup: SetupModel
  @ObservedObject var posters: PosterCache

  var body: some View {
    List(selection: $library.selection) {
      Section("Recordings") {
        ForEach(library.filtered, id: \.self) { url in
          row(url).tag(url as URL?)
            .contextMenu {
              Button("Rename") { library.beginRename(url) }
              Button("Suggest a Name with \(AISettings.shared.provider.shortName)") { library.suggestName(url) }
              Divider()
              Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
      }
    }
    .searchable(text: $library.search, placement: .sidebar, prompt: "Search names and what you said")
    .overlay {
      if library.filtered.isEmpty {
        ContentUnavailableView(
          library.search.isEmpty ? "No Recordings Yet" : "No Matches",
          systemImage: library.search.isEmpty ? "film.stack" : "magnifyingglass",
          description: Text(library.search.isEmpty ? "Press ⌘N to record, or import a video." : "Nothing named or said like that."))
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        if !library.status.isEmpty {
          Text(library.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        Button {
          library.selection = nil
        } label: {
          Label(
            setup.allRequiredOK ? "Getting Started" : "Finish Setup",
            systemImage: setup.allRequiredOK ? "questionmark.circle" : "exclamationmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(setup.allRequiredOK ? Color.secondary : Color.orange)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func row(_ url: URL) -> some View {
    let info = library.info(url)
    return HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08))
        if let img = posters.images[url] {
          Image(nsImage: img).resizable().scaledToFill()
        } else {
          Image(systemName: "film").foregroundStyle(.tertiary)
        }
      }
      .frame(width: 64, height: 40)
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
      .onAppear { posters.load(url) }

      VStack(alignment: .leading, spacing: 2) {
        if library.renaming == url {
          TextField("Name", text: $library.renameText)
            .textFieldStyle(.roundedBorder)
            .onSubmit(library.commitRename)
            .onExitCommand { library.renaming = nil }
        } else {
          Text(url.lastPathComponent).lineLimit(2).font(.body)
        }
        HStack(spacing: 6) {
          Text(info.duration > 0 ? fmtTime(info.duration) : "–").monospacedDigit()
          Text(info.date.formatted(.dateTime.month(.abbreviated).day()))
          stageBadge(info.stage)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
    .onTapGesture(count: 2) { library.beginRename(url) }
    .simultaneousGesture(TapGesture().onEnded { library.selection = url })
  }

  @ViewBuilder
  private func stageBadge(_ stage: Library.Stage) -> some View {
    switch stage {
    case .new: badge("New", .blue)
    case .edited: EmptyView()
    case .exported: badge("Exported", .green)
    }
  }

  private func badge(_ text: String, _ color: Color) -> some View {
    Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
      .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
  }
}

/// Poster frames for the sidebar, made once per recording per launch.
final class PosterCache: ObservableObject {
  static let shared = PosterCache()
  @Published private(set) var images: [URL: NSImage] = [:]
  private var loading: Set<URL> = []

  func load(_ url: URL) {
    guard images[url] == nil, !loading.contains(url) else { return }
    loading.insert(url)
    let source = (try? Data(contentsOf: url.appendingPathComponent("source.json"))).flatMap { try? JSONDecoder().decode(Project.Source.self, from: $0) }
    let video = url.appendingPathComponent(source?.video ?? "screen.mp4")
    let at = min(2, (source?.duration ?? 0) / 3)
    Task { @MainActor in
      let gen = AVAssetImageGenerator(asset: AVURLAsset(url: video))
      gen.appliesPreferredTrackTransform = true
      gen.maximumSize = CGSize(width: 256, height: 160)
      if let (cg, _) = try? await gen.image(at: CMTime(seconds: at, preferredTimescale: 600)) {
        images[url] = NSImage(cgImage: cg, size: .zero)
      }
      loading.remove(url)
    }
  }
}

// MARK: Editor

struct PlayerView: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let v = AVPlayerView()
    v.controlsStyle = .none
    v.player = player
    return v
  }
  func updateNSView(_ v: AVPlayerView, context: Context) {
    if v.player !== player { v.player = player }
  }
}

struct EditorView: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var editor: EditorUI

  var body: some View {
    VStack(spacing: 0) {
      stage
      TransportBar(project: project)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      Divider()
      VStack(spacing: 10) {
        TimelineView(project: project, ui: editor.timeline)
        ClaudeBar(project: project)
      }
      .padding(12)
    }
    .frame(minWidth: 560)
    .navigationTitle(project.name)
    .navigationSubtitle(project.status)
    .inspector(isPresented: $editor.showInspector) {
      InspectorView(project: project, ui: editor.inspector)
    }
    .toolbar { EditorToolbar(project: project, editor: editor) }
    .sheet(isPresented: $project.showPublish) { PublishView(project: project) }
    .sheet(isPresented: $project.showHistory) { VersionHistoryView(project: project) }
  }

  /// The preview, at the output's shape, on a dark stage.
  private var stage: some View {
    let w = project.plan.map { Double($0.output.width) } ?? project.project?.source.width ?? 16
    let h = project.plan.map { Double($0.output.height) } ?? project.project?.source.height ?? 9
    return ZStack {
      LinearGradient(colors: [Color(white: 0.11), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
      PlayerView(player: project.player)
        .aspectRatio(CGFloat(w) / CGFloat(max(h, 1)), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .padding(20)
        .onTapGesture(perform: project.togglePlay)
      if project.busy {
        VStack {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(project.status).font(.callout).lineLimit(1)
          }
          .padding(.horizontal, 12).padding(.vertical, 7)
          .glassCard(cornerRadius: 16)
          .environment(\.colorScheme, .dark)
          Spacer()
        }
        .padding(.top, 12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .layoutPriority(1)
  }
}

/// Play, step and scrub, under the preview.
struct TransportBar: View {
  @ObservedObject var project: ProjectModel

  var body: some View {
    let total = Double(max(project.totalOutFrames - 1, 1))
    let fps = Double(project.fps)
    HStack(spacing: 12) {
      HStack(spacing: 4) {
        icon("backward.end.fill", "Go to start (⌘←)", action: project.goToStart)
        Button(action: project.togglePlay) {
          Image(systemName: project.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 34, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play/Pause (Space; J/K/L to shuttle)")
        .accessibilityLabel(project.isPlaying ? "Pause" : "Play")
        icon("forward.end.fill", "Go to end (⌘→)", action: project.goToEnd)
      }
      Text(fmtTime(project.outFrame / fps)).monospacedDigit()
        .frame(width: 56, alignment: .trailing)
      Slider(value: Binding(get: { min(project.outFrame, total) }, set: { project.seek(outFrame: $0) }), in: 0...total)
        .controlSize(.small)
        .disabled(!project.hasPlan)
      Text(fmtTime(Double(project.totalOutFrames) / fps)).monospacedDigit().foregroundStyle(.secondary)
        .frame(width: 56, alignment: .leading)
    }
    .font(.system(.callout, design: .rounded))
  }

  private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 24).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
  }
}

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
        Button("Version History…") { project.showHistory = true }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.planURL]) }
      } label: { Label("More", systemImage: "ellipsis.circle") }
        .help("Re-analyze, version history, Show in Finder")
      if project.hasPlan {
        Button { project.openPublish() } label: { Label("Publish", systemImage: "megaphone") }
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
          Button("GIF (for docs)…") { project.exportGIF() }.disabled(project.busy)
          Button("Upload and Copy Link…") { project.uploadAndCopyLink() }.disabled(project.busy)
        } label: {
          Label("Export", systemImage: "square.and.arrow.up")
        } primaryAction: {
          project.export()
        }
        .help("Export the video (⌘⇧E); the arrow has formats, GIF and upload")
      } else {
        Button { project.analyzeAndPlan() } label: { Label("Analyze", systemImage: "wand.and.stars") }
          .disabled(project.busy)
      }
      Button { editor.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        .help("Show or hide the inspector (⌥⌘I)")
    }
  }
}

// MARK: AI editing

/// Ask the AI for an edit: a glass prompt box, starter ideas, and what you asked and what it did.
struct ClaudeBar: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ai = AISettings.shared

  static let ideas = [
    "Cut my retakes", "Tighten the pauses", "Zoom in when I click", "Side by side for the intro", "Add a title at the start",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !project.asks.isEmpty { history }
      HStack(spacing: 10) {
        Image(systemName: "sparkles").foregroundStyle(Theme.ai).font(.system(size: 15, weight: .semibold))
        TextField("Ask \(ai.provider.shortName) to edit…", text: $project.instruction, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...4)
          .onSubmit(project.askClaude)
        if project.busy && project.asks.last?.running == true {
          ProgressView().controlSize(.small)
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

  private var history: some View {
    ScrollViewReader { scroll in
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(project.asks) { ask in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Spacer(minLength: 40)
                Text(ask.instruction)
                  .padding(.horizontal, 10).padding(.vertical, 6)
                  .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.2)))
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
            }
            .font(.callout)
            .id(ask.id)
          }
        }
        .padding(10)
      }
      .frame(maxHeight: 120)
      .card(padding: 0)
      .onChange(of: project.asks.last?.reply) { _, _ in
        if let id = project.asks.last?.id { scroll.scrollTo(id, anchor: .bottom) }
      }
    }
  }
}

struct PublishView: View {
  @ObservedObject var project: ProjectModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Publish").font(.title2.bold())
        Spacer()
        if project.busy { ProgressView().controlSize(.small) }
        Text(project.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      TextField("Video title (used on thumbnails and in the description)", text: $project.publishTitle)
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("Make Captions, Chapters & Thumbnails", action: project.makePublishKit)
        Button("Draft YouTube Description with \(AISettings.shared.provider.shortName)", action: project.draftDescription)
        Spacer()
        Button("Show in Finder") {
          try? FileManager.default.createDirectory(at: project.publishDir, withIntermediateDirectories: true)
          NSWorkspace.shared.open(project.publishDir)
        }
      }
      .disabled(project.busy)

      let thumbs = project.publishFiles.filter { $0.pathExtension == "png" }
      if !thumbs.isEmpty {
        Text("Thumbnails: your clearest smiling camera frames, with the title in your profile's style").font(.headline)
        ScrollView(.horizontal) {
          HStack(spacing: 10) {
            ForEach(thumbs, id: \.self) { url in
              if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fit).frame(height: 150)
                  .clipShape(RoundedRectangle(cornerRadius: 8))
                  .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                  .help(url.lastPathComponent)
              }
            }
          }
        }
      }
      let other = project.publishFiles.filter { $0.pathExtension != "png" }
      if !other.isEmpty {
        Text("Files").font(.headline)
        ForEach(other, id: \.self) { url in
          HStack {
            Text(url.lastPathComponent).font(.system(.body, design: .monospaced))
            Spacer()
            Button("Copy") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString((try? String(contentsOf: url, encoding: .utf8)) ?? "", forType: .string)
            }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
        }
      }
      if !project.descriptionText.isEmpty {
        Text("Description draft").font(.headline)
        ScrollView {
          Text(project.descriptionText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 140)
      }
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button("Done") { project.showPublish = false }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 760, height: 620)
  }
}
