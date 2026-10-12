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
