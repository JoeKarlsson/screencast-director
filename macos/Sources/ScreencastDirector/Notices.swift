import AppKit
import SwiftUI

/// Banners at the top of the main window, instead of modal alerts that stop the whole app.
/// Information fades after a few seconds; errors stay until closed.
final class Notices: ObservableObject {
  static let shared = Notices()

  struct Notice: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
    var actionLabel: String?
    var action: (() -> Void)?
  }

  @Published private(set) var current: Notice?
  private var dismissWork: DispatchWorkItem?

  func show(_ text: String, error: Bool = false, action: String? = nil, _ run: (() -> Void)? = nil) {
    current = Notice(text: text, isError: error, actionLabel: action, action: run)
    dismissWork?.cancel()
    guard !error else { return }
    let work = DispatchWorkItem { [weak self] in self?.current = nil }
    dismissWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 5 : 12), execute: work)
  }

  func show(_ error: Error, _ prefix: String? = nil) {
    show([prefix, error.localizedDescription].compactMap { $0 }.joined(separator: ": "), error: true)
  }

  func dismiss() { current = nil }
}

struct NoticeBanner: View {
  @ObservedObject var notices: Notices

  var body: some View {
    VStack {
      if let n = notices.current {
        HStack(spacing: 10) {
          Image(systemName: n.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .foregroundStyle(n.isError ? Color.orange : Color.green)
          Text(n.text).textSelection(.enabled).lineLimit(3).fixedSize(horizontal: false, vertical: true)
          if let label = n.actionLabel, let action = n.action {
            Button(label) {
              notices.dismiss()
              action()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          }
          Button(action: notices.dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .glassCard(cornerRadius: 14)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .transition(.move(edge: .top).combined(with: .opacity))
        .id(n.id)
      }
      Spacer()
    }
    .padding(.top, 10)
    .animation(.snappy, value: notices.current?.id)
  }
}

/// Runs an alert as a sheet on the main window when there is one, else on its own.
func presentAlert(_ alert: NSAlert, then done: @escaping (NSApplication.ModalResponse) -> Void) {
  if let window = AppDelegate.shared?.window, window.isVisible {
    alert.beginSheetModal(for: window, completionHandler: done)
  } else {
    done(alert.runModal())
  }
}
