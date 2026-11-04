import AVKit
import AppKit
import DirectorCore
import SwiftUI

struct PublishView: View {
  @ObservedObject var project: ProjectModel

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Publish").font(.title2.bold())
        Spacer()
        if project.busy { ProgressView().controlSize(.small) }
        Text(project.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      TextField("Video title (used on thumbnails and in the description)", text: $project.publishTitle)
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("Make Captions, Chapters & Thumbnails", action: project.makePublishKit)
        Button("Draft YouTube Description with \(AISettings.shared.provider.shortName)", action: project.draftDescription)
        Spacer()
        Button("Show in Finder") {
          do {
            try FileManager.default.createDirectory(at: project.publishDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(project.publishDir)
          } catch {
            Notices.shared.show("Couldn't make the publish folder: \(error.localizedDescription)", error: true)
          }
        }
      }
      .disabled(project.busy)

      // The moments covers are made from: the playhead's frame, or the clearest faces when none are picked.
      // Covers are camera frames, so a recording without a camera has none to pick.
      let covers = project.plan?.coverAt ?? []
      if project.plan?.camera != nil { HStack {
        Button("Use Playhead Frame for a Cover") {
          let t = project.playheadSrc
          project.apply { $0.addCover(at: t) }
        }
        .help("Make a cover from the camera frame at the playhead (up to three; Make Thumbnails uses them)")
        Text(covers.isEmpty ? "Covers pick your clearest camera frames" : "Covers from " + covers.map { fmtTime($0) }.joined(separator: ", "))
          .font(.caption).foregroundStyle(.secondary)
        if !covers.isEmpty {
          Button("Clear") { project.apply { $0.coverAt = nil } }.controlSize(.small)
            .help("Go back to picking the clearest camera frames")
        }
      }
      .disabled(project.busy) }

      let thumbs = project.publishFiles.filter { $0.pathExtension == "png" }
      if !thumbs.isEmpty {
        let picked = covers.isEmpty ? "your clearest camera frames" : "the frames you picked"
        Text("Thumbnails: \(picked), with the title in your profile's style").font(.headline)
        ScrollView(.horizontal) {
          HStack(spacing: 10) {
            ForEach(thumbs, id: \.self) { url in
              if let img = NSImage(contentsOf: url) {
                // Each at its own shape: vertical covers stay vertical.
                Image(nsImage: img).resizable().scaledToFit().frame(height: 220)
                  .clipShape(RoundedRectangle(cornerRadius: 8))
                  .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                  .help(url.lastPathComponent)
              }
            }
          }
        }
      }
      let other = project.publishFiles.filter { $0.pathExtension != "png" }
      if !other.isEmpty {
        Text("Files").font(.headline)
        ForEach(other, id: \.self) { url in
          HStack {
            Text(url.lastPathComponent).font(.system(.body, design: .monospaced))
            Spacer()
            Button("Copy") {
              do {
                let text = try String(contentsOf: url, encoding: .utf8)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
              } catch {
                Notices.shared.show("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)", error: true)
              }
            }
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
          }
        }
      }
      if !project.descriptionText.isEmpty {
        Text("Description draft").font(.headline)
        ScrollView {
          Text(project.descriptionText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 140)
      }
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button("Done") { project.showPublish = false }.keyboardShortcut(.defaultAction).help("Close Publish")
      }
    }
    .padding(20)
    .frame(width: 760, height: 620)
  }
}
