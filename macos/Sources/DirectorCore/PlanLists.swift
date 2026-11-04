import Foundation

// The plan's optional lists and settings as plain values: an empty list reads as [] and writes back
// as nil, so plan.json leaves out what a video doesn't use.
extension Plan {
  /// `annotations` as a plain list (empty when there are none).
  public var annotationList: [Annotation] {
    get { annotations ?? [] }
    set { annotations = newValue.isEmpty ? nil : newValue }
  }

  /// `inserts` as a plain list (empty when there are none).
  public var insertList: [Insert] {
    get { inserts ?? [] }
    set { inserts = newValue.isEmpty ? nil : newValue }
  }

  /// `markers` as a plain list (empty when there are none), kept in time order.
  public var markerList: [Marker] {
    get { markers ?? [] }
    set { markers = newValue.isEmpty ? nil : newValue.sorted { $0.t < $1.t } }
  }

  /// `audio`, starting from the defaults when the plan has none.
  public var audioSettings: AudioSettings {
    get { audio ?? AudioSettings() }
    set { audio = newValue }
  }

  /// `cursor`, starting from the defaults when the plan has none.
  public var cursorSettings: CursorSettings {
    get { cursor ?? CursorSettings() }
    set { cursor = newValue }
  }

  /// The camera's `punchIns` as a plain list (empty when there are none, or no camera to punch).
  public var punchInList: [PunchIn] {
    get { camera?.punchIns ?? [] }
    set { camera?.punchIns = newValue.isEmpty ? nil : newValue }
  }

  /// The always-on `effects` as a plain list (empty when there are none).
  public var effectList: [EffectUse] {
    get { effects ?? [] }
    set { effects = newValue.isEmpty ? nil : newValue }
  }

  /// `effectRanges` as a plain list (empty when there are none).
  public var effectRangeList: [EffectRange] {
    get { effectRanges ?? [] }
    set { effectRanges = newValue.isEmpty ? nil : newValue }
  }

  /// `sfx` as a plain list (empty when there are none).
  public var sfxList: [SoundEffect] {
    get { sfx ?? [] }
    set { sfx = newValue.isEmpty ? nil : newValue }
  }

  /// `animations` as a plain list (empty when there are none).
  public var animationList: [Animation] {
    get { animations ?? [] }
    set { animations = newValue.isEmpty ? nil : newValue }
  }

  /// `clips` as a plain list (empty when there are none).
  public var clipList: [Clip] {
    get { clips ?? [] }
    set { clips = newValue.isEmpty ? nil : newValue }
  }
}
