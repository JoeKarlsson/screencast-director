import Foundation

/// A failure with a message for the person using the app or CLI. Throw this rather than a bare
/// NSError, which shows up as "Publish error 2".
public struct DirectorError: LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
