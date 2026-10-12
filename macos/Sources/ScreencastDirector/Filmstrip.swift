import AVFoundation
import SwiftUI

/// Small frames of one recording for the timeline's Clips track, generated off the main thread
/// and kept by time bucket, so zooming and redrawing reuse them. Its state is only touched on the
/// main thread.
final class FilmstripCache: ObservableObject, @unchecked Sendable {
  /// Bumped (coalesced) when new frames arrive.
  @Published private(set) var version = 0

  /// Pixel width of a generated frame.
  static let frameWidth: CGFloat = 160
  /// Most frames kept per recording; the oldest go first.
  private static let maxFrames = 800
  /// Most recordings kept.
  private static let maxCaches = 3
  private static var caches: [(key: String, cache: FilmstripCache)] = []

  /// The cache for `video` in project folder `dir`, shared by every timeline that shows it.
  static func shared(dir: URL, video: String, duration: Double) -> FilmstripCache {
    let key = dir.appendingPathComponent(video).path
    if let i = caches.firstIndex(where: { $0.key == key }) {
      let c = caches.remove(at: i)
      caches.append(c)
      return c.cache
    }
    let c = FilmstripCache(url: dir.appendingPathComponent(video), duration: duration)
    caches.append((key, c))
    if caches.count > maxCaches { caches.removeFirst() }
    return c
  }

  /// Finest bucket in seconds: half a second, coarser for long recordings so a fully zoomed-in
  /// timeline needs at most ~300 frames.
  let finest: Double
  private let asset: AVURLAsset
  private let generator: AVAssetImageGenerator
  private var frames: [Int: CGImage] = [:]
  private var order: [Int] = []
  private var pending = Set<Int>()
  /// Keys the generator couldn't make, never asked for again.
  private var failed = Set<Int>()
  private let duration: Double
  private var queued: [Int] = []
  private var running = false
  private var publishScheduled = false

  private init(url: URL, duration: Double) {
    var s = 0.5
    while duration / s > 300 { s *= 2 }
    finest = s
    self.duration = duration
    asset = AVURLAsset(url: url)
    generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: Self.frameWidth, height: Self.frameWidth)
    let tol = CMTime(seconds: 0.5, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tol
    generator.requestedTimeToleranceAfter = tol
  }

  /// The bucket size for tiles `tileSeconds` apart: a power-of-two multiple of `finest`.
  func step(forTileSeconds t: Double) -> Double {
    var s = finest
    while s * 2 <= t { s *= 2 }
    return s
  }

  /// The bucket key (milliseconds of its midpoint) for source time `t`.
  func key(_ t: Double, step: Double) -> Int {
    let mid = ((t / step).rounded(.down) + 0.5) * step
    return Int((max(0, min(mid, duration - 0.1)) * 1000).rounded())
  }

  func image(_ key: Int) -> CGImage? { frames[key] }

  /// Queue the frames that aren't cached or on their way. Cheap; safe to call from a view body.
  func request(_ keys: [Int]) {
    for k in keys where frames[k] == nil && !pending.contains(k) && !failed.contains(k) {
      pending.insert(k)
      queued.append(k)
    }
    if !queued.isEmpty && !running { DispatchQueue.main.async { self.runNext() } }
  }

  private func runNext() {
    guard !running, !queued.isEmpty else { return }
    running = true
    let batch = Array(queued.prefix(24))
    queued.removeFirst(batch.count)
    let times = batch.map { CMTime(value: CMTimeValue($0), timescale: 1000) }
    let generator = self.generator
    Task.detached(priority: .utility) { [self] in
      var got: [(Int, CGImage)] = []
      for await r in generator.images(for: times) {
        if let img = try? r.image { got.append((Int((r.requestedTime.seconds * 1000).rounded()), img)) }
      }
      let results = got
      await MainActor.run {
        for k in batch { self.pending.remove(k) }
        for (k, img) in results { self.store(k, img) }
        for k in batch where self.frames[k] == nil { self.failed.insert(k) }
        self.running = false
        self.schedulePublish()
        self.runNext()
      }
    }
  }

  private func store(_ k: Int, _ img: CGImage) {
    if frames[k] == nil { order.append(k) }
    frames[k] = img
    while order.count > Self.maxFrames { frames[order.removeFirst()] = nil }
  }

  private func schedulePublish() {
    guard !publishScheduled else { return }
    publishScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.publishScheduled = false
      self.version += 1
    }
  }
}

/// The scrolled-to part of the timeline (content x, padded and snapped so small scrolls don't
/// publish), so the filmstrip only draws and requests what's near the screen.
final class TimelineViewport: ObservableObject {
  @Published private(set) var range: ClosedRange<CGFloat> = 0...3000
  /// The exact visible rect, for checking whether something is on screen.
  private(set) var visible = CGRect(x: 0, y: 0, width: 800, height: 0)

  func update(_ r: CGRect) {
    visible = r
    let chunk: CGFloat = 512
    let lo = ((r.minX - r.width) / chunk).rounded(.down) * chunk
    let hi = ((r.maxX + r.width) / chunk).rounded(.up) * chunk
    let new = max(0, lo)...max(0, hi)
    if new != range { range = new }
  }
}

/// Frames tiled across one clip bar, on a fixed grid of the whole timeline (so tiles stay put
/// when a clip is trimmed). Draws nothing until frames arrive.
struct Filmstrip: View, Equatable {
  @ObservedObject var cache: FilmstripCache
  @ObservedObject var viewport: TimelineViewport
  let start: Double
  let end: Double
  let pxPerSec: Double
  let height: CGFloat
  /// Width / height of the recording.
  let aspect: Double

  static func == (a: Filmstrip, b: Filmstrip) -> Bool {
    a.cache === b.cache && a.viewport === b.viewport && a.start == b.start && a.end == b.end
      && a.pxPerSec == b.pxPerSec && a.height == b.height && a.aspect == b.aspect
  }

  var body: some View {
    let barX = CGFloat(start * pxPerSec)
    let barW = max(3, CGFloat((end - start) * pxPerSec))
    let lo = max(barX, viewport.range.lowerBound)
    let hi = min(barX + barW, viewport.range.upperBound)
    let tileW = max(8, height * CGFloat(min(3, max(0.4, aspect))))
    let step = cache.step(forTileSeconds: Double(tileW) / pxPerSec)
    let first = Int((lo / tileW).rounded(.down))
    let last = Int((hi / tileW).rounded(.up))
    let tiles: [(x: CGFloat, key: Int)] =
      hi > lo
      ? (first..<max(first, last)).map { i in
        let x = CGFloat(i) * tileW
        return (x, cache.key(Double(x + tileW / 2) / pxPerSec, step: step))
      } : []
    cache.request(tiles.map(\.key))
    let version = cache.version
    return Canvas { ctx, size in
      _ = version
      for t in tiles {
        guard let img = cache.image(t.key) else { continue }
        ctx.draw(Image(decorative: img, scale: 1), in: CGRect(x: t.x - lo, y: 0, width: tileW, height: size.height))
      }
    }
    .frame(width: max(0, hi - lo), height: height)
    .padding(.leading, max(0, lo - barX))
    .frame(width: barW, height: height, alignment: .leading)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
