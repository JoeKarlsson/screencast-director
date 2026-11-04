import AppKit
import DirectorCore
import SwiftUI

// The inspector's Audio tab, and picking music and sounds.
extension InspectorView {
  // MARK: Audio

  @ViewBuilder
  func audioPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Audio")
    InspectorSection("Voice",
      detail: "Normalize evens out your voice phrase by phrase, so quiet and loud moments sit at the same steady level; a limiter keeps peaks from clipping.") {
      toggle("Normalize voice", (plan.audio?.normalize ?? false) && !project.levels.isEmpty
        ? String(format: "Adds %+.1f dB.", AudioGain.normalizeGain(project.levels)) : "",
        bind(nil, { $0.audioSettings.normalize ?? false }, { $0.audioSettings.normalize = $1 }))
      toggle("Warm voice", "More chest, less boxiness, gentle compression and a touch of warmth.",
        bind(nil, { $0.audioSettings.warm ?? false }, { $0.audioSettings.warm = $1 }))
        .help("Warm voice: EQ for more chest and less boxiness, gentle compression, and light saturation.")
      toggle("Clean up voice", "Removes room noise, hum and echo. The first time takes a few seconds.",
        bind(nil, { $0.audioSettings.cleanup ?? false }, { $0.audioSettings.cleanup = $1 }))
        .help("Removes room noise, hum and echo with Apple's voice isolation. The first time takes a few seconds.")
      slider("Volume", bind("gain", { $0.audioSettings.gainDB ?? 0 }, { $0.audioSettings.gainDB = ($1 * 2).rounded() / 2 }), -12...12, String(format: "%+.1f dB",
        plan.audio?.gainDB ?? 0))
    }
    InspectorSection("Music", detail: "A background track, looped to the video's length. It drops while you talk.") {
      if let music = plan.music {
        HStack(spacing: 8) {
          Image(systemName: "music.note").foregroundStyle(Theme.audio)
          Text((music.file as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 4)
          Button { project.apply { $0.music = nil } } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove the music")
            .accessibilityLabel("Remove")
        }
        slider("Volume", bind("musicVolume", { $0.music?.volumeDB ?? MusicDuck.defaultVolumeDB }, { $0.music?.volumeDB = $1.rounded() }), -40...0, String(format: "%.0f dB",
          music.volumeDB ?? MusicDuck.defaultVolumeDB))
        slider("Under voice", bind("musicDuck", { $0.music?.duckDB ?? MusicDuck.defaultDuckDB }, { $0.music?.duckDB = $1.rounded() }), -40...0, String(format: "%.0f dB",
          music.duckDB ?? MusicDuck.defaultDuckDB))
      }
      // One row: the library (most picks) and a file of your own.
      HStack(spacing: 8) {
        Button { openPicker(.music) } label: {
          Label(plan.music == nil ? "Music Library…" : "Change Music…", systemImage: "music.quarternote.3").frame(maxWidth: .infinity)
        }
        .help("Pick background music from the library")
        .popover(isPresented: $ui.showMusicPicker, arrowEdge: .leading) {
          AudioPicker(kind: .music, preview: ui.audioPreview, entries: ui.pickerEntries, add: { project.useMusic($0) }, close: { ui.showMusicPicker = false })
        }
        Button("File…") { project.chooseMusicFile() }
          .help("Use a music file of your own")
      }
    }
    InspectorSection("Sound Effects", detail: "One-shot sounds at moments in the video. Add one at the playhead, or ask Claude.") {
        ForEach(Array(plan.sfxList.enumerated()), id: \.offset) { i, e in
          HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2").foregroundStyle(Theme.audio)
            Text(fmtTime(e.t)).monospacedDigit().foregroundStyle(.secondary)
            Text(e.note ?? (e.file as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
              project.apply { p in
                guard var list = p.sfx, list.indices.contains(i) else { return }
                list.remove(at: i)
                p.sfx = list.isEmpty ? nil : list
              }
            } label: { Image(systemName: "xmark.circle.fill") }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .help("Remove this sound effect")
              .accessibilityLabel("Remove")
          }
        }
        Button { openPicker(.sounds) } label: { Label("Add Sound Effect…", systemImage: "speaker.wave.2").frame(maxWidth: .infinity) }
          .help("Pick a sound effect to add at the playhead")
          .popover(isPresented: $ui.showSoundPicker, arrowEdge: .leading) {
            AudioPicker(kind: .sounds, preview: ui.audioPreview, entries: ui.pickerEntries, add: { project.addSound($0) }, close: { ui.showSoundPicker = false })
          }
    }
    InspectorSection("Pauses", detail: "How hard to cut silence. Cuts that removed words always stay cut.") {
      Picker("Pauses", selection: Binding(get: { project.plan?.pauses ?? .normal }, set: { project.setPauses($0) })) {
        ForEach(PauseLevel.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  /// Opens the sound or music library; `forItem` picks the selected title's or mark's own sound.
  func openPicker(_ kind: AudioLibrary.Kind, forItem: Bool = false) {
    do {
      ui.pickerEntries = try AudioLibrary(kind).items()
      if forItem { ui.showItemSoundPicker = true } else if kind == .sounds { ui.showSoundPicker = true } else { ui.showMusicPicker = true }
    } catch {
      Notices.shared.show(error, "Couldn't load the \(kind == .sounds ? "sound" : "music") library")
    }
  }
}
