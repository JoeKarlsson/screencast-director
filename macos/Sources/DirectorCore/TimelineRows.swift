import Foundation

/// The timeline's rows, top to bottom. Their look (label, icon, color) lives in the app.
public enum TimelineTrack: CaseIterable, Sendable {
  case ruler, clips, audio, words, zooms, layouts, punchIns, titles, marks, broll, animations, effects, sounds

  public var height: Double {
    switch self {
    case .ruler: return 22
    case .clips: return 34
    case .audio: return 30
    case .words: return 18
    default: return 24
    }
  }

  /// The track an item's bar sits on (nil for markers, which sit in the ruler).
  public static func of(_ s: Selection) -> TimelineTrack? {
    switch s {
    case .segment, .gap: return .clips
    case .zoom: return .zooms
    case .layout: return .layouts
    case .callout: return .titles
    case .annotation: return .marks
    case .insert: return .broll
    case .animation: return .animations
    case .sfx: return .sounds
    case .effectRange: return .effects
    case .punchIn: return .punchIns
    case .marker: return nil
    }
  }
}

/// Which rows the timeline shows and where each sits. The ruler, clips and audio always show, words
/// when there's a transcript, and every other row only while it has something on it (new items are
/// added from the toolbar, so an empty row has nothing to offer).
public struct TimelineRows: Equatable, Sendable {
  /// Space between rows.
  public static let gap = 4.0
  public let visible: [TimelineTrack]

  public init(plan: Plan?, hasWords: Bool) {
    visible = TimelineTrack.allCases.filter { t in
      guard let plan else { return [.ruler, .clips, .audio].contains(t) }
      switch t {
      case .ruler, .clips, .audio: return true
      case .words: return hasWords
      case .zooms: return !plan.zooms.isEmpty
      case .layouts: return !plan.layouts.isEmpty
      case .punchIns: return !plan.punchInList.isEmpty
      case .titles: return !plan.callouts.isEmpty
      case .marks: return !plan.annotationList.isEmpty
      case .broll: return !plan.insertList.isEmpty
      case .animations: return !plan.animationList.isEmpty
      case .effects: return !plan.effectRangeList.isEmpty
      // Free-standing sounds and the ones attached to titles, marks and animation beats.
      case .sounds: return !plan.soundEffects.isEmpty
      }
    }
  }

  /// The top of a row; a hidden row sits below the last one, out of the way.
  public func y(_ track: TimelineTrack) -> Double {
    var y = 0.0
    for t in visible {
      if t == track { return y }
      y += t.height + Self.gap
    }
    return y
  }

  /// The height of every shown row with its gap.
  public var total: Double { visible.reduce(0) { $0 + $1.height + Self.gap } }
}
