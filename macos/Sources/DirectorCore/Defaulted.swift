import Foundation

/// A value a missing key decodes to (see `Defaulted`).
public protocol DefaultValue {
  associatedtype Value: Codable & Equatable & Sendable
  static var value: Value { get }
}

/// A plan field that may be missing from the JSON: an older plan, or one Claude wrote by hand, then
/// loads with `D.value` instead of failing to load at all. It encodes as the plain value, so the
/// file looks the same, and Codable stays synthesized, so a new field can't be forgotten in a
/// hand-written decoder.
@propertyWrapper
public struct Defaulted<D: DefaultValue>: Codable, Equatable, Sendable {
  public var wrappedValue: D.Value
  public init(wrappedValue: D.Value) { self.wrappedValue = wrappedValue }
  public init(from decoder: Decoder) throws { wrappedValue = try decoder.singleValueContainer().decode(D.Value.self) }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(wrappedValue)
  }
}

extension KeyedDecodingContainer {
  /// A missing (or null) key decodes to the default rather than throwing keyNotFound.
  public func decode<D>(_ type: Defaulted<D>.Type, forKey key: Key) throws -> Defaulted<D> {
    try decodeIfPresent(type, forKey: key) ?? Defaulted(wrappedValue: D.value)
  }
}

/// The defaults plan fields fall back to.
public enum Fallback: Sendable {
  public enum True: DefaultValue, Sendable { public static var value: Bool { true } }
  public enum False: DefaultValue, Sendable { public static var value: Bool { false } }
  public enum NoZooms: DefaultValue, Sendable { public static var value: [Zoom] { [] } }
  public enum NoLayouts: DefaultValue, Sendable { public static var value: [LayoutRange] { [] } }
  public enum NoCallouts: DefaultValue, Sendable { public static var value: [Callout] { [] } }
  public enum ScreenLayout: DefaultValue, Sendable { public static var value: LayoutMode { .screen } }
  /// Plans saved before `version` existed play their segments in recording order.
  public enum FirstVersion: DefaultValue, Sendable { public static var value: Int { 1 } }
  public enum StandardStyle: DefaultValue, Sendable { public static var value: Plan.Style { .standard } }
  public enum NoCaptions: DefaultValue, Sendable { public static var value: Plan.Captions { Plan.Captions(enabled: false, maxWords: 7) } }
  public enum CaptionWords: DefaultValue, Sendable { public static var value: Int { 7 } }
}
