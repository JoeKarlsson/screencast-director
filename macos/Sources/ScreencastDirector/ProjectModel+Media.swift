import AVFoundation
import AppKit
import DirectorCore
import Foundation
import UniformTypeIdentifiers

// B-roll, LUTs, logos, fonts, sounds and music: files picked or recorded into the project.
extension ProjectModel {
  // MARK: B-roll

  /// Asks for a picture or video, copies it into the project's broll/ folder, and shows it from the
  /// playhead (3 s for a picture, up to 5 s of a clip).
  func addInsert() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .movie]
    panel.message = "Pick a picture or clip to show over the video"
    // Opens on the project's B-roll (clips recorded with Record B-roll are there) when it has some.
    let broll = dir.appendingPathComponent("broll")
    if FileManager.default.fileExists(atPath: broll.path) { panel.directoryURL = broll }
    let start = playheadSrc
    let done: (NSApplication.ModalResponse) -> Void = { [self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        let file = try Project.importFile(url, into: "broll", dir: dir)
        Task { @MainActor in
          var length = 3.0
          if !Insert(start: 0, end: 1, file: file).isImage, let d = try? await AVURLAsset(url: dir.appendingPathComponent(file)).load(.duration) {
            length = min(5, max(0.5, d.seconds))
          }
          guard let plan else { return }
          let ins = Insert(start: start, end: min(plan.source.duration, start + length), file: file)
          apply { $0.insertList.append(ins) }
          if let i = self.plan?.insertList.firstIndex(of: ins) { select(.insert(i), adding: false) }
        }
      } catch {
        Notices.shared.show(error, "Couldn't add the B-roll")
      }
    }
    presentPanel(panel, then: done)
  }

  /// Record B-roll: records a clip from the camera or screen into broll/ (`BrollRecorder`).
  func recordBroll() {
    guard let app = AppDelegate.shared, !app.recorder.isRecording else { return }
    app.brollRecorder.show(for: self)
  }

  /// A clip Record B-roll just saved in broll/: full frame from the playhead, for its length.
  func addRecordedBroll(_ file: String, length: Double) {
    guard let plan else { return }
    let ins = RecordedBroll.insert(file: file, playhead: playheadSrc, length: length, duration: plan.source.duration)
    apply { $0.insertList.append(ins) }
    if let i = self.plan?.insertList.firstIndex(of: ins) { select(.insert(i), adding: false) }
    status = "Recorded B-roll at \(fmtTime(ins.start)) (\(file))."
  }

  /// Asks for a `.cube` LUT, copies it into the project's luts/ folder, and grades the camera with it.
  /// A file that isn't a 3D LUT is refused with the reason, before anything is copied.
  func chooseLUT() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
    panel.message = "Choose a .cube LUT for the camera"
    let done: (NSApplication.ModalResponse) -> Void = { [self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        _ = try CubeLUT.load(url)
        let file = try Project.importFile(url, into: "luts", dir: dir)
        apply { p in
          var g = p.camera?.grade ?? Grade()
          g.lut = file
          p.camera?.grade = g
        }
      } catch {
        Notices.shared.show(error, "Couldn't use that LUT")
      }
    }
    presentPanel(panel, then: done)
  }

  /// A PNG logo picked by the user, copied into the project's logos/ folder; `use` puts its path in the plan.
  func chooseLogo(_ use: @escaping (inout Plan, String) -> Void) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png]
    panel.message = "Choose a PNG logo (a transparent background works best)"
    presentPanel(panel) { [self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        let file = try Project.importFile(url, into: "logos", dir: dir)
        apply { use(&$0, file) }
      } catch {
        Notices.shared.show(error, "Couldn't use that logo")
      }
    }
  }

  /// A font file copied into the project's fonts/ folder and added to the look's font files, so its
  /// fonts show up in the font pickers.
  func chooseFontFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.font]
    panel.message = "Choose a font file (.ttf or .otf)"
    presentPanel(panel) { [self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        let file = try Project.importFile(url, into: "fonts", dir: dir)
        // Font files are registered by absolute path (Fonts.register).
        let path = dir.appendingPathComponent(file).path
        apply { p in
          var look = p.look ?? Look()
          if !(look.fontFiles ?? []).contains(path) { look.fontFiles = (look.fontFiles ?? []) + [path] }
          p.look = look
        }
      } catch {
        Notices.shared.show(error, "Couldn't add that font")
      }
    }
  }

  /// A library sound at the playhead. It's copied into the project's sfx/ folder (unless the
  /// project already has that file), so the video keeps it if the library changes.
  func addSound(_ entry: AudioLibrary.Entry) {
    let file: String
    do {
      file = try AudioLibrary(.sounds).freeze(entry, project: dir)
    } catch {
      Notices.shared.show(error, "Couldn't add \(entry.item.name)")
      return
    }
    let e = SoundEffect(t: playheadSrc, file: file, note: entry.item.name)
    apply { p in p.sfxList.append(e) }
    if let i = plan?.sfx?.firstIndex(of: e) { select(.sfx(i), adding: false) }
    status = "\(entry.item.name) at \(fmtTime(e.t))."
  }

  /// A library track as the video's music, copied into the project's music/ folder (unless it's
  /// there already). Keeps the current volume settings when swapping tracks.
  func useMusic(_ entry: AudioLibrary.Entry) {
    let file: String
    do {
      file = try AudioLibrary(.music).freeze(entry, project: dir)
    } catch {
      Notices.shared.show(error, "Couldn't use \(entry.item.name)")
      return
    }
    apply { p in
      var m = p.music ?? Music(file: file)
      m.file = file
      p.music = m
    }
    status = "Music: \(entry.item.name)."
  }

  /// Asks for an audio file, copies it into the project's music/ folder, and uses it as the music.
  /// Keeps the current volume settings.
  func chooseMusicFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
    panel.message = "Choose a background track"
    presentPanel(panel) { [self] response in
      guard response == .OK, let url = panel.url else { return }
      let file: String
      do { file = try Project.importFile(url, into: "music", dir: dir) } catch {
        Notices.shared.show(error, "Couldn't add the music")
        return
      }
      apply { p in
        var m = p.music ?? Music(file: file)
        m.file = file
        p.music = m
      }
      status = "Music: \(url.deletingPathExtension().lastPathComponent)."
    }
  }
}
