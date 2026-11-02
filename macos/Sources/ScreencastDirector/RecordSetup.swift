import AVFoundation
import AppKit
import CoreImage
import DirectorCore
import ScreenCaptureKit
import SwiftUI

/// "New Recording…": a small glass panel at the top of the screen that picks what to record (a
/// display or one window), the mic and the camera, checks the camera's white balance, then
/// starts. ⌃⌥⌘R skips it and records with the last choices.
final class RecordSetup {
  private var panel: FloatingPanel?
  private let cameraCheck = CameraCheck()
  private let micCheck = MicCheck()
  var onStart: () -> Void = {}

  func show(settings: AppSettings) {
    let panel = self.panel ?? FloatingPanel(size: NSSize(width: 560, height: 200), activating: true)
    let size = panel.host(
      RecordSetupView(
        settings: settings, windows: CaptureWindows.shared, cameraCheck: cameraCheck, micCheck: micCheck,
        start: { [weak self] in
          self?.close()
          self?.onStart()
        },
        close: { [weak self] in self?.close() }))
    self.panel = panel
    if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 24))
    }
    CaptureWindows.shared.refresh()
    if settings.useCamera { cameraCheck.run(settings.cameraDevice) }
    micCheck.run(settings.microphoneDevice)
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
  }

  /// Also lets go of the camera and mic, so the recorder can open them.
  func close() {
    cameraCheck.stop()
    micCheck.stop()
    panel?.orderOut(nil)
  }
}

struct DisplayChoice: Identifiable {
  let id: Int
  let name: String

  /// Connected displays, the main one first. ID 0 stands for "the main display".
  static var all: [DisplayChoice] {
    NSScreen.screens.enumerated().map { i, screen in
      let n = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
      return DisplayChoice(id: i == 0 ? 0 : n, name: i == 0 ? "\(screen.localizedName) (main)" : screen.localizedName)
    }
  }
}

struct RecordSetupView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var windows: CaptureWindows
  @ObservedObject var cameraCheck: CameraCheck
  @ObservedObject var micCheck: MicCheck
  let start: () -> Void
  let close: () -> Void

  private var recordingWindow: Bool { settings.captureWindowID != 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("New Recording", systemImage: "record.circle").font(.headline).foregroundStyle(.primary)
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close (Esc)")
      }

      HStack(spacing: 10) {
        sourceTile("Display", "display", selected: !recordingWindow) { settings.captureWindowID = 0 }
        sourceTile("Window", "macwindow", selected: recordingWindow) {
          if let first = windows.windows.first {
            settings.captureWindowID = first.id
            settings.captureWindowLabel = first.label
          }
        }
        .disabled(windows.windows.isEmpty)
      }

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          rowLabel(recordingWindow ? "Window" : "Display", recordingWindow ? "macwindow" : "display")
          if recordingWindow {
            CapturePicker(settings: settings, list: windows, showsDisplay: false).labelsHidden()
          } else {
            Picker("Display", selection: $settings.displayID) {
              ForEach(DisplayChoice.all) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
          }
        }
        GridRow {
          rowLabel("Microphone", "mic")
          HStack {
            Picker("Microphone", selection: settings.micSelection) {
              Text("System default").tag("")
              ForEach(AppSettings.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .labelsHidden()
            if let problem = micCheck.problem {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 44).help(problem)
            } else {
              MicMeter(level: micCheck.level).frame(width: 44).help("Microphone level: speak to check it's working")
              if micCheck.silent {
                Text("No sound").font(.caption.weight(.medium)).foregroundStyle(.orange).fixedSize()
                  .help("The mic hasn't heard anything for a few seconds. Say something, and check it isn't muted.")
              }
            }
          }
          .onChange(of: settings.micID) { _, _ in micCheck.run(settings.microphoneDevice) }
        }
        GridRow {
          rowLabel("Camera", "video")
          HStack {
            Toggle("Camera", isOn: $settings.useCamera).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Picker("Camera", selection: settings.cameraSelection) {
              ForEach(AppSettings.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .labelsHidden()
            .disabled(!settings.useCamera)
          }
        }
      }

      HStack(spacing: 10) {
        cameraPreview
        whiteBalance
      }
        .onChange(of: settings.useCamera) { _, on in
          if on { cameraCheck.run(settings.cameraDevice) } else { cameraCheck.stop() }
        }
        .onChange(of: settings.cameraID) { _, _ in
          if settings.useCamera { cameraCheck.run(settings.cameraDevice) }
        }

      HStack {
        Text(settings.countdown > 0 ? "Starts after a \(settings.countdown)-second countdown." : "Starts right away.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(action: start) {
          Label("Start Recording", systemImage: "record.circle.fill").padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.recording)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .help("Or press ⌃⌥⌘R in any app")
      }
    }
    .padding(18)
    .frame(width: 520)
    .glassCard(cornerRadius: Theme.panelCorner)
    .tint(Theme.accent)
  }

  /// The camera as it will be recorded, mirrored like the recording widget's.
  private var cameraPreview: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(Color.black.opacity(0.35))
      if let session = cameraCheck.previewSession {
        CameraPreview(session: session).id(ObjectIdentifier(session))
      } else {
        Image(systemName: "video.slash").foregroundStyle(.secondary)
      }
    }
    .frame(width: 200, height: 112)
    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    .help("Camera preview")
  }

  /// The pre-flight white balance reading. Its height is fixed so the panel, pinned to the top of
  /// the screen, doesn't grow upward when the advice arrives.
  private var whiteBalance: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Group {
          switch cameraCheck.state {
          case .checking: ProgressView().controlSize(.mini)
          // A warm or colored picture can be the look, so an off reading is information, not a warning.
          case .done(let r):
            Image(systemName: r.isNeutral ? "checkmark.circle.fill" : "info.circle.fill")
              .foregroundStyle(r.isNeutral ? Color.green : Theme.accent)
          case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
          case .idle: Image(systemName: "camera.filters").foregroundStyle(.secondary)
          }
        }
        .frame(width: 14, height: 14)
        Text("White balance").font(.caption.weight(.semibold))
        Spacer(minLength: 0)
        Button { cameraCheck.run(settings.cameraDevice) } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(!settings.useCamera || cameraCheck.state == .checking)
          .help("Check the camera's white balance again")
      }
      // Capped so the box keeps its height; the full text is in the tooltip.
      Text(whiteBalanceText).font(.caption).foregroundStyle(.secondary).lineLimit(5).help(whiteBalanceText)
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
    .background(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(Color.primary.opacity(0.05)))
  }

  private var whiteBalanceText: String {
    guard settings.useCamera else { return "Turn on the camera to check its white balance before you record." }
    switch cameraCheck.state {
    case .idle: return "Not checked yet."
    case .checking: return "Reading the camera…"
    case .done(let r): return r.advice
    case .failed(let why): return why
    }
  }

  private func rowLabel(_ text: String, _ symbol: String) -> some View {
    Label(text, systemImage: symbol).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
  }

  private func sourceTile(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 22, weight: .regular))
        Text(title).font(.callout.weight(.medium))
      }
      .frame(maxWidth: .infinity, minHeight: 64)
      .background(
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
          .fill(selected ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05)))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
          .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Listens to the selected mic while New Recording is up, for its level meter.
final class MicCheck: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  /// 0...1, -60 dBFS to 0 dBFS peak, like the recording widget's meter.
  @Published private(set) var level: Float = 0
  /// Why there's no level (no mic, access off, couldn't open), shown instead of the meter.
  @Published private(set) var problem: String?
  /// Nothing heard for a few seconds (`SilenceWatch`). Checked on a timer, so a mic that sends no
  /// audio at all is caught too.
  @Published private(set) var silent = false
  private var generation = 0
  private var watch = SilenceWatch(start: 0)
  private var silenceTimer: Timer?
  private let queue = DispatchQueue(label: "mic-check")
  // Touched only on `queue`.
  private var session: AVCaptureSession?
  private var sessionGeneration = 0
  private var lastPost = 0.0

  func run(_ device: AVCaptureDevice?) {
    generation += 1
    let gen = generation
    level = 0
    silent = false
    silenceTimer?.invalidate()
    guard let device else {
      stop()
      problem = "No microphone found."
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: problem = nil
    case .notDetermined:
      problem = "Waiting for microphone access: answer the macOS prompt."
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async {
          guard gen == self.generation else { return }
          if granted { self.run(device) } else { self.problem = "Microphone access was denied." }
        }
      }
      return
    default:
      problem = "Microphone access is off. Allow it in System Settings > Privacy & Security > Microphone."
      return
    }
    watch = SilenceWatch(start: CACurrentMediaTime())
    silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self else { return }
      let silent = self.watch.isSilent(at: CACurrentMediaTime())
      if silent != self.silent { self.silent = silent }
    }
    queue.async {
      self.closeSession()
      do {
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
          AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
          AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: self.queue)
        session.addOutput(output)
        session.commitConfiguration()
        (self.session, self.sessionGeneration) = (session, gen)
        session.startRunning()
      } catch {
        DispatchQueue.main.async {
          guard gen == self.generation else { return }
          self.silenceTimer?.invalidate()
          self.problem = "Couldn't open \(device.localizedName): \(error.localizedDescription)"
        }
      }
    }
  }

  func stop() {
    generation += 1
    level = 0
    silent = false
    silenceTimer?.invalidate()
    queue.async { self.closeSession() }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard session != nil else { return }
    let now = CACurrentMediaTime()
    guard now - lastPost >= 0.05 else { return }
    lastPost = now
    var peak: Float = 0
    try? sb.withAudioBufferList { list, _ in
      for buffer in list {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(samples[i])) }
      }
    }
    let db = 20 * log10(max(Double(peak), 1e-6))
    let level = Float(max(0, min(1, (db + 60) / 60)))
    let gen = sessionGeneration
    DispatchQueue.main.async {
      guard gen == self.generation else { return }
      self.level = level
      self.watch.hear(peakDB: db, at: CACurrentMediaTime())
    }
  }

  private func closeSession() {
    session?.stopRunning()
    session = nil
  }
}

/// Keeps the selected camera open while New Recording is up, for the preview, and reads its white
/// balance with `WhiteBalance.measure` once auto exposure and white balance have settled.
final class CameraCheck: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  enum State: Equatable {
    case idle, checking
    case done(WhiteBalance.Reading)
    case failed(String)
  }

  @Published private(set) var state = State.idle
  /// The open camera, for the preview. Nil when the camera is off or couldn't be opened.
  @Published private(set) var previewSession: AVCaptureSession?
  /// Bumped on the main thread by every run and stop, so a late result from an earlier camera is dropped.
  private var generation = 0
  private var openDeviceID: String?
  private let queue = DispatchQueue(label: "camera-check")
  // Touched only on `queue`.
  private var session: AVCaptureSession?
  private var sessionGeneration = 0
  private var firstFrameAt: Date?
  private var wantsReading = false

  /// Webcams start dark and off-color, then settle; read the picture after this long.
  private static let settleSeconds = 1.5
  private static let timeoutSeconds = 6.0

  /// Opens `device` (or keeps it open) and takes a fresh reading.
  func run(_ device: AVCaptureDevice?) {
    generation += 1
    let gen = generation
    guard let device else {
      stopSession()
      state = .failed("No camera found.")
      return
    }
    if device.uniqueID == openDeviceID, previewSession != nil {
      state = .checking
      queue.async {
        self.sessionGeneration = gen
        self.wantsReading = true
      }
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: break
    case .notDetermined:
      state = .failed("Waiting for camera access: answer the macOS prompt.")
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          guard gen == self.generation else { return }
          if granted { self.run(device) } else { self.state = .failed("Camera access was denied.") }
        }
      }
      return
    default:
      state = .failed("Camera access is off. Allow it in System Settings > Privacy & Security > Camera.")
      return
    }
    state = .checking
    openDeviceID = device.uniqueID
    queue.async {
      self.closeSession()
      do {
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: self.queue)
        session.addOutput(output)
        session.commitConfiguration()
        (self.session, self.sessionGeneration, self.firstFrameAt, self.wantsReading) = (session, gen, nil, true)
        session.startRunning()
        DispatchQueue.main.async {
          guard gen == self.generation else { return }
          self.previewSession = session
        }
      } catch {
        self.finish(gen, .failed("Couldn't open \(device.localizedName): \(error.localizedDescription)"))
        return
      }
      self.queue.asyncAfter(deadline: .now() + Self.timeoutSeconds) {
        guard self.session != nil, self.firstFrameAt == nil, self.sessionGeneration == gen else { return }
        self.finish(gen, .failed("No picture from \(device.localizedName). Check that it's connected and not in use by another app."))
      }
    }
  }

  /// Lets go of the camera.
  func stop() {
    generation += 1
    if state == .checking { state = .idle }
    stopSession()
  }

  private func stopSession() {
    previewSession = nil
    openDeviceID = nil
    queue.async { self.closeSession() }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard session != nil, wantsReading else { return }
    let now = Date()
    guard let first = firstFrameAt else {
      firstFrameAt = now
      return
    }
    guard now.timeIntervalSince(first) >= Self.settleSeconds, let px = CMSampleBufferGetImageBuffer(sb) else { return }
    wantsReading = false
    let reading = WhiteBalance.measure(CIImage(cvPixelBuffer: px))
    finish(
      sessionGeneration,
      reading.map { .done($0) } ?? .failed("Too dark or too bright to judge. Light the room as you'll record it, then check again."))
  }

  private func closeSession() {
    session?.stopRunning()
    (session, firstFrameAt, wantsReading) = (nil, nil, false)
  }

  private func finish(_ gen: Int, _ result: State) {
    DispatchQueue.main.async {
      guard gen == self.generation else { return }
      self.state = result
    }
  }
}
