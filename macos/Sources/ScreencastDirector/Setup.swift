import AVFoundation
import AppKit
import DirectorCore
import SwiftUI

/// What the app needs, checked live: permissions, Whisper, Claude Code.
final class SetupModel: ObservableObject {
  struct Item: Identifiable {
    let id: String
    let title: String
    let detail: String
    let ok: Bool
    let required: Bool
    let fixLabel: String
    let fix: () -> Void
  }

  @Published private(set) var items: [Item] = []
  var allRequiredOK: Bool { items.allSatisfy { $0.ok || !$0.required } }

  init() {
    refresh()
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.refresh()
    }
  }

  static func openPrivacy(_ pane: String) {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
  }

  func refresh() {
    let screen = CGPreflightScreenCaptureAccess()
    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    let cam = AVCaptureDevice.authorizationStatus(for: .video)
    let input = CGPreflightListenEventAccess()
    let whisper = Tools.whisperCLI
    let model = Tools.model
    let claude = Claude.executable

    func request(_ type: AVMediaType, _ status: AVAuthorizationStatus, pane: String) -> () -> Void {
      {
        if status == .notDetermined {
          AVCaptureDevice.requestAccess(for: type) { _ in DispatchQueue.main.async { self.refresh() } }
        } else {
          SetupModel.openPrivacy(pane)
        }
      }
    }

    let installWhisper = "brew install whisper-cpp"
    let modelPath = Tools.modelsDir.appendingPathComponent("ggml-large-v3-turbo.bin").path
    let downloadModel = "curl -L --create-dirs -o '\(modelPath)' https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"

    items = [
      Item(
        id: "screen", title: "Screen Recording", detail: "To record your display.", ok: screen, required: true,
        fixLabel: "Allow…",
        fix: {
          if !CGRequestScreenCaptureAccess() { SetupModel.openPrivacy("Privacy_ScreenCapture") }
        }),
      Item(
        id: "mic", title: "Microphone", detail: "To record your narration.", ok: mic == .authorized, required: true,
        fixLabel: mic == .notDetermined ? "Allow…" : "Open Settings", fix: request(.audio, mic, pane: "Privacy_Microphone")),
      Item(
        id: "input", title: "Input Monitoring",
        detail: "Logs where you click and when you type (never what you type), for auto-zoom and speed-ups.", ok: input, required: false,
        fixLabel: "Allow…",
        fix: {
          if !CGRequestListenEventAccess() { SetupModel.openPrivacy("Privacy_ListenEvent") }
        }),
      Item(
        id: "camera", title: "Camera", detail: "Only for the camera bubble and split screen.", ok: cam == .authorized, required: false,
        fixLabel: cam == .notDetermined ? "Allow…" : "Open Settings", fix: request(.video, cam, pane: "Privacy_Camera")),
      Item(
        id: "whisper", title: "Transcription (Whisper)",
        detail: whisper != nil && model != nil
          ? "\(model!.lastPathComponent) via \(whisper!.path)"
          : (whisper == nil ? "Install whisper.cpp: \(installWhisper)" : "No Whisper model found. Copy the command and run it in Terminal to download one (1.6 GB)."),
        ok: whisper != nil && model != nil, required: true, fixLabel: "Copy Command",
        fix: {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(whisper == nil ? installWhisper : downloadModel, forType: .string)
        }),
      Item(
        id: "claude", title: "Claude Code", detail: claude?.path ?? "For \"Ask Claude\". Install from claude.com/claude-code.",
        ok: claude != nil, required: false, fixLabel: "Open Website",
        fix: { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) }),
    ]
  }
}

struct SetupView: View {
  @ObservedObject var setup: SetupModel
  let record: () -> Void
  let importVideo: () -> Void
  let watchTour: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 14) {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
          VStack(alignment: .leading, spacing: 4) {
            Text("Screencast Director").font(.largeTitle.bold())
            Text("Record your screen, then edit it by hand or by telling Claude what you want.").foregroundStyle(.secondary)
          }
        }

        if Bundle.main.url(forResource: "tour", withExtension: "mp4") != nil {
          Button(action: watchTour) { Label("Watch the Tour (3 min)", systemImage: "play.rectangle.fill") }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }

        VStack(alignment: .leading, spacing: 10) {
          Text("How it works").font(.title3.bold())
          step(1, "Record", "Press ⌃⌥⌘R in any app (or the ● button). Talk through your demo (flubbed a line? press ⌃⌥⌘M and say it again), then press ⌃⌥⌘R again.")
          step(2, "It drafts the edit", "Dead air is cut, typing is sped up, the camera zooms to your clicks, captions come from your voice.")
          step(3, "Adjust", "Scrub the timeline, trim or cut clips, add zooms, split screen and titles; style it in the inspector.")
          step(4, "Or ask Claude", "\"Cut my retakes and zoom in when I mention the config.\" ⌘Z undoes it if you don't like it.")
          step(5, "Export", "An MP4 lands in the recording's folder.")
          HStack {
            Button(action: record) { Label("Start Recording", systemImage: "record.circle") }
              .buttonStyle(.borderedProminent).tint(.red)
            Button(action: importVideo) { Label("Import a Video…", systemImage: "square.and.arrow.down") }
          }
          .padding(.top, 4)
        }

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Setup").font(.title3.bold())
            Spacer()
            Button("Check Again", action: setup.refresh).controlSize(.small)
          }
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
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
          }
          Text("After allowing Screen Recording or Input Monitoring, macOS may ask you to quit and reopen the app.")
            .font(.caption).foregroundStyle(.secondary)
          Link(
            "Privacy: what's recorded and what leaves your Mac",
            destination: URL(string: "https://github.com/JoeKarlsson/screencast-director/blob/main/docs/privacy.md")!
          )
          .font(.caption)
        }
      }
      .padding(28)
      .frame(maxWidth: 680, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  private func step(_ n: Int, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(n)").font(.callout.bold()).frame(width: 24, height: 24).background(Circle().fill(Color.accentColor.opacity(0.25)))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body.weight(.semibold))
        Text(text).font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}
