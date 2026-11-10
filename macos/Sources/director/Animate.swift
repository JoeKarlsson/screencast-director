import AVFoundation
import AppKit
import VideoToolbox
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

  /// Defines overlapProbe(band): the pieces on screen (stickers, dots, hubs, chips, labels, tags,
  /// rows, the heading) that overlap each other by more than `overlapShare` of the smaller one, and,
  /// when `band` (a share of the height) is over 0, any that reach into the caption band at the bottom.
  /// Returns [kind, first piece, second piece, share] rows ("overlap" or "captions").
  static let overlapShare = 0.15
  static let overlapProbe = """
    function overlapProbe(band) {
      const kinds = ["sticker", "dot", "hub", "chip", "label", "tag", "row", "head"];
      const pieces = [];
      for (const e of document.querySelectorAll("#cam > .abs")) {
        const k = kinds.find(c => e.classList.contains(c));
        if (!k) continue;
        let o = 1;
        for (let n = e; n && n !== document.body; n = n.parentElement) {
          const cs = getComputedStyle(n);
          if (cs.display === "none" || cs.visibility === "hidden") { o = 0; break; }
          o *= parseFloat(cs.opacity);
        }
        const r = e.getBoundingClientRect();
        if (o < .5 || r.width * r.height < 100) continue;
        const img = e.querySelector("img");
        const text = (e.textContent || "").trim().replace(/\\s+/g, " ").slice(0, 32);
        pieces.push({ name: k + " \\"" + (text || (img && img.alt) || "?") + "\\"", r });
      }
      const out = [], H = innerHeight;
      for (let i = 0; i < pieces.length; i++) for (let j = i + 1; j < pieces.length; j++) {
        const a = pieces[i].r, b = pieces[j].r;
        const ix = Math.min(a.right, b.right) - Math.max(a.left, b.left), iy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
        if (ix <= 0 || iy <= 0) continue;
        const share = ix * iy / Math.min(a.width * a.height, b.width * b.height);
        if (share > \(overlapShare)) out.push(["overlap", pieces[i].name, pieces[j].name, share]);
      }
      if (band > 0) for (const p of pieces) if (p.r.bottom > H * (1 - band) && p.r.top < H) out.push(["captions", p.name, "", 0]);
      return out;
    }
    """

  /// The caption band an animation keeps clear when captions are on: the bottom 150 of 1080 pixels
  /// in a landscape video (vertical captions sit outside a full-frame animation's card).
  static func captionBand(_ plan: Plan, _ a: Animation) -> Double {
    let size = plan.animationOutput(a)
    return plan.captions.enabled && size.width > size.height ? 150.0 / 1080 : 0
  }

  /// One line per pair of pieces that overlapped (or piece in the caption band), from the rows
  /// each frame's overlapProbe returned, with when it started (source seconds) and for how long.
  static func overlapWarnings(_ a: Animation, index: Int, frames: [(t: Double, rows: [[Any]])]) -> [String] {
    var found: [(kind: String, p: String, q: String, start: Double, end: Double, share: Double)] = []
    let step = 1 / Double(fps)
    for (t, rows) in frames {
      for row in rows {
        guard row.count == 4, let kind = row[0] as? String, let p = row[1] as? String, let q = row[2] as? String else { continue }
        let share = (row[3] as? Double) ?? 0
        if let i = found.firstIndex(where: { $0.kind == kind && $0.p == p && $0.q == q }) {
          found[i].end = t + step
          found[i].share = max(found[i].share, share)
        } else {
          found.append((kind, p, q, t, t + step, share))
        }
      }
    }
    return found.map { f in
      let when = String(format: "from src %.2f for %.2f s", a.start + f.start, f.end - f.start)
      return f.kind == "overlap"
        ? "WARNING: animation #\(index) (\(a.template)): \(f.p) and \(f.q) overlap \(Int((f.share * 100).rounded()))% \(when); move one (x/y) or space their cues"
        : "WARNING: animation #\(index) (\(a.template)): \(f.p) reaches into the caption band at the bottom \(when); move it up"
    }
  }

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
    let todo = force ? plan.animationList.enumerated().map { ($0, $1, $1.clipPath(in: plan, dir: dir)) } : plan.animationsToRender(dir: dir)
    guard !todo.isEmpty else { return 0 }
    for (i, a, path) in todo {
      let page = Page(plan, a)
      let started = Date()
      let (pops, overlaps) = try await page.render(a, index: i, plan: plan, sources: sources, to: dir.appendingPathComponent(path))
      log(String(format: "animation #%d (%@): %@ in %.1fs", i, a.template, path, Date().timeIntervalSince(started)))
      for f in pops { log(popWarning(index: i, a, frame: f)) }
      for w in overlaps { log(w) }
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
    let page = Page(plan, a)
    var frames: [(image: CGImage, label: String)] = []
    let (pops, overlaps) = try await page.render(
      a, index: index, plan: plan, sources: AnimationSources(project: dir, builtIn: resources), to: out, from: at - a.start, length: length
    ) { f, image in
      frames.append((image, String(format: "src %.2f  f%d", a.start + Double(f) / Double(fps), f)))
    }
    for line in pops.map({ popWarning(index: index, a, frame: $0) }) + overlaps { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    let sheet = out.deletingPathExtension().appendingPathExtension("png")
    try Publish.writePNG(try ContactSheet.draw(frames), to: sheet)
    return sheet
  }

  /// "WARNING: animation #0 (storyboard) pops for one frame at src 0:12.3 (frame 41) ..."
  static func popWarning(index: Int, _ a: Animation, frame: Int) -> String {
    "WARNING: animation #\(index) (\(a.template)) pops for one frame at src \(fmtTime(a.start + Double(frame) / Double(fps))) (frame \(frame)): "
      + "something shows for a single frame and is gone the next; look with animate-test"
  }

  /// Every version of animation `index` (it and its alternates) rendered in full to
  /// `<folder>/animation-<index>-v<k>.mp4`, and one sheet beside them with a row per version at the
  /// same moments, so they compare at a glance. Returns the sheet.
  @MainActor
  static func renderVariants(_ dir: URL, _ plan: Plan, index: Int, folder: URL, log: (String) -> Void) async throws -> URL {
    let list = plan.animationList
    guard list.indices.contains(index) else { throw DirectorError("no animation #\(index) (the plan has \(list.count))") }
    let versions = list[index].versions
    guard versions.count > 1 else { throw DirectorError("animation #\(index) has no alternates to compare") }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let size = plan.animationOutput(list[index])
    let columns = ContactSheet.layout(frameWidth: size.width, frameHeight: size.height).columns
    let frameCount = Int((list[index].end - list[index].start) * Double(fps))
    // The same frames for every version: spread over the animation, the last one near its end.
    let picks = Set((1...columns).map { frameCount * $0 / columns - ($0 == columns ? 2 : 0) })
    let sources = AnimationSources(project: dir, builtIn: resources)
    var cells: [(image: CGImage, label: String)] = []
    for (k, a) in versions.enumerated() {
      let out = folder.appendingPathComponent("animation-\(index)-v\(k).mp4")
      var row: [(image: CGImage, label: String)] = []
      let (pops, overlaps) = try await Page(plan, a).render(
        a, index: index, plan: plan, sources: sources, to: out
      ) { f, image in
        if picks.contains(f) {
          row.append((image, String(format: "v%d %@%@  src %.1f", k, a.template, k == 0 ? " (in use)" : "", a.start + Double(f) / Double(fps))))
        }
      }
      log("v\(k) \(a.template)\(a.note.map { ": \($0)" } ?? ""): \(out.path)")
      for line in pops.map({ "v\(k): " + popWarning(index: index, a, frame: $0) }) + overlaps { log(line) }
      cells += row
    }
    let sheet = folder.appendingPathComponent("animation-\(index)-variants.png")
    try Publish.writePNG(try ContactSheet.draw(cells), to: sheet)
    return sheet
  }

  @MainActor
  final class Page: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    let width: Int, height: Int
    /// An overlay's page: nothing painted behind the template, and a clip with alpha.
    let transparent: Bool
    var loading: CheckedContinuation<Void, Error>?

    /// The page for animation `a` in `plan`: its clip's size, transparent for an overlay.
    convenience init(_ plan: Plan, _ a: Animation) {
      let size = plan.animationOutput(a)
      self.init(width: size.width, height: size.height, transparent: a.isOverlay)
    }

    init(width: Int, height: Int, transparent: Bool = false) {
      self.width = width
      self.height = height
      self.transparent = transparent
      _ = NSApplication.shared
      let rect = NSRect(x: 0, y: 0, width: width, height: height)
      web = WKWebView(frame: rect, configuration: WKWebViewConfiguration())
      // Without this WebKit fills the view white before the page paints, so a snapshot has no alpha.
      if transparent { web.setValue(false, forKey: "drawsBackground") }
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
    /// test; `onFrame` gets each finished frame. Returns the frames that pop (`Animation.pops`) and
    /// what the overlap probe found, a line each (`overlapWarnings`).
    func render(
      _ a: Animation, index: Int, plan: Plan, sources: AnimationSources, to out: URL, from: Double = 0, length: Double? = nil,
      onFrame: ((Int, CGImage) throws -> Void)? = nil
    ) async throws -> (pops: [Int], overlaps: [String]) {
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
        _ = try await web.evaluateJavaScript(try String(contentsOf: scriptURL, encoding: .utf8) + "\n;" + Animate.motionProbe + "\n;" + Animate.overlapProbe + "\n;0")
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
      // An overlay keeps its alpha: HEVC with alpha in a .mov (the frames are premultiplied, as drawn).
      let writer = try AVAssetWriter(outputURL: tmp, fileType: transparent ? .mov : .mp4)
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: transparent
          ? [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
              AVVideoQualityKey: 0.9, kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.9,
              kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha,
            ],
          ]
          : [
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
      let band = Animate.captionBand(plan, a)
      var overlaps: [(t: Double, rows: [[Any]])] = []
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
        // Overlaps on every frame, mid-move included: a piece flying through a label is as wrong as one parked on it.
        let at = Animation.subframeTimes(frame: f, fps: Animate.fps, duration: duration, count: 1)[0]
        if let rows = try await web.evaluateJavaScript("seek(\(at)); overlapProbe(\(band))") as? [[Any]], !rows.isEmpty {
          overlaps.append((Double(f) / Double(Animate.fps), rows))
        }
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
      return (Animation.pops(tiles).map { $0 + first }, Animate.overlapWarnings(a, index: index, frames: overlaps))
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
        // Cleared first: an overlay's snapshot is see-through, and drawing composites over the last one.
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
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
      "width": plan.animationOutput(a).width, "height": plan.animationOutput(a).height, "fonts": fonts, "logos": logos,
      "accent": look?.accent ?? "#FFE500",
    ]
    if let f = look?.titleFont { config["titleFont"] = f }
    if let f = look?.captionFont { config["bodyFont"] = f }
    if let t = look?.animationTheme { config["theme"] = t }
    if plan.animationSafeTop(a) > 0 { config["safeTop"] = plan.animationSafeTop(a) }
    if a.isOverlay { config["overlay"] = true }
    return config
  }

}
