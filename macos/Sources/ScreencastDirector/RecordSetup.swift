import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

/// "New Recording…": a small glass panel at the top of the screen that picks what to record (a
/// display or one window), the mic and the camera, then starts. ⌃⌥⌘R skips it and records with
/// the last choices.
final class RecordSetup {
  private var panel: FloatingPanel?
  var onStart: () -> Void = {}

  func show(settings: AppSettings) {
    let panel = self.panel ?? FloatingPanel(size: NSSize(width: 560, height: 200), activating: true)
    let size = panel.host(
      RecordSetupView(
        settings: settings, windows: CaptureWindows.shared,
        start: { [weak self] in
          self?.close()
          self?.onStart()
        },
        close: { [weak self] in self?.close() }))
    self.panel = panel
    if let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
      panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 24))
    }
    CaptureWindows.shared.refresh()
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
  }

  func close() { panel?.orderOut(nil) }
}

struct DisplayChoice: Identifiable {
  let id: Int
  let name: String

  /// Connected displays, the main one first. ID 0 stands for "the main display".
  static var all: [DisplayChoice] {
    NSScreen.screens.enumerated().map { i, screen in
      let n = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
      return DisplayChoice(id: i == 0 ? 0 : n, name: i == 0 ? "\(screen.localizedName) (main)" : screen.localizedName)
    }
  }
}

struct RecordSetupView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var windows: CaptureWindows
  let start: () -> Void
  let close: () -> Void

  private var recordingWindow: Bool { settings.captureWindowID != 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("New Recording", systemImage: "record.circle").font(.headline).foregroundStyle(.primary)
        Spacer()
        Button(action: close) {
          Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close (Esc)")
      }

      HStack(spacing: 10) {
        sourceTile("Display", "display", selected: !recordingWindow) { settings.captureWindowID = 0 }
        sourceTile("Window", "macwindow", selected: recordingWindow) {
          if let first = windows.windows.first {
            settings.captureWindowID = first.id
            settings.captureWindowLabel = first.label
          }
        }
        .disabled(windows.windows.isEmpty)
      }

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          rowLabel(recordingWindow ? "Window" : "Display", recordingWindow ? "macwindow" : "display")
          if recordingWindow {
            CapturePicker(settings: settings, list: windows, showsDisplay: false).labelsHidden()
          } else {
            Picker("Display", selection: $settings.displayID) {
              ForEach(DisplayChoice.all) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
          }
        }
        GridRow {
          rowLabel("Microphone", "mic")
          Picker("Microphone", selection: settings.micSelection) {
            Text("System default").tag("")
            ForEach(AppSettings.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
          }
          .labelsHidden()
        }
        GridRow {
          rowLabel("Camera", "video")
          HStack {
            Toggle("Camera", isOn: $settings.useCamera).labelsHidden().toggleStyle(.switch).controlSize(.small)
            Picker("Camera", selection: $settings.cameraID) {
              ForEach(AppSettings.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .labelsHidden()
            .disabled(!settings.useCamera)
          }
        }
      }

      HStack {
        Text(settings.countdown > 0 ? "Starts after a \(settings.countdown)-second countdown." : "Starts right away.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(action: start) {
          Label("Start Recording", systemImage: "record.circle.fill").padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.recording)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .help("Or press ⌃⌥⌘R in any app")
      }
    }
    .padding(18)
    .frame(width: 520)
    .glassCard(cornerRadius: Theme.panelCorner)
  }

  private func rowLabel(_ text: String, _ symbol: String) -> some View {
    Label(text, systemImage: symbol).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
  }

  private func sourceTile(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 22, weight: .regular))
        Text(title).font(.callout.weight(.medium))
      }
      .frame(maxWidth: .infinity, minHeight: 64)
      .background(
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
          .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
          .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
