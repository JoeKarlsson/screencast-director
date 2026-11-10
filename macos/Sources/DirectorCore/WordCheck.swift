import Foundation

// `director check-words`: transcribe a finished export and compare what's heard with the words the
// plan keeps. A word missing at a cut was clipped; extra words were left in (a false start riding
// along with a kept clip). Whisper mishears a word here and there, so only what a one-word slip
// can't explain is reported.

public enum WordCheck {
  public struct Finding: Equatable, Sendable {
    /// "missing" (kept by the plan, not heard) or "extra" (heard, not kept).
    public var kind: String
    public var words: [String]
    /// Output seconds.
    public var at: Double
    /// For missing words: a cut edge (source seconds) within `nearCut` of them, which clipped them.
    public var cut: Double?
  }

  /// A missing word this close to a cut edge (source seconds) was cut into.
  public static let nearCut = 0.3

  /// Lowercase letters and digits only, so "Kindle." and "kindle" match.
  static func token(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }

  /// The words the plan keeps, in play order, with their output seconds. Sped-up clips play muted.
  public static func expected(_ plan: Plan, words: [Word]) -> [(text: String, out: Double, src: Double)] {
    let fps = Double(plan.output.fps)
    return mapPlan(plan).filter { $0.speed == 1 }.flatMap { s in
      words.filter { $0.start >= s.start - 0.02 && $0.start < s.end }.map { w in
        (w.text, Double(s.outStart) / fps + (w.start - s.start), w.start)
      }
    }.filter { !token($0.text).isEmpty }
  }

  /// Compares the kept words with what was heard (`heard` in output seconds). `cuts` are the clip
  /// edges in source seconds and `joins` the output seconds where one clip cuts to another: clipped
  /// words and false starts happen there. Reported: missing or extra words at a cut, and runs of
  /// three or more anywhere. A run heard as about as many other words close by ("my space" heard
  /// as "MySpace") is a mishearing, not reported.
  public static func compare(
    expected: [(text: String, out: Double, src: Double)], heard: [Word], cuts: [Double], joins: [Double]
  ) -> [Finding] {
    let a = expected.map { token($0.text) }
    let heardWords = heard.filter { !token($0.text).isEmpty }
    let diff = heardWords.map { token($0.text) }.difference(from: a)
    func runs(_ offsets: [Int]) -> [[Int]] {
      offsets.sorted().reduce(into: [[Int]]()) { out, i in
        if let last = out.last?.last, last == i - 1 { out[out.count - 1].append(i) } else { out.append([i]) }
      }
    }
    let missingRuns = runs(diff.removals.compactMap { if case let .remove(offset, _, _) = $0 { offset } else { nil } })
    let extraRuns = runs(diff.insertions.compactMap { if case let .insert(offset, _, _) = $0 { offset } else { nil } })
    func misheard(_ count: Int, at t: Double, among others: [[Int]], time: (Int) -> Double) -> Bool {
      others.contains { abs($0.count - count) <= 1 && abs(time($0[0]) - t) < 1.5 }
    }
    var out: [Finding] = []
    for run in missingRuns {
      let first = expected[run[0]], last = expected[run[run.count - 1]]
      guard !misheard(run.count, at: first.out, among: extraRuns, time: { heardWords[$0].start }) else { continue }
      let cut = cuts.first { $0 >= first.src - nearCut && $0 <= last.src + nearCut + 0.5 }
      guard run.count >= 3 || cut != nil else { continue }
      out.append(Finding(kind: "missing", words: run.map { expected[$0].text }, at: first.out, cut: cut))
    }
    for run in extraRuns {
      let at = heardWords[run[0]].start, end = heardWords[run[run.count - 1]].end
      guard !misheard(run.count, at: at, among: missingRuns, time: { expected[$0].out }) else { continue }
      let atJoin = joins.contains { $0 >= at - nearCut - 0.3 && $0 <= end + nearCut }
      guard run.count >= 3 || atJoin else { continue }
      out.append(Finding(kind: "extra", words: run.map { heardWords[$0].text }, at: at, cut: nil))
    }
    return out.sorted { $0.at < $1.at }
  }

  /// "missing at out 1:23.4: "the config file" (the cut at src 1:28.2 clips it)"
  public static func describe(_ f: Finding) -> String {
    let words = "\"" + f.words.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") + "\""
    if f.kind == "extra" {
      return "extra at out \(fmtTime(f.at)): \(words) is heard in the export but isn't a kept word (a false start or retake left in?)"
    }
    return "missing at out \(fmtTime(f.at)): \(words) isn't heard in the export"
      + (f.cut.map { " (the cut at src \(fmtTime($0)) clips it)" } ?? "")
  }

  /// Transcribes `export` and compares it with the plan's kept words.
  public static func run(_ project: Project, _ plan: Plan, export: URL) async throws -> [Finding] {
    let work = project.dir.appendingPathComponent(".render")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let wav = work.appendingPathComponent("check-words.wav"), json = work.appendingPathComponent("check-words.json")
    guard try await Analyzer.extractAudio(export, to: wav) else { throw DirectorError("\(export.lastPathComponent) has no audio") }
    guard let cli = Tools.whisperCLI, let model = Tools.model else { throw AnalyzerError.whisperMissing }
    try Analyzer.transcribe(wav: wav, whisperCLI: cli, model: model, to: json)
    let cuts = plan.segments.flatMap { [$0.start, $0.end] }
    let mapped = mapPlan(plan), fps = Double(plan.output.fps)
    let joins = mapped.indices.dropFirst().filter { abs(mapped[$0 - 1].end - mapped[$0].start) > 0.001 }.map { Double(mapped[$0].outStart) / fps }
    return compare(expected: expected(plan, words: project.words), heard: Project.loadWords(json), cuts: cuts, joins: joins)
  }
}
