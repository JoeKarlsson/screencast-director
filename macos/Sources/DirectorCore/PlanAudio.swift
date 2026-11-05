import Foundation

// The plan's sound: voice settings, background music, and sound effects (free-standing or attached to items).

public struct AudioSettings: Codable, Equatable, Sendable {
  /// Bring the voice to a standard level (about -20 dBFS RMS while speaking).
  public var normalize: Bool?
  /// Extra gain in dB, -12...12.
  public var gainDB: Double?
  /// Remove room noise and echo from the voice (Apple's voice isolation, cached as voice-clean.m4a).
  public var cleanup: Bool?
  /// Warm the voice: chest EQ, less boxiness, gentle compression and light saturation (`WarmVoice`).
  public var warm: Bool?
  public init(normalize: Bool? = nil, gainDB: Double? = nil, cleanup: Bool? = nil, warm: Bool? = nil) {
    self.normalize = normalize
    self.gainDB = gainDB
    self.cleanup = cleanup
    self.warm = warm
  }
}

/// A background music track, looped to the video's length and ducked under the voice.
public struct Music: Codable, Equatable, Sendable {
  /// A file in the project folder, or an absolute path.
  public var file: String
  /// Music level when nobody's talking, in dB (0 = as recorded). Default -14.
  public var volumeDB: Double?
  /// How far the music drops while the voice is talking, in dB. Default -18.
  public var duckDB: Double?
  public init(file: String, volumeDB: Double? = nil, duckDB: Double? = nil) {
    self.file = file
    self.volumeDB = volumeDB
    self.duckDB = duckDB
  }
}

extension AudioSettings {
  /// `settings` with Normalize voice and Warm voice on, for new recordings when Settings asks.
  public static func polished(_ settings: AudioSettings?) -> AudioSettings {
    var a = settings ?? AudioSettings()
    a.normalize = true
    a.warm = true
    return a
  }
}

/// A sound attached to something on screen (a title, an annotation, an animation's beat). It plays
/// when that thing appears, so it moves when the thing moves and is cut only when the thing is.
public struct Sound: Codable, Equatable, Sendable {
  /// A file in the project folder, or an absolute path.
  public var file: String
  /// Level in dB (0 = as recorded).
  public var gainDB: Double?
  public init(file: String, gainDB: Double? = nil) {
    self.file = file
    self.gainDB = gainDB
  }
}

extension Plan {
  /// Every sound effect that plays: the free-standing `sfx`, plus the sounds attached to titles,
  /// annotations and animation beats at the moment each appears. Sorted by time.
  public var soundEffects: [SoundEffect] {
    var all = sfxList
    for c in callouts {
      if let s = c.sound { all.append(SoundEffect(t: c.start, file: s.file, gainDB: s.gainDB, note: "title \"\(c.text)\"")) }
    }
    for a in annotationList {
      if let s = a.sound { all.append(SoundEffect(t: a.start, file: s.file, gainDB: s.gainDB, note: "\(a.kind) \(a.text ?? a.note ?? "")")) }
    }
    for an in animationList {
      for (cue, s) in an.sounds ?? [:] {
        let t = cue == "start" ? an.start : an.cues?[cue] ?? an.start
        all.append(SoundEffect(t: t, file: s.file, gainDB: s.gainDB, note: "\(an.note ?? an.template): \(cue)"))
      }
    }
    return all.sorted { $0.t < $1.t }
  }
}

/// A one-shot sound effect. `t` is source seconds; an effect whose time is cut is dropped, and one
/// in a sped-up stretch still plays at normal speed from the mapped output time.
public struct SoundEffect: Codable, Equatable, Sendable {
  public var t: Double
  /// A file in the project folder, or an absolute path.
  public var file: String
  /// Level in dB (0 = as recorded).
  public var gainDB: Double?
  public var note: String?
  public init(t: Double, file: String, gainDB: Double? = nil, note: String? = nil) {
    self.t = t
    self.file = file
    self.gainDB = gainDB
    self.note = note
  }
}
