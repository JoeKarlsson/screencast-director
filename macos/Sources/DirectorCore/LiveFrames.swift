import CoreImage
import Foundation

/// The app's live animation preview: a frame `director animate-preview` drew for one animation at
/// the playhead, shown in place of its clip so an edit shows at once instead of after a render.
/// Only the app's preview scene has one; exports never do. The compositor reads it from its own thread.
public final class LiveFrames: @unchecked Sendable {
  private let lock = NSLock()
  private var shown: (animation: Int, image: CIImage)?
  public init() {}

  /// The live frame for animation `index`, if it's the one being previewed.
  public func image(_ index: Int) -> CIImage? { lock.withLock { shown?.animation == index ? shown?.image : nil } }
  /// Shows `image` for animation `index`, replacing any other animation's frame; nil shows none.
  public func show(_ image: CIImage?, for index: Int) { lock.withLock { shown = image.map { (index, $0) } } }
  public var isEmpty: Bool { lock.withLock { shown == nil } }
}
