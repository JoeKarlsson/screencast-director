import Foundation

/// A short piece of the edit exported on its own, like a vertical social clip: a source-time range
/// of the main edit, in a format. It renders from the main edit, so fixes there show up in it.
public struct Clip: Codable, Equatable {
  public var name: String
  public var start: Double
  public var end: Double
  /// An `ExportPreset` id ("vertical", "square", ...); nil keeps the video's own format.
  public var format: String?

  public init(name: String, start: Double, end: Double, format: String? = nil) {
    self.name = name
    self.start = start
    self.end = end
    self.format = format
  }

  public var preset: ExportPreset? { format.flatMap { id in ExportPreset.all.first { $0.id == id } } }
}

extension Plan {
  /// `clips` as a plain list (empty when there are none).
  public var clipList: [Clip] {
    get { clips ?? [] }
    set { clips = newValue.isEmpty ? nil : newValue }
  }

  /// The edit cut down to a clip's range and reshaped for its format. Only the animations it
  /// overlaps stay (so only those render), and the intro and outro cards are left out.
  public func trimmed(to clip: Clip) -> Plan {
    var p = self
    p.segments = segments.compactMap { s in
      let lo = max(s.start, clip.start), hi = min(s.end, clip.end)
      guard hi - lo > 0.05 else { return nil }
      var t = s
      t.start = lo
      t.end = hi
      return t
    }
    // The clip opens on a plain cut, not on the main edit's transition into that segment.
    if !p.segments.isEmpty { p.segments[0].transition = nil }
    p.animationList = animationList.filter { $0.end > clip.start && $0.start < clip.end }
    p.clips = nil
    p.intro = nil
    p.outro = nil
    return clip.preset.map { $0.applied(to: p) } ?? p
  }
}

/// A name safe to use in a file name.
func fileSafe(_ name: String) -> String {
  name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
}

/// Where an export goes, named after the project folder: "Name.mp4", "Name (4K).mp4" for a
/// preset, "Name - Hook.mp4" for a clip.
public func exportURL(dir: URL, preset: ExportPreset? = nil, clip: Clip? = nil) -> URL {
  let project = dir.lastPathComponent
  let name = clip.map { "\(project) - \(fileSafe($0.name))" } ?? project + (preset.map { " (\($0.fileLabel))" } ?? "")
  return dir.appendingPathComponent(name + ".mp4")
}

/// Whether a file in a project folder is an export: named after the project, or an older out*.mp4.
public func isExportFile(_ file: String, project: String) -> Bool {
  file.hasSuffix(".mp4") && (file.hasPrefix(project) || file.hasPrefix("out"))
}
