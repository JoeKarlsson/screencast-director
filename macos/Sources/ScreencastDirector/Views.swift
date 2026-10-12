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

// MARK: Library

/// Recordings with a poster frame, length, date and how far along each one is.
struct LibrarySidebar: View {
  @ObservedObject var library: Library
  @ObservedObject var setup: SetupModel
  @ObservedObject var posters: PosterCache

  var body: some View {
    List(selection: $library.selection) {
      Section {
        ForEach(library.filtered, id: \.self) { url in
          row(url).tag(url as URL?)
            .contextMenu {
              Button("Rename") { library.beginRename(url) }
              Button("Suggest a Name with \(AISettings.shared.provider.shortName)") { library.suggestName(url) }
              Divider()
              Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
      } header: {
        HStack {
          Text("Recordings")
          Spacer()
          Menu {
            Picker("Sort By", selection: $library.sort) {
              ForEach(Library.Sort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
          } label: {
            Label(library.sort.label, systemImage: "arrow.up.arrow.down")
              .labelStyle(.titleAndIcon)
              .font(.caption)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Sort recordings")
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
          StageBadge(stage: info.stage)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
    .onTapGesture(count: 2) { library.beginRename(url) }
    .simultaneousGesture(TapGesture().onEnded { library.selection = url })
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
      gen.maximumSize = CGSize(width: 640, height: 400)
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
  @ObservedObject var posters = PosterCache.shared

  /// The preview isn't ready (building the composition) or there's nothing to show yet (analyzing).
  private var loading: Bool {
    (project.hasPlan && editor.frameShownFor != project.dir) || (!project.hasPlan && project.busy)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        if editor.showTranscript {
          ScrollView {
            TranscriptView(project: project, playhead: project.playhead, ui: editor.transcript) { prompt in
              project.instruction = prompt
              editor.focusAsk += 1
            }
            .padding(14)
          }
          .frame(width: 360)
          .background(Color.primary.opacity(0.02))
          .transition(.move(edge: .leading).combined(with: .opacity))
          Divider()
        }
        stage
      }
      TransportBar(project: project)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
      Divider()
      VStack(spacing: 10) {
        TimelineView(project: project, ui: editor.timeline)
        ClaudeBar(project: project, editor: editor)
      }
      .padding(12)
    }
    .frame(minWidth: 560)
    .navigationTitle(project.name)
    .navigationSubtitle(project.status)
    .inspector(isPresented: $editor.showInspector) {
      InspectorView(project: project, ui: editor.inspector, transcriptUI: editor.transcript)
    }
    .toolbar { EditorToolbar(project: project, editor: editor) }
    .sheet(isPresented: $project.showPublish) { PublishView(project: project) }
    .sheet(isPresented: $project.showHistory) { VersionHistoryView(project: project) }
  }

  /// The preview, at the output's shape, on a dark stage.
  private var stage: some View {
    let w = project.plan.map { Double($0.output.width) } ?? project.project?.source.width ?? 16
    let h = project.plan.map { Double($0.output.height) } ?? project.project?.source.height ?? 9
    let aspect = CGFloat(w) / CGFloat(max(h, 1))
    return ZStack {
      LinearGradient(colors: [Color(white: 0.11), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
      PlayerView(player: project.player)
        .aspectRatio(aspect, contentMode: .fit)
        .overlay { if loading { loadingCover.transition(.opacity) } }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .padding(20)
        .onTapGesture(perform: project.togglePlay)
        .animation(.easeOut(duration: 0.3), value: loading)
      if project.busy && !loading {
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
    .onAppear {
      posters.load(project.dir)
      revealWhenReady()
    }
    .onChange(of: project.previewReady) { _, _ in revealWhenReady() }
  }

  /// Lifts the loading cover once the first preview is ready, a beat later so the player has drawn.
  private func revealWhenReady() {
    guard project.previewReady, editor.frameShownFor != project.dir else { return }
    let dir = project.dir
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editor.frameShownFor = dir }
  }

  /// A blurred poster frame with what's happening, until the preview can play.
  private var loadingCover: some View {
    ZStack {
      Color.black
      if let poster = posters.images[project.dir] {
        Image(nsImage: poster).resizable().scaledToFill().blur(radius: 28).opacity(0.55).clipped()
      }
      VStack(spacing: 10) {
        ProgressView().controlSize(.large)
        Text(project.busy ? project.status : "Loading preview…").font(.headline).lineLimit(1)
      }
      .padding(.horizontal, 22).padding(.vertical, 16)
      .glassCard(cornerRadius: 18)
      .environment(\.colorScheme, .dark)
    }
  }
}

/// The clock and scrubber: the only part of the transport that follows the playhead.
struct TransportScrubber: View {
  let project: ProjectModel
  @ObservedObject var playhead: Playhead
  let total: Double
  let fps: Double

  var body: some View {
    Text(fmtTime(playhead.frame / fps)).monospacedDigit()
      .frame(width: 56, alignment: .trailing)
    Slider(value: Binding(get: { min(playhead.frame, total) }, set: { project.seek(outFrame: $0) }), in: 0...total)
      .controlSize(.small)
      .disabled(!project.hasPlan)
      .accessibilityLabel("Playhead")
      .background(alignment: .bottom) {
        if let plan = project.plan { OutputMap(plan: plan, mapped: project.mapped).equatable().frame(height: 4).offset(y: 9).padding(.horizontal, 2) }
      }
  }
}

/// The finished video's shape under the scrubber: intro and outro cards, clips at real-time (blue)
/// or sped up (orange), titles and zooms as ticks. Cut parts don't appear, so it matches the export.
struct OutputMap: View, Equatable {
  let plan: Plan
  let mapped: [MappedSegment]

  var body: some View {
    Canvas { ctx, size in
      let total = Double(planFrames(plan))
      guard total > 0 else { return }
      func x(_ f: Double) -> CGFloat { CGFloat(f / total) * size.width }
      let cards = cardFrames(plan)
      if cards.intro > 0 { ctx.fill(Path(CGRect(x: 0, y: 0, width: x(Double(cards.intro)), height: size.height)), with: .color(.gray.opacity(0.6))) }
      if cards.outro > 0 {
        ctx.fill(Path(CGRect(x: x(total - Double(cards.outro)), y: 0, width: x(Double(cards.outro)), height: size.height)), with: .color(.gray.opacity(0.6)))
      }
      for s in mapped {
        let rect = CGRect(x: x(Double(s.outStart)) + 0.5, y: 0, width: max(1, x(Double(s.frames)) - 1), height: size.height)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(s.speed > 1.01 ? Color.orange.opacity(0.75) : Theme.clip.opacity(0.6)))
      }
      let fps = plan.output.fps
      for c in plan.callouts {
        guard let f = srcToOut(mapped, c.start, fps: fps) else { continue }
        ctx.fill(Path(CGRect(x: x(f) - 1, y: -3, width: 2, height: size.height + 3)), with: .color(Theme.title))
      }
      for z in plan.zooms {
        let a = srcToOutClamped(mapped, z.start, fps: fps), b = srcToOutClamped(mapped, z.end, fps: fps, before: true)
        guard b > a else { continue }
        ctx.fill(Path(CGRect(x: x(a), y: size.height - 1.5, width: x(b) - x(a), height: 1.5)), with: .color(Theme.zoom))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .help("The finished video: blue plays in real time, orange is sped up, ticks are titles, purple underlines are zooms")
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
      TransportScrubber(project: project, playhead: project.playhead, total: total, fps: fps)
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
    .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
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
      Button { withAnimation(.snappy) { editor.showTranscript.toggle() } } label: { Label("Transcript", systemImage: "text.quote") }
        .help("Edit by text: select words to cut them or add a zoom, title or annotation (⌥⌘T)")
      Button { withAnimation(.snappy) { editor.showInspector.toggle() } } label: { Label("Inspector", systemImage: "sidebar.right") }
        .help("Show or hide the inspector (⌥⌘I)")
    }
  }
}

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
        Circle().fill(ai.isReady ? Color.green : Color.orange).frame(width: 6, height: 6)
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
                  .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.2)))
              }
              if ask.running, !ask.steps.isEmpty {
                // The last few steps, newest last, so you can see it working.
                VStack(alignment: .leading, spacing: 2) {
                  ForEach(Array(ask.steps.suffix(4).enumerated()), id: \.offset) { i, step in
                    let current = i == min(ask.steps.count, 4) - 1
                    Label(step, systemImage: current ? "circle.dotted" : "checkmark")
                      .font(.caption).foregroundStyle(current ? .primary : .secondary)
                  }
                }
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
