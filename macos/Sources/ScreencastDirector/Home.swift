import AppKit
import DirectorCore
import SwiftUI

/// What the main window shows with no project open: a big Record button, your recordings as a
/// gallery, and the setup checklist (up front until it's all green, folded away after).
struct HomeView: View {
  @ObservedObject var library: Library
  @ObservedObject var setup: SetupModel
  @ObservedObject var posters: PosterCache
  @ObservedObject var ui: HomeUI
  let record: () -> Void
  let importVideo: () -> Void
  let watchTour: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        hero
        if !setup.allRequiredOK { setupCard(expanded: true) }
        if library.projects.isEmpty {
          howItWorks
        } else {
          gallery
        }
        if setup.allRequiredOK { setupCard(expanded: false) }
      }
      .padding(32)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .background(
      LinearGradient(colors: [Theme.accent.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
        .ignoresSafeArea())
  }

  // MARK: Hero

  private var hero: some View {
    HStack(alignment: .center, spacing: 24) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
        .shadow(color: Theme.accent.opacity(0.35), radius: 16, y: 6)
      VStack(alignment: .leading, spacing: 6) {
        Text("Screencast Director").font(.system(size: 30, weight: .bold, design: .rounded))
        Text("Record your screen, then edit it by hand or by telling Claude what you want.")
          .font(.title3).foregroundStyle(.secondary)
        HStack(spacing: 10) {
          Button(action: record) {
            Label("New Recording", systemImage: "record.circle.fill").font(.headline).padding(.horizontal, 8).padding(.vertical, 2)
          }
          .buttonStyle(.borderedProminent)
          .tint(Theme.recording)
          .controlSize(.large)
          .help("Pick what to record (⌘N)")
          Button(action: importVideo) { Label("Import a Video…", systemImage: "square.and.arrow.down") }
            .controlSize(.large)
          if Bundle.main.url(forResource: "tour", withExtension: "mp4") != nil {
            Button(action: watchTour) { Label("Watch the Tour", systemImage: "play.rectangle") }
              .controlSize(.large)
          }
        }
        .padding(.top, 10)
        Text("Or press ⌃⌥⌘R in any app to record right away. ⌃⌥⌘M marks a retake.")
          .font(.callout).foregroundStyle(.secondary).padding(.top, 2)
      }
    }
  }

  // MARK: Gallery

  private var gallery: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("Recordings").font(.title2.bold())
        Text("\(library.filtered.count)").font(.title3).foregroundStyle(.secondary)
        Spacer()
        Picker("Sort By", selection: $library.sort) {
          ForEach(Library.Sort.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 340), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
        ForEach(library.filtered, id: \.self) { url in
          RecordingCard(url: url, info: library.info(url), poster: posters.images[url], hovered: ui.hovered == url)
            .onAppear { posters.load(url) }
            .onHover { ui.hovered = $0 ? url : (ui.hovered == url ? nil : ui.hovered) }
            .onTapGesture { library.selection = url }
            .contextMenu {
              Button("Open") { library.selection = url }
              Button("Rename") { library.beginRename(url) }
              Button("Suggest a Name with \(AISettings.shared.provider.shortName)") { library.suggestName(url) }
              Divider()
              Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(url.lastPathComponent)
        }
      }
    }
  }

  // MARK: First run

  private var howItWorks: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("How it works").font(.title2.bold())
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
        step(1, "record.circle", "Record", "Talk through your demo. Flubbed a line? ⌃⌥⌘M and say it again.")
        step(2, "wand.and.stars", "It drafts the edit", "Dead air is cut, typing sped up, clicks zoomed, captions from your voice.")
        step(3, "slider.horizontal.3", "Adjust", "Trim, cut, zoom, split screen and titles on the timeline and inspector.")
        step(4, "sparkles", "Or ask Claude", "\"Cut my retakes and zoom in on the config.\" ⌘Z undoes it.")
        step(5, "square.and.arrow.up", "Export", "MP4, GIF, captions and thumbnails, in any shape.")
      }
    }
  }

  private func step(_ n: Int, _ symbol: String, _ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent)
        .frame(width: 40, height: 40)
        .background(Circle().fill(Theme.accent.opacity(0.15)))
      Text("\(n). \(title)").font(.headline)
      Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
    .card(padding: 14)
  }

  // MARK: Setup

  private func setupCard(expanded: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        withAnimation(.snappy) { ui.showSetup.toggle() }
      } label: {
        HStack {
          Image(systemName: setup.allRequiredOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(setup.allRequiredOK ? Color.green : Color.orange)
          Text(setup.allRequiredOK ? "Setup: all set" : "Finish setup to start recording").font(.headline)
          Spacer()
          if !expanded {
            Image(systemName: "chevron.right").rotationEffect(.degrees(ui.showSetup ? 90 : 0)).foregroundStyle(.secondary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(expanded)
      if expanded || ui.showSetup {
        ForEach(setup.items) { item in
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.ok ? "checkmark.circle.fill" : (item.required ? "exclamationmark.circle.fill" : "circle"))
              .foregroundStyle(item.ok ? .green : (item.required ? .orange : .secondary))
              .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title + (item.required ? "" : " (optional)")).font(.body.weight(.medium))
              Text(item.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if !item.ok { Button(item.fixLabel, action: item.fix).controlSize(.small) }
          }
          .padding(.vertical, 4)
        }
        HStack {
          Text("After allowing Screen Recording or Input Monitoring, macOS may ask you to quit and reopen the app.")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Link(
            "Privacy", destination: URL(string: "https://github.com/JoeKarlsson/screencast-director/blob/main/docs/privacy.md")!
          )
          .font(.caption)
          Button("Check Again", action: setup.refresh).controlSize(.small)
        }
      }
    }
    .card(padding: 16)
  }
}

final class HomeUI: ObservableObject {
  @Published var hovered: URL?
  @Published var showSetup = false
}

/// A recording in the gallery: poster, name, length, date and stage.
struct RecordingCard: View {
  let url: URL
  let info: Library.Info
  let poster: NSImage?
  let hovered: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topTrailing) {
        Color.primary.opacity(0.07)
          .aspectRatio(16 / 10, contentMode: .fit)
          .frame(maxWidth: .infinity)
          .overlay {
            if let poster {
              Image(nsImage: poster).resizable().scaledToFill()
            } else {
              Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
            }
          }
          .clipped()
        StageBadge(stage: info.stage).padding(8)
        Text(info.duration > 0 ? fmtTime(info.duration) : "")
          .font(.caption.weight(.semibold)).monospacedDigit()
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(Capsule().fill(.black.opacity(0.6)))
          .foregroundStyle(.white)
          .padding(8)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
      }
      .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
          .strokeBorder(hovered ? Theme.accent : Color.primary.opacity(0.1), lineWidth: hovered ? 2 : 1))
      .shadow(color: .black.opacity(hovered ? 0.25 : 0.1), radius: hovered ? 14 : 6, y: hovered ? 8 : 3)
      VStack(alignment: .leading, spacing: 2) {
        Text(url.lastPathComponent).font(.body.weight(.medium)).lineLimit(2, reservesSpace: true)
        Text(info.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 2)
    }
    .scaleEffect(hovered ? 1.02 : 1)
    .animation(.snappy(duration: 0.2), value: hovered)
    .contentShape(Rectangle())
  }
}

/// New / Exported, readable on a selected (accent-filled) sidebar row too.
struct StageBadge: View {
  let stage: Library.Stage
  @Environment(\.backgroundProminence) var prominence

  var body: some View {
    switch stage {
    case .new: badge("New", .blue)
    case .edited: EmptyView()
    case .exported: badge("Exported", .green)
    }
  }

  private func badge(_ text: String, _ color: Color) -> some View {
    let onSelection = prominence == .increased
    return Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
      .background(Capsule().fill(onSelection ? Color.white.opacity(0.25) : color.opacity(0.85)))
      .foregroundStyle(.white)
  }
}
