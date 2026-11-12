import CoreGraphics
import Foundation

/// The hand-drawn marks: the Sticker Note's ring and burst, the storyboard's landing burst, a big
/// chapter's rays and coil, a cover's marks. Each is an SVG path (absolute M, L, Q and C) in its own
/// viewBox; a path with several moves is several strokes, drawn one after another. The app draws its
/// own set (MarksBuiltIn.swift, from macos/make-marks.py); a theme's marks.json replaces any of them
/// by name and can add more for its own scripts.
public struct MarkSet: Equatable, Sendable {
  public struct Mark: Codable, Equatable, Sendable {
    /// "0 0 width height".
    public var viewBox: String
    public var path: String
  }

  public let marks: [String: Mark]
  private let parsed: [String: Scribble]

  public init(_ marks: [String: Mark]) {
    self.marks = marks
    parsed = marks.compactMapValues { m in MarkSet.size(m.viewBox).map { Scribble(size: $0, path: m.path) } }
  }

  public static func == (a: MarkSet, b: MarkSet) -> Bool { a.marks == b.marks }

  /// The app's own marks.
  public static let builtIn = MarkSet(builtInMarks)

  /// A mark by name: this set's, else the app's. "burstDense" (the name frozen templates use) is the burst.
  public subscript(_ name: String) -> Scribble {
    parsed[name] ?? (name == "burstDense" ? parsed["burst"] : nil) ?? MarkSet.builtIn.parsed[name] ?? MarkSet.builtIn.parsed["burst"]!
  }

  /// This set over `base`: a mark here replaces base's of the same name.
  public func over(_ base: MarkSet) -> MarkSet { MarkSet(base.marks.merging(marks) { _, mine in mine }) }

  /// Reads a theme's marks.json ({name: {viewBox, path}}), throwing with the file and the mark that's wrong.
  public static func load(_ file: URL) throws -> MarkSet {
    let marks: [String: Mark]
    do {
      marks = try JSONDecoder().decode([String: Mark].self, from: Data(contentsOf: file))
    } catch {
      throw DirectorError("\(file.path) isn't a map of mark names to {viewBox, path}: \(error.localizedDescription)")
    }
    for (name, m) in marks {
      guard size(m.viewBox) != nil else { throw DirectorError("mark \"\(name)\" in \(file.path): viewBox must be \"0 0 width height\", not \(m.viewBox.debugDescription)") }
      guard !Scribble.parse(m.path).isEmpty else { throw DirectorError("mark \"\(name)\" in \(file.path) has no strokes in its path") }
    }
    return MarkSet(marks)
  }

  /// What the animation page gets as `config.marks` (SCRIBBLES there): every mark, plus "burstDense"
  /// for templates that ask for the burst by that name.
  public var json: [String: [String: String]] {
    var all = MarkSet.builtIn.marks.merging(marks) { _, mine in mine }
    if all["burstDense"] == nil { all["burstDense"] = all["burst"] }
    return all.mapValues { ["viewBox": $0.viewBox, "path": $0.path] }
  }

  /// The width and height of a "0 0 w h" viewBox.
  static func size(_ viewBox: String) -> CGSize? {
    let n = viewBox.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
    guard n.count == 4, n[0] == 0, n[1] == 0, n[2] > 0, n[3] > 0 else { return nil }
    return CGSize(width: n[2], height: n[3])
  }
}
