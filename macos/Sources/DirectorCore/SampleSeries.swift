import Foundation

/// motion.json and loudness.json: `[[t, value], ...]` samples, `t` in source seconds.
public enum SampleSeries {
  /// The samples in `url`, or nil when there's no such file. An entry that isn't a [t, value] pair
  /// is skipped; a file that isn't JSON or isn't a list of lists throws rather than reading as no samples.
  public static func read(_ url: URL) throws -> [(Double, Double)]? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[Double]] else {
      throw DirectorError("\(url.lastPathComponent) isn't a list of [time, value] pairs")
    }
    return entries.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
  }

  /// Writes the samples on one line, times to the millisecond and values to `decimals` places.
  public static func write(_ samples: [(Double, Double)], to url: URL, decimals: Int) throws {
    let body = samples.map { String(format: "[%.3f, %.\(decimals)f]", $0.0, $0.1) }.joined(separator: ", ")
    try "[\(body)]\n".write(to: url, atomically: true, encoding: .utf8)
  }
}
