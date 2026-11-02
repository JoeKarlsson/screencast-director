import AppKit
import DirectorCore
import SwiftUI

// The inspector's Audio tab, and picking music and sounds.
extension InspectorView {
  // MARK: Audio

  @ViewBuilder
  func audioPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Audio")
    InspectorSection("Voice", detail: "Normalize evens out your voice phrase by phrase, so quiet and loud moments sit at the same steady level; a limiter keeps peaks from clipping.") {
      toggle("Normalize voice", (plan.audio?.normalize ?? false) && !project.levels.isEmpty
        ? String(format: "Adds %+.1f dB.", AudioGain.normalizeGain(project.levels)) : "",
        Binding(get: { plan.audio?.normalize ?? false }, set: { v in
          project.apply { p in
            var a = p.audio ?? AudioSettings()
            a.normalize = v
            p.audio = a
          }
        }))
      toggle("Warm voice", "More chest, less boxiness, gentle compression and a touch of warmth.",
        Binding(get: { plan.audio?.warm ?? false }, set: { v in
          project.apply { p in
            var a = p.audio ?? AudioSettings()
            a.warm = v
            p.audio = a
          }
        }))
        .help("Warm voice: EQ for more chest and less boxiness, gentle compression, and light saturation.")
      toggle("Clean up voice", "Removes room noise, hum and echo. The first time takes a few seconds.",
        Binding(get: { plan.audio?.cleanup ?? false }, set: { v in
          project.apply { p in
            var a = p.audio ?? AudioSettings()
            a.cleanup = v
            p.audio = a
          }
        }))
        .help("Removes room noise, hum and echo with Apple's voice isolation. The first time takes a few seconds.")
      slider("Volume", Binding(get: { project.plan?.audio?.gainDB ?? 0 }, set: { v in
        project.apply(coalesce: "gain") { p in
          var a = p.audio ?? AudioSettings()
          a.gainDB = (v * 2).rounded() / 2
          p.audio = a
        }
      }), -12...12, String(format: "%+.1f dB", plan.audio?.gainDB ?? 0))
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
        slider("Volume", Binding(get: { project.plan?.music?.volumeDB ?? MusicDuck.defaultVolumeDB }, set: { v in
          project.apply(coalesce: "musicVolume") { p in p.music?.volumeDB = v.rounded() }
        }), -40...0, String(format: "%.0f dB", music.volumeDB ?? MusicDuck.defaultVolumeDB))
        slider("Under voice", Binding(get: { project.plan?.music?.duckDB ?? MusicDuck.defaultDuckDB }, set: { v in
          project.apply(coalesce: "musicDuck") { p in p.music?.duckDB = v.rounded() }
        }), -40...0, String(format: "%.0f dB", music.duckDB ?? MusicDuck.defaultDuckDB))
      } else {
        Button { project.chooseMusicFile() } label: { Label("Add Music File…", systemImage: "music.note.list").frame(maxWidth: .infinity) }
      }
      Button { openPicker(.music) } label: {
        Label(plan.music == nil ? "Music Library…" : "Change Music…", systemImage: "music.quarternote.3").frame(maxWidth: .infinity)
      }
      .help("Pick background music from the library")
      .popover(isPresented: $ui.showMusicPicker, arrowEdge: .leading) {
        AudioPicker(kind: .music, preview: ui.audioPreview, entries: ui.pickerEntries, add: { project.useMusic($0) }) { ui.showMusicPicker = false }
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
            AudioPicker(kind: .sounds, preview: ui.audioPreview, entries: ui.pickerEntries, add: { project.addSound($0) }) { ui.showSoundPicker = false }
          }
    }
    InspectorSection("Pauses", detail: "How hard to cut silence. Cuts that removed words always stay cut.") {
      Picker("Pauses", selection: Binding(get: { plan.pauses ?? .normal }, set: { project.setPauses($0) })) {
        ForEach(PauseLevel.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  func openPicker(_ kind: AudioLibrary.Kind) {
    do {
      ui.pickerEntries = try AudioLibrary(kind).items()
      if kind == .sounds { ui.showSoundPicker = true } else { ui.showMusicPicker = true }
    } catch {
      Notices.shared.show(error, "Couldn't load the \(kind == .sounds ? "sound" : "music") library")
    }
  }
}
