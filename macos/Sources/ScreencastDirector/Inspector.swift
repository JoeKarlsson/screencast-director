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

  var body: some View {
    VStack(spacing: 0) {
      InspectorTabBar(ui: ui)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let plan = project.plan {
            pane(plan)
          } else {
            emptyState("waveform.badge.magnifyingglass", "Not analyzed yet", "Analyze the recording to start editing.")
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .labeledContentStyle(InspectorRowStyle())
    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
    .onChange(of: project.selection) { _, sel in if sel != nil { ui.tab = .selection } }
  }

  @ViewBuilder
  private func pane(_ plan: Plan) -> some View {
    switch ui.tab {
    case .selection: selectionPane(plan)
    case .style: lookPane(plan)
    case .camera: cameraPane(plan)
    case .audio: audioPane(plan)
    case .overlays: overlaysPane(plan)
    case .format: formatPane(plan)
    case .transcript:
      PaneTitle(title: "Transcript", detail: "Cut words are struck through; sped-up words are orange.")
      TranscriptView(project: project).card()
    }
  }

  /// A binding into the plan; every change is saved (slider drags coalesce into one undo step).
  private func bind<T>(_ key: String, _ get: @escaping (Plan) -> T, _ set: @escaping (inout Plan, T) -> Void) -> Binding<T> {
    // SwiftUI can read a binding after the plan changed under it; fall back to the value it was built with.
    let fallback = get(project.plan!)
    return Binding(
      get: { project.plan.map(get) ?? fallback },
      set: { v in project.apply(coalesce: key) { set(&$0, v) } })
  }

  /// A binding to one field of the i-th zoom, clip, layout or title. Bounds-checked: after an undo
  /// or delete removes that item, SwiftUI may still read the binding once before it redraws.
  private func bindItem<E, T>(
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

  // MARK: Rows

  private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ label: String) -> some View {
    LabeledContent(title) {
      Slider(value: value, in: range).controlSize(.small)
      Text(label).font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
    }
  }

  /// A switch on the right of a title (and an optional line under it).
  private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View { toggle(title, "", isOn) }

  private func toggle(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        if !detail.isEmpty {
          Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
  }

  private func emptyState(_ icon: String, _ title: String, _ detail: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(.tertiary)
        .padding(.bottom, 4)
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
  }

  // MARK: Selection

  /// The selected item's kind as a colored chip, its name, and its time range.
  private func itemHeader(_ kind: String, _ icon: String, _ color: Color, _ range: String) -> some View {
    HStack(spacing: 10) {
      KindChip(icon: icon, color: color)
      VStack(alignment: .leading, spacing: 1) {
        Text(kind).font(.title3.weight(.semibold))
        Text(range).font(.callout).monospacedDigit().foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }

  private func range(_ start: Double, _ end: Double) -> String { "\(fmtTime(start))–\(fmtTime(end))" }

  private func removeButton(_ title: String = "Remove") -> some View {
    Button(role: .destructive, action: project.deleteSelection) {
      Label(title, systemImage: "trash").frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private func selectionPane(_ plan: Plan) -> some View {
    switch project.selection {
    case .segment(let i) where plan.segments.indices.contains(i):
      let s = plan.segments[i]
      itemHeader("Clip", "film", Theme.clip, "\(range(s.start, s.end)) · \(fmtTime((s.end - s.start) / s.speed)) in the video")
      InspectorSection("Speed", detail: "Faster than 1× plays without sound.") {
        Picker("Speed", selection: bindItem("speed\(i)", \.segments, i, \.speed)) {
          ForEach([1.0, 1.5, 2, 3, 4, 8], id: \.self) { Text("\($0.formatted())×").tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      HStack(spacing: 8) {
        Button(action: project.splitAtPlayhead) { Label("Split at Playhead", systemImage: "scissors").frame(maxWidth: .infinity) }
        removeButton("Cut Clip")
      }
    case .gap(let g):
      itemHeader("Cut", "scissors", Color.gray, range(g.start, g.end))
      InspectorSection("Not in the video", detail: "This part of the recording is cut. Restore it to bring it back at normal speed.") {
        Button { project.restore(g) } label: { Label("Restore at 1×", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity) }
      }
    case .zoom(let i) where plan.zooms.indices.contains(i):
      let z = plan.zooms[i]
      itemHeader("Zoom", "plus.magnifyingglass", Theme.zoom, range(z.start, z.end))
      InspectorSection("Scale") {
        slider("Scale", bindItem("zoomScale\(i)", \.zooms, i, \.scale) { ($0 * 10).rounded() / 10 }, 1.1...3, "\(z.scale.formatted())×")
      }
      InspectorSection("Focus", detail: "Drag on the frame to aim the zoom. The box is what stays in view.") {
        FocusPicker(project: project, ui: ui, index: i, zoom: z)
        Button {
          let f = zoomFocus(at: z.start + 0.5, clicks: project.project?.clicks ?? [])
          project.apply {
            guard $0.zooms.indices.contains(i) else { return }
            $0.zooms[i].x = f.x
            $0.zooms[i].y = f.y
          }
        } label: {
          Label("Aim at Last Click", systemImage: "cursorarrow.click").frame(maxWidth: .infinity)
        }
      }
      removeButton()
    case .layout(let i) where plan.layouts.indices.contains(i):
      let l = plan.layouts[i]
      itemHeader("Layout", "rectangle.split.2x1", Theme.layout, range(l.start, l.end))
      InspectorSection("Layout", detail: "How the screen and camera share the frame for this range.") {
        layoutPicker(bindItem("layout\(i)", \.layouts, i, \.mode), hasCamera: plan.camera != nil)
      }
      removeButton()
    case .callout(let i) where plan.callouts.indices.contains(i):
      itemHeader("Title", "textformat", Theme.title, range(plan.callouts[i].start, plan.callouts[i].end))
      InspectorSection("Text") {
        TextField("Title", text: bindItem("callout\(i)", \.callouts, i, \.text)).textFieldStyle(.roundedBorder)
      }
      removeButton()
    default:
      nothingSelected
    }
  }

  private var nothingSelected: some View {
    VStack(alignment: .leading, spacing: 14) {
      emptyState("cursorarrow.click.2", "Nothing selected", "Click a clip, zoom, layout or title on the timeline to edit it.")
      InspectorSection("On the timeline") {
        tip("arrow.left.and.right", "Drag a selected bar's handles to trim it; drag zooms, layouts and titles to move them.")
        tip("scissors", "Click a dashed cut to restore it.")
        tip("sparkles", "Or describe the edit in the Claude box under the timeline.")
      }
      InspectorSection("Shortcuts") {
        shortcut(["Space"], "Play or pause")
        shortcut(["J", "K", "L"], "Shuttle back, stop, forward")
        shortcut(["C"], "Split at the playhead")
        shortcut(["⌫"], "Remove the selection")
        shortcut(["S"], "Change speed")
        shortcut(["Z"], "Add a zoom")
        shortcut(["⌘", "Z"], "Undo, including Claude's edits")
        shortcut(["⌘", "/"], "All shortcuts")
      }
    }
  }

  private func tip(_ icon: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
      Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func shortcut(_ keys: [String], _ text: String) -> some View {
    HStack(spacing: 10) {
      HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap($0) } }
        .frame(width: 78, alignment: .leading)
      Text(text).font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }

  /// The four layouts as icon tiles.
  private func layoutPicker(_ binding: Binding<LayoutMode>, hasCamera: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
        ForEach(LayoutMode.allCases, id: \.self) { mode in
          let on = binding.wrappedValue == mode
          Button {
            binding.wrappedValue = mode
          } label: {
            VStack(spacing: 5) {
              Image(systemName: layoutIcon(mode)).font(.system(size: 18))
              Text(modeName(mode)).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
      .disabled(!hasCamera)
      .opacity(hasCamera ? 1 : 0.5)
      if !hasCamera {
        Text("This recording has no camera. Turn on \"Record camera\" in Settings to use split screen and the camera bubble.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func layoutIcon(_ m: LayoutMode) -> String {
    switch m {
    case .screen: return "rectangle"
    case .pip: return "rectangle.inset.bottomtrailing.filled"
    case .side: return "rectangle.split.2x1"
    case .camera: return "person.crop.rectangle"
    }
  }

  // MARK: Background & Frame

  @ViewBuilder
  private func lookPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Background & Frame")
    InspectorSection("Profile", detail: "A branded look: background, frame, fonts, colors and logo.") {
      Menu {
        ForEach(ProfileStore.shared.names, id: \.self) { name in
          Button(name) { project.applyProfile(name) }
        }
        Divider()
        Button("Save This Look as a Profile…") { ProfileStore.shared.promptSave(from: plan) }
        Button("Open Profiles Folder") { ProfileStore.shared.openFolder() }
      } label: {
        Label(plan.look?.name ?? "Built-in look", systemImage: "paintbrush")
      }
      .onAppear { ProfileStore.shared.refresh() }
    }
    InspectorSection("Background", detail: "A gradient behind the screen.") {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
        ForEach(BackgroundPreset.all, id: \.name) { p in
          Button {
            project.apply { $0.style.background = p.colors }
          } label: {
            GradientSwatch(colors: p.colors.map(hexColor), selected: plan.style.background == p.colors)
          }
          .buttonStyle(.plain)
          .help(p.name)
          .accessibilityLabel(p.name)
        }
      }
      LabeledContent("Custom") {
        ColorPicker("From", selection: bind("bg0", { hexColor($0.style.background.first ?? "#000000") }, { $0.style.background[0] = hexString($1) }))
          .labelsHidden()
          .help("Top-left color")
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
        ColorPicker("To", selection: bind("bg1", { hexColor($0.style.background.last ?? "#000000") }, { $0.style.background[$0.style.background.count - 1] = hexString($1) }))
          .labelsHidden()
          .help("Bottom-right color")
      }
    }
    InspectorSection("Frame", detail: "Space around the screen and how round its corners are.") {
      slider("Padding", bind("padding", { $0.style.padding }, { $0.style.padding = ($1 * 200).rounded() / 200 }), 0...0.15, "\(Int(plan.style.padding * 100))%")
      slider("Corners", bind("radius", { $0.style.radius }, { $0.style.radius = $1.rounded() }), 0...40, "\(Int(plan.style.radius)) pt")
    }
    InspectorSection("Motion", detail: "How long the camera takes to zoom and pan.") {
      slider("Zoom speed", bind("transition", { $0.style.transition }, { $0.style.transition = ($1 * 10).rounded() / 10 }), 0.3...1.6,
        "\(plan.style.transition.formatted()) s")
    }
  }

  // MARK: Camera

  @ViewBuilder
  private func cameraPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Camera")
    if plan.camera != nil {
      InspectorSection("Framing", detail: "Drag to pick what stays centered; zoom in to reframe.") {
        CameraFramer(project: project, ui: ui)
        slider("Zoom", Binding(get: { project.plan?.camera?.zoom ?? 1 }, set: { v in
          project.apply(coalesce: "camZoom") { $0.camera?.zoom = (v * 20).rounded() / 20 }
        }), 1...2.5, "\((plan.camera?.zoom ?? 1).formatted())×")
        Button(action: project.centerCameraOnFace) {
          Label("Center on My Face", systemImage: "face.smiling").frame(maxWidth: .infinity)
        }
      }
      InspectorSection("Color", detail: "Start from a preset, then fine-tune.") {
        FlowLayout(spacing: 6, lineSpacing: 6) {
          ForEach(Grade.presets, id: \.name) { preset in
            Button(preset.name) { project.apply { $0.camera?.grade = preset.grade } }
              .controlSize(.small)
          }
        }
        gradeSlider("Exposure", \.exposure, 0, -1...1, "%+.2f")
        gradeSlider("Contrast", \.contrast, 1, 0.7...1.4, "%.2f")
        gradeSlider("Saturation", \.saturation, 1, 0...1.6, "%.2f")
        gradeSlider("Warmth", \.warmth, 0, -1...1, "%+.2f")
      }
    } else {
      emptyState("video.slash", "No camera", "This recording has no camera video. Turn on \"Record camera\" in Settings for the next one.")
    }
    InspectorSection("Split screen", detail: "The default; add Layout ranges on the timeline to switch for part of the video.") {
      layoutPicker(bind("defaultLayout", { $0.defaultLayout }, { $0.defaultLayout = $1 }), hasCamera: plan.camera != nil)
    }
  }

  private func gradeSlider(
    _ title: String, _ kp: WritableKeyPath<Grade, Double?>, _ neutral: Double, _ range: ClosedRange<Double>, _ fmt: String
  ) -> some View {
    let value = project.plan?.camera?.grade?[keyPath: kp] ?? neutral
    return slider(title, Binding(get: { project.plan?.camera?.grade?[keyPath: kp] ?? neutral }, set: { v in
      project.apply(coalesce: "grade\(title)") { p in
        var g = p.camera?.grade ?? Grade()
        g[keyPath: kp] = (v * 100).rounded() / 100
        p.camera?.grade = g
      }
    }), range, String(format: fmt, value))
  }

  // MARK: Audio

  @ViewBuilder
  private func audioPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Audio")
    InspectorSection("Voice", detail: "Normalize brings your voice to a steady level; a limiter keeps peaks from clipping.") {
      toggle("Normalize voice", (plan.audio?.normalize ?? false) && !project.levels.isEmpty
        ? String(format: "Adds %+.1f dB.", AudioGain.normalizeGain(project.levels)) : "",
        Binding(get: { plan.audio?.normalize ?? false }, set: { v in
          project.apply { p in
            var a = p.audio ?? AudioSettings()
            a.normalize = v
            p.audio = a
          }
        }))
      toggle("Clean up voice", "Removes room noise, hum and echo. The first time takes a few seconds.",
        Binding(get: { plan.audio?.cleanup ?? false }, set: { v in
          project.apply { p in
            var a = p.audio ?? AudioSettings()
            a.cleanup = v
            p.audio = a
          }
        }))
        .help("Removes room noise, hum and echo with Apple's voice isolation. The first time takes a few seconds.")
      slider("Volume", Binding(get: { project.plan?.audio?.gainDB ?? 0 }, set: { v in
        project.apply(coalesce: "gain") { p in
          var a = p.audio ?? AudioSettings()
          a.gainDB = (v * 2).rounded() / 2
          p.audio = a
        }
      }), -12...12, String(format: "%+.1f dB", plan.audio?.gainDB ?? 0))
    }
    InspectorSection("Music", detail: "A background track, looped to the video's length. It drops while you talk.") {
      if let music = plan.music {
        HStack(spacing: 8) {
          Image(systemName: "music.note").foregroundStyle(Theme.audio)
          Text((music.file as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 4)
          Button { project.apply { $0.music = nil } } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove the music")
            .accessibilityLabel("Remove")
        }
        slider("Volume", Binding(get: { project.plan?.music?.volumeDB ?? MusicDuck.defaultVolumeDB }, set: { v in
          project.apply(coalesce: "musicVolume") { p in p.music?.volumeDB = v.rounded() }
        }), -40...0, String(format: "%.0f dB", music.volumeDB ?? MusicDuck.defaultVolumeDB))
        slider("Under voice", Binding(get: { project.plan?.music?.duckDB ?? MusicDuck.defaultDuckDB }, set: { v in
          project.apply(coalesce: "musicDuck") { p in p.music?.duckDB = v.rounded() }
        }), -40...0, String(format: "%.0f dB", music.duckDB ?? MusicDuck.defaultDuckDB))
      } else {
        Button { pickMusic() } label: { Label("Add Music…", systemImage: "music.note.list").frame(maxWidth: .infinity) }
      }
    }
    InspectorSection("Pauses", detail: "How hard to cut silence. Cuts that removed words always stay cut.") {
      Picker("Pauses", selection: Binding(get: { plan.pauses ?? .normal }, set: { project.setPauses($0) })) {
        ForEach(PauseLevel.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  // MARK: Cursor & Overlays

  @ViewBuilder
  private func overlaysPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Cursor & Overlays")
    InspectorSection("Cursor", detail: project.project?.source.cursorHidden == true
      ? "Drawn from your mouse moves, so it glides instead of jittering."
      : "This recording has the system cursor baked in. Record with the cursor hidden to restyle and smooth it.") {
      if project.project?.source.cursorHidden == true {
        toggle("Show cursor", Binding(get: { !(plan.cursor?.hidden ?? false) }, set: { v in
          project.apply { p in
            var c = p.cursor ?? CursorSettings()
            c.hidden = v ? nil : true
            p.cursor = c
          }
        }))
        slider("Size", Binding(get: { project.plan?.cursor?.size ?? 32 }, set: { v in
          project.apply(coalesce: "cursorSize") { p in
            var c = p.cursor ?? CursorSettings()
            c.size = v.rounded()
            p.cursor = c
          }
        }), 16...72, "\(Int(plan.cursor?.size ?? 32)) pt")
        slider("Smoothing", Binding(get: { project.plan?.cursor?.smoothing ?? 0.12 }, set: { v in
          project.apply(coalesce: "cursorSmoothing") { p in
            var c = p.cursor ?? CursorSettings()
            c.smoothing = (v * 100).rounded() / 100
            p.cursor = c
          }
        }), 0...0.4, String(format: "%.2f s", plan.cursor?.smoothing ?? 0.12))
      }
      toggle("Click ripples", "A ring where you click.", bind("ripples", { $0.clickRipples }, { $0.clickRipples = $1 }))
    }
    InspectorSection("Captions", detail: "Burned in from the transcript, in the profile's fonts.") {
      toggle("Captions", bind("captions", { $0.captions.enabled }, { $0.captions.enabled = $1 }))
      LabeledContent("Words") {
        Text("\(plan.captions.maxWords) per caption").monospacedDigit()
        Spacer(minLength: 0)
        Stepper("Words per caption", value: bind("maxWords", { $0.captions.maxWords }, { $0.captions.maxWords = $1 }), in: 3...14)
          .labelsHidden()
      }
      .disabled(!plan.captions.enabled)
    }
    InspectorSection("Keyboard") {
      toggle("Shortcut labels", "Shows chips like ⌘K when you press a shortcut.", bind("chips", { $0.shortcutChips }, { $0.shortcutChips = $1 }))
    }
  }

  // MARK: Format

  @ViewBuilder
  private func formatPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Format", detail: "\(plan.output.width)×\(plan.output.height) at \(plan.output.fps) fps")
    InspectorSection("Shape", detail: "The Export menu also renders other formats without changing this one.") {
      LabeledContent("Shape") {
        Picker("Shape", selection: Binding(get: { Aspect.of(plan.output) }, set: { project.setFormat(aspect: $0) })) {
          ForEach(Aspect.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()
      }
      LabeledContent("Resolution") {
        Picker("Resolution", selection: Binding(get: { Resolution.of(plan.output) }, set: { project.setFormat(resolution: $0) })) {
          ForEach(Resolution.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()
      }
      LabeledContent("Frame rate") {
        Picker("Frame rate", selection: bind("fps", { $0.output.fps }, { $0.output.fps = $1 })) {
          Text("30 fps").tag(30)
          Text("60 fps").tag(60)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
    }
    InspectorSection("Screen crop", detail: "Cropped screens pan to follow zooms and clicks.") {
      LabeledContent("Screen") {
        Picker("Screen", selection: bind("screenAspect", { $0.style.screenAspect ?? 0 }, { $0.style.screenAspect = $1 == 0 ? nil : $1 })) {
          Text("Whole screen").tag(0.0)
          Text("Crop 4:3").tag(4.0 / 3)
          Text("Crop 5:4").tag(1.25)
          Text("Crop square").tag(1.0)
          Text("Crop 4:5").tag(0.8)
        }
        .labelsHidden()
      }
    }
    InspectorSection("Intro and outro", detail: "Full-frame title cards in the profile's fonts and colors. A profile can switch them on for every video.") {
      cardControls(plan, \.intro, "Intro card")
      Divider()
      cardControls(plan, \.outro, "Outro card")
    }
  }

  @ViewBuilder
  private func cardControls(_ plan: Plan, _ kp: WritableKeyPath<Plan, Card?>, _ title: String) -> some View {
    let intro = kp == \Plan.intro
    toggle(title, Binding(get: { project.plan?[keyPath: kp]?.isOn ?? false }, set: { v in
      let name = project.name
      project.apply { p in
        // First switch-on: the profile's card, else the recording's name over your name.
        let fromLook = (intro ? p.look?.intro : p.look?.outro)?.resolved(name: name)
        var c = p[keyPath: kp] ?? fromLook ?? (intro ? Card(title: name, subtitle: NSFullUserName()) : Card(title: "Thanks for watching"))
        c.enabled = v
        p[keyPath: kp] = c
      }
    }))
    if plan[keyPath: kp]?.isOn == true {
      TextField("Title", text: cardText(kp, \.title)).textFieldStyle(.roundedBorder)
      TextField("Subtitle", text: cardText(kp, \.subtitle)).textFieldStyle(.roundedBorder)
      slider("Length", Binding(get: { project.plan?[keyPath: kp]?.seconds ?? Card.defaultDuration }, set: { v in
        project.apply(coalesce: "\(title)Length") { $0[keyPath: kp]?.duration = (v * 10).rounded() / 10 }
      }), 1...6, String(format: "%.1f s", plan[keyPath: kp]?.seconds ?? Card.defaultDuration))
    }
  }

  private func cardText(_ kp: WritableKeyPath<Plan, Card?>, _ field: WritableKeyPath<Card, String?>) -> Binding<String> {
    Binding(
      get: { project.plan?[keyPath: kp]?[keyPath: field] ?? "" },
      set: { v in project.apply(coalesce: "card\(kp.hashValue)\(field.hashValue)") { $0[keyPath: kp]?[keyPath: field] = v } })
  }

  /// Copies the chosen track into the project folder, so the project still plays if the original moves.
  private func pickMusic() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
    panel.message = "Choose a background track"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var name = url.lastPathComponent
    if url.deletingLastPathComponent().standardizedFileURL != project.dir.standardizedFileURL {
      // Never overwrite a project file (or an earlier track) that happens to share the name.
      var n = 1
      while FileManager.default.fileExists(atPath: project.dir.appendingPathComponent(name).path) {
        n += 1
        name = "\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)"
      }
      do {
        try FileManager.default.copyItem(at: url, to: project.dir.appendingPathComponent(name))
      } catch {
        Notices.shared.show(error)
        return
      }
    }
    project.apply { p in p.music = Music(file: name) }
  }
}

/// A frame of the raw recording at the zoom's start; drag to aim the zoom. The box shows what will be in view.
struct FocusPicker: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: InspectorUI
  let index: Int
  let zoom: Zoom

  var body: some View {
    let aspect = (project.plan?.source.width ?? 16) / (project.plan?.source.height ?? 9)
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      let vw = w / zoom.scale, vh = h / zoom.scale
      let cx = min(max(zoom.x * w, vw / 2), w - vw / 2)
      let cy = min(max(zoom.y * h, vh / 2), h - vh / 2)
      ZStack(alignment: .topLeading) {
        if let img = ui.thumbnail {
          Image(nsImage: img).resizable().frame(width: w, height: h)
        } else {
          Rectangle().fill(Color.black)
        }
        Rectangle().fill(Color.black.opacity(0.35)).frame(width: w, height: h)
          .mask(
            Rectangle().overlay(Rectangle().frame(width: vw, height: vh).position(x: cx, y: cy).blendMode(.destinationOut))
              .compositingGroup())
        Rectangle().strokeBorder(Color.white, lineWidth: 2).frame(width: vw, height: vh).position(x: cx, y: cy)
        Circle().fill(Color.purple).overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
          .frame(width: 12, height: 12).position(x: zoom.x * w, y: zoom.y * h)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { v in
          let x = (min(max(v.location.x / w, 0), 1) * 1000).rounded() / 1000
          let y = (min(max(v.location.y / h, 0), 1) * 1000).rounded() / 1000
          project.apply(coalesce: "focus\(index)") {
            guard $0.zooms.indices.contains(index) else { return }
            $0.zooms[index].x = x
            $0.zooms[index].y = y
          }
        })
    }
    .aspectRatio(aspect, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .onAppear(perform: load)
    .onChange(of: zoom.start) { _, _ in load() }
  }

  private func load() {
    let t = zoom.start + min(0.5, (zoom.end - zoom.start) / 2)
    guard abs(ui.thumbnailFor - t) > 0.01 else { return }
    ui.thumbnailFor = t
    project.thumbnail(at: t) { img in ui.thumbnail = img }
  }
}

/// A frame of the camera video with the framing point; drag to move it.
struct CameraFramer: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: InspectorUI

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width, h = geo.size.height
      let x = project.plan?.camera?.x ?? 0.5, y = project.plan?.camera?.y ?? 0.5
      ZStack(alignment: .topLeading) {
        if let img = ui.cameraThumbnail {
          Image(nsImage: img).resizable().frame(width: w, height: h)
        } else {
          Rectangle().fill(Color.black)
        }
        Circle().strokeBorder(Color.white, lineWidth: 2).frame(width: 18, height: 18).position(x: x * w, y: y * h)
        Circle().fill(Color.white).frame(width: 4, height: 4).position(x: x * w, y: y * h)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { v in
          let nx = (min(max(v.location.x / w, 0), 1) * 1000).rounded() / 1000
          let ny = (min(max(v.location.y / h, 0), 1) * 1000).rounded() / 1000
          project.apply(coalesce: "camFocus") {
            $0.camera?.x = nx
            $0.camera?.y = ny
          }
        })
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .onAppear { if ui.cameraThumbnail == nil { project.cameraThumbnail { ui.cameraThumbnail = $0 } } }
  }
}
