import CoreImage
import Foundation

/// A 3D color lookup table from a `.cube` file (the Adobe/Resolve text format), ready for
/// `CIColorCubeWithColorSpace`.
public struct CubeLUT {
  public let size: Int
  /// RGBA floats, red changing fastest, as Core Image wants them.
  public let data: Data

  public struct Failure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
  }

  public static func parse(_ text: String, name: String) throws -> CubeLUT {
    var size = 0
    var rgba: [Float] = []
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
      let parts = line.split(whereSeparator: \.isWhitespace)
      switch parts[0] {
      case "LUT_3D_SIZE":
        guard parts.count == 2, let n = Int(parts[1]), (2...128).contains(n) else {
          throw Failure(message: "\(name): LUT_3D_SIZE must be 2 to 128")
        }
        size = n
        rgba.reserveCapacity(n * n * n * 4)
      case "LUT_1D_SIZE":
        throw Failure(message: "\(name) is a 1D LUT; only 3D LUTs are supported")
      case "DOMAIN_MIN", "DOMAIN_MAX":
        let want: Float = parts[0] == "DOMAIN_MIN" ? 0 : 1
        guard parts.dropFirst().allSatisfy({ Float($0) == want }) else {
          throw Failure(message: "\(name): only a 0...1 domain is supported")
        }
      default:
        guard parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
          throw Failure(message: "\(name): unreadable line \"\(line)\"")
        }
        rgba += [r, g, b, 1]
      }
    }
    guard size > 0 else { throw Failure(message: "\(name) has no LUT_3D_SIZE line") }
    guard rgba.count == size * size * size * 4 else {
      throw Failure(message: "\(name) has \(rgba.count / 4) colors; LUT_3D_SIZE \(size) needs \(size * size * size)")
    }
    return CubeLUT(size: size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
  }

  private static let lock = NSLock()
  private static var cache: [String: (modified: Date, lut: CubeLUT)] = [:]

  /// Loads a `.cube` file, reusing the parsed table until the file changes.
  public static func load(_ url: URL) throws -> CubeLUT {
    let modified = (try url.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate ?? .distantPast
    lock.lock()
    defer { lock.unlock() }
    if let hit = cache[url.path], hit.modified == modified { return hit.lut }
    let lut = try parse(String(contentsOf: url, encoding: .utf8), name: url.lastPathComponent)
    cache[url.path] = (modified, lut)
    return lut
  }

  func apply(to img: CIImage) -> CIImage {
    img.applyingFilter(
      "CIColorCubeWithColorSpace",
      parameters: ["inputCubeDimension": size, "inputCubeData": data, "inputColorSpace": Scene.srgb])
  }
}
