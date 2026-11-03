import CryptoKit
import Foundation

/// A motion-graphics explainer (a template filled with data) played full frame over the video.
/// Times are source seconds, as everywhere. `director animate` renders each one to a cached clip
/// in `.animations/`, named by `renderKey`, so changing the data or a cue re-renders it.
public struct Animation: Codable, Equatable {
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
  public static let engineVersion = 2

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
  public func renderKey(width: Int, height: Int, fps: Int, script: String = "") -> String {
    struct Key: Encodable {
      let v: Int, template: String, script: String, data: JSONValue, cues: [String: Double], duration: Double, w: Int, h: Int, fps: Int
    }
    let enc = JSONEncoder()
    enc.outputFormatting = .sortedKeys
    let key = Key(
      v: Animation.engineVersion, template: template, script: script, data: data, cues: localCues.mapValues { ($0 * 1000).rounded() / 1000 },
      duration: ((end - start) * 1000).rounded() / 1000, w: width, h: height, fps: fps)
    let digest = SHA256.hash(data: (try? enc.encode(key)) ?? Data())
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// The rendered clip, relative to the project folder `dir`.
  public func clipPath(_ output: Plan.Output, dir: URL?) -> String {
    let script = dir.map { AnimationSources.digest(template, in: AnimationSources.videoFolder($0)) } ?? ""
    return ".animations/\(template)-\(renderKey(width: output.width, height: output.height, fps: output.fps, script: script)).mp4"
  }
}

/// Any JSON value, for template data that differs from template to template.
public enum JSONValue: Codable, Equatable {
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
  /// `animations` as a plain list (empty when there are none).
  public var animationList: [Animation] {
    get { animations ?? [] }
    set { animations = newValue.isEmpty ? nil : newValue }
  }

  /// Rendered animations as full-frame B-roll, for the renderer and the composition. An animation
  /// that hasn't been rendered yet is left out (the app and `director render` render it first).
  public func animationInserts(dir: URL?) -> [Insert] {
    animationList.compactMap { a in
      let path = a.clipPath(output, dir: dir)
      guard let dir, FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) else { return nil }
      return Insert(start: a.start, end: a.end, file: path, placement: "full", fit: "fill", note: a.note)
    }
  }

  /// Clip file names to keep in `.animations/`: each animation at this plan's size and at every
  /// export preset's, so an export in another format doesn't delete the preview's clips (or the
  /// preview's render delete an export's).
  public func animationClipNames(dir: URL) -> Set<String> {
    let outputs = [output] + ExportPreset.all.map { $0.applied(to: self).output }
    return Set(outputs.flatMap { o in animationList.map { ($0.clipPath(o, dir: dir) as NSString).lastPathComponent } })
  }

  /// Animations whose clip is missing, with the clip path each should be rendered to.
  public func animationsToRender(dir: URL) -> [(index: Int, animation: Animation, path: String)] {
    animationList.enumerated().compactMap { i, a in
      let path = a.clipPath(output, dir: dir)
      return FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) ? nil : (i, a, path)
    }
  }
}
