import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// Captions (SRT), YouTube chapters and the timed transcript, from the same caption pages as the video.

extension Publish {
  // MARK: Captions and chapters

  static func stamp(_ seconds: Double, srt: Bool) -> String {
    let ms = Int((seconds * 1000).rounded())
    let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
    if srt { return String(format: "%02d:%02d:%02d,%03d", h, m, s, f) }
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  /// SubRip captions in output time, one cue per caption page (same grouping as the burned-in captions).
  public static func srt(_ scene: Scene) -> String {
    let fps = Double(scene.fps)
    let pages = Scene.captionPages(scene.words, scene.mapped, fps: scene.fps, maxWords: max(scene.plan.captions.maxWords, 8))
    return pages.enumerated().map { i, p in
      let start = p.startF / fps
      let next = i + 1 < pages.count ? pages[i + 1].startF / fps : .infinity
      let end = min(max(start + 0.3, (p.endF + 2) / fps), next)
      return "\(i + 1)\n\(stamp(start, srt: true)) --> \(stamp(end, srt: true))\n\(p.words.map(\.text).joined(separator: " "))\n"
    }.joined(separator: "\n")
  }

  /// YouTube chapters from the plan's chapter titles (or its plain titles, when it has no chapter
  /// titles; never lower thirds or slates): "0:00 Intro" plus one line per title. YouTube needs at
  /// least three, starting at 0:00, each at least 10 s long; returns nil when that can't be met.
  public static func chapters(_ scene: Scene) -> String? {
    let marks = chapterMarks(scene)
    guard marks.count >= 3 else { return nil }
    return marks.map { "\(stamp($0.0, srt: false)) \($0.1)" }.joined(separator: "\n")
  }

  /// The chapter points `chapters` writes (output seconds and name), before its at-least-three rule.
  static func chapterMarks(_ scene: Scene) -> [(Double, String)] {
    let fps = Double(scene.fps)
    var marks: [(Double, String)] = [(0, "Intro")]
    let chapterTitles = scene.plan.callouts.filter { $0.style == "chapter" }
    let sections = chapterTitles.isEmpty ? scene.plan.callouts.filter { ($0.style ?? "title") == "title" } : chapterTitles
    let placed = sections.compactMap { c in srcToOut(scene.mapped, c.start, fps: scene.fps).map { ($0, c) } }
    for (f, c) in placed.sorted(by: { $0.0 < $1.0 }) {
      let t = f / fps
      if t - (marks.last?.0 ?? 0) >= 10 { marks.append((t, c.text)) } else if t < 10 { marks[0].1 = c.text }
    }
    let total = Double(scene.frameCount) / fps
    if let last = marks.last, total - last.0 < 10 { marks.removeLast() }
    return marks
  }

  /// The narration with output timestamps, for an AI to write a description and chapters from.
  public static func timedTranscript(_ scene: Scene) -> String {
    let fps = Double(scene.fps)
    let pages = Scene.captionPages(scene.words, scene.mapped, fps: scene.fps, maxWords: 14)
    return pages.map { "[\(stamp($0.startF / fps, srt: false))] \($0.words.map(\.text).joined(separator: " "))" }.joined(separator: "\n")
  }
}
