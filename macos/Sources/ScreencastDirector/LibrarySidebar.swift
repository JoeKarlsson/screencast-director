import AVKit
import AppKit
import DirectorCore
import SwiftUI

// MARK: Library

/// Recordings with a poster frame, length, date and how far along each one is.
struct LibrarySidebar: View {
  @ObservedObject var library: Library
  @ObservedObject var setup: SetupModel
  @ObservedObject var posters: PosterCache

  var body: some View {
    List(selection: $library.selection) {
      Section {
        ForEach(library.filtered, id: \.self) { url in
          row(url).tag(url as URL?)
            .contextMenu {
              Button("Rename") { library.beginRename(url) }
              Button("Suggest a Name with \(AISettings.shared.provider.shortName)") { library.suggestName(url) }
              Divider()
              Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
              Divider()
              Button("Move to Trash…") { library.promptDelete(url) }
            }
        }
      } header: {
        HStack {
          Text("Recordings")
          Spacer()
          Menu {
            Picker("Sort By", selection: $library.sort) {
              ForEach(Library.Sort.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
          } label: {
            Label(library.sort.label, systemImage: "arrow.up.arrow.down")
              .labelStyle(.titleAndIcon)
              .font(.caption)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Sort recordings")
        }
      }
    }
    .searchable(text: $library.search, placement: .sidebar, prompt: "Search names and what you said")
    .overlay {
      if library.filtered.isEmpty {
        ContentUnavailableView(
          library.search.isEmpty ? "No Recordings Yet" : "No Matches",
          systemImage: library.search.isEmpty ? "film.stack" : "magnifyingglass",
          description: Text(library.search.isEmpty ? "Press ⌘N to record, or import a video." : "Nothing named or said like that."))
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        if !library.status.isEmpty {
          Text(library.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        Button {
          library.selection = nil
        } label: {
          Label(
            setup.allRequiredOK ? "Getting Started" : "Finish Setup",
            systemImage: setup.allRequiredOK ? "questionmark.circle" : "exclamationmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(setup.allRequiredOK ? Color.secondary : Theme.warning)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func row(_ url: URL) -> some View {
    let info = library.info(url)
    return HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08))
        if let img = posters.images[url] {
          Image(nsImage: img).resizable().scaledToFill()
        } else {
          Image(systemName: "film").foregroundStyle(.tertiary)
        }
      }
      .frame(width: 64, height: 40)
      .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
      .onAppear { posters.load(url) }

      VStack(alignment: .leading, spacing: 2) {
        if library.renaming == url {
          TextField("Name", text: $library.renameText)
            .textFieldStyle(.roundedBorder)
            .onSubmit(library.commitRename)
            .onExitCommand { library.renaming = nil }
        } else {
          Text(url.lastPathComponent).lineLimit(2).font(.body)
        }
        HStack(spacing: 6) {
          Text(info.duration > 0 ? fmtTime(info.duration) : "–").monospacedDigit()
          Text(info.date.formatted(.dateTime.month(.abbreviated).day()))
          StageBadge(stage: info.stage)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 3)
    .onTapGesture(count: 2) { library.beginRename(url) }
    .simultaneousGesture(TapGesture().onEnded { library.selection = url })
  }

}

/// Thumbnails, made once per project per launch from its newest export (the recording before one
/// exists): a poster frame, plus a few frames from across the video that the home screen's cards
/// cycle through on hover.
final class PosterCache: ObservableObject {
  static let shared = PosterCache()
  @Published private(set) var images: [URL: NSImage] = [:]
  @Published private(set) var montages: [URL: [NSImage]] = [:]
  private var loading: Set<URL> = []
  static let montageFrames = 6

  func load(_ url: URL) {
    guard images[url] == nil, !loading.contains(url) else { return }
    loading.insert(url)
    let source = (try? Data(contentsOf: url.appendingPathComponent("source.json"))).flatMap { try? JSONDecoder().decode(Project.Source.self, from: $0) }
    let video = thumbnailVideo(project: url, source: source?.video ?? "screen.mp4")
    Task { @MainActor in
      defer { loading.remove(url) }
      let asset = AVURLAsset(url: video)
      guard let duration = try? await asset.load(.duration).seconds else { return }
      let gen = AVAssetImageGenerator(asset: asset)
      gen.appliesPreferredTrackTransform = true
      // Square bounds, so a vertical export is as sharp in a card as a landscape one.
      gen.maximumSize = CGSize(width: 640, height: 640)
      // Nearby frames are fine for a thumbnail and far faster than exact ones.
      let slack = CMTime(seconds: 0.5, preferredTimescale: 600)
      gen.requestedTimeToleranceBefore = slack
      gen.requestedTimeToleranceAfter = slack
      var frames: [NSImage] = []
      for t in montageTimes(duration: duration, count: Self.montageFrames) {
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
        frames.append(NSImage(cgImage: cg, size: .zero))
        if frames.count == 1 { images[url] = frames[0] }
      }
      montages[url] = frames
    }
  }
}
