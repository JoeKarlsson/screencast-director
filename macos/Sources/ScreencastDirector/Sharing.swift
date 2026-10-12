import AppKit
import DirectorCore
import SwiftUI

/// Settings > Sharing: an S3-compatible bucket (AWS, MinIO, R2, B2) for "Upload and Copy Link".
/// Endpoint, bucket and public URL live in UserDefaults; the keys live in the Keychain.
final class SharingSettings: ObservableObject {
  static let shared = SharingSettings()
  private let d = UserDefaults.standard

  @Published var endpoint: String { didSet { d.set(endpoint, forKey: "s3Endpoint") } }
  @Published var region: String { didSet { d.set(region, forKey: "s3Region") } }
  @Published var bucket: String { didSet { d.set(bucket, forKey: "s3Bucket") } }
  @Published var publicBase: String { didSet { d.set(publicBase, forKey: "s3PublicBase") } }

  init() {
    endpoint = d.string(forKey: "s3Endpoint") ?? ""
    region = d.string(forKey: "s3Region") ?? "us-east-1"
    bucket = d.string(forKey: "s3Bucket") ?? ""
    publicBase = d.string(forKey: "s3PublicBase") ?? ""
  }

  var accessKey: String {
    get { Keychain.get("s3-access-key") ?? "" }
    set {
      if newValue.isEmpty { Keychain.delete("s3-access-key") } else { Keychain.set(newValue, for: "s3-access-key") }
      objectWillChange.send()
    }
  }
  var secretKey: String {
    get { Keychain.get("s3-secret-key") ?? "" }
    set {
      if newValue.isEmpty { Keychain.delete("s3-secret-key") } else { Keychain.set(newValue, for: "s3-secret-key") }
      objectWillChange.send()
    }
  }

  /// nil until endpoint, bucket and both keys are filled in.
  var config: S3.Config? {
    guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespaces)), url.scheme != nil, !bucket.isEmpty,
      !accessKey.isEmpty, !secretKey.isEmpty
    else { return nil }
    return S3.Config(
      endpoint: url, region: region.isEmpty ? "us-east-1" : region, bucket: bucket, accessKey: accessKey, secretKey: secretKey,
      publicBase: publicBase.isEmpty ? nil : publicBase)
  }

  /// A filled-in endpoint that isn't https (shown as a warning; uploads still work).
  var insecure: Bool {
    let e = endpoint.trimmingCharacters(in: .whitespaces).lowercased()
    return !e.isEmpty && !e.hasPrefix("https://")
  }
}

struct SharingSection: View {
  @ObservedObject var sharing = SharingSettings.shared

  var body: some View {
    Section("Sharing") {
      TextField("Endpoint", text: $sharing.endpoint, prompt: Text("http://192.168.0.202:9000"))
      if sharing.insecure {
        Label("This endpoint isn't HTTPS: keys are signed, but uploads and links travel unencrypted. Fine on a home network, not on public Wi-Fi.", systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      }
      TextField("Region", text: $sharing.region)
      TextField("Bucket", text: $sharing.bucket)
      SecureField("Access key", text: Binding(get: { sharing.accessKey }, set: { sharing.accessKey = $0 }))
      SecureField("Secret key", text: Binding(get: { sharing.secretKey }, set: { sharing.secretKey = $0 }))
      TextField("Public URL", text: $sharing.publicBase, prompt: Text("https://media.example.com (blank: endpoint/bucket)"))
      Text("Any S3-compatible store: MinIO, AWS S3, Cloudflare R2, Backblaze B2. Keys are stored in your Keychain. **Upload and Copy Link** in the Export menu puts a file here and copies its public link.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

extension ProjectModel {
  /// The output range (seconds) of the selected clip, zoom or title, or nil for the whole video.
  var selectedOutputRange: (Double, Double)? {
    guard let plan, let selection else { return nil }
    let fps = Double(plan.output.fps)
    func range(_ a: Double, _ b: Double) -> (Double, Double) {
      (srcToOutClamped(mapped, a, fps: plan.output.fps) / fps, srcToOutClamped(mapped, b, fps: plan.output.fps, before: true) / fps)
    }
    switch selection {
    case .segment(let i) where plan.segments.indices.contains(i): return range(plan.segments[i].start, plan.segments[i].end)
    case .zoom(let i) where plan.zooms.indices.contains(i): return range(plan.zooms[i].start, plan.zooms[i].end)
    case .callout(let i) where plan.callouts.indices.contains(i): return range(plan.callouts[i].start, plan.callouts[i].end)
    case .annotation(let i) where plan.annotationList.indices.contains(i):
      return range(plan.annotationList[i].start, plan.annotationList[i].end)
    default: return nil
    }
  }

  /// Export > GIF (for docs): asks for a range (the selection, else the whole video) and writes a
  /// 720 px, 12 fps GIF next to the recording.
  func exportGIF() {
    guard let plan else { return }
    let total = Double(totalOutFrames) / Double(fps)
    let (a0, b0) = selectedOutputRange ?? (0, total)
    let alert = NSAlert()
    alert.messageText = "Export a GIF"
    alert.informativeText = "Output seconds (\(fmtTime(total)) in all). Long GIFs get big: 10 to 20 s is plenty for docs."
    func field(_ v: Double) -> NSTextField {
      let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
      f.stringValue = String(format: "%.1f", v)
      return f
    }
    let from = field(a0), to = field(b0)
    let width = NSPopUpButton(frame: .zero, pullsDown: false)
    width.addItems(withTitles: ["720 px", "640 px", "480 px"])
    let row = NSStackView(views: [NSTextField(labelWithString: "From"), from, NSTextField(labelWithString: "to"), to, width])
    row.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
    alert.accessoryView = row
    alert.addButton(withTitle: "Export GIF")
    alert.addButton(withTitle: "Cancel")
    presentAlert(alert) { [self] response in
      guard response == .alertFirstButtonReturn, let a = Double(from.stringValue), let b = Double(to.stringValue), b > a else { return }
      makeGIF(plan: plan, from: a, to: b, width: [720, 640, 480][max(0, width.indexOfSelectedItem)])
    }
  }

  private func makeGIF(plan: Plan, from a: Double, to b: Double, width px: Int) {
    let url = dir.appendingPathComponent(String(format: "%@ %.1f-%.1f.gif", name, a, b))
    let project = self.project
    run("Making a GIF…") { [self] in
      guard let project else { return }
      let built = try await buildComposition(project: project, plan: plan)
      let frames = try await GIF.export(built, to: url, options: GIF.Options(from: a, to: b, width: px, fps: 12)) { p in
        Task { @MainActor in self.status = "Making a GIF… \(Int(p * 100))%" }
      }
      let mb = Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1e6
      status = String(format: "Wrote %@ (%d frames, %.1f MB)", url.lastPathComponent, frames, mb)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  /// Export > Upload and Copy Link: picks a file from the recording's folder (an export, a GIF,
  /// a thumbnail), uploads it to the Sharing bucket and puts the public link on the clipboard.
  func uploadAndCopyLink() {
    guard let config = SharingSettings.shared.config else {
      Notices.shared.show("Set up a bucket in Settings > Sharing first.", action: "Open Settings") {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
      }
      return
    }
    let panel = NSOpenPanel()
    panel.directoryURL = FileManager.default.fileExists(atPath: outURL.path) ? outURL : dir
    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .gif, .png, .jpeg]
    panel.message = "Choose a file to upload and share"
    let window = AppDelegate.shared?.window
    let chosen: (NSApplication.ModalResponse) -> Void = { [self] response in
      guard response == .OK, let file = panel.url else { return }
      upload(file, config: config)
    }
    if let window { panel.beginSheetModal(for: window, completionHandler: chosen) } else { chosen(panel.runModal()) }
  }

  private func upload(_ file: URL, config: S3.Config) {
    let key = S3.key(for: file, name: "\(name) \(file.deletingPathExtension().lastPathComponent)")
    run("Uploading \(file.lastPathComponent)…") { [self] in
      let link = try await S3.upload(file, key: key, config: config)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(link.absoluteString, forType: .string)
      status = "Link copied: \(link.absoluteString)"
    }
  }
}
