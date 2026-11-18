import Foundation

/// Things in an animation template's script that break frame-exact rendering. The renderer seeks the
/// page to each frame's time and averages several nearby times for motion blur, so a template must
/// draw from `t` alone: anything on the page's own clock, random each call, or styled from a font
/// only some Macs have renders differently from frame to frame or from one render to the next.
/// After HyperFrames' lint rules (packages/lint, Apache 2.0); the checks here are this engine's own.
public enum TemplateLint {
  static let rules: [(pattern: String, problem: String)] = [
    (#"\bMath\.random\s*\("#,
      "Math.random() changes every time a frame is drawn, so the frame flickers and each render differs; derive it from a seeded hash of the piece's index"),
    (#"\b(Date\.now|performance\.now)\s*\(|\bnew\s+Date\s*\("#, "reads the wall clock, which has nothing to do with the frame being drawn; use t"),
    (#"\b(setTimeout|setInterval|requestAnimationFrame)\s*\("#,
      "runs on the page's clock, not the frame being drawn, so nothing it does lands on a frame reliably; compute the state from t"),
    (#"\btransition(-[a-z]+)?\s*:\s*['"`]?[a-z-]*\s*[\d.]+m?s|\.style\.transition\s*="#,
      "a CSS transition starts when a style changes and the seek then pins it to the frame's time, so it jumps instead of moving; compute the in-between value from t"),
    (#"(font-family\s*:|fontFamily\s*=|\bfont\s*:[^;"'`]*)\s*['"`]+[^'"`]+['"`]"#,
      "names a font directly, which only renders where that font is installed and ignores the video's look; use var(--title) or var(--body)"),
  ]

  /// One line per hazard in `source` (a template's .js): "line N: `code` problem". Comments don't count.
  public static func problems(_ source: String) -> [String] {
    var out: [String] = []
    var inBlock = false
    for (n, raw) in source.components(separatedBy: "\n").enumerated() {
      let code = stripComments(raw, inBlock: &inBlock)
      for rule in rules {
        guard let r = code.range(of: rule.pattern, options: .regularExpression) else { continue }
        // A font list ending in a generic family (Menlo, monospace) always renders something fitting.
        if rule.problem.hasPrefix("names a font"), code[r.lowerBound...].range(of: #"\b(monospace|sans-serif|serif|system-ui|cursive)\b"#, options: .regularExpression) != nil { continue }
        out.append("line \(n + 1): `\(code[r].trimmingCharacters(in: .whitespaces))` \(rule.problem)")
      }
    }
    return out
  }

  /// `line` without its // and /* */ comments; `inBlock` carries an open /* to the next line.
  /// Comment markers inside strings are rare enough in templates to ignore.
  static func stripComments(_ line: String, inBlock: inout Bool) -> String {
    var out = "", rest = Substring(line)
    while !rest.isEmpty {
      if inBlock {
        guard let end = rest.range(of: "*/") else { return out }
        rest = rest[end.upperBound...]
        inBlock = false
      } else if let open = rest.range(of: "/*"), rest.range(of: "//").map({ open.lowerBound < $0.lowerBound }) ?? true {
        out += rest[..<open.lowerBound]
        rest = rest[open.upperBound...]
        inBlock = true
      } else if let slash = rest.range(of: "//"), !rest[..<slash.lowerBound].hasSuffix(":") {
        return out + rest[..<slash.lowerBound]
      } else {
        return out + rest
      }
    }
    return out
  }
}
