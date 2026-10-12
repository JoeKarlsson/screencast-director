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
  @Published var lastError: String?

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
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
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
    if !settings.micID.isEmpty { cfg.microphoneCaptureDeviceID = settings.micID }

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
    InputTap.start(writingTo: dir.appendingPathComponent("events.jsonl"), capture: captureRect)

    await MainActor.run {
      isRecording = true
      startedAt = Date()
    }
  }

  /// Stops everything, writes source.json, and returns the project folder.
  func stop() async throws -> URL? {
    guard isRecording, let dir else { return nil }
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
    let source = Project.Source(
      video: "screen.mp4", width: size.width, height: size.height, duration: duration, captureStart: firstPTS?.seconds,
      camera: camera, cursorHidden: cursorHidden ? true : nil)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(source).write(to: dir.appendingPathComponent("source.json"))
    Recorder.copyFollowspotScript(into: dir)

    await MainActor.run {
      isRecording = false
      startedAt = nil
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
      guard let first = firstPTS, pts >= first else { return }
      if audioInput?.isReadyForMoreMediaData == true { audioInput?.append(sb) }
    default:
      break
    }
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
