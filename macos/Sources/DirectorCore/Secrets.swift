import AVFoundation
import Foundation
import Vision

/// Secrets visible on the recorded screen: API keys and tokens, passwords in connection strings and
/// config, private keys and email addresses, found by reading the whole screen with Vision about once
/// a second, in the stretches the edit keeps. Kept in secrets.json (masked, so the file never holds a
/// secret). `director secrets --blur` covers each with a blur annotation, and describe WARNs about any
/// the edit shows unblurred, and about kept stretches the scan never read (a cut put back since).
public enum Secrets: Sendable {
  public struct Finding: Codable, Equatable, Sendable {
    /// What it looks like: "api key", "token", "secret" (a value after password=, api_key: ...), "password" (in a URL), "private key", "email".
    public var kind: String
    /// The text with its middle hidden ("sk-a…9fQ").
    public var masked: String
    /// Source seconds it's on screen, padded half a sample each side (it may appear between samples).
    public var start: Double
    public var end: Double
    /// Box in 0...1 fractions of the screen, top-left origin (like annotations).
    public var x, y, w, h: Double
    /// Shown on purpose (`director secrets <dir> --allow <n>`): no warning, no blur.
    public var allowed: Bool?
  }

  /// A stretch of the recording, in source seconds.
  public struct Span: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
  }

  /// secrets.json: what a scan read and found.
  public struct Scan: Codable, Equatable, Sendable {
    /// The stretches it read: what the edit kept then, a second wider each side.
    public var scanned: [Span]
    /// Kinds shown on purpose wherever they are (`--allow email`).
    public var allowedKinds: [String]?
    public var findings: [Finding]

    public init(scanned: [Span], allowedKinds: [String]? = nil, findings: [Finding]) {
      self.scanned = scanned
      self.allowedKinds = allowedKinds
      self.findings = findings
    }
  }

  public static let kinds = ["api key", "token", "secret", "password", "private key", "email"]

  public static func url(_ dir: URL) -> URL { dir.appendingPathComponent("secrets.json") }

  /// nil when the screen was never scanned; throws when secrets.json can't be read, so its warnings never vanish quietly.
  public static func load(_ dir: URL) throws -> Scan? {
    guard FileManager.default.fileExists(atPath: url(dir).path) else { return nil }
    return try JSONDecoder().decode(Scan.self, from: Data(contentsOf: url(dir)))
  }

  public static func save(_ scan: Scan, to dir: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    try enc.encode(scan).write(to: url(dir), options: .atomic)
  }

  /// The stretches the edit keeps, merged, each widened by `pad` (clamped to the recording).
  public static func kept(_ plan: Plan, pad: Double = 0) -> [Span] {
    var out: [Span] = []
    for s in plan.segments.sorted(by: { $0.start < $1.start }) {
      let span = Span(start: max(0, s.start - pad), end: min(plan.source.duration, s.end + pad))
      if let last = out.last, span.start <= last.end {
        out[out.count - 1].end = max(last.end, span.end)
      } else {
        out.append(span)
      }
    }
    return out
  }

  /// Kept stretches longer than a fifth of a second that the scan didn't read.
  public static func unscanned(_ scan: Scan, plan: Plan) -> [Span] {
    var out: [Span] = []
    for k in kept(plan) {
      var t = k.start
      for s in scan.scanned.sorted(by: { $0.start < $1.start }) where s.end > t && s.start < k.end {
        if s.start > t { out.append(Span(start: t, end: s.start)) }
        t = max(t, s.end)
      }
      if t < k.end { out.append(Span(start: t, end: k.end)) }
    }
    return out.filter { $0.end - $0.start > 0.2 }
  }

  // MARK: Matching

  /// Each pattern's capture group 1, when it has one, is the secret part (a password, not its label).
  static let patterns: [(kind: String, regex: NSRegularExpression)] = [
    ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ("api key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
    // After a known prefix, any characters: OCR misreads a few inside a key ("E†56").
    ("api key", #"\bgh[pousr]_[^\s"';,]{30,}"#),
    ("api key", #"\bgithub_pat_[^\s"';,]{40,}"#),
    ("api key", #"\bsk-[^\s"';,]{20,}"#),
    ("api key", #"\b[rs]k_(?:live|test)_[^\s"';,]{16,}"#),
    ("api key", #"\bAIza[^\s"';,]{35}"#),
    ("token", #"\bxox[abprs]-[^\s"';,]{10,}"#),
    ("token", #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}"#),
    // user:password@host in a URL.
    ("password", #"\b[a-z][a-z0-9+.\-]*://[^\s:/@]+:([^\s@/]{3,})@"#),
    // password=..., "apiKey": "...", Pwd: ... in config files, connection strings and env files
    // (OPENAI_API_KEY=: no \b, since _ is a word character).
    (
      "secret",
      #"(?i)(?<![a-z])(?:password|passwd|pwd|secret|client[_ ]?secret|api[_\-]?key|access[_\-]?key|auth[_\-]?token|token)["']?\s*[=:]\s*["']?([^\s;"',]{4,})"#
    ),
    ("email", #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b"#),
    // Anything else that looks like a key: a long run of mixed case and digits.
    ("token", #"\b[A-Za-z0-9_\-]{32,}\b"#),
  ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }  // swiftlint:disable:this force_try

  static let url = try! NSRegularExpression(pattern: #"(?:https?://|www\.)\S+"#)  // swiftlint:disable:this force_try

  /// The secrets in one line of text, as ranges of it.
  public static func matches(_ text: String) -> [(kind: String, range: Range<String.Index>)] {
    var out: [(kind: String, range: Range<String.Index>)] = []
    let all = NSRange(text.startIndex..., in: text)
    // Long IDs in URLs (a status bar's link) aren't keys; a labeled one (token=...) still is.
    let urls = url.matches(in: text, range: all).compactMap { Range($0.range, in: text) }
    for (kind, regex) in patterns {
      for m in regex.matches(in: text, range: all) {
        let r = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
        guard let range = Range(r, in: text) else { continue }
        let s = text[range]
        // Masked fields (•••• or ****) and placeholders hide nothing.
        if s.allSatisfy({ "•*·●.x-_".contains($0) }) || ["<password>", "{password}", "password"].contains(s.lowercased()) { continue }
        if regex == patterns.last!.regex, !looksRandom(String(s)) || urls.contains(where: { $0.overlaps(range) }) { continue }
        // The first pattern to claim a stretch of text names it.
        if out.contains(where: { $0.range.overlaps(range) }) { continue }
        out.append((kind, range))
      }
    }
    return out
  }

  /// Mixed case and digits, not a UUID or a hex hash (commit SHAs and IDs fill screens and aren't secret),
  /// and no run of 8 digits: a random key almost never has one, a numeric ID in a URL always does.
  /// Three of each case, since OCR glues words onto a hash ("…6f7aPassword"), while a 32-character key has a dozen.
  static func looksRandom(_ s: String) -> Bool {
    let hex = s.allSatisfy { $0.isHexDigit || $0 == "-" }
    let longNumber = s.range(of: #"\d{8}"#, options: .regularExpression) != nil
    return !hex && !longNumber && s.filter(\.isUppercase).count >= 3 && s.filter(\.isLowercase).count >= 3 && s.filter(\.isNumber).count >= 3
  }

  /// A few leading characters and the length, enough to recognize a finding: four only for long keys,
  /// whose start is a public prefix (sk-, AKIA), and never the end. describe's output, which carries
  /// it, can go to an AI provider.
  public static func mask(_ s: String) -> String {
    let keep = s.count >= 24 ? 4 : s.count >= 8 ? 2 : 0
    return String(s.prefix(keep)) + "… (\(s.count))"
  }

  // MARK: Scanning

  struct Hit {
    var kind: String
    var masked: String
    var x, y, w, h: Double
  }

  /// Reads the screen in `spans` (the whole recording when nil) every `step` seconds, but only where it
  /// changed since the last read (motion.json; a pasted key is enough), and returns what it found,
  /// merged across samples, and how many samples couldn't be decoded (a truncated recording), so a
  /// stretch never read isn't called clean.
  public static func scan(_ project: Project, spans: [Span]? = nil, step: Double = 1, progress: ((Double) -> Void)? = nil) async throws -> (
    findings: [Finding], unread: Int
  ) {
    let asset = AVURLAsset(url: project.dir.appendingPathComponent(project.source.video))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = CMTime(seconds: step / 4, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTime(seconds: step / 4, preferredTimescale: 600)
    let spans = spans ?? [Span(start: 0, end: project.source.duration)]
    let total = max(spans.reduce(0) { $0 + $1.end - $1.start }, 0.001)
    var times: [Double] = []
    for s in spans { times += stride(from: s.start, to: s.end, by: step) }
    var samples: [(t: Double, hits: [Hit])] = []
    var lastRead = -Double.infinity
    var unread = 0
    for (i, t) in times.enumerated() {
      progress?(Double(i) * step / total)
      if changed(project.motion, from: lastRead, to: t) {
        guard let (frame, actual) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else {
          unread += 1
          continue
        }
        samples.append((actual.seconds, read(frame)))
        lastRead = t
      } else if let previous = samples.last {
        samples.append((t, previous.hits))
      }
    }
    progress?(1)
    return (merge(samples, step: step), unread)
  }

  /// Whether the screen changed between two times. Mean pixel change of 0.02 catches a few typed
  /// characters on a 4K screen; with no motion.json every sample counts as changed.
  static func changed(_ motion: [(Double, Double)], from a: Double, to b: Double) -> Bool {
    guard a.isFinite, !motion.isEmpty else { return true }
    return motion.contains { $0.0 > a && $0.0 <= b && $0.1 > 0.02 }
  }

  /// Every secret in a frame, boxed tightly around the secret itself.
  static func read(_ image: CGImage) -> [Hit] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: image).perform([request])
    var out: [Hit] = []
    for obs in request.results ?? [] {
      guard let candidate = obs.topCandidates(1).first else { continue }
      let text = candidate.string
      for (kind, range) in matches(text) {
        // Vision boxes are bottom-left origin; the substring's box, else the whole line's.
        let b = (try? candidate.boundingBox(for: range))?.boundingBox ?? obs.boundingBox
        out.append(Hit(kind: kind, masked: mask(String(text[range])), x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height))
      }
    }
    return out
  }

  /// One finding per secret that stays put across consecutive samples (the same kind in the same
  /// place: OCR reads a character differently now and then); a box a little larger than the text so
  /// the blur covers it whole. It may have appeared any time after the last sample without it and
  /// gone any time before the next, so it runs from one to the other.
  static func merge(_ samples: [(t: Double, hits: [Hit])], step: Double) -> [Finding] {
    var open: [Finding] = []
    var done: [Finding] = []
    for (k, (t, hits)) in samples.enumerated() {
      let before = k > 0 ? samples[k - 1].t : 0
      let after = k + 1 < samples.count ? samples[k + 1].t : t + step
      var next: [Finding] = []
      for hit in hits {
        let box = (x: hit.x - 0.004, y: hit.y - 0.006, w: hit.w + 0.008, h: hit.h + 0.012)
        if let i = open.firstIndex(where: { $0.kind == hit.kind && abs($0.x - box.x) < 0.02 && abs($0.y - box.y) < 0.02 }) {
          var f = open.remove(at: i)
          f.end = after
          // Grow to cover every sample's box (OCR boxes wobble by a few pixels).
          let x2 = max(f.x + f.w, box.x + box.w), y2 = max(f.y + f.h, box.y + box.h)
          f.x = min(f.x, box.x)
          f.y = min(f.y, box.y)
          f.w = x2 - f.x
          f.h = y2 - f.y
          next.append(f)
        } else {
          next.append(Finding(kind: hit.kind, masked: hit.masked, start: before, end: after, x: box.x, y: box.y, w: box.w, h: box.h))
        }
      }
      done += open
      open = next
    }
    return stacked(done + open).map { f in
      var f = f
      f.x = max(0, f.x)
      f.y = max(0, f.y)
      f.w = min(f.w, 1 - f.x)
      f.h = min(f.h, 1 - f.y)
      return f
    }.sorted { ($0.start, $0.y, $0.x) < ($1.start, $1.y, $1.x) }
  }

  /// A column of the same kind of secret on screen over the same time (a table of emails) as one finding.
  static func stacked(_ findings: [Finding]) -> [Finding] {
    var out: [Finding] = []
    var count: [Int] = []
    for f in findings.sorted(by: { ($0.start, $0.y) < ($1.start, $1.y) }) {
      if let i = out.lastIndex(where: {
        $0.kind == f.kind && $0.start == f.start && $0.end == f.end && abs($0.x - f.x) < 0.01 && f.y - ($0.y + $0.h) < 2 * f.h
      }) {
        out[i].w = max(out[i].x + out[i].w, f.x + f.w) - min(out[i].x, f.x)
        out[i].x = min(out[i].x, f.x)
        out[i].h = max(out[i].h, f.y + f.h - out[i].y)
        count[i] += 1
      } else {
        out.append(f)
        count.append(1)
      }
    }
    return zip(out, count).map { f, n in
      var f = f
      if n > 1 { f.masked += " and \(n - 1) more" }
      return f
    }
  }

  // MARK: The plan

  /// Whether a blur annotation hides the finding for all of the time the edit shows it.
  static func covered(_ f: Finding, by blurs: [Annotation], plan: Plan) -> Bool {
    let slack = 0.002
    let over = blurs.filter { $0.x <= f.x + slack && $0.y <= f.y + slack && $0.x + $0.w >= f.x + f.w - slack && $0.y + $0.h >= f.y + f.h - slack }
    var t = f.start
    while t <= f.end {
      let shown = plan.segments.contains { t >= $0.start && t < $0.end }
      if shown && !over.contains(where: { t >= $0.start && t < $0.end }) { return false }
      t += 0.1
    }
    return true
  }

  /// Findings the edit shows without a blur over them (allowed ones, and allowed kinds, aside).
  public static func uncovered(_ findings: [Finding], plan: Plan, allowedKinds: [String]? = nil) -> [(index: Int, finding: Finding)] {
    let blurs = (plan.annotations ?? []).filter { $0.kind == "blur" }
    let allowedKinds = Set(allowedKinds ?? [])
    return findings.enumerated().filter {
      $0.element.allowed != true && !allowedKinds.contains($0.element.kind) && !covered($0.element, by: blurs, plan: plan)
    }.map { ($0.offset, $0.element) }
  }

  /// A blur annotation for each uncovered finding. They cut in and out (no fade), so not a frame shows.
  public static func blurs(for scan: Scan, plan: Plan) -> [Annotation] {
    uncovered(scan.findings, plan: plan, allowedKinds: scan.allowedKinds).map { _, f in
      Annotation(
        start: f.start, end: f.end, kind: "blur", x: f.x, y: f.y, w: f.w, h: f.h, enter: Motion(preset: "none"), exit: Motion(preset: "none"),
        note: "secret: \(f.kind) \(f.masked)")
    }
  }

  /// A fresh scan keeps the allowed marks of the findings it finds again (same kind, same place, overlapping time).
  public static func keepingAllowed(_ fresh: [Finding], from old: [Finding]) -> [Finding] {
    let allowed = old.filter { $0.allowed == true }
    return fresh.map { f in
      var f = f
      if allowed.contains(where: { $0.kind == f.kind && abs($0.x - f.x) < 0.02 && abs($0.y - f.y) < 0.02 && $0.start < f.end && f.start < $0.end }) {
        f.allowed = true
      }
      return f
    }
  }
}
