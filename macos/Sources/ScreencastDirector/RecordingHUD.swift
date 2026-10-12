import AVFoundation
import AppKit
import Combine
import SwiftUI

// The floating recording widget (Screen Studio style), the countdown before a recording starts,
// and the panel that picks what to record. All three are panels with `sharingType = .none`, so they
// never show up in the recording, even with "Show this app in recordings" on.

/// A borderless glass panel that floats over every Space and full-screen app.
final class FloatingPanel: NSPanel {
  init(size: NSSize, activating: Bool = false) {
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: activating ? [.borderless, .fullSizeContentView] : [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    // Above normal floating windows and full-screen apps, so Stop is always in reach.
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    isMovableByWindowBackground = true
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    // `-panelsInScreenshots YES` lets screenshots (docs, UI checks) see the panels.
    sharingType = UserDefaults.standard.bool(forKey: "panelsInScreenshots") ? .readOnly : .none
  }
  override var canBecomeKey: Bool { true }

  /// Puts a SwiftUI view in the panel and sizes the panel to it.
  @discardableResult
  func host<V: View>(_ view: V) -> NSSize {
    let controller = NSHostingController(rootView: view)
    // A hosting view's fittingSize is zero until it's in a window; ask the controller instead.
    let size = controller.sizeThatFits(in: NSSize(width: 4000, height: 4000))
    controller.sizingOptions = [.preferredContentSize]
    contentViewController = controller
    setContentSize(size)
    return size
  }
}

// MARK: Recording widget

/// The widget's state: a ticking clock, and the two-click confirm for Restart and Discard.
final class RecordingHUDModel: ObservableObject {
  enum Confirm { case restart, discard }
  @Published var confirming: Confirm?
  /// Just the clock and Stop, for when the full widget is in the way. Remembered.
  @Published var compact = UserDefaults.standard.bool(forKey: "hudCompact") {
    didSet { UserDefaults.standard.set(compact, forKey: "hudCompact") }
  }
  @Published private(set) var elapsed: TimeInterval = 0
  let recorder: Recorder
  var onStop: () -> Void = {}
  var onRestart: () -> Void = {}
  var onDiscard: () -> Void = {}
  private var timer: Timer?
  private var confirmReset: DispatchWorkItem?

  init(recorder: Recorder) { self.recorder = recorder }

  func startClock() {
    timer?.invalidate()
    elapsed = 0
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.elapsed = self.recorder.elapsed
    }
  }
  func stopClock() {
    timer?.invalidate()
    timer = nil
    confirming = nil
  }

  /// First click arms the button for 3 seconds; the second one does it.
  func tap(_ action: Confirm) {
    if confirming == action {
      confirming = nil
      if action == .restart { onRestart() } else { onDiscard() }
      return
    }
    confirming = action
    confirmReset?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.confirming = nil }
    confirmReset = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
  }
}

func clockText(_ t: TimeInterval) -> String {
  let s = Int(t)
  return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Shows and hides the widget. It sits at the bottom center of the screen until you drag it;
/// after that it comes back where you left it.
final class RecordingHUD: NSObject, NSWindowDelegate {
  let model: RecordingHUDModel
  private var panel: FloatingPanel?
  private let originKey = "hudOrigin"

  init(recorder: Recorder) { model = RecordingHUDModel(recorder: recorder) }

  func show(on screen: NSScreen?) {
    let panel = self.panel ?? FloatingPanel(size: NSSize(width: 460, height: 60))
    let size = panel.host(RecordingHUDView(model: model, recorder: model.recorder))
    panel.delegate = self
    self.panel = panel
    if let saved = UserDefaults.standard.string(forKey: originKey).map(NSPointFromString),
      NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: saved, size: size)) })
    {
      panel.setFrameOrigin(saved)
    } else if let frame = (screen ?? NSScreen.main)?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48))
    }
    model.startClock()
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
  }

  func hide() {
    model.stopClock()
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
  }

  func windowDidMove(_ notification: Notification) {
    guard let panel, panel.isVisible, panel.alphaValue > 0.9 else { return }
    UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: originKey)
  }
}

struct RecordingHUDView: View {
  @ObservedObject var model: RecordingHUDModel
  @ObservedObject var recorder: Recorder

  var body: some View {
    HStack(spacing: 14) {
      clock
      if !model.compact { details }
      HStack(spacing: 6) {
        if !model.compact { controls }
        Button(action: model.onStop) {
          Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
            .frame(width: 34, height: 34)
            .background(Circle().fill(Theme.recording))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("Stop and edit (⌃⌥⌘R)")
        Button {
          model.compact.toggle()
        } label: {
          Image(systemName: model.compact ? "chevron.left" : "chevron.right")
            .font(.system(size: 10, weight: .bold))
            .frame(width: 16, height: 30)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.compact ? "Show the full widget" : "Shrink to the clock and Stop")
      }
    }
    .padding(.leading, 18)
    .padding(.trailing, 8)
    .padding(.vertical, 10)
    .glassCard(cornerRadius: 30)
    .animation(.snappy, value: recorder.retakeCount)
    .animation(.snappy, value: recorder.isPaused)
    .animation(.snappy, value: model.confirming)
    .fixedSize()
  }

  @ViewBuilder
  private var details: some View {
      MicMeter(level: recorder.isPaused ? 0 : recorder.micLevel)
        .help("Microphone level")
      if let session = recorder.cameraSession {
        CameraPreview(session: session)
          .frame(width: 34, height: 34)
          .clipShape(Circle())
          .overlay(Circle().strokeBorder(.white.opacity(0.25)))
          .help("Camera")
      }
      if recorder.retakeCount > 0 {
        Label("\(recorder.retakeCount)", systemImage: "arrow.uturn.backward.circle.fill")
          .font(.callout.weight(.semibold)).monospacedDigit()
          .foregroundStyle(.orange)
          .help("Retakes marked (⌃⌥⌘M): the line before each one is cut from the draft")
          .id(recorder.retakeCount)
          .transition(.scale.combined(with: .opacity))
      }
      if !recorder.loggingInput {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
          .help("Input Monitoring is off, so clicks and typing aren't logged: no auto-zoom or typing speed-ups. Turn it on in System Settings > Privacy & Security.")
      }
      Divider().frame(height: 24)
  }

  @ViewBuilder
  private var controls: some View {
        hudButton(recorder.isPaused ? "play.fill" : "pause.fill", recorder.isPaused ? "Resume" : "Pause (the paused part is cut)") {
          recorder.isPaused ? recorder.resume() : recorder.pause()
        }
        hudButton(
          model.confirming == .restart ? "checkmark" : "arrow.counterclockwise",
          model.confirming == .restart ? "Click again to throw this take away and start over" : "Restart",
          tint: model.confirming == .restart ? .orange : nil
        ) { model.tap(.restart) }
        hudButton(
          model.confirming == .discard ? "checkmark" : "trash",
          model.confirming == .discard ? "Click again to discard this recording" : "Discard",
          tint: model.confirming == .discard ? .red : nil
        ) { model.tap(.discard) }
  }

  private var clock: some View {
    HStack(spacing: 8) {
      if recorder.isPaused {
        Image(systemName: "pause.circle.fill").foregroundStyle(.yellow).font(.title3)
      } else {
        PulsingDot()
      }
      VStack(alignment: .leading, spacing: 0) {
        Text(clockText(model.elapsed))
          .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
        if recorder.isPaused { Text("Paused").font(.caption2).foregroundStyle(.secondary) }
      }
      .frame(minWidth: 52, alignment: .leading)
    }
  }

  private func hudButton(_ symbol: String, _ help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
        .frame(width: 30, height: 30)
        .background(Circle().fill(tint.map { $0.opacity(0.9) } ?? Color.primary.opacity(0.08)))
        .foregroundStyle(tint == nil ? Color.primary : .white)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

/// The red recording dot, breathing.
struct PulsingDot: View {
  var body: some View {
    SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
      let phase = (sin(ctx.date.timeIntervalSinceReferenceDate * 3) + 1) / 2
      Circle().fill(Theme.recording)
        .frame(width: 11, height: 11)
        .shadow(color: Theme.recording.opacity(0.7), radius: 2 + 4 * phase)
        .opacity(0.65 + 0.35 * phase)
    }
    .frame(width: 14, height: 14)
  }
}

/// Ten bars: green for speech, yellow near the top, red when it clips.
struct MicMeter: View {
  let level: Float
  var bars = 10

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<bars, id: \.self) { i in
        let on = Float(i) / Float(bars) < level
        Capsule()
          .fill(on ? color(i) : Color.primary.opacity(0.12))
          .frame(width: 3, height: 6 + CGFloat(i) * 1.4)
      }
    }
    .frame(height: 22)
    .animation(.linear(duration: 0.08), value: level)
  }

  private func color(_ i: Int) -> Color {
    i >= bars - 1 ? .red : i >= bars - 3 ? .yellow : .green
  }
}

/// A live preview of the camera being recorded.
struct CameraPreview: NSViewRepresentable {
  let session: AVCaptureSession

  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    v.wantsLayer = true
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    if let c = layer.connection, c.isVideoMirroringSupported {
      c.automaticallyAdjustsVideoMirroring = false
      c.isVideoMirrored = true
    }
    v.layer = layer
    return v
  }
  func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: Countdown

/// 3, 2, 1 in the middle of the screen being recorded. Pressing ⌃⌥⌘R again cancels it.
final class Countdown: ObservableObject {
  @Published private(set) var remaining = 0
  private var panel: FloatingPanel?
  private var timer: Timer?
  private var done: (() -> Void)?
  var isRunning: Bool { timer != nil }

  func run(seconds: Int, on screen: NSScreen?, then done: @escaping () -> Void) {
    guard seconds > 0 else { return done() }
    cancel()
    self.done = done
    remaining = seconds
    let panel = FloatingPanel(size: NSSize(width: 220, height: 220))
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.host(CountdownView(countdown: self))
    if let frame = (screen ?? NSScreen.main)?.frame {
      panel.setFrameOrigin(NSPoint(x: frame.midX - 110, y: frame.midY - 110))
    }
    panel.orderFrontRegardless()
    self.panel = panel
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self else { return }
      if self.remaining > 1 {
        self.remaining -= 1
      } else {
        let done = self.done
        self.cancel()
        done?()
      }
    }
  }

  func cancel() {
    timer?.invalidate()
    timer = nil
    done = nil
    panel?.orderOut(nil)
    panel = nil
  }
}

struct CountdownView: View {
  @ObservedObject var countdown: Countdown

  var body: some View {
    VStack(spacing: 4) {
      Text("\(countdown.remaining)")
        .font(.system(size: 84, weight: .bold, design: .rounded)).monospacedDigit()
        .contentTransition(.numericText(countsDown: true))
      Text("⌃⌥⌘R to cancel").font(.caption).foregroundStyle(.secondary)
    }
    .frame(width: 170, height: 170)
    .glassCard(cornerRadius: 85)
    .animation(.snappy, value: countdown.remaining)
    .frame(width: 220, height: 220)
  }
}
