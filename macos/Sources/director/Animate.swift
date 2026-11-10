import AVFoundation
import AppKit
import DirectorCore
import WebKit

/// Renders the plan's animations to their cached clips with an offscreen WKWebView: the bundled
/// Resources/animations page is driven frame by frame (init once, then seek(t)) and each snapshot is
/// written to an H.264 clip. Graphics step at 12 fps, the handmade Vox look, each frame an average of
/// snapshots for motion blur (`Animation.subframeCount`). Runs on the main actor and
/// awaits WebKit, so the main queue stays free to deliver its callbacks.
enum Animate {
  static let fps = 12

  /// Defines motionProbe(): each element's on-screen box, in pixels. Two probes a moment apart tell
  /// how far anything moved. Fades and lines drawing on don't count: blending two snapshots already
  /// makes them smooth.
  static let motionProbe = """
    function motionProbe() {
      const out = [];
      for (const e of document.body.querySelectorAll("*")) {
        const r = e.getBoundingClientRect();
        out.push(r.x, r.y, r.width, r.height);
      }
      return out;
    }
    """

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
    let todo = force ? plan.animationList.enumerated().map { ($0, $1, $1.clipPath(plan.animationOutput, dir: dir, look: plan.look,
      safeTop: plan.animationSafeTop)) } : plan.animationsToRender(dir: dir)
    guard !todo.isEmpty else { return 0 }
    let page = Page(width: plan.animationOutput.width, height: plan.animationOutput.height)
    for (i, a, path) in todo {
      let started = Date()
      let pops = try await page.render(a, plan: plan, sources: sources, to: dir.appendingPathComponent(path))
      log(String(format: "animation #%d (%@): %@ in %.1fs", i, a.template, path, Date().timeIntervalSince(started)))
      for f in pops { log(popWarning(index: i, a, frame: f)) }
    }
    return todo.count
  }

  /// A quick test of one animation: `length` seconds of animation `index` from source second `at`,
  /// written to `out` (an mp4) with a contact sheet of its frames beside it (the same name, .png),
  /// which it returns. The cached clips in .animations are left alone.
  @MainActor
  static func renderTest(_ dir: URL, _ plan: Plan, index: Int, at: Double, length: Double = 1, to out: URL) async throws -> URL {
    let list = plan.animationList
    guard list.indices.contains(index) else { throw DirectorError("no animation #\(index) (the plan has \(list.count))") }
    let a = list[index]
    guard at >= a.start, at < a.end else {
      throw DirectorError("animation #\(index) plays from \(fmtTime(a.start)) to \(fmtTime(a.end)) (source), so \(fmtTime(at)) isn't in it")
    }
    let page = Page(width: plan.animationOutput.width, height: plan.animationOutput.height)
    var frames: [(image: CGImage, label: String)] = []
    let pops = try await page.render(a, plan: plan, sources: AnimationSources(project: dir, builtIn: resources), to: out, from: at - a.start, length: length) {
      f, image in frames.append((image, String(format: "src %.2f  f%d", a.start + Double(f) / Double(fps), f)))
    }
    for f in pops { FileHandle.standardError.write(Data((popWarning(index: index, a, frame: f) + "\n").utf8)) }
    let sheet = out.deletingPathExtension().appendingPathExtension("png")
    try Publish.writePNG(try ContactSheet.draw(frames), to: sheet)
    return sheet
  }

  /// "WARNING: animation #0 (storyboard) pops for one frame at src 0:12.3 (frame 41) ..."
  static func popWarning(index: Int, _ a: Animation, frame: Int) -> String {
    "WARNING: animation #\(index) (\(a.template)) pops for one frame at src \(fmtTime(a.start + Double(frame) / Double(fps))) (frame \(frame)): "
      + "something shows for a single frame and is gone the next; look with animate-test"
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

    /// Renders `a` to `out`, or just `length` seconds of it from `from` (seconds into it) for a quick
    /// test; `onFrame` gets each finished frame. Returns the frames that pop (`Animation.pops`).
    @discardableResult
    func render(
      _ a: Animation, plan: Plan, sources: AnimationSources, to out: URL, from: Double = 0, length: Double? = nil,
      onFrame: ((Int, CGImage) throws -> Void)? = nil
    ) async throws -> [Int] {
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
        _ = try await web.evaluateJavaScript(try String(contentsOf: scriptURL, encoding: .utf8) + "\n;" + Animate.motionProbe + "\n;0")
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

      let duration = a.end - a.start
      let frames = max(1, Int((duration * Double(Animate.fps)).rounded()))
      let first = min(frames - 1, Int((from * Double(Animate.fps)).rounded()))
      let last = length.map { min(frames, first + max(1, Int(($0 * Double(Animate.fps)).rounded()))) } ?? frames
      let bytes = width * height * 4
      var sum = [UInt32](repeating: 0, count: bytes)
      var pixels = [UInt8](repeating: 0, count: bytes)
      var tiles: [[Double]] = []
      func seek(_ t: Double, probe: Bool = false) async throws -> [Double] {
        let result: Any?
        do {
          result = try await web.evaluateJavaScript("seek(\(t)); \(probe ? "motionProbe()" : "[]")")
        } catch {
          throw DirectorError("the \(a.template) template failed at \(t)s: \(error)")
        }
        guard let boxes = result as? [Double] else { throw DirectorError("the motion probe returned \(String(describing: result)) at \(t)s") }
        return boxes
      }
      for f in first..<last {
        // Motion blur: how far things move across the shutter decides how many snapshots to average.
        let span = Animation.subframeTimes(frame: f, fps: Animate.fps, duration: duration, count: 2)
        let before = try await seek(span[0], probe: true), after = try await seek(span[1], probe: true)
        let motion = before.count == after.count ? zip(before, after).map { abs($0 - $1) }.max() ?? 0 : .infinity
        let times = Animation.subframeTimes(frame: f, fps: Animate.fps, duration: duration, count: Animation.subframeCount(motion: motion))
        for i in sum.indices { sum[i] = 0 }
        for t in times {
          _ = try await seek(t)
          try draw(try await snapshot(), into: &pixels)
          for i in sum.indices { sum[i] &+= UInt32(pixels[i]) }
        }
        let count = UInt32(times.count)
        for i in pixels.indices { pixels[i] = UInt8((sum[i] + count / 2) / count) }
        tiles.append(Animation.popTiles(bgra: pixels, width: width, height: height))
        if let onFrame { try onFrame(f, try image(pixels)) }
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        guard let pool = adaptor.pixelBufferPool else { throw DirectorError("no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw DirectorError("no pixel buffer") }
        copy(pixels, into: buffer)
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f - first), timescale: CMTimeScale(Animate.fps)))
      }
      input.markAsFinished()
      writer.endSession(atSourceTime: CMTime(value: CMTimeValue(last - first), timescale: CMTimeScale(Animate.fps)))
      await writer.finishWriting()
      guard writer.status == .completed else { throw writer.error ?? DirectorError("writing \(out.lastPathComponent) failed") }
      try? FileManager.default.removeItem(at: out)
      try FileManager.default.moveItem(at: tmp, to: out)
      return Animation.pops(tiles).map { $0 + first }
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

    /// Draws a snapshot into `pixels`: BGRA, `width` * 4 bytes a row.
    func draw(_ image: CGImage, into pixels: inout [UInt8]) throws {
      let (width, height) = (width, height)
      try pixels.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw DirectorError("can't draw the snapshot") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      }
    }

    /// Copies a frame into the clip's buffer, row by row (the buffer's rows may be padded).
    func copy(_ pixels: [UInt8], into buffer: CVPixelBuffer) {
      CVPixelBufferLockBaseAddress(buffer, [])
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      let out = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer), row = width * 4
      pixels.withUnsafeBytes { src in
        for y in 0..<height { memcpy(out + y * stride, src.baseAddress! + y * row, row) }
      }
    }

    /// A frame's pixels as an image, for a test's contact sheet.
    func image(_ pixels: [UInt8]) throws -> CGImage {
      guard let provider = CGDataProvider(data: Data(pixels) as CFData),
        let image = CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
      else { throw DirectorError("can't make an image of the frame") }
      return image
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
