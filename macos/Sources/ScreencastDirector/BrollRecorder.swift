import AVFoundation
import AppKit
import DirectorCore
import ScreenCaptureKit
import SwiftUI

/// Record B-roll: a small floating panel that records a clip from the camera or the screen into the
/// open project's broll/ folder (`RecordedBroll.file`), then shows it full frame from the playhead
/// (`ProjectModel.addRecordedBroll`). No audio: B-roll plays muted.
final class BrollRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
  enum Source: String, CaseIterable, Identifiable {
    case camera, screen
    var id: String { rawValue }
    var label: String { self == .camera ? "Camera" : "Screen" }
  }

  @Published var source = Source.camera {
    didSet { if source != oldValue { openSource() } }
  }
  /// The open camera, for the preview and the recording. Nil for the screen or when it couldn't open.
  @Published private(set) var previewSession: AVCaptureSession?
  @Published private(set) var isRecording = false
  /// Between Stop and the clip being on the timeline.
  @Published private(set) var isSaving = false
  @Published private(set) var elapsed: TimeInterval = 0
  let settings = AppSettings.shared

  private var panel: FloatingPanel?
  private weak var project: ProjectModel?
  private var movieOutput: AVCaptureMovieFileOutput?
  private var stream: SCStream?
  private var recordingOutput: SCRecordingOutput?
  /// The clip being recorded, as a project path (broll/broll-….mov).
  private var file: String?
  private var startedAt: Date?
  private var timer: Timer?
  private let sessionQueue = DispatchQueue(label: "broll.camera")

  /// Opens the panel for `project`, with the camera on.
  func show(for project: ProjectModel) {
    guard !isRecording, !isSaving else {
      panel?.makeKeyAndOrderFront(nil)
      return
    }
    self.project = project
    let panel = self.panel ?? FloatingPanel(size: NSSize(width: 320, height: 300), activating: true)
    let size = panel.host(BrollRecorderView(recorder: self, settings: settings))
    self.panel = panel
    if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 24, y: frame.maxY - size.height - 24))
    }
    openSource()
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
  }

  /// Closes the panel and lets go of the camera. Not while recording: Stop first.
  func close() {
    guard !isRecording, !isSaving else { return }
    closeCamera()
    panel?.orderOut(nil)
  }

  /// Opens the picked camera (or lets go of it for the screen).
  func openSource() {
    closeCamera()
    guard source == .camera, panel != nil else { return }
    guard let device = settings.cameraDevice else {
      Notices.shared.show("No camera found. Connect one, or record the screen instead.", error: true)
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      break
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted { self.openSource() } else { Self.cameraDenied() }
        }
      }
      return
    default:
      Self.cameraDenied()
      return
    }
    let session = AVCaptureSession()
    session.beginConfiguration()
    let output = AVCaptureMovieFileOutput()
    do {
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input), session.canAddOutput(output) else {
        throw DirectorError("\(device.localizedName) is busy or not supported")
      }
      session.addInput(input)
      session.addOutput(output)
      _ = try device.useBestRecordingFormat()
    } catch {
      session.commitConfiguration()
      Notices.shared.show(error, "Couldn't open the camera")
      return
    }
    // H.264 at the camera's size, like the recorder's camera.mp4 (macOS can otherwise pass frames through).
    if let c = output.connection(with: .video) {
      var s = output.outputSettings(for: c)
      s[AVVideoCodecKey] = AVVideoCodecType.h264
      s[AVVideoCompressionPropertiesKey] = nil
      output.setOutputSettings(s, for: c)
    }
    session.commitConfiguration()
    (previewSession, movieOutput) = (session, output)
    sessionQueue.async { session.startRunning() }
  }

  private static func cameraDenied() {
    Notices.shared.show("Camera access is off. Allow it in System Settings > Privacy & Security > Camera.", error: true, action: "Open Settings") {
      SetupModel.openPrivacy("Privacy_Camera")
    }
  }

  private func closeCamera() {
    if let session = previewSession { sessionQueue.async { session.stopRunning() } }
    (previewSession, movieOutput) = (nil, nil)
  }

  // MARK: Recording

  func toggle() {
    if isRecording { stop() } else { start() }
  }

  func start() {
    // `file` is set from Record until the clip is saved, so a second press while the screen starts does nothing.
    guard !isRecording, !isSaving, file == nil, let project else { return }
    let dir = project.dir
    let file = RecordedBroll.file(at: Date()) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    let url = dir.appendingPathComponent(file)
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      Notices.shared.show(error, "Couldn't make the broll folder")
      return
    }
    switch source {
    case .camera:
      guard let movieOutput, previewSession?.isRunning == true else {
        Notices.shared.show("The camera isn't on yet. Wait for the preview, then press Record.", error: true)
        return
      }
      self.file = file
      movieOutput.startRecording(to: url, recordingDelegate: self)
      began()
    case .screen:
      self.file = file
      Task { @MainActor in
        do {
          try await self.startScreen(url)
          self.began()
        } catch {
          (self.stream, self.recordingOutput, self.file) = (nil, nil, nil)
          Notices.shared.show(error, "Couldn't record the screen")
        }
      }
    }
  }

  /// The display picked for recordings (the main one by default), without this app's windows.
  private func startScreen(_ url: URL) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let wanted = settings.displayID != 0 ? CGDirectDisplayID(settings.displayID) : CGMainDisplayID()
    guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
      throw DirectorError("No display to record.")
    }
    let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    let scale = CGFloat(filter.pointPixelScale)
    let cfg = SCStreamConfiguration()
    cfg.width = Int((filter.contentRect.width * scale / 2).rounded() * 2)
    cfg.height = Int((filter.contentRect.height * scale / 2).rounded() * 2)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    cfg.capturesAudio = false
    let recordingConfig = SCRecordingOutputConfiguration()
    recordingConfig.outputURL = url
    recordingConfig.outputFileType = .mov
    recordingConfig.videoCodecType = .h264
    let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try stream.addRecordingOutput(output)
    (self.stream, recordingOutput) = (stream, output)
    try await stream.startCapture()
  }

  private func began() {
    isRecording = true
    startedAt = Date()
    elapsed = 0
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self, let startedAt = self.startedAt else { return }
      self.elapsed = Date().timeIntervalSince(startedAt)
    }
  }

  /// Stops; the clip joins the timeline when the file is finished (`finished`).
  func stop() {
    guard isRecording else { return }
    isRecording = false
    isSaving = true
    timer?.invalidate()
    timer = nil
    switch source {
    case .camera:
      movieOutput?.stopRecording()
    case .screen:
      Task { @MainActor in
        do {
          try await self.stream?.stopCapture()
        } catch {
          self.finished(error)
        }
      }
    }
  }

  func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
    // The movie output reports some stops (disk full, max length) as errors though the file is good.
    let ok = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
    DispatchQueue.main.async { self.finished(ok ? nil : error) }
  }

  func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    DispatchQueue.main.async { self.finished(nil) }
  }

  func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
    DispatchQueue.main.async { self.finished(error) }
  }

  /// The file is done: put it on the timeline and close the panel, or say what went wrong.
  private func finished(_ error: Error?) {
    guard isSaving || isRecording, let file else { return }
    timer?.invalidate()
    timer = nil
    (stream, recordingOutput, self.file, isRecording) = (nil, nil, nil, false)
    guard let project else {
      isSaving = false
      Notices.shared.show("The project closed while recording. The clip is in its broll folder (\(file)).", error: true)
      return
    }
    let url = project.dir.appendingPathComponent(file)
    if let error {
      isSaving = false
      try? FileManager.default.removeItem(at: url)
      Notices.shared.show(error, "B-roll recording failed")
      return
    }
    Task { @MainActor in
      do {
        let length = try await AVURLAsset(url: url).load(.duration).seconds
        guard length > 0 else { throw DirectorError("the clip is empty") }
        self.isSaving = false
        project.addRecordedBroll(file, length: length)
        self.close()
      } catch {
        self.isSaving = false
        Notices.shared.show(error, "Couldn't add the recorded B-roll (\(file))")
      }
    }
  }
}

struct BrollRecorderView: View {
  @ObservedObject var recorder: BrollRecorder
  @ObservedObject var settings: AppSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Record B-roll").font(.headline)
        Spacer()
        Button { recorder.close() } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless)
          .disabled(recorder.isRecording || recorder.isSaving)
          .help("Close")
      }
      Picker("Source", selection: $recorder.source) {
        ForEach(BrollRecorder.Source.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .disabled(recorder.isRecording || recorder.isSaving)
      if recorder.source == .camera {
        Picker("Camera", selection: settings.cameraSelection) {
          ForEach(AppSettings.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
        }
        .disabled(recorder.isRecording || recorder.isSaving)
        .onChange(of: settings.cameraID) { _, _ in recorder.openSource() }
      }
      preview
      HStack {
        Button(action: recorder.toggle) {
          Label(recorder.isRecording ? "Stop" : "Record", systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
            .frame(minWidth: 80)
        }
        .controlSize(.large)
        .tint(recorder.isRecording ? .red : Theme.accent)
        .buttonStyle(.borderedProminent)
        .disabled(recorder.isSaving)
        .help(recorder.isRecording ? "Stop and add the clip at the playhead" : "Record a clip into the project's broll folder")
        Spacer()
        if recorder.isSaving {
          ProgressView().controlSize(.small)
        } else {
          if recorder.isRecording { PulsingDot() }
          Text(clockText(recorder.elapsed)).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
        }
      }
      Text("Muted, full frame from the playhead.").font(.caption).foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(width: 300)
    .glassCard(cornerRadius: Theme.panelCorner)
    .tint(Theme.accent)
  }

  /// The camera as it records (not mirrored, so text reads the right way), or a note for the screen.
  private var preview: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(Color.black.opacity(0.35))
      if recorder.source == .screen {
        Label("Records the screen, without this app's windows", systemImage: "display").font(.caption).foregroundStyle(.secondary).padding()
      } else if let session = recorder.previewSession {
        CameraPreview(session: session, mirrored: false).id(ObjectIdentifier(session))
      } else {
        Image(systemName: "video.slash").foregroundStyle(.secondary)
      }
    }
    .frame(width: 272, height: 153)
    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
  }
}
