import AVFoundation
import Foundation

/// What made an export, written into the MP4 itself: the app version, when, and the exact plan it
/// rendered (after any preset or clip), so `director provenance <video>` answers "which edit is this
/// upload" even after plan.json has moved on.
public struct Provenance: Codable, Equatable, Sendable {
  public var app: String
  public var exported: Date
  public var plan: Plan

  /// "0.2.0 (412)" from the app's Info.plist; the bundled director reads its app's (two folders up).
  public static var appVersion: String {
    let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
    let info =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] != nil
      ? Bundle.main.infoDictionary
      : exe.flatMap {
        NSDictionary(contentsOf: $0.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")) as? [String: Any]
      }
    guard let version = info?["CFBundleShortVersionString"] as? String else { return "development build" }
    return (info?["CFBundleVersion"] as? String).map { "\(version) (\($0))" } ?? version
  }

  public func metadataItem() throws -> AVMetadataItem {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let item = AVMutableMetadataItem()
    // The MP4 description: an export drops QuickTime keys, and macOS 26 drops a private iTunes key too.
    item.identifier = .commonIdentifierDescription
    item.value = String(decoding: try enc.encode(self), as: UTF8.self) as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
  }

  /// nil for a video exported before this or by something else.
  public static func read(_ url: URL) async throws -> Provenance? {
    let items = try await AVURLAsset(url: url).load(.commonMetadata)
    guard let item = items.first(where: { $0.commonKey == .commonKeyDescription }), let text = try await item.load(.stringValue),
      text.hasPrefix("{\"app\":")
    else { return nil }
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    return try dec.decode(Provenance.self, from: Data(text.utf8))
  }
}
