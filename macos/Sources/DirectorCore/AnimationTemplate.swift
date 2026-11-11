import Foundation

/// What an animation template offers for editing, from templates/<name>.json next to its .js:
/// the fields the inspector shows, the beats it can be cued to, and the data a new one starts with.
public struct AnimationTemplate: Codable, Equatable, Sendable {
  public struct Field: Codable, Equatable, Sendable {
    /// Dotted path into the data ("center.logo").
    public var key: String
    public var label: String
    /// text | texts (a list of lines) | logo (one name) | logos (a list of names) | number | lottie (a Lottie file's name)
    public var type: String
    /// Most entries a list (or the largest number) takes.
    public var max: Int?
    public var help: String?
  }
  public struct Cue: Codable, Equatable, Sendable {
    public var key: String
    public var label: String
    /// Seconds from the start in the template's own length, scaled to a new animation's length.
    public var at: Double
  }

  public var name: String
  public var title: String
  public var summary: String
  /// The length the default beats are timed for, in seconds.
  public var length: Double
  public var fields: [Field]
  public var cues: [Cue]
  public var data: JSONValue
  /// A new one floats over the video (`Animation.overlay`) instead of filling the frame.
  public var overlay: Bool?

  /// Every template in `dir` (Resources/animations/templates), by title.
  public static func all(in dir: URL) -> [AnimationTemplate] { load(in: dir).templates }

  /// Every readable template in `dir`, by title, and why each manifest that isn't readable was left out.
  public static func load(in dir: URL) -> (templates: [AnimationTemplate], problems: [String]) {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var templates: [AnimationTemplate] = [], problems: [String] = []
    for file in files where file.pathExtension == "json" {
      do {
        templates.append(try JSONDecoder().decode(AnimationTemplate.self, from: Data(contentsOf: file)))
      } catch {
        problems.append("\(file.path) isn't a template manifest: \(error.localizedDescription)")
      }
    }
    return (templates.sorted { $0.title < $1.title }, problems)
  }

  /// A new animation over start...end with the template's starting data and its beats spread over
  /// the new length.
  public func make(start: Double, end: Double, note: String? = nil) -> Animation {
    let k = (end - start) / max(length, 0.1)
    let cues = Dictionary(uniqueKeysWithValues: self.cues.map { ($0.key, ((start + $0.at * k) * 100).rounded() / 100) })
    var a = Animation(start: start, end: end, template: name, data: data, cues: cues, note: note ?? title)
    a.overlay = overlay
    return a
  }
}

extension JSONValue {
  /// The value at a dotted path ("center.logo"), nil when any step is missing.
  public subscript(path path: String) -> JSONValue? {
    get {
      var v: JSONValue? = self
      for key in path.split(separator: ".") {
        guard case .object(let o)? = v else { return nil }
        v = o[String(key)]
      }
      return v
    }
    set {
      let keys = path.split(separator: ".").map(String.init)
      self = JSONValue.setting(self, keys[...], to: newValue)
    }
  }

  private static func setting(_ v: JSONValue, _ keys: ArraySlice<String>, to new: JSONValue?) -> JSONValue {
    guard let key = keys.first else { return new ?? .null }
    var o: [String: JSONValue] = [:]
    if case .object(let existing) = v { o = existing }
    if keys.count == 1, new == nil {
      o.removeValue(forKey: key)
    } else {
      o[key] = setting(o[key] ?? .null, keys.dropFirst(), to: new)
    }
    return .object(o)
  }

  public var string: String? { if case .string(let s) = self { return s } else { return nil } }
  public var number: Double? { if case .number(let n) = self { return n } else { return nil } }
  /// The strings in an array (other entries are skipped).
  public var strings: [String] { if case .array(let a) = self { return a.compactMap(\.string) } else { return [] } }
}
