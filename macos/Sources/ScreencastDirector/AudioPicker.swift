import AVFoundation
import AppKit
import DirectorCore
import SwiftUI

/// Plays a library item, for picking one by ear. Sounds play to the end; press again to stop.
final class AudioPreview: ObservableObject {
  @Published private(set) var playing: URL?
  private var player: AVAudioPlayer?

  func toggle(_ entry: AudioLibrary.Entry) {
    if playing == entry.url {
      stop()
      return
    }
    do {
      let p = try AVAudioPlayer(contentsOf: entry.url)
      p.play()
      player = p
      playing = entry.url
      let url = entry.url
      DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.05) { [weak self] in
        if self?.playing == url { self?.playing = nil }
      }
    } catch {
      Notices.shared.show(error, "Couldn't play \(entry.item.name)")
    }
  }

  func stop() {
    player?.stop()
    player = nil
    playing = nil
  }
}

/// A library by category: play an item to hear it, then add it (a sound at the playhead, or the
/// video's music).
struct AudioPicker: View {
  let kind: AudioLibrary.Kind
  @ObservedObject var preview: AudioPreview
  let entries: [AudioLibrary.Entry]
  let add: (AudioLibrary.Entry) -> Void
  let close: () -> Void

  private var categories: [String] {
    var out: [String] = []
    for e in entries where !out.contains(e.item.category) { out.append(e.item.category) }
    return out
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(kind == .sounds ? "Sound Effects" : "Music").font(.headline)
        Spacer()
        Button(kind == .sounds ? "My Sounds Folder" : "My Music Folder") { revealPersonalFolder() }
          .help("Drop your own \(kind == .sounds ? "sounds" : "tracks") here (m4a, mp3, wav, aiff) and they show up in this list")
      }
      .padding(10)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(categories, id: \.self) { category in
            Text(category).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 8).padding(.horizontal, 10)
            ForEach(entries.filter { $0.item.category == category }, id: \.url) { e in row(e) }
          }
        }
        .padding(.bottom, 8)
      }
    }
    .frame(width: 360, height: 440)
    .onDisappear { preview.stop() }
  }

  private func row(_ e: AudioLibrary.Entry) -> some View {
    HStack(spacing: 8) {
      Button { preview.toggle(e) } label: {
        Image(systemName: preview.playing == e.url ? "stop.circle.fill" : "play.circle.fill").font(.title3)
      }
      .buttonStyle(.plain)
      .foregroundStyle(kind == .sounds ? Theme.sfx : Theme.audio)
      .accessibilityLabel(preview.playing == e.url ? "Stop \(e.item.name)" : "Play \(e.item.name)")
      VStack(alignment: .leading, spacing: 1) {
        Text(e.item.name)
        if let detail = [e.item.use, e.item.author].compactMap({ $0 }).first {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if let length = e.item.length { Text(lengthText(length)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
      Button(kind == .sounds ? "Add" : "Use") {
        preview.stop()
        add(e)
        close()
      }
      .help(kind == .sounds ? "Add \(e.item.name) at the playhead" : "Use \(e.item.name) as the music")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
  }

  private func lengthText(_ seconds: Double) -> String {
    seconds < 60 ? String(format: "%.1f s", seconds) : String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
  }

  private func revealPersonalFolder() {
    let folder = AudioLibrary.personalFolder(kind)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      NSWorkspace.shared.activateFileViewerSelecting([folder])
    } catch {
      Notices.shared.show(error, "Couldn't open the folder")
    }
  }
}
