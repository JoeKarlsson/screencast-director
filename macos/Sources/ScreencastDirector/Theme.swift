import AppKit
import SwiftUI

/// The editor's shared look: one color per kind of timeline item (the timeline bars, the
/// inspector's icons and headers use the same ones), corner radii, and Liquid Glass with a
/// material fallback for macOS 15.
enum Theme {
  /// The app's accent: the indigo of the icon.
  static let accent = Color(red: 0.42, green: 0.36, blue: 0.92)
  static let clip = Color.blue
  static let audio = Color.green
  static let words = Color.secondary
  static let zoom = Color.purple
  static let layout = Color.teal
  static let title = Color.orange
  static let mark = Color.pink
  static let broll = Color.indigo
  static let animation = Color(red: 0.93, green: 0.62, blue: 0.05)
  static let sfx = Color.mint
  static let effect = Color.cyan
  static let punchIn = Color.yellow
  static let recording = Color.red
  static let ai = Color.orange
  /// Status: all set, needs attention, failed.
  static let ok = Color.green
  static let warning = Color.orange
  static let error = Color.red
  /// A cut part of the recording.
  static let cut = Color.gray
  /// A sped-up clip or word.
  static let fast = Color.orange

  /// Radii that nest: a button inside a control inside a card inside a panel.
  static let corner: CGFloat = 6
  static let controlCorner: CGFloat = 8
  static let cardCorner: CGFloat = 12
  static let panelCorner: CGFloat = 16

  /// Spacing steps.
  enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
  }

  /// The type scale: micro and label are the timeline's bar and ruler text, the rest is everything
  /// else. `mono` gives timecodes, durations and sizes even-width digits.
  enum TextSize: CGFloat {
    case micro = 9, label = 10, caption = 11, small = 12, body = 13, title = 16
  }

  static func font(_ size: TextSize, _ weight: Font.Weight = .regular, design: Font.Design = .default, mono: Bool = false) -> Font {
    let f = Font.system(size: size.rawValue, weight: weight, design: design)
    return mono ? f.monospacedDigit() : f
  }

  /// A symbol or display numeral, sized to its button or panel rather than the type scale.
  static func glyph(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
    .system(size: size, weight: weight, design: design)
  }

  /// UI motion, one place to retime it: things arriving decelerate, things leaving accelerate
  /// away and finish sooner, things that stay but move (panels, folds, scrolls) ease both ends.
  /// No springs: nothing in the editor overshoots. With Reduce Motion on, every change is instant.
  enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let enterCurve = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let exitCurve = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.6, 0.6)
    static let enterDuration = 0.22
    static let exitDuration = 0.175

    static var enter: Animation? { allowed(.timingCurve(0.22, 1, 0.36, 1, duration: enterDuration)) }
    static var exit: Animation? { allowed(.timingCurve(0.3, 0, 0.6, 0.6, duration: exitDuration)) }
    static var move: Animation? { allowed(.easeInOut(duration: enterDuration)) }

    /// `animation`, or none under Reduce Motion.
    static func allowed(_ animation: Animation) -> Animation? { reduce ? nil : animation }
  }
}

extension View {
  /// The one shadow: for something that floats over the rest (a banner).
  func floatingShadow() -> some View {
    shadow(color: .black.opacity(0.22), radius: 14, y: 8)
  }

  /// Liquid Glass on macOS 26 and later, a thin material before that.
  @ViewBuilder
  func glassCard(cornerRadius: CGFloat = Theme.cardCorner, tint: Color? = nil) -> some View {
    if #available(macOS 26, *) {
      glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
  }

  /// A choice tile (layouts, motion styles, presets): accent-filled and outlined when chosen.
  func selectableTile(on: Bool) -> some View {
    foregroundStyle(on ? Theme.accent : Color.primary)
      .background(RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous).fill(on ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.04)))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
          .strokeBorder(on ? Theme.accent : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
  }

  /// A grouped box for a block of related controls (inspector sections, setup rows).
  func card(padding: CGFloat = 12) -> some View {
    self.padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous).fill(Color.primary.opacity(0.045)))
  }
}
