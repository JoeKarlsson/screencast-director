import Foundation

/// A short piece of the edit exported on its own, like a vertical social clip: a source-time range
/// of the main edit, in a format. It renders from the main edit, so fixes there show up in it.
public struct Clip: Codable, Equatable {
  public var name: String
  public var start: Double
  public var end: Double
  /// An `ExportPreset` id ("vertical", "square", ...); nil keeps the video's own format.
  public var format: String?
  /// A hook title shown big at the top for the clip's first seconds.
  public var title: String?
  /// A logo image (relative to the project, or absolute) shown small at the top center throughout.
  public var logo: String?
  /// How hard to cut the clip's pauses (social runs tighter than the main edit); nil keeps the edit's.
  public var pace: PauseLevel?

  public init(name: String, start: Double, end: Double, format: String? = nil, title: String? = nil, logo: String? = nil, pace: PauseLevel? = nil) {
    self.name = name
    self.start = start
    self.end = end
    self.format = format
    self.title = title
    self.logo = logo
    self.pace = pace
  }

  /// How long the hook title stays up.
  public static let titleSeconds = 3.0

  public var preset: ExportPreset? { format.flatMap { id in ExportPreset.all.first { $0.id == id } } }
}

extension Plan {
  /// A new social clip over `range`: vertical, named "Clip N" with the first free number.
  public func newClip(over range: Range<Double>) -> Clip {
    let names = Set(clipList.map(\.name))
    let n = (1...).first { !names.contains("Clip \($0)") }!
    return Clip(name: "Clip \(n)", start: range.lowerBound, end: range.upperBound, format: "vertical")
  }

  /// The edit cut down to a clip's range and reshaped for its format. Only the animations that
  /// start inside it stay (so only those render), and the intro and outro cards are left out. With a
  /// `pace`, the clip's pauses are re-cut: from measured `silences` when there are some (the better
  /// judge), else from gaps between `words` (the transcript).
  public func trimmed(to clip: Clip, words: [Word] = [], silences: [(Double, Double)]? = nil) -> Plan {
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
    // Only animations that start inside the clip: opening on the tail of an explainer reads as a glitch.
    p.animationList = animationList.filter { $0.start >= clip.start - 0.1 && $0.start < clip.end }
    if let pace = clip.pace, !words.isEmpty, !p.segments.isEmpty {
      // Animations keep their timing: a stand-in word over each, and no measured silence inside one,
      // leaves no pause to cut there.
      let guards = p.animationList.map { Word(text: "", start: $0.start, end: $0.end) }
      let quiet = silences.map { all in all.filter { s in !p.animationList.contains { $0.start < s.1 && $0.end > s.0 } } }
      p.retrimPauses(words: words + guards, level: pace, silences: quiet)
      if !p.segments.isEmpty { p.segments[0].transition = nil }
    }
    p.clips = nil
    p.intro = nil
    p.outro = nil
    if let title = clip.title, let first = p.segments.first {
      p.callouts.append(Callout(start: first.start, end: first.start + Clip.titleSeconds, text: title, style: "title", enter: Motion(preset: "pop")))
    }
    if let logo = clip.logo {
      var look = p.look ?? Look()
      look.watermark = Look.Watermark(image: logo, corner: "top", height: 0.024, opacity: 1)
      p.look = look
    }
    return clip.preset.map { $0.applied(to: p) } ?? p
  }
}

/// A name safe to use in a file name.
func fileSafe(_ name: String) -> String {
  name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
}

/// Where an export goes, named after the project folder and ending in its resolution when given:
/// "Name 2160x3840.mp4", "Name (4K) 3840x2160.mp4" for a preset, "Name - Hook 1080x1920.mp4" for a clip.
public func exportURL(dir: URL, preset: ExportPreset? = nil, clip: Clip? = nil, size: Plan.Output? = nil) -> URL {
  let project = dir.lastPathComponent
  let name = clip.map { "\(project) - \(fileSafe($0.name))" } ?? project + (preset.map { " (\($0.fileLabel))" } ?? "")
  return dir.appendingPathComponent(name + (size.map { " \($0.width)x\($0.height)" } ?? "") + ".mp4")
}

/// Whether a file in a project folder is an export: named after the project, or an older out*.mp4.
public func isExportFile(_ file: String, project: String) -> Bool {
  file.hasSuffix(".mp4") && (file.hasPrefix(project) || file.hasPrefix("out"))
}
