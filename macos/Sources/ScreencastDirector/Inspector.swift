import AppKit
import DirectorCore
import SwiftUI

final class InspectorUI: ObservableObject {
  /// The icon tabs. `style` is the look (background, frame, profile); ⌘1 opens it.
  enum Tab: String, CaseIterable {
    case selection, style, camera, audio, overlays, format, transcript

    var title: String {
      switch self {
      case .selection: return "Selection"
      case .style: return "Background & Frame"
      case .camera: return "Camera"
      case .audio: return "Audio"
      case .overlays: return "Cursor & Overlays"
      case .format: return "Format"
      case .transcript: return "Transcript"
      }
    }

    var icon: String {
      switch self {
      case .selection: return "cursorarrow.rays"
      case .style: return "paintpalette"
      case .camera: return "person.crop.square"
      case .audio: return "waveform"
      case .overlays: return "cursorarrow.motionlines"
      case .format: return "aspectratio"
      case .transcript: return "text.quote"
      }
    }
  }
  @Published var tab: Tab = .selection
  /// Folded sections the user opened or closed, by key; the rest use their default (see `fold`).
  @Published var folds: [String: Bool] = [:]
  /// An app typed into an animation's app list, before Return adds it.
  @Published var newAnimationApp = ""
  @Published var showSoundPicker = false
  @Published var showMusicPicker = false
  /// The library picker for the selected title's or mark's own sound.
  @Published var showItemSoundPicker = false
  /// The open picker's library, loaded when it opens (so new files in My Sounds or My Music show up).
  var pickerEntries: [AudioLibrary.Entry] = []
  let audioPreview = AudioPreview()
  @Published var thumbnail: NSImage?
  @Published var cameraThumbnail: NSImage?
  var thumbnailFor: Double = -1
}

struct BackgroundPreset {
  let name: String
  let colors: [String]
  static let all = [
    BackgroundPreset(name: "Dusk", colors: ["#1d2b64", "#f8cdda"]),
    BackgroundPreset(name: "Ocean", colors: ["#0f2027", "#2c7da0"]),
    BackgroundPreset(name: "Sunset", colors: ["#ee9ca7", "#ffdde1"]),
    BackgroundPreset(name: "Forest", colors: ["#134e5e", "#71b280"]),
    BackgroundPreset(name: "Ember", colors: ["#3a1c71", "#ffaf7b"]),
    BackgroundPreset(name: "Graphite", colors: ["#232526", "#5b5f63"]),
    BackgroundPreset(name: "Snow", colors: ["#e6e9f0", "#eef1f5"]),
    BackgroundPreset(name: "Lime", colors: ["#1e3c2b", "#c6ea8d"]),
  ]
}

func hexColor(_ hex: String) -> Color {
  var s = hex.trimmingCharacters(in: .whitespaces)
  if s.hasPrefix("#") { s.removeFirst() }
  let v = UInt32(s, radix: 16) ?? 0
  return Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

func hexString(_ color: Color) -> String {
  guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
  return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

/// The editor's right-hand column: icon tabs over a scrolling pane of cards. Views.swift hosts it
/// in SwiftUI's inspector column, so it sets the column width, not a frame.
struct InspectorView: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: InspectorUI
  let transcriptUI: TranscriptUI

  var body: some View {
    VStack(spacing: 0) {
      InspectorTabBar(ui: ui)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
          if let plan = project.plan {
            pane(plan)
          } else {
            emptyState("waveform.badge.magnifyingglass", "Not analyzed yet", "Analyze the recording to start editing.")
            Button { project.analyzeAndPlan() } label: { Label("Analyze", systemImage: "wand.and.stars") }
              .buttonStyle(.borderedProminent)
              .disabled(project.busy)
              .frame(maxWidth: .infinity)
          }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .labeledContentStyle(InspectorRowStyle())
    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
    .onChange(of: project.selection) { _, sel in if sel != nil { ui.tab = .selection } }
  }

  @ViewBuilder
  func pane(_ plan: Plan) -> some View {
    switch ui.tab {
    case .selection: selectionPane(plan)
    case .style: lookPane(plan)
    case .camera: cameraPane(plan)
    case .audio: audioPane(plan)
    case .overlays: overlaysPane(plan)
    case .format: formatPane(plan)
    case .transcript:
      PaneTitle(title: "Transcript", detail: "Cut words are struck through; sped-up words are orange. ⌥⌘T opens it beside the preview.")
      TranscriptView(project: project, playhead: project.playhead, ui: transcriptUI).card()
    }
  }

  /// A binding into the plan; every change is saved. Changes with the same `key` coalesce into one
  /// undo step (slider drags); a nil key (toggles, pickers) makes each change its own step.
  func bind<T>(_ key: String?, _ get: @escaping (Plan) -> T, _ set: @escaping (inout Plan, T) -> Void) -> Binding<T> {
    // SwiftUI can read a binding after the plan changed under it; fall back to the value it was built with.
    let fallback = get(project.plan!)
    return Binding(
      get: { project.plan.map(get) ?? fallback },
      set: { v in project.apply(coalesce: key) { set(&$0, v) } })
  }

  /// A binding to one field of the i-th zoom, clip, layout or title. Bounds-checked: after an undo
  /// or delete removes that item, SwiftUI may still read the binding once before it redraws.
  func bindItem<E, T>(
    _ key: String, _ list: WritableKeyPath<Plan, [E]>, _ i: Int, _ field: WritableKeyPath<E, T>, map: @escaping (T) -> T = { $0 }
  ) -> Binding<T> {
    let fallback = project.plan![keyPath: list][i][keyPath: field]
    return Binding(
      get: {
        guard let p = project.plan, p[keyPath: list].indices.contains(i) else { return fallback }
        return p[keyPath: list][i][keyPath: field]
      },
      set: { v in
        project.apply(coalesce: key) { p in
          guard p[keyPath: list].indices.contains(i) else { return }
          p[keyPath: list][i][keyPath: field] = map(v)
        }
      })
  }

  /// `bindItem` for an optional field: reads `fallback` while it's unset, and writes what `store`
  /// makes of the new value (nil clears the field).
  func bindItem<E, T>(
    _ key: String, _ list: WritableKeyPath<Plan, [E]>, _ i: Int, _ field: WritableKeyPath<E, T?>, or fallback: T,
    store: @escaping (T) -> T? = { $0 }
  ) -> Binding<T> {
    let item = bindItem(key, list, i, field)
    return Binding(get: { item.wrappedValue ?? fallback }, set: { item.wrappedValue = store($0) })
  }

  /// Whether a foldable section is open: what the user last chose, else `open`, which a section sets
  /// from whether it matters for this video (a bubble nothing shows starts closed).
  func fold(_ key: String, open: Bool) -> Binding<Bool> {
    Binding(get: { ui.folds[key] ?? open }, set: { ui.folds[key] = $0 })
  }

  /// For text fields over optional strings: an emptied field clears the value.
  func emptyAsNil(_ s: String) -> String? { s.isEmpty ? nil : s }

  // MARK: Rows

  func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ label: String) -> some View {
    LabeledContent(title) {
      Slider(value: value, in: range).controlSize(.small)
      Text(label).font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
    }
  }

  /// A switch on the right of a title (and an optional line under it).
  func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View { toggle(title, "", isOn) }

  func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
    HStack(spacing: Theme.Space.m) {
      Text(title)
      Spacer(minLength: 8)
      Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
    .help(detail)
  }

  func emptyState(_ icon: String, _ title: String, _ detail: String) -> some View {
    VStack(spacing: Theme.Space.s) {
      Image(systemName: icon)
        .font(Theme.glyph(34, .light))
        .foregroundStyle(.tertiary)
        .padding(.bottom, Theme.Space.xs)
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Theme.Space.xl)
  }
}
