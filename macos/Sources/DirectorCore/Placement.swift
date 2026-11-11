import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

// Stickers and overlays as boxes on the frame, for the preview's handles: drag to move, a corner to
// size, a knob to turn. A sticker's x, y, w and rotation are its own box. An overlay is a layer the
// frame's size: w scales it and rotation turns it about the frame's center, which then moves to x, y.

/// A sticker or overlay the preview can move, size and turn, with its defaults filled in.
public struct PlacedItem: Equatable, Sendable {
  public var selection: Selection
  public var start: Double
  public var end: Double
  public var isSticker: Bool
  /// Center (fractions of the frame from its top left), width (a share of the frame's) and turn
  /// (degrees, clockwise).
  public var x: Double
  public var y: Double
  public var w: Double
  public var rotation: Double
  /// The picture or clip it draws (an animation's rendered clip), whose shape sets a sticker's height.
  public var file: String
  /// What an overlay draws inside its frame-sized layer, in output pixels from the top left (a
  /// Lottie's box); nil for the whole frame.
  public var content: CGRect?

  /// A sticker's or overlay's box as drawn, in output pixels from the top left: its center, its
  /// size before the turn, and the turn in degrees clockwise.
  public struct Box: Equatable, Sendable {
    public var center: CGPoint
    public var size: CGSize
    public var rotation: Double
  }

  public static let stickerWidths = 0.05...0.9
  public static let overlayWidths = 0.05...4.0

  /// Where it's drawn on `plan`'s frame: a sticker's box needs its picture's size (nil until known).
  public func box(in plan: Plan, mediaSize: CGSize?) -> Box? {
    if isSticker {
      guard let mediaSize, mediaSize.width > 0, mediaSize.height > 0 else { return nil }
      var a = Insert(start: start, end: end, file: file, placement: "sticker")
      (a.x, a.y, a.w) = (x, y, w)
      let r = plan.stickerFrame(a, imageSize: mediaSize).insetBy(dx: -plan.stickerBorder, dy: -plan.stickerBorder)
      return Box(center: CGPoint(x: r.midX, y: r.midY), size: r.size, rotation: rotation)
    }
    let frame = plan.frameSize
    let content = content ?? CGRect(origin: .zero, size: frame)
    return Box(
      center: layerPoint(CGPoint(x: content.midX, y: content.midY), frame: frame), size: CGSize(width: content.width * w, height: content.height * w),
      rotation: rotation)
  }

  /// Where a point of an overlay's layer (output pixels from the top left) lands on the frame.
  public func layerPoint(_ p: CGPoint, frame: CGSize) -> CGPoint {
    let t = rotation * .pi / 180
    let dx = (p.x - frame.width / 2) * w, dy = (p.y - frame.height / 2) * w
    return CGPoint(x: x * frame.width + dx * cos(t) - dy * sin(t), y: y * frame.height + dx * sin(t) + dy * cos(t))
  }

  /// Moved so its box's center lands `d` output pixels from where it's drawn now (`box`).
  public func moved(by d: CGSize, from box: Box, in plan: Plan) -> PlacedItem {
    var out = self
    let f = plan.frameSize
    if isSticker {
      out.x = min(1, max(0, (box.center.x + d.width) / f.width))
      out.y = min(1, max(0, (box.center.y + d.height) / f.height))
    } else {
      out.x = x + d.width / f.width
      out.y = y + d.height / f.height
    }
    return out.rounded
  }

  /// `factor` times as big, about its box's center.
  public func sized(by factor: Double, from box: Box, in plan: Plan) -> PlacedItem {
    var out = self
    let range = isSticker ? PlacedItem.stickerWidths : PlacedItem.overlayWidths
    out.w = min(range.upperBound, max(range.lowerBound, w * factor))
    return out.keeping(box.center, in: plan).rounded
  }

  /// Turned to `degrees` clockwise, about its box's center. Within 3 degrees of square it sits square.
  public func turned(to degrees: Double, from box: Box, in plan: Plan) -> PlacedItem {
    var out = self
    var r = degrees.truncatingRemainder(dividingBy: 360)
    if r > 180 { r -= 360 } else if r <= -180 { r += 360 }
    out.rotation = abs(r) < 3 ? 0 : r
    return out.keeping(box.center, in: plan).rounded
  }

  /// An overlay moved so its content's center sits at `center` again after a size or turn (a
  /// sticker sizes and turns about its own center already).
  private func keeping(_ center: CGPoint, in plan: Plan) -> PlacedItem {
    guard !isSticker else { return self }
    let f = plan.frameSize
    let content = content ?? CGRect(origin: .zero, size: f)
    let now = layerPoint(CGPoint(x: content.midX, y: content.midY), frame: f)
    var out = self
    out.x += (center.x - now.x) / f.width
    out.y += (center.y - now.y) / f.height
    return out
  }

  private var rounded: PlacedItem {
    var out = self
    (out.x, out.y, out.w) = ((x * 1000).rounded() / 1000, (y * 1000).rounded() / 1000, (w * 1000).rounded() / 1000)
    out.rotation = (rotation * 10).rounded() / 10
    return out
  }

  /// An overlay sitting as if unplaced: filling the frame, square.
  var isWholeFrame: Bool { !isSticker && x == 0.5 && y == 0.5 && w == 1 && rotation == 0 }

  /// A picture's or clip's size as Scene draws it (a picture turned by its orientation, a clip's
  /// first video track as stored); nil when it can't be read.
  public static func mediaSize(of file: String, dir: URL) async -> CGSize? {
    guard let url = Scene.fileURL(file, dir: dir), FileManager.default.fileExists(atPath: url.path) else { return nil }
    if Insert.imageExtensions.contains(url.pathExtension.lowercased()) {
      return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])?.extent.size
    }
    guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return nil }
    return try? await track.load(.naturalSize)
  }
}

extension Insert {
  /// A sticker's place when it doesn't say: upper right, about a third of the frame wide (tilted `stickerTilt`).
  public static let stickerX = 0.74
  public static let stickerY = 0.3
  public static let stickerWidth = 0.32

  /// How an overlay's frame-sized layer is placed (`x`, `y`, `w`, `rotation`, as `PlacedItem` reads
  /// them) in Core Image's coordinates (y up) on a `W` by `H` frame; nil when it fills the frame square.
  public func overlayTransform(W: Double, H: Double) -> CGAffineTransform? {
    guard isOverlay, !isSticker, x != nil || y != nil || w != nil || rotation != nil else { return nil }
    let k = w ?? 1, turn = -(rotation ?? 0) * .pi / 180
    return CGAffineTransform(translationX: -W / 2, y: -H / 2).concatenating(CGAffineTransform(scaleX: k, y: k))
      .concatenating(CGAffineTransform(rotationAngle: turn)).concatenating(CGAffineTransform(translationX: W * (x ?? 0.5), y: H - H * (y ?? 0.5)))
  }
}

extension Plan {
  public var frameSize: CGSize { CGSize(width: output.width, height: output.height) }

  /// The white border round a sticker, in output pixels.
  public var stickerBorder: Double { 10 * min(Double(output.width), Double(output.height)) / 1080 }

  /// Where a sticker's picture sits, in output pixels from the top left: `w` of the frame's width at
  /// the picture's shape, no taller than 80% of the frame, centered on `x`, `y` but kept, border and
  /// all, 4% of the frame's height from its edges, and moved clear of the captions.
  public func stickerFrame(_ a: Insert, imageSize s: CGSize) -> CGRect {
    let W = Double(output.width), H = Double(output.height)
    let edge = stickerBorder + H * 0.04
    var w = W * (a.w ?? Insert.stickerWidth), h = w * s.height / s.width
    if h > H * 0.8 { (w, h) = (H * 0.8 * s.width / s.height, H * 0.8) }
    let cx = min(max(W * (a.x ?? Insert.stickerX), w / 2 + edge), W - w / 2 - edge)
    var cy = min(max(H * (a.y ?? Insert.stickerY), h / 2 + edge), H - h / 2 - edge)
    // Clear of the captions too: moved above them, or below when there's no room above.
    if let band = captionShares, cy + h / 2 + stickerBorder > H * band.top, cy - h / 2 - stickerBorder < H * band.bottom {
      if H * band.top - edge - h / 2 >= h / 2 + edge {
        cy = H * band.top - edge - h / 2
      } else if H * band.bottom + edge + h / 2 <= H - h / 2 - edge {
        cy = H * band.bottom + edge + h / 2
      }
    }
    return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
  }

  /// Every sticker and overlay, B-roll and animations alike, as the preview's handles move them;
  /// with `at`, only those on screen at that source time (an animation's clip name hashes files).
  /// An animation's `file` is its clip (which may not be rendered yet).
  public func placedItems(dir: URL?, at t: Double? = nil) -> [PlacedItem] {
    var out: [PlacedItem] = []
    for (i, a) in insertList.enumerated() where a.isOverlay && t.map({ $0 >= a.start && $0 < a.end }) != false {
      let s = a.isSticker
      out.append(
        PlacedItem(
          selection: .insert(i), start: a.start, end: a.end, isSticker: s, x: a.x ?? (s ? Insert.stickerX : 0.5),
          y: a.y ?? (s ? Insert.stickerY : 0.5), w: a.w ?? (s ? Insert.stickerWidth : 1), rotation: a.rotation ?? (s ? Insert.stickerTilt : 0),
          file: a.file))
    }
    for (i, a) in animationList.enumerated() where a.floats && t.map({ $0 >= a.start && $0 < a.end }) != false {
      let s = a.sticker != nil
      let p = a.sticker ?? a.place
      out.append(
        PlacedItem(
          selection: .animation(i), start: a.start, end: a.end, isSticker: s, x: p?.x ?? (s ? Insert.stickerX : 0.5),
          y: p?.y ?? (s ? Insert.stickerY : 0.5), w: p?.w ?? (s ? Animation.stickerWidth : 1), rotation: p?.rotation ?? (s ? Insert.stickerTilt : 0),
          file: a.clipPath(in: self, dir: dir), content: s ? nil : lottieBox(a, dir: dir)))
    }
    return out
  }

  /// Where the lottie template draws its Lottie on the frame (its data's x, y and width; the height
  /// from the file's shape, frozen into the video at render, and square before that).
  func lottieBox(_ a: Animation, dir: URL?) -> CGRect? {
    guard a.template == "lottie" else { return nil }
    let W = Double(output.width), H = Double(output.height)
    var ratio = 1.0
    if let dir, let name = a.lottieFile,
      let data = try? Data(contentsOf: AnimationSources.videoFolder(dir).appendingPathComponent("lottie/\(name)")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let lw = json["w"] as? Double, let lh = json["h"] as? Double, lw > 0
    {
      ratio = lh / lw
    }
    let w = (a.data[path: "width"]?.number ?? 40) / 100 * W, h = w * ratio
    let cx = (a.data[path: "x"]?.number ?? 50) / 100 * W, cy = (a.data[path: "y"]?.number ?? 50) / 100 * H
    return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
  }

  /// Puts a sticker or overlay where the preview's handles left it. An overlay back at the whole
  /// frame, square, drops its place.
  public mutating func place(_ item: PlacedItem) {
    let keep = !item.isWholeFrame
    switch item.selection {
    case .insert(let i) where insertList.indices.contains(i):
      insertList[i].x = keep ? item.x : nil
      insertList[i].y = keep ? item.y : nil
      insertList[i].w = keep ? item.w : nil
      insertList[i].rotation = keep ? item.rotation : nil
    case .animation(let i) where animationList.indices.contains(i):
      let p = Animation.Sticker(x: item.x, y: item.y, w: item.w, rotation: item.rotation)
      if animationList[i].sticker != nil {
        animationList[i].sticker = p
      } else {
        animationList[i].place = keep ? p : nil
      }
    default: break
    }
  }
}
