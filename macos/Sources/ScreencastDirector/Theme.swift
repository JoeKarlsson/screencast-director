import SwiftUI

/// The editor's shared look: one color per kind of timeline item (the timeline bars, the
/// inspector's icons and headers use the same ones), corner radii, and Liquid Glass with a
/// material fallback for macOS 15.
enum Theme {
  static let clip = Color.blue
  static let audio = Color.green
  static let words = Color.secondary
  static let zoom = Color.purple
  static let layout = Color.teal
  static let title = Color.orange
  static let recording = Color.red
  static let ai = Color.orange

  static let corner: CGFloat = 6
  static let cardCorner: CGFloat = 10
  static let panelCorner: CGFloat = 18
}

extension View {
  /// Liquid Glass on macOS 26 and later, a thin material before that.
  @ViewBuilder
  func glassCard(cornerRadius: CGFloat = Theme.cardCorner, tint: Color? = nil) -> some View {
    if #available(macOS 26, *) {
      glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
  }

  /// A grouped box for a block of related controls (inspector sections, setup rows).
  func card(padding: CGFloat = 12) -> some View {
    self.padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(Color.primary.opacity(0.045)))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
  }
}
