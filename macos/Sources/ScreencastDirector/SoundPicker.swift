import AVFoundation
import AppKit
import DirectorCore
import SwiftUI

/// Plays a library sound once, for picking one by ear.
final class SoundPreview: ObservableObject {
  @Published private(set) var playing: String?
  private var player: AVAudioPlayer?

  func toggle(_ entry: SoundLibrary.Entry) {
    if playing == entry.sound.file {
      stop()
      return
    }
    do {
      let p = try AVAudioPlayer(contentsOf: entry.url)
      p.play()
      player = p
      playing = entry.sound.file
      let file = entry.sound.file
      DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.05) { [weak self] in
        if self?.playing == file { self?.playing = nil }
      }
    } catch {
      Notices.shared.show(error, "Couldn't play \(entry.sound.name)")
    }
  }

  func stop() {
    player?.stop()
    player = nil
    playing = nil
  }
}

/// The sound library by category: play a sound to hear it, Add puts it at the playhead.
struct SoundPicker: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var preview: SoundPreview
  let entries: [SoundLibrary.Entry]
  let close: () -> Void

  private var categories: [String] {
    var out: [String] = []
    for e in entries where !out.contains(e.sound.category) { out.append(e.sound.category) }
    return out
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Sound Effects").font(.headline)
        Spacer()
        Button("My Sounds Folder") { revealPersonalFolder() }
          .help("Drop your own sounds here (m4a, mp3, wav, aiff) and they show up in this list")
      }
      .padding(10)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(categories, id: \.self) { category in
            Text(category).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 8).padding(.horizontal, 10)
            ForEach(entries.filter { $0.sound.category == category }, id: \.sound.file) { e in row(e) }
          }
        }
        .padding(.bottom, 8)
      }
    }
    .frame(width: 340, height: 440)
    .onDisappear { preview.stop() }
  }

  private func row(_ e: SoundLibrary.Entry) -> some View {
    HStack(spacing: 8) {
      Button { preview.toggle(e) } label: {
        Image(systemName: preview.playing == e.sound.file ? "stop.circle.fill" : "play.circle.fill").font(.title3)
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.sfx)
      .accessibilityLabel(preview.playing == e.sound.file ? "Stop \(e.sound.name)" : "Play \(e.sound.name)")
      VStack(alignment: .leading, spacing: 1) {
        Text(e.sound.name)
        if let use = e.sound.use { Text(use).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
      }
      Spacer(minLength: 4)
      if let length = e.sound.length { Text(String(format: "%.1f s", length)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
      Button("Add") {
        preview.stop()
        project.addSound(e)
        close()
      }
      .help("Add \(e.sound.name) at the playhead")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
  }

  private func revealPersonalFolder() {
    let folder = SoundLibrary.personalFolder
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      NSWorkspace.shared.activateFileViewerSelecting([folder])
    } catch {
      Notices.shared.show(error, "Couldn't open the sounds folder")
    }
  }
}
