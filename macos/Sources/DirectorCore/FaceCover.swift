import AVFoundation
import CoreGraphics
import Foundation
import Vision

// Pop-ups over the speaker's face: a sticker (a meme GIF or picture, or an animation shown as one,
// like the note) or a title. Each is checked a few frames into its run: the frame is rendered
// without any pop-up and with only this one, through the same compositor as the export, so the
// face is wherever the camera layer really puts it (layout, punch-ins, B-roll over it) and the
// pop-up is exactly what it draws (caption nudge, tilt, pop-in). Vision finds the face in the first;
// the pixels that changed in the second are the pop-up. `director faces` lists every sample and
// `director review` the ones over a face.

public enum FaceCover {
  /// Covering more than this share of the face box is covering the face.
  public static let maxShare = 0.10
  /// Where in a pop-up's run it's checked: a moment after it has landed, its middle, a moment before it leaves.
  static let afterStart = 0.4, beforeEnd = 0.3

  public struct Sample: Sendable {
    public var item: String
    public var note: String?
    public var outSeconds: Double
    /// Top-left output pixels; nil when no face is in the frame.
    public var face: CGRect?
    /// Where the pop-up drew (top-left output pixels); nil when it drew nothing.
    public var drawn: CGRect?
    /// Share of the face box the pop-up covers.
    public var share: Double
    /// A spot clear of the face, the captions and the apps' buttons, for a pop-up this shape.
    public var clear: CGRect?
    public var covers: Bool { share > FaceCover.maxShare }
  }

  struct PopUp {
    var item: String
    var note: String?
    var start: Double
    var end: Double
    /// A sticker animation's clip, which has to be rendered for the check to see it.
    var clip: String?
    var add: (inout Plan) -> Void
  }

  /// The pop-ups, each able to add itself back to `withoutPopUps(plan)`. Title cards (slate,
  /// chapter) fill the frame on purpose, so they aren't pop-ups.
  static func popUps(_ plan: Plan, dir: URL) -> [PopUp] {
    var out: [PopUp] = []
    for (i, a) in plan.insertList.enumerated() where a.isSticker {
      out.append(PopUp(item: "sticker #\(i) \((a.file as NSString).lastPathComponent)", note: a.note, start: a.start, end: a.end, clip: nil) { $0.insertList.append(a) })
    }
    for (i, a) in plan.animationList.enumerated() where a.sticker != nil {
      out.append(
        PopUp(item: "animation #\(i) (\(a.template))", note: a.note, start: a.start, end: a.end, clip: a.clipPath(in: plan, dir: dir)) {
          $0.animationList.append(a)
        })
    }
    for (i, c) in plan.callouts.enumerated() where !isCard(c) {
      out.append(PopUp(item: "callout #\(i) \"\(c.text)\"", note: nil, start: c.start, end: c.end, clip: nil) { $0.callouts.append(c) })
    }
    return out
  }

  static func isCard(_ c: Callout) -> Bool { ["slate", "chapter"].contains(c.style ?? "") }

  static func withoutPopUps(_ plan: Plan) -> Plan {
    var p = plan
    p.insertList = plan.insertList.filter { !$0.isSticker }
    p.animationList = plan.animationList.filter { $0.sticker == nil }
    p.callouts = plan.callouts.filter(isCard)
    return p
  }

  /// Output frames to check a pop-up at: after it lands, its middle and before it leaves, each
  /// inside a stretch it plays in.
  static func sampleFrames(_ plan: Plan, start: Double, end: Double) -> [Int] {
    let fps = Double(plan.output.fps)
    let pieces = srcRangeToOut(mapPlan(plan), start, end, fps: plan.output.fps)
    guard let s = pieces.first?.startF, let e = pieces.last?.endF else { return [] }
    let picks = [s + afterStart * fps, (s + e) / 2, e - beforeEnd * fps].map { Int($0.rounded()) }
    var out: [Int] = []
    for f in picks where pieces.contains(where: { Double(f) >= $0.startF && Double(f) < $0.endF }) && !out.contains(f) { out.append(f) }
    return out
  }

  /// Every pop-up's samples, rendered from `project`'s media. Throws when a sticker animation
  /// hasn't been rendered (the check would see nothing there).
  public static func check(_ project: Project, _ plan: Plan, progress: ((String) -> Void)? = nil) async throws -> [Sample] {
    let items = popUps(plan, dir: project.dir)
    guard !items.isEmpty else { return [] }
    for p in items {
      if let clip = p.clip, !FileManager.default.fileExists(atPath: project.dir.appendingPathComponent(clip).path) {
        throw DirectorError("\(p.item) isn't rendered yet (\(clip)); run `director animate` first")
      }
    }
    let base = withoutPopUps(plan)
    let bare = try await buildComposition(project: project, plan: base)
    var out: [Sample] = []
    for p in items {
      progress?(p.item)
      var with = base
      p.add(&with)
      let built = try await buildComposition(project: project, plan: with)
      for f in sampleFrames(plan, start: p.start, end: p.end) {
        let under = try await stillImage(bare, frame: f), over = try await stillImage(built, frame: f)
        let face = try FaceCover.face(in: under)
        let (drawn, share) = covered(face: face, under: under, over: over)
        out.append(
          Sample(
            item: p.item, note: p.note, outSeconds: Double(f) / Double(plan.output.fps), face: face, drawn: drawn, share: share,
            clear: face.map { clearSpot(plan, face: $0, shape: drawn?.size ?? CGSize(width: 1, height: 1)) } ?? nil))
      }
    }
    return out
  }

  /// The biggest face in a frame, in its top-left pixels.
  public static func face(in image: CGImage) throws -> CGRect? {
    let request = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])
    guard let b = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox else { return nil }
    let W = Double(image.width), H = Double(image.height)
    return CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
  }

  /// Where `over` differs from `under` (the pop-up), and the share of `face` it covers. Compared at
  /// a quarter size; a pixel counts when a channel moved by more than a sixth of its range, which
  /// leaves out the sticker's faint shadow edge.
  public static func covered(face: CGRect?, under: CGImage, over: CGImage) -> (drawn: CGRect?, share: Double) {
    let k = 4, w = max(1, under.width / k), h = max(1, under.height / k)
    func pixels(_ image: CGImage) -> [UInt8] {
      var px = [UInt8](repeating: 0, count: w * h * 4)
      px.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      }
      return px
    }
    let a = pixels(under), b = pixels(over)
    let sx = Double(under.width) / Double(w), sy = Double(under.height) / Double(h)
    var minX = w, minY = h, maxX = -1, maxY = -1, inFace = 0, faceCells = 0
    let fx = face.map { (Int($0.minX / sx), Int($0.minY / sy), Int(($0.maxX / sx).rounded(.up)), Int(($0.maxY / sy).rounded(.up))) }
    for y in 0..<h {
      for x in 0..<w {
        let i = (y * w + x) * 4
        let changed = (0..<3).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) > 42 }
        let inBox = fx.map { x >= $0.0 && x < $0.2 && y >= $0.1 && y < $0.3 } ?? false
        if inBox { faceCells += 1 }
        guard changed else { continue }
        (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
        if inBox { inFace += 1 }
      }
    }
    let drawn = maxX < 0 ? nil : CGRect(x: Double(minX) * sx, y: Double(minY) * sy, width: Double(maxX - minX + 1) * sx, height: Double(maxY - minY + 1) * sy)
    return (drawn, faceCells == 0 ? 0 : Double(inFace) / Double(faceCells))
  }

  /// The largest spot (top-left output pixels) for a pop-up of `shape` inside the safe area (the
  /// frame less 4% at each edge outside vertical), clear of the face (with a margin of a tenth of
  /// it) and the captions band: the biggest rectangle the obstacles' edges cut out, shrunk to the shape.
  public static func clearSpot(_ plan: Plan, face: CGRect, shape: CGSize) -> CGRect? {
    let W = Double(plan.output.width), H = Double(plan.output.height)
    let area = SafeArea.rect(plan) ?? CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: W * 0.04, dy: H * 0.04)
    var blocked = [face.insetBy(dx: -face.width * 0.1, dy: -face.height * 0.1)]
    if let band = plan.captionShares { blocked.append(CGRect(x: 0, y: H * band.top, width: W, height: H * (band.bottom - band.top))) }
    let xs = Set([area.minX, area.maxX] + blocked.flatMap { [$0.minX, $0.maxX] }).filter { $0 >= area.minX && $0 <= area.maxX }.sorted()
    let ys = Set([area.minY, area.maxY] + blocked.flatMap { [$0.minY, $0.maxY] }).filter { $0 >= area.minY && $0 <= area.maxY }.sorted()
    var best: CGRect?
    for (i, x0) in xs.enumerated() {
      for x1 in xs[(i + 1)...] {
        for (j, y0) in ys.enumerated() {
          for y1 in ys[(j + 1)...] {
            let r = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            guard !blocked.contains(where: { $0.intersects(r) }) else { continue }
            // Shrunk to the pop-up's shape, about the spot's center.
            let k = min(r.width / max(shape.width, 1), r.height / max(shape.height, 1))
            let fit = CGRect(x: r.midX - shape.width * k / 2, y: r.midY - shape.height * k / 2, width: shape.width * k, height: shape.height * k)
            if best.map({ fit.width * fit.height > $0.width * $0.height }) ?? true { best = fit }
          }
        }
      }
    }
    return best
  }

  /// One line for a sample: when, what, the face and how much of it is covered, and a clear spot as
  /// a sticker's x, y and w (shares of the frame).
  public static func describe(_ s: Sample, _ plan: Plan) -> String {
    let W = Double(plan.output.width), H = Double(plan.output.height)
    func box(_ r: CGRect) -> String { String(format: "x %.2f-%.2f y %.2f-%.2f", r.minX / W, r.maxX / W, r.minY / H, r.maxY / H) }
    let note = s.note.map { " (\($0))" } ?? ""
    var line = "\(s.item)\(note) at out \(fmtTime(s.outSeconds)): "
    guard let face = s.face else { return line + "no face in the frame" }
    line += "face \(box(face)), " + String(format: "%d%% covered", Int((s.share * 100).rounded()))
    if let d = s.drawn { line += ", pop-up \(box(d))" }
    guard s.covers else { return line }
    // A spot narrower than this is no spot: the face fills the free area.
    if let c = s.clear, c.width >= W * 0.15 {
      line += String(format: "; clear spot: x %.2f, y %.2f, w up to %.2f", c.midX / W, c.midY / H, c.width / W)
    } else {
      line += "; no clear spot this shape: make it smaller, or put it over B-roll"
    }
    return line
  }
}
