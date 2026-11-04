import AVKit
import AppKit
import DirectorCore
import SwiftUI

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
        .overlay { if !loading { BubbleDragger(project: project, playhead: project.playhead, drag: editor.bubbleDrag) } }
        .overlay { if !loading { CaptionDragger(project: project, playhead: project.playhead, drag: editor.captionDrag) } }
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
        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(s.speed > 1.01 ? Theme.fast.opacity(0.75) : Theme.clip.opacity(0.6)))
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
      PreviewVolumeControl(settings: AppSettings.shared)
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

/// How loud the preview plays while editing: a mute button and a volume slider. The export keeps the
/// plan's own levels.
struct PreviewVolumeControl: View {
  @ObservedObject var settings: AppSettings

  private var symbol: String {
    let v = settings.previewVolume
    if settings.previewMuted || v == 0 { return "speaker.slash.fill" }
    return v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
  }

  var body: some View {
    HStack(spacing: 4) {
      Button { settings.previewMuted.toggle() } label: {
        Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 24, alignment: .leading).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(settings.previewMuted ? "Unmute the preview" : "Mute the preview (the export isn't affected)")
      Slider(
        value: Binding(
          get: { Double(settings.previewMuted ? 0 : settings.previewVolume) },
          set: { v in
            settings.previewVolume = Float(v)
            if v > 0 { settings.previewMuted = false }
          }),
        in: 0...1
      )
      .controlSize(.mini)
      .frame(width: 72)
      .help("Preview volume (the export isn't affected)")
    }
  }
}
