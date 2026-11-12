import AppKit
import CoreImage
import DirectorCore
import ImageIO

/// The live animation preview: while the video is paused inside the selected animation, the bundled
/// `director animate-preview` draws its frame at the playhead from the plan as it is now, and the
/// preview shows that frame where the clip goes, so an edit shows in a moment instead of after a
/// render. WebKit stays in director, out of the app's process. The helper quits when the app does
/// (its stdin closes).
final class LiveAnimationPreview: ObservableObject {
  let frames = LiveFrames()
  /// The animation drawn live now: its clip's size and its text pieces (shares of the clip), for the
  /// handles that move them by hand.
  @Published private(set) var shown: Shown?
  /// Dragging in the preview moves the shown animation's text pieces instead of the whole sticker.
  @Published var arranging = false

  struct Shown: Equatable {
    let index: Int
    let clipSize: CGSize
    let pieces: [String: CGRect]
  }
  /// Redraws the paused frame once a new live frame is in.
  var redraw: () -> Void = {}
  private let dir: URL
  private var process: Process?
  private var input: FileHandle?
  private var output = Data()
  /// A request is with the helper; only the newest one waits behind it.
  private var drawing = false
  private var pending: Request?
  /// The animation the preview wants now; a late reply for another one is dropped.
  private var wanted: Int?
  private var lastError: String?

  private struct Request: Encodable {
    let index: Int, t: Double, plan: Plan
  }

  init(dir: URL) { self.dir = dir }

  deinit { process?.terminate() }

  /// Shows animation `index` at `t` seconds into it, drawn from `plan`.
  func show(_ index: Int, at t: Double, plan: Plan) {
    wanted = index
    pending = Request(index: index, t: t, plan: plan)
    sendNext()
  }

  /// Back to the rendered clips: playing, or nothing selected to preview.
  func clear() {
    wanted = nil
    pending = nil
    if shown != nil { shown = nil }
    guard !frames.isEmpty else { return }
    frames.show(nil, for: -1)
    redraw()
  }

  private func sendNext() {
    guard !drawing, let next = pending else { return }
    pending = nil
    do {
      let input = try runningInput()
      drawing = true
      try input.write(contentsOf: JSONEncoder().encode(next) + Data("\n".utf8))
    } catch {
      drawing = false
      report("Live preview: \(error.localizedDescription)")
    }
  }

  /// The helper's stdin, starting it when it isn't running.
  private func runningInput() throws -> FileHandle {
    if let input, process?.isRunning == true { return input }
    let p = Process()
    p.executableURL = Claude.director
    p.arguments = ["animate-preview", dir.path]
    let stdin = Pipe(), stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = FileHandle.nullDevice
    stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      // Empty is the end: the helper exited, and the handler would fire again and again.
      guard !data.isEmpty else { h.readabilityHandler = nil; return }
      DispatchQueue.main.async { self?.received(data) }
    }
    p.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.process = nil
        self.input = nil
        self.output.removeAll()
        self.drawing = false
      }
    }
    try p.run()
    process = p
    input = stdin.fileHandleForWriting
    return stdin.fileHandleForWriting
  }

  private func received(_ data: Data) {
    output.append(data)
    while let newline = output.firstIndex(of: UInt8(ascii: "\n")) {
      let line = output[output.startIndex..<newline]
      output.removeSubrange(output.startIndex...newline)
      drawing = false
      reply(Data(line))
    }
    sendNext()
  }

  private func reply(_ line: Data) {
    guard let fields = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let index = fields["index"] as? Int else { return }
    if let message = fields["error"] as? String { return report("Live preview: \(message)") }
    guard let path = fields["png"] as? String else { return }
    let url = URL(fileURLWithPath: path)
    // Decoded now: the file goes right away, and a CIImage would read it lazily.
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
    try? FileManager.default.removeItem(at: url)
    guard let image, index == wanted else { return }
    lastError = nil
    let pieces = (fields["pieces"] as? [String: [Double]] ?? [:]).compactMapValues { b in
      b.count == 4 ? CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]) : nil
    }
    let size = CGSize(width: fields["width"] as? Double ?? 0, height: fields["height"] as? Double ?? 0)
    let now = Shown(index: index, clipSize: size, pieces: pieces)
    if shown != now { shown = now }
    frames.show(CIImage(cgImage: image), for: index)
    redraw()
  }

  /// Says what went wrong once, not on every frame of a scrub.
  private func report(_ message: String) {
    guard message != lastError else { return }
    lastError = message
    Notices.shared.show(message, error: true)
  }
}
