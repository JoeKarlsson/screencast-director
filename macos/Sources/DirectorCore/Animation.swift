import CryptoKit
import Foundation

/// A motion-graphics explainer (a template filled with data) played full frame over the video.
/// Times are source seconds, as everywhere. `director animate` renders each one to a cached clip
/// in `.animations/`, named by `renderKey`, so changing the data or a cue re-renders it.
public struct Animation: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  /// One of the templates in Resources/animations/templates (e.g. "sprawl", "hub").
  public var template: String
  /// The template's content: titles, logos, labels. Each template documents its fields.
  public var data: JSONValue
  /// Named beats in source seconds (usually a spoken word's start), e.g. {"lock": 67.3}.
  public var cues: [String: Double]?
  public var note: String?
  /// Sounds keyed by cue name ("start" for the animation's start); each plays on its beat.
  public var sounds: [String: Sound]?

  public init(start: Double, end: Double, template: String, data: JSONValue, cues: [String: Double]? = nil, note: String? = nil) {
    self.start = start
    self.end = end
    self.template = template
    self.data = data
    self.cues = cues
    self.note = note
  }

  /// Bump when the templates or the engine change how a clip looks, so cached clips re-render.
  public static let engineVersion = 9

  /// Motion blur: each frame averages snapshots spread over `shutter` of a frame (a 90 degree
  /// shutter), so moving graphics streak while still ones stay sharp. How many depends on how far
  /// things move in that span (`subframeCount`): at 12 fps a pop-in moves far in one frame, and
  /// snapshots more than a few pixels apart show as separate copies instead of a streak.
  public static let maxSubframes = 10
  public static let shutter = 0.25
  /// The farthest apart, in output pixels, two snapshots of the same thing may land (3 px at 1080p
  /// on a 4K frame). A slower drift, like the zine's scribbles, isn't blurred at all.
  public static let subframeStep = 6.0

  /// Snapshots for a frame in which something moves `motion` pixels across the shutter: one when
  /// it moves less than a step, else enough to keep them `subframeStep` apart, up to `maxSubframes`.
  public static func subframeCount(motion: Double) -> Int {
    motion.isNaN ? maxSubframes : motion < subframeStep ? 1 : Int(min(Double(maxSubframes), max(2, (motion / subframeStep).rounded(.up) + 1)))
  }

  /// The `count` page times averaged into frame `frame`. They start a hair after the frame's own
  /// time and stay inside it, so the hand-drawn boil, grain and shake (stepped on whole frames) never
  /// mix two steps in one frame, and never run past the clip's end.
  public static func subframeTimes(frame: Int, fps: Int, duration: Double, count: Int = maxSubframes) -> [Double] {
    let t = Double(frame) / Double(fps)
    let span = shutter / Double(fps)
    return (0..<count).map { k in min(duration, t + 1e-6 + (count < 2 ? 0 : Double(k) / Double(count - 1) * span * 0.999)) }
  }

  /// One-frame pops: something on screen for a single frame (a sticker drawn a frame before its
  /// cue, a start state flashing), the jump-and-jump-back pattern huashu-motion's `om qa` looks for.
  /// Frames are compared as the mean color of square tiles about a quarter of the frame's short side,
  /// so a thing moving inside a tile or a whole-frame drift barely changes them, while a sticker
  /// appearing in one changes it a lot. A tile pops when its frame differs from both neighbors by
  /// `popDiff` (share of full range) and the neighbors differ from each other by under a third of that.
  public static let popTilesPerShortSide = 4
  public static let popDiff = 0.04

  /// Mean B, G and R (0-1) of each tile of a BGRA frame, row by row, as `pops` compares them.
  public static func popTiles(bgra pixels: [UInt8], width: Int, height: Int) -> [Double] {
    let side = max(1, min(width, height) / popTilesPerShortSide)
    let cols = max(1, Int((Double(width) / Double(side)).rounded())), rows = max(1, Int((Double(height) / Double(side)).rounded()))
    var sums = [Int](repeating: 0, count: cols * rows * 3), counts = [Int](repeating: 0, count: cols * rows)
    for y in 0..<height {
      let row = min(rows - 1, y * rows / height) * cols
      for x in 0..<width {
        let tile = row + min(cols - 1, x * cols / width), p = (y * width + x) * 4
        sums[tile * 3] += Int(pixels[p])
        sums[tile * 3 + 1] += Int(pixels[p + 1])
        sums[tile * 3 + 2] += Int(pixels[p + 2])
        counts[tile] += 1
      }
    }
    return sums.indices.map { Double(sums[$0]) / Double(max(1, counts[$0 / 3])) / 255 }
  }

  /// Indices of the frames (each `popTiles` of one frame) where some tile pops.
  public static func pops(_ frames: [[Double]]) -> [Int] {
    guard frames.count > 2 else { return [] }
    func diff(_ a: [Double], _ b: [Double], _ tile: Int) -> Double {
      (0..<3).map { abs(a[tile * 3 + $0] - b[tile * 3 + $0]) }.max()!
    }
    return (1..<(frames.count - 1)).filter { i in
      let (before, now, after) = (frames[i - 1], frames[i], frames[i + 1])
      guard before.count == now.count, now.count == after.count else { return false }
      return (0..<(now.count / 3)).contains { tile in
        let jump = min(diff(now, before, tile), diff(now, after, tile))
        return jump >= popDiff && diff(before, after, tile) < jump / 3
      }
    }
  }

  /// Shifts the animation and its cues together, so the beats keep landing where they did in it.
  public mutating func move(by d: Double) {
    start += d
    end += d
    cues = cues?.mapValues { $0 + d }
  }

  /// The cues relative to the animation's start, which is what the template plays against.
  public var localCues: [String: Double] { (cues ?? [:]).mapValues { $0 - start } }

  /// Names the rendered clip: everything that changes its frames, and nothing else. `script` is the
  /// digest of the video's frozen copy of the template (see AnimationSources), so editing it re-renders.
  public func renderKey(width: Int, height: Int, fps: Int, script: String = "", look: Look? = nil, safeTop: Int = 0) -> String {
    // The parts of the look the page draws with (Animate.config): a new theme, accent or font re-renders.
    struct Brand: Encodable, Sendable { let theme: String?, accent: String?, titleFont: String?, bodyFont: String? }
    struct Key: Encodable, Sendable {
      let v: Int, template: String, script: String, data: JSONValue, cues: [String: Double], duration: Double, w: Int, h: Int, fps: Int
      let brand: Brand?
      /// Pixels at the top kept clear of a vertical video's app UI (nil when none, so older clips keep their names).
      let top: Int?
    }
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    let key = Key(
      v: Animation.engineVersion, template: template, script: script, data: data, cues: localCues.mapValues { ($0 * 1000).rounded() / 1000 },
      duration: ((end - start) * 1000).rounded() / 1000, w: width, h: height, fps: fps,
      brand: look.map { Brand(theme: $0.animationTheme, accent: $0.accent, titleFont: $0.titleFont, bodyFont: $0.captionFont) },
      top: safeTop > 0 ? safeTop : nil)
    // Encoding plain values can only fail on a non-finite number; hash the key's description then,
    // so two different animations never share the empty-data name.
    let digest = SHA256.hash(data: (try? enc.encode(key)) ?? Data(String(reflecting: key).utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// The rendered clip, relative to the project folder `dir`.
  public func clipPath(_ output: Plan.Output, dir: URL?, look: Look? = nil, safeTop: Int = 0) -> String {
    let script = dir.map { AnimationSources.digest(template, in: AnimationSources.videoFolder($0)) } ?? ""
    return ".animations/\(template)-\(renderKey(width: output.width, height: output.height, fps: output.fps, script: script, look: look, safeTop: safeTop)).mp4"
  }
}

/// Any JSON value, for template data that differs from template to template.
public enum JSONValue: Codable, Equatable, Sendable {
  case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Double.self) {
      self = .number(n)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .number(let n): try c.encode(n)
    case .bool(let b): try c.encode(b)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    case .null: try c.encodeNil()
    }
  }
}

extension Plan {
  /// Rendered animations as full-frame B-roll, for the renderer and the composition. An animation
  /// that hasn't been rendered yet is left out (the app and `director render` render it first).
  public func animationInserts(dir: URL?) -> [Insert] {
    // In portrait an animation plays in the screen card, above the camera; elsewhere over the whole frame.
    let placement = socialTop(self) == nil ? "full" : "screen"
    return animationList.compactMap { a in
      let path = a.clipPath(animationOutput, dir: dir, look: look, safeTop: animationSafeTop)
      guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) else { return nil }
      return Insert(start: a.start, end: a.end, file: path, from: animationSeek(a), placement: placement, fit: "fill", note: a.note)
    }
  }

  /// Clip file names to keep in `.animations/`: each animation at this plan's size and at every
  /// export preset's, so an export in another format doesn't delete the preview's clips (or the
  /// preview's render delete an export's).
  public func animationClipNames(dir: URL) -> Set<String> {
    let plans = [self] + ExportPreset.all.map { $0.applied(to: self) }
    return Set(plans.flatMap { p in
      animationList.map { ($0.clipPath(p.animationOutput, dir: dir, look: look, safeTop: p.animationSafeTop) as NSString).lastPathComponent }
    })
  }

  /// Deletes clips in `.animations/` that neither this plan nor the saved plan.json can use (this plan
  /// may be one clip's, or another format's). Returns the names it deleted, or nil when plan.json exists
  /// but doesn't load (half-written mid-edit): then nothing is deleted, since its clips can't be known.
  /// A `.rendering-` file from the last hour is another render in progress (the app's or the CLI's)
  /// and is kept; an older one was left by a render that died.
  public func removeUnusedAnimationClips(dir: URL, now: Date = Date()) throws -> [String]? {
    let folder = dir.appendingPathComponent(".animations")
    let planFile = dir.appendingPathComponent("plan.json")
    var wanted = animationClipNames(dir: dir)
    if FileManager.default.fileExists(atPath: planFile.path) {
      guard let saved = try? Plan.load(planFile) else { return nil }
      wanted.formUnion(saved.animationClipNames(dir: dir))
    }
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    func renderingNow(_ name: String) -> Bool {
      guard name.hasPrefix(".rendering-") else { return false }
      let modified = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.modificationDate]) as? Date
      return modified.map { now.timeIntervalSince($0) < 3600 } ?? false
    }
    let unused = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !wanted.contains($0) && !renderingNow($0) }
    for f in unused { try FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
    return unused
  }

  /// Seconds into an animation's clip where it starts playing: past the part the edit cuts from its
  /// start (a clip opening partway into it), so its beats stay on their words; nil from the top.
  public func animationSeek(_ a: Animation) -> Double? {
    let firstKept = segments.filter { $0.end > a.start }.min { $0.start < $1.start }.map { max($0.start, a.start) } ?? a.start
    return firstKept > a.start + 0.01 ? firstKept - a.start : nil
  }

  /// The size animation clips render at: the frame, or in portrait the screen card they play in.
  public var animationOutput: Output {
    guard socialTop(self) != nil else { return output }
    let card = layoutBoxes(.pip, plan: self).screen
    func even(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
    return Output(width: even(card.w), height: even(card.h), fps: output.fps)
  }

  /// Pixels at the top of the animation clip that a vertical video's app UI would cover (SafeArea),
  /// for the page to keep clear: the part of the screen card above the safe area. 0 elsewhere.
  public var animationSafeTop: Int {
    guard let safe = SafeArea.rect(self) else { return 0 }
    let card = layoutBoxes(.pip, plan: self).screen
    let covered = Double(safe.minY) - card.y
    guard covered > 0, card.h > 0 else { return 0 }
    return Int((covered * Double(animationOutput.height) / card.h).rounded())
  }

  /// Animations whose clip is missing, with the clip path each should be rendered to.
  public func animationsToRender(dir: URL) -> [(index: Int, animation: Animation, path: String)] {
    animationList.enumerated().compactMap { i, a in
      let path = a.clipPath(animationOutput, dir: dir, look: look, safeTop: animationSafeTop)
      return FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) ? nil : (i, a, path)
    }
  }
}
