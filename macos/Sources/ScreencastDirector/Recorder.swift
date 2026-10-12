import AVFoundation
import AppKit
import DirectorCore
import Foundation
import ScreenCaptureKit

/// Records the main display (ScreenCaptureKit, with the mic), optionally a camera, and the input log
/// into a new project folder. Everything is stamped on the host clock, so source.json's captureStart
/// and the camera offset line events and camera up with the screen to the frame.
final class Recorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  @Published private(set) var isRecording = false
  @Published private(set) var startedAt: Date?
  /// Set when ScreenCaptureKit stops the stream on its own (mic unplugged, window closed, display
  /// asleep). AppDelegate watches it, saves what was recorded and says what happened.
  @Published var lastError: String?
  @Published private(set) var isPaused = false
  /// Mic level, 0...1 (peak, -60...0 dBFS), about 20 times a second.
  @Published private(set) var micLevel: Float = 0
  /// Retake marks in this recording.
  @Published private(set) var retakeCount = 0
  /// False when Input Monitoring is off, so clicks and typing aren't logged (no auto-zoom).
  @Published private(set) var loggingInput = true

  /// Recorded time so far, not counting pauses.
  var elapsed: TimeInterval {
    guard let startedAt else { return 0 }
    let now = Date()
    let paused = pausedSeconds + (pauseStartedAt.map { now.timeIntervalSince($0) } ?? 0)
    return max(0, now.timeIntervalSince(startedAt) - paused)
  }
  private var pausedSeconds: TimeInterval = 0
  private var pauseStartedAt: Date?
  /// Paused stretches on the host clock; turned into source seconds in source.json at stop.
  private var pauseRanges: [(Double, Double)] = []
  private var pauseHostStart: Double?
  private var lastLevelPost = 0.0
  /// The camera session while recording, for the recording widget's preview.
  var cameraSession: AVCaptureSession? { camSession }

  private var stream: SCStream?
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var firstPTS: CMTime?
  private var lastPixelBuffer: CVPixelBuffer?
  private var size = CGSize.zero
  private let queue = DispatchQueue(label: "recorder.samples")

  private var camSession: AVCaptureSession?
  private var camWriter: AVAssetWriter?
  private var camInput: AVAssetWriterInput?
  private var camFirstPTS: CMTime?
  private let camQueue = DispatchQueue(label: "recorder.camera")

  private(set) var dir: URL?
  private var cursorHidden = false

  func start(in root: URL, settings: AppSettings) async throws {
    guard !isRecording else { return }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let wanted = settings.displayID != 0 ? CGDirectDisplayID(settings.displayID) : CGMainDisplayID()
    guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
      throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to record."])
    }
    let filter: SCContentFilter
    // The recorded area in global points, for normalizing click and cursor positions.
    let captureRect: CGRect
    if settings.captureWindowID != 0 {
      // One window: crisper than the whole display, and smaller files.
      guard let window = content.windows.first(where: { Int($0.windowID) == settings.captureWindowID }) else {
        throw NSError(
          domain: "Recorder", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "The window picked in Settings (\(settings.captureWindowLabel)) isn't open anymore. Pick another one, or record the whole display."])
      }
      filter = SCContentFilter(desktopIndependentWindow: window)
      captureRect = window.frame
    } else {
      // Keep this app's own windows out of the recording.
      let own = settings.showSelfInRecordings ? [] : content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
      filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
      captureRect = CGDisplayBounds(display.displayID)
    }

    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HHmmss"
    let dir = root.appendingPathComponent("Recording \(fmt.string(from: Date()))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.dir = dir

    let scale = CGFloat(filter.pointPixelScale)
    // Even pixel sizes: the H.264 encoder rejects odd ones, and windows can be any size.
    func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }
    size = CGSize(width: even(filter.contentRect.width * scale), height: even(filter.contentRect.height * scale))
    let cfg = SCStreamConfiguration()
    cfg.ignoreShadowsSingleWindow = true
    cfg.width = Int(size.width)
    cfg.height = Int(size.height)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    // With a smooth cursor, leave the real one out; the renderer draws it from the input log.
    cursorHidden = settings.smoothCursor
    cfg.showsCursor = !cursorHidden
    cfg.queueDepth = 8
    cfg.captureMicrophone = true
    if AppSettings.microphones.contains(where: { $0.uniqueID == settings.micID }) { cfg.microphoneCaptureDeviceID = settings.micID }

    let writer = try AVAssetWriter(outputURL: dir.appendingPathComponent("screen.mp4"), fileType: .mp4)
    let v = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: size.width * size.height * 4, AVVideoExpectedSourceFrameRateKey: settings.fps,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
      ])
    v.expectsMediaDataInRealTime = true
    let a = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000])
    a.expectsMediaDataInRealTime = true
    writer.add(v)
    writer.add(a)
    writer.startWriting()
    (self.writer, videoInput, audioInput, firstPTS, lastPixelBuffer) = (writer, v, a, nil, nil)

    if settings.useCamera, let device = settings.cameraDevice { try startCamera(device, dir: dir) }

    let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
    let logging = InputTap.start(writingTo: dir.appendingPathComponent("events.jsonl"), capture: captureRect)

    await MainActor.run {
      isRecording = true
      startedAt = Date()
      isPaused = false
      pausedSeconds = 0
      pauseStartedAt = nil
      pauseRanges = []
      pauseHostStart = nil
      retakeCount = 0
      loggingInput = logging
      lastError = nil
    }
  }

  /// Pausing keeps the screen recording, so the clock and the input log stay lined up; the paused
  /// stretch is saved in source.json and the draft cuts it. Input isn't logged while paused.
  func pause() {
    guard isRecording, !isPaused else { return }
    isPaused = true
    pauseStartedAt = Date()
    pauseHostStart = InputTap.now()
    InputTap.paused = true
  }

  func resume() {
    guard isRecording, isPaused else { return }
    isPaused = false
    if let start = pauseStartedAt { pausedSeconds += Date().timeIntervalSince(start) }
    if let start = pauseHostStart { pauseRanges.append((start, InputTap.now())) }
    pauseStartedAt = nil
    pauseHostStart = nil
    InputTap.paused = false
  }

  func markRetake() {
    guard isRecording, !isPaused else { return }
    InputTap.markRetake()
    retakeCount += 1
  }

  /// Stops and throws the recording away.
  func cancel() async {
    guard let dir = try? await stop(discard: true) else { return }
    try? FileManager.default.removeItem(at: dir)
  }

  /// Stops everything, writes source.json, and returns the project folder. With `discard`, it
  /// only shuts the capture down (the caller deletes the folder).
  func stop(discard: Bool = false) async throws -> URL? {
    guard isRecording, let dir else { return nil }
    await MainActor.run { resume() }
    InputTap.stop()
    try? await stream?.stopCapture()
    stream = nil

    let end = CMClockGetTime(CMClockGetHostTimeClock())
    queue.sync {
      // ScreenCaptureKit only sends frames when the screen changes; repeat the last one at the
      // stop time so a still ending isn't cut short.
      if let px = lastPixelBuffer, let v = videoInput, v.isReadyForMoreMediaData, let first = firstPTS, end > first {
        if let sb = Recorder.sampleBuffer(px, at: end) { v.append(sb) }
      }
      videoInput?.markAsFinished()
      audioInput?.markAsFinished()
    }
    await writer?.finishWriting()
    if discard {
      camSession?.stopRunning()
      (camSession, camWriter, camInput, camFirstPTS) = (nil, nil, nil, nil)
      await MainActor.run {
        isRecording = false
        startedAt = nil
        micLevel = 0
      }
      return dir
    }
    if let err = writer?.error { throw err }

    var camera: Plan.Camera?
    if let camSession {
      camSession.stopRunning()
      camQueue.sync { camInput?.markAsFinished() }
      await camWriter?.finishWriting()
      if let camFirst = camFirstPTS, let first = firstPTS {
        camera = Plan.Camera(video: "camera.mp4", offset: ((first.seconds - camFirst.seconds) * 1000).rounded() / 1000)
      }
    }
    (camSession, camWriter, camInput, camFirstPTS) = (nil, nil, nil, nil)

    let asset = AVURLAsset(url: dir.appendingPathComponent("screen.mp4"))
    let duration = try await asset.load(.duration).seconds
    var source = Project.Source(
      video: "screen.mp4", width: size.width, height: size.height, duration: duration, captureStart: firstPTS?.seconds,
      camera: camera, cursorHidden: cursorHidden ? true : nil)
    if let first = firstPTS?.seconds, !pauseRanges.isEmpty {
      source.pauses = pauseRanges.map { [max(0, $0.0 - first), min(duration, $0.1 - first)] }.filter { $0[1] > $0[0] }
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(source).write(to: dir.appendingPathComponent("source.json"))
    Recorder.copyFollowspotScript(into: dir)

    await MainActor.run {
      isRecording = false
      startedAt = nil
      micLevel = 0
    }
    return dir
  }

  /// If Followspot (Joe's teleprompter) is running, the script it has open is what was just read:
  /// save it as script.md so the edit can keep the best take of each line. Followspot links the
  /// open script at Application Support/Followspot/www/current.md.
  static func copyFollowspotScript(into dir: URL) {
    let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.joekarlsson.followspot" }
    guard running else { return }
    let link = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Followspot/www/current.md")
    guard let text = try? String(contentsOf: link.resolvingSymlinksInPath(), encoding: .utf8), !text.isEmpty else { return }
    try? text.write(to: dir.appendingPathComponent("script.md"), atomically: true, encoding: .utf8)
  }

  // MARK: Screen + mic samples

  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard let writer, writer.status == .writing, sb.isValid else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    switch type {
    case .screen:
      guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
        let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
        let px = CMSampleBufferGetImageBuffer(sb)
      else { return }
      if firstPTS == nil {
        firstPTS = pts
        writer.startSession(atSourceTime: pts)
      }
      lastPixelBuffer = px
      if videoInput?.isReadyForMoreMediaData == true { videoInput?.append(sb) }
    case .microphone:
      // Audio before the first frame would start the file early; drop it.
      postLevel(sb)
      guard let first = firstPTS, pts >= first else { return }
      if audioInput?.isReadyForMoreMediaData == true { audioInput?.append(sb) }
    default:
      break
    }
  }

  /// Peak level of a mic buffer, posted to the main thread at most every 50 ms.
  private func postLevel(_ sb: CMSampleBuffer) {
    let now = CACurrentMediaTime()
    guard now - lastLevelPost >= 0.05 else { return }
    lastLevelPost = now
    var peak: Float = 0
    try? sb.withAudioBufferList { list, _ in
      for buffer in list {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(samples[i])) }
      }
    }
    let db = 20 * log10(max(peak, 1e-6))
    let level = max(0, min(1, (db + 60) / 60))
    DispatchQueue.main.async { self.micLevel = level }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async { self.lastError = error.localizedDescription }
  }

  static func sampleBuffer(_ px: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: px, formatDescriptionOut: &format)
    guard let format else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil, imageBuffer: px, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb
  }

  // MARK: Camera

  private func startCamera(_ device: AVCaptureDevice, dir: URL) throws {
    let session = AVCaptureSession()
    session.beginConfiguration()
    session.sessionPreset = .hd1920x1080
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw NSError(domain: "Recorder", code: 2) }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.setSampleBufferDelegate(self, queue: camQueue)
    session.addOutput(output)
    session.commitConfiguration()

    let w = try AVAssetWriter(outputURL: dir.appendingPathComponent("camera.mp4"), fileType: .mp4)
    let input2 = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
      ])
    input2.expectsMediaDataInRealTime = true
    w.add(input2)
    w.startWriting()
    (camSession, camWriter, camInput, camFirstPTS) = (session, w, input2, nil)
    session.startRunning()
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let camWriter, camWriter.status == .writing else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    if camFirstPTS == nil {
      camFirstPTS = pts
      camWriter.startSession(atSourceTime: pts)
    }
    if camInput?.isReadyForMoreMediaData == true { camInput?.append(sb) }
  }
}
