import CoreGraphics
import CoreText
import Foundation

/// A contact sheet: a frame from each beat of the edit in one image, labeled with its output time,
/// to check before rendering for cropped text, overlaps and things vanishing mid-transition.
/// `director contact-sheet` writes it.
public enum ContactSheet {
  public struct Beat: Equatable {
    public let frame: Int
    public let label: String
  }

  /// Output frames worth a look: the first and last frames, half a second after each cut, after each
  /// zoom, layout, title, annotation, B-roll, punch-in and animation appears, and after each animation
  /// cue. Beats closer than a quarter second share a frame.
  public static func beats(_ plan: Plan, settle: Double = 0.5) -> [Beat] {
    let fps = plan.output.fps
    let mapped = mapPlan(plan)
    let last = max(0, planFrames(plan) - 1)
    let settleF = settle * Double(fps)
    var found: [(Double, String)] = [(0, "start")]
    for (i, m) in mapped.enumerated() where i > 0 ? abs(mapped[i - 1].end - m.start) > 0.001 : m.start > 0.001 {
      found.append((Double(m.outStart) + settleF, "cut"))
    }
    // An item shows from the first moment of it the edit keeps; look once it has settled.
    func item(_ start: Double, _ end: Double, _ label: String) {
      guard let piece = srcRangeToOut(mapped, start, end, fps: fps).first else { return }
      found.append((min(piece.startF + settleF, piece.endF - 1), label))
    }
    plan.zooms.forEach { item($0.start, $0.end, "zoom") }
    plan.layouts.forEach { item($0.start, $0.end, "\($0.mode.rawValue) layout") }
    plan.callouts.forEach { item($0.start, $0.end, $0.style ?? "title") }
    plan.annotationList.forEach { item($0.start, $0.end, $0.kind) }
    plan.insertList.forEach { item($0.start, $0.end, "B-roll") }
    plan.punchInList.forEach { item($0.start, $0.end, "punch-in") }
    for a in plan.animationList {
      item(a.start, a.end, a.template)
      for (name, t) in (a.cues ?? [:]) where t >= a.start && t < a.end {
        // A pop-in takes about a quarter second to land.
        if let f = srcToOut(mapped, min(t + 0.4, a.end - 0.01), fps: fps) { found.append((f, "\(a.template) \(name)")) }
      }
    }
    found.append((Double(last), "end"))

    var beats: [Beat] = []
    for (f, label) in found.map({ (min(last, max(0, Int($0.0.rounded()))), $0.1) }).sorted(by: { $0.0 < $1.0 }) {
      if let prev = beats.last, f - prev.frame < fps / 4 {
        if !prev.label.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(label) {
          beats[beats.count - 1] = Beat(frame: prev.frame, label: prev.label + ", " + label)
        }
      } else {
        beats.append(Beat(frame: f, label: label))
      }
    }
    return beats
  }

  /// Frames on one sheet: `columns` across (as many as fit 1920 px, at least 4) and five rows.
  public static func layout(frameWidth: Int, frameHeight: Int) -> (thumb: CGSize, columns: Int, perSheet: Int) {
    // Each frame fits a 480 x 360 box.
    let scale = min(480 / Double(frameWidth), 360 / Double(frameHeight))
    let thumb = CGSize(width: (Double(frameWidth) * scale).rounded(), height: (Double(frameHeight) * scale).rounded())
    let columns = max(4, 1920 / Int(thumb.width + gap))
    return (thumb, columns, columns * 5)
  }

  static let gap = 16.0, labelHeight = 34.0

  /// One sheet: each image scaled into the grid with its label underneath, on a dark background.
  public static func draw(_ images: [(image: CGImage, label: String)]) throws -> CGImage {
    guard let first = images.first?.image else { throw DirectorError("a contact sheet needs at least one frame") }
    let (thumb, columns, _) = layout(frameWidth: first.width, frameHeight: first.height)
    let cols = min(columns, images.count), rows = (images.count + columns - 1) / columns
    let cellW = thumb.width + gap, cellH = thumb.height + labelHeight + gap
    let w = Int(Double(cols) * cellW + gap), h = Int(Double(rows) * cellH + gap)
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw DirectorError("can't make a \(w)x\(h) contact sheet") }
    ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    for (i, item) in images.enumerated() {
      // Core Graphics counts y from the bottom; rows run down from the top.
      let x = gap + Double(i % columns) * cellW
      let top = Double(h) - gap - Double(i / columns) * cellH
      ctx.draw(item.image, in: CGRect(x: x, y: top - thumb.height, width: thumb.width, height: thumb.height))
      let text = NSAttributedString(string: item.label, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): white])
      let line = CTLineCreateWithAttributedString(text)
      // Long labels are cut to the frame's width.
      let fitted = CTLineCreateTruncatedLine(line, thumb.width, .end, CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil)))) ?? line
      ctx.textPosition = CGPoint(x: x, y: top - thumb.height - 24)
      CTLineDraw(fitted, ctx)
    }
    guard let image = ctx.makeImage() else { throw DirectorError("can't finish the contact sheet") }
    return image
  }
}
