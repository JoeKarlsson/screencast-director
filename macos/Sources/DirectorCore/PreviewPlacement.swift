import CoreGraphics
import Foundation

// Where the preview's handles go: annotations, titles and the watermark as boxes on the output
// frame (output pixels, top-left origin), and the plan values a box dragged or sized there stands for.
// Stickers and overlays have their own (Placement.swift).

extension Scene {
  /// Whether output frame `f` is on the intro or outro card, which shows none of the video's marks.
  func onCard(_ f: Int) -> Bool {
    (f < introFrames && plan.intro != nil) || (f >= outroStart && outroStart < frameCount && plan.outro != nil)
  }

  /// Where the recorded screen's pixels land at output frame `f` (output = tx + k * source pixel),
  /// and the screen card; nil on a card or while the screen isn't showing.
  public func screenPlacement(frame f: Int) -> (k: Double, tx: Double, ty: Double, card: CGRect)? {
    guard !onCard(f) else { return nil }
    let b = boxes(atFrame: f).screen
    guard b.opacity > 0.01 else { return nil }
    let m = screenMap(b, cameraState(f, base: cameraBase))
    return (m.k, m.tx, m.ty, CGRect(x: b.x, y: b.y, width: b.w, height: b.h))
  }

  /// An annotation's rectangle on the frame at `f`, following the zoom (nil while the screen's hidden).
  public func annotationRect(_ a: Annotation, frame f: Int) -> CGRect? {
    guard let m = screenPlacement(frame: f) else { return nil }
    let sw = plan.source.width, sh = plan.source.height
    return CGRect(x: m.tx + m.k * a.x * sw, y: m.ty + m.k * a.y * sh, width: m.k * a.w * sw, height: m.k * a.h * sh)
  }

  /// `a` moved and sized to cover `rect` on the frame at `f`, kept on the recording.
  public func annotation(_ a: Annotation, covering rect: CGRect, frame f: Int) -> Annotation {
    guard let m = screenPlacement(frame: f) else { return a }
    let sw = m.k * plan.source.width, sh = m.k * plan.source.height
    var out = a
    out.w = Scene.round4(min(1, max(0.01, rect.width / sw)))
    out.h = Scene.round4(min(1, max(0.01, rect.height / sh)))
    out.x = Scene.round4(min(1 - out.w, max(0, (rect.minX - m.tx) / sw)))
    out.y = Scene.round4(min(1 - out.h, max(0, (rect.minY - m.ty) / sh)))
    return out
  }

  /// A title's or lower third's box as drawn once it's in (nil for slates and chapters).
  public func calloutRect(_ c: Callout) -> CGRect? {
    guard c.placeable else { return nil }
    let rect = c.style == "lower-third" ? lowerThirdLayout(c).rect : titleLayout(c).rect
    var center = CGPoint(x: c.x.map { $0 * W } ?? rect.midX, y: c.y.map { $0 * H } ?? rect.midY)
    if !c.isPlaced {
      let move = SafeArea.shift(rect, plan: plan)
      center.x += move.width
      center.y += move.height
    }
    let s = c.size ?? 1
    return CGRect(x: center.x - rect.width * s / 2, y: center.y - rect.height * s / 2, width: rect.width * s, height: rect.height * s)
  }

  /// `c` moved and sized so its box is `rect` (the box's center and width count).
  public func callout(_ c: Callout, covering rect: CGRect) -> Callout {
    var unplaced = c
    (unplaced.x, unplaced.y, unplaced.size) = (nil, nil, nil)
    guard let own = calloutRect(unplaced), own.width > 0 else { return c }
    var out = c
    out.x = Scene.round3(min(1, max(0, rect.midX / W)))
    out.y = Scene.round3(min(1, max(0, rect.midY / H)))
    // No wider than the frame, which would cut its ends off.
    let widest = min(Callout.sizes.upperBound, W / own.width)
    let size = Scene.round3(min(widest, max(Callout.sizes.lowerBound, rect.width / own.width)))
    out.size = abs(size - 1) < 0.01 ? nil : size
    return out
  }

  /// The watermark's box when it shows at output frame `f`.
  public func watermarkRect(frame f: Int) -> CGRect? {
    guard let watermark, let w = look.watermark, !onCard(f) else { return nil }
    // Portrait hides it while the screen card shows (the same rule as `overlays`).
    if socialTop(plan) != nil && boxes(atFrame: f).screen.opacity > 0.5 { return nil }
    return watermarkRect(watermark, w)
  }

  /// The watermark moved to the corner nearest where `rect` was dropped, at `rect`'s height.
  public func watermark(covering rect: CGRect) -> Look.Watermark? {
    guard let watermark, var w = look.watermark else { return nil }
    w.height = Scene.round3(min(0.3, max(0.01, rect.height / min(W, H))))
    let corners = ["topLeft", "topRight", "bottomLeft", "bottomRight"] + (insets(plan).fullBleed ? ["top", "bottom"] : [])
    func distance(_ corner: String) -> Double {
      var c = w
      c.corner = corner
      let r = watermarkRect(watermark, c)
      return hypot(r.midX - rect.midX, r.midY - rect.midY)
    }
    w.corner = corners.min { distance($0) < distance($1) }
    return w
  }

  static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
  static func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
