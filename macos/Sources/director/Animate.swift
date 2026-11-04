import AVFoundation
import AppKit
import DirectorCore
import WebKit

/// Renders the plan's animations to their cached clips with an offscreen WKWebView: the bundled
/// Resources/animations page is driven frame by frame (init once, then seek(t)) and each snapshot is
/// written to an H.264 clip. Graphics step at 12 fps, the handmade Vox look. Runs on the main actor and
/// awaits WebKit, so the main queue stays free to deliver its callbacks.
enum Animate {
  static let fps = 12

  /// Where the templates live: next to the app's director binary when bundled, else in the source tree.
  static var resources: URL {
    let bundled = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("../Resources/animations").standardizedFileURL
    if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("animation.html").path) { return bundled }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/animations").standardizedFileURL
  }

  /// Renders each animation whose clip is missing (all of them with `force`) and deletes clips no
  /// animation uses any more. Returns how many it rendered.
  @MainActor
  static func renderMissing(_ dir: URL, _ plan: Plan, force: Bool = false, log: (String) -> Void) async throws -> Int {
    let sources = AnimationSources(project: dir, builtIn: resources)
    // Freeze each template into the video first: the clip's name includes the frozen copy.
    for name in Set(plan.animationList.map(\.template)) where try sources.freeze(name) {
      log("froze the \(name) template into animations/templates/")
    }
    let folder = dir.appendingPathComponent(".animations")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if try plan.removeUnusedAnimationClips(dir: dir) == nil {
      log("plan.json doesn't load right now, so unused animation clips are kept")
    }
    let todo = force ? plan.animationList.enumerated().map { ($0, $1, $1.clipPath(plan.animationOutput, dir: dir, look: plan.look, safeTop: plan.animationSafeTop)) } : plan.animationsToRender(dir: dir)
    guard !todo.isEmpty else { return 0 }
    let page = Page(width: plan.animationOutput.width, height: plan.animationOutput.height)
    for (i, a, path) in todo {
      let started = Date()
      try await page.render(a, plan: plan, sources: sources, to: dir.appendingPathComponent(path))
      log(String(format: "animation #%d (%@): %@ in %.1fs", i, a.template, path, Date().timeIntervalSince(started)))
    }
    return todo.count
  }

  @MainActor
  final class Page: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    let width: Int, height: Int
    var loading: CheckedContinuation<Void, Error>?

    init(width: Int, height: Int) {
      self.width = width
      self.height = height
      _ = NSApplication.shared
      let rect = NSRect(x: 0, y: 0, width: width, height: height)
      web = WKWebView(frame: rect, configuration: WKWebViewConfiguration())
      // Off screen but in a window, so WebKit lays out and paints.
      window = NSWindow(contentRect: rect.offsetBy(dx: -20000, dy: -20000), styleMask: .borderless, backing: .buffered, defer: false)
      super.init()
      window.contentView = web
      window.orderBack(nil)
      web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoading(error) }
    func finishLoading(_ error: Error?) {
      let c = loading
      loading = nil
      if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func render(_ a: Animation, plan: Plan, sources: AnimationSources, to out: URL) async throws {
      // A fresh page per animation, so one template's nodes never leak into the next. Read access to
      // the whole disk: fonts come from profile folders, templates and logos from the video, the
      // personal library or the bundle.
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        loading = c
        web.loadFileURL(Animate.resources.appendingPathComponent("animation.html"), allowingReadAccessTo: URL(fileURLWithPath: "/"))
      }
      guard let scriptURL = sources.script(a.template) else {
        throw DirectorError("no template named \"\(a.template)\" in the video's animations folder, the personal library or the app")
      }
      do {
        _ = try await web.evaluateJavaScript(try String(contentsOf: scriptURL, encoding: .utf8) + "\n;0")
      } catch {
        throw DirectorError("the \(a.template) template (\(scriptURL.path)) has an error: \(error)")
      }
      do {
        let config = try Animate.config(a, plan: plan, logos: try sources.logos())
        _ = try await web.callAsyncJavaScript("return await init(config)", arguments: ["config": config], contentWorld: .page)
      } catch {
        throw DirectorError("the \(a.template) template didn't start: \(error)")
      }

      // One temp file per process: the app and the CLI can render the same clip at once (same
      // contents, since the name is a hash of them), and each moves its own into place.
      let tmp = out.deletingLastPathComponent().appendingPathComponent(".rendering-\(getpid())-\(out.lastPathComponent)")
      try? FileManager.default.removeItem(at: tmp)
      let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
          AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000],
        ])
      input.expectsMediaDataInRealTime = false
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
          kCVPixelBufferHeightKey as String: height,
        ])
      writer.add(input)
      guard writer.startWriting() else { throw writer.error ?? DirectorError("can't write \(tmp.path)") }
      writer.startSession(atSourceTime: .zero)

      let frames = max(1, Int(((a.end - a.start) * Double(Animate.fps)).rounded()))
      for f in 0..<frames {
        let t = Double(f) / Double(Animate.fps)
        do {
          _ = try await web.evaluateJavaScript("seek(\(t)); 0")
        } catch {
          throw DirectorError("the \(a.template) template failed at \(t)s: \(error)")
        }
        let image = try await snapshot()
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        guard let pool = adaptor.pixelBufferPool else { throw DirectorError("no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw DirectorError("no pixel buffer") }
        draw(image, into: buffer)
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(Animate.fps)))
      }
      input.markAsFinished()
      writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(Animate.fps)))
      await writer.finishWriting()
      guard writer.status == .completed else { throw writer.error ?? DirectorError("writing \(out.lastPathComponent) failed") }
      try? FileManager.default.removeItem(at: out)
      try FileManager.default.moveItem(at: tmp, to: out)
    }

    func snapshot() async throws -> CGImage {
      let snap = WKSnapshotConfiguration()
      snap.rect = NSRect(x: 0, y: 0, width: width, height: height)
      // snapshotWidth is in points; the backing scale turns it into pixels.
      snap.snapshotWidth = NSNumber(value: Double(width) / Double(window.backingScaleFactor))
      let image = try await web.takeSnapshot(configuration: snap)
      guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DirectorError("the snapshot had no image") }
      return cg
    }

    func draw(_ image: CGImage, into buffer: CVPixelBuffer) {
      CVPixelBufferLockBaseAddress(buffer, [])
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
      ctx.interpolationQuality = .high
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  /// What the page's init() gets: the template, its data and cues, and the plan's brand look.
  static func config(_ a: Animation, plan: Plan, logos files: [String: URL]) throws -> [String: Any] {
    let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a.data), options: [.fragmentsAllowed])
    let logos = files.mapValues(\.absoluteString)
    let look = plan.look
    let fonts: [[String: String]] = (look?.fontFiles ?? []).map { path in
      ["family": ((path as NSString).lastPathComponent as NSString).deletingPathExtension, "url": URL(fileURLWithPath: path).absoluteString]
    }
    var config: [String: Any] = [
      "template": a.template, "data": data, "cues": a.localCues, "duration": a.end - a.start,
      "width": plan.animationOutput.width, "height": plan.animationOutput.height, "fonts": fonts, "logos": logos,
      "accent": look?.accent ?? "#FFE500",
    ]
    if let f = look?.titleFont { config["titleFont"] = f }
    if let f = look?.captionFont { config["bodyFont"] = f }
    if let t = look?.animationTheme { config["theme"] = t }
    if plan.animationSafeTop > 0 { config["safeTop"] = plan.animationSafeTop }
    return config
  }

}
