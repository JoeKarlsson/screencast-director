import AppKit
import DirectorCore
import SwiftUI

final class InspectorUI: ObservableObject {
  enum Tab: String, CaseIterable { case selection = "Selection", style = "Style" }
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

struct InspectorView: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: InspectorUI

  var body: some View {
    VStack(spacing: 0) {
      Picker("", selection: $ui.tab) {
        ForEach(InspectorUI.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(10)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let plan = project.plan {
            if ui.tab == .selection { selectionPane(plan) } else { stylePane(plan) }
          } else {
            Text("Analyze the recording to start editing.").foregroundStyle(.secondary)
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 280, idealWidth: 300, maxWidth: 360)
    .onChange(of: project.selection) { _, sel in if sel != nil { ui.tab = .selection } }
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

  private func header(_ title: String, _ detail: String = "") -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.headline)
      if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
    }
  }

  // MARK: Selection

  @ViewBuilder
  private func selectionPane(_ plan: Plan) -> some View {
    switch project.selection {
    case .segment(let i) where plan.segments.indices.contains(i):
      let s = plan.segments[i]
      header("Clip", "\(fmtTime(s.start))–\(fmtTime(s.end)) of the recording, \(fmtTime((s.end - s.start) / s.speed)) in the video")
      Text("Speed").font(.subheadline)
      Picker("Speed", selection: bindItem("speed\(i)", \.segments, i, \.speed)) {
        ForEach([1.0, 1.5, 2, 3, 4, 8], id: \.self) { Text("\($0.formatted())×").tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Text("Faster than 1× plays without sound.").font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Split at Playhead", action: project.splitAtPlayhead)
        Button("Cut Clip", role: .destructive, action: project.deleteSelection)
      }
    case .gap(let g):
      header("Cut", "\(fmtTime(g.start))–\(fmtTime(g.end)) of the recording isn't in the video.")
      Button("Restore at 1×") { project.restore(g) }
    case .zoom(let i) where plan.zooms.indices.contains(i):
      let z = plan.zooms[i]
      header("Zoom", "\(fmtTime(z.start))–\(fmtTime(z.end)) of the recording")
      LabeledContent("Scale") {
        Slider(value: bindItem("zoomScale\(i)", \.zooms, i, \.scale) { ($0 * 10).rounded() / 10 }, in: 1.1...3)
        Text("\(z.scale.formatted())×").monospacedDigit().frame(width: 36)
      }
      Text("Focus: drag on the frame").font(.subheadline)
      FocusPicker(project: project, ui: ui, index: i, zoom: z)
      HStack {
        Button("Aim at Last Click") {
          let f = zoomFocus(at: z.start + 0.5, clicks: project.project?.clicks ?? [])
          project.apply {
            guard $0.zooms.indices.contains(i) else { return }
            $0.zooms[i].x = f.x
            $0.zooms[i].y = f.y
          }
        }
        Button("Remove", role: .destructive, action: project.deleteSelection)
      }
    case .layout(let i) where plan.layouts.indices.contains(i):
      let l = plan.layouts[i]
      header("Layout", "\(fmtTime(l.start))–\(fmtTime(l.end)) of the recording")
      layoutPicker(bindItem("layout\(i)", \.layouts, i, \.mode), hasCamera: plan.camera != nil)
      Button("Remove", role: .destructive, action: project.deleteSelection)
    case .callout(let i) where plan.callouts.indices.contains(i):
      header("Title", "\(fmtTime(plan.callouts[i].start))–\(fmtTime(plan.callouts[i].end)) of the recording")
      TextField("Title", text: bindItem("callout\(i)", \.callouts, i, \.text))
      Button("Remove", role: .destructive, action: project.deleteSelection)
    default:
      header("Nothing selected")
      VStack(alignment: .leading, spacing: 6) {
        Text("• Click a clip, zoom, layout or title on the timeline to edit it.")
        Text("• Drag a selected bar's white handles to trim it; drag zooms, layouts and titles to move them.")
        Text("• Click a dashed cut to restore it.")
        Text("• Screen Studio keys: Space plays, J/K/L shuttle, C splits, ⌫ removes, S changes speed, Z adds a zoom. ⌘/ lists them all.")
        Text("• ⌘Z undoes, including Claude's edits.")
        Text("• Or describe the edit in the Claude box under the timeline.")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  private func layoutPicker(_ binding: Binding<LayoutMode>, hasCamera: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("Layout", selection: binding) {
        ForEach(LayoutMode.allCases, id: \.self) { Text(modeName($0)).tag($0) }
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      .disabled(!hasCamera)
      if !hasCamera {
        Text("This recording has no camera. Turn on \"Record camera\" in Settings to use split screen and the camera bubble.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Style

  @ViewBuilder
  private func stylePane(_ plan: Plan) -> some View {
    header("Profile", "Branded look: background, frame, fonts, colors and logo.")
    Menu(plan.look?.name ?? "Built-in look") {
      ForEach(ProfileStore.shared.names, id: \.self) { name in
        Button(name) { project.applyProfile(name) }
      }
      Divider()
      Button("Save This Look as a Profile…") { ProfileStore.shared.promptSave(from: plan) }
      Button("Open Profiles Folder") { ProfileStore.shared.openFolder() }
    }
    .onAppear { ProfileStore.shared.refresh() }

    Divider()
    header("Sound", "Normalize brings your voice to a steady level; a limiter keeps peaks from clipping.")
    Toggle("Normalize voice", isOn: Binding(get: { plan.audio?.normalize ?? false }, set: { v in
      project.apply { p in
        var a = p.audio ?? AudioSettings()
        a.normalize = v
        p.audio = a
      }
    }))
    LabeledContent("Volume") {
      Slider(value: Binding(get: { project.plan?.audio?.gainDB ?? 0 }, set: { v in
        project.apply(coalesce: "gain") { p in
          var a = p.audio ?? AudioSettings()
          a.gainDB = (v * 2).rounded() / 2
          p.audio = a
        }
      }), in: -12...12)
      Text(String(format: "%+.1f dB", plan.audio?.gainDB ?? 0)).monospacedDigit().frame(width: 60, alignment: .trailing)
    }
    if (plan.audio?.normalize ?? false), !project.levels.isEmpty {
      Text(String(format: "Normalize adds %+.1f dB.", AudioGain.normalizeGain(project.levels)))
        .font(.caption).foregroundStyle(.secondary)
    }

    Divider()
    header("Pauses", "How hard to cut silence. Cuts that removed words always stay cut.")
    Picker("Pauses", selection: Binding(get: { plan.pauses ?? .normal }, set: { project.setPauses($0) })) {
      ForEach(PauseLevel.allCases, id: \.self) { Text($0.label).tag($0) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()

    Divider()
    header("Format")
    Picker("Shape", selection: Binding(get: { Aspect.of(plan.output) }, set: { project.setFormat(aspect: $0) })) {
      ForEach(Aspect.allCases, id: \.self) { Text($0.label).tag($0) }
    }
    Picker("Resolution", selection: Binding(get: { Resolution.of(plan.output) }, set: { project.setFormat(resolution: $0) })) {
      ForEach(Resolution.allCases, id: \.self) { Text($0.label).tag($0) }
    }
    Picker("Screen", selection: bind("screenAspect", { $0.style.screenAspect ?? 0 }, { $0.style.screenAspect = $1 == 0 ? nil : $1 })) {
      Text("Whole screen").tag(0.0)
      Text("Crop 4:3").tag(4.0 / 3)
      Text("Crop 5:4").tag(1.25)
      Text("Crop square").tag(1.0)
      Text("Crop 4:5").tag(0.8)
    }
    Text("\(plan.output.width)×\(plan.output.height). Cropped screens pan to follow zooms and clicks. The Export menu also renders other formats without changing this one.")
      .font(.caption).foregroundStyle(.secondary)

    if plan.camera != nil {
      Divider()
      header("Camera framing", "Drag to pick what stays centered; zoom in to reframe.")
      CameraFramer(project: project, ui: ui)
      LabeledContent("Zoom") {
        Slider(value: Binding(get: { project.plan?.camera?.zoom ?? 1 }, set: { v in
          project.apply(coalesce: "camZoom") { $0.camera?.zoom = (v * 20).rounded() / 20 }
        }), in: 1...2.5)
        Text("\((plan.camera?.zoom ?? 1).formatted())×").monospacedDigit().frame(width: 40)
      }
      Button("Center on My Face", action: project.centerCameraOnFace)

      Divider()
      header("Camera color")
      HStack {
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

    Divider()
    header("Split screen")
    layoutPicker(bind("defaultLayout", { $0.defaultLayout }, { $0.defaultLayout = $1 }), hasCamera: plan.camera != nil)
    Text("The default; add Layout ranges on the timeline to switch for part of the video.").font(.caption).foregroundStyle(.secondary)

    Divider()
    header("Background")
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 8), count: 4), spacing: 8) {
      ForEach(BackgroundPreset.all, id: \.name) { p in
        Button {
          project.apply { $0.style.background = p.colors }
        } label: {
          RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: p.colors.map(hexColor), startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 36)
            .overlay(
              RoundedRectangle(cornerRadius: 8).strokeBorder(
                plan.style.background == p.colors ? Color.accentColor : Color.white.opacity(0.15), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(p.name)
      }
    }
    HStack {
      ColorPicker("From", selection: bind("bg0", { hexColor($0.style.background.first ?? "#000000") }, { $0.style.background[0] = hexString($1) }))
      ColorPicker("To", selection: bind("bg1", { hexColor($0.style.background.last ?? "#000000") }, { $0.style.background[$0.style.background.count - 1] = hexString($1) }))
    }

    Divider()
    header("Frame")
    slider("Padding", bind("padding", { $0.style.padding }, { $0.style.padding = ($1 * 200).rounded() / 200 }), 0...0.15, "\(Int(plan.style.padding * 100))%")
    slider("Corners", bind("radius", { $0.style.radius }, { $0.style.radius = $1.rounded() }), 0...40, "\(Int(plan.style.radius))")
    slider("Zoom speed", bind("transition", { $0.style.transition }, { $0.style.transition = ($1 * 10).rounded() / 10 }), 0.3...1.6,
      "\(plan.style.transition.formatted()) s")

    Divider()
    header("Overlays")
    Toggle("Captions", isOn: bind("captions", { $0.captions.enabled }, { $0.captions.enabled = $1 }))
    Stepper("Words per caption: \(plan.captions.maxWords)", value: bind("maxWords", { $0.captions.maxWords }, { $0.captions.maxWords = $1 }), in: 3...14)
      .disabled(!plan.captions.enabled)
    Toggle("Click ripples", isOn: bind("ripples", { $0.clickRipples }, { $0.clickRipples = $1 }))
    Toggle("Shortcut labels (⌘K)", isOn: bind("chips", { $0.shortcutChips }, { $0.shortcutChips = $1 }))

    Divider()
    header("Frame rate")
    Picker("Frame rate", selection: bind("fps", { $0.output.fps }, { $0.output.fps = $1 })) {
      Text("30 fps").tag(30)
      Text("60 fps").tag(60)
    }
  }

  private func gradeSlider(
    _ title: String, _ kp: WritableKeyPath<Grade, Double?>, _ neutral: Double, _ range: ClosedRange<Double>, _ fmt: String
  ) -> some View {
    let value = project.plan?.camera?.grade?[keyPath: kp] ?? neutral
    return LabeledContent(title) {
      Slider(value: Binding(get: { project.plan?.camera?.grade?[keyPath: kp] ?? neutral }, set: { v in
        project.apply(coalesce: "grade\(title)") { p in
          var g = p.camera?.grade ?? Grade()
          g[keyPath: kp] = (v * 100).rounded() / 100
          p.camera?.grade = g
        }
      }), in: range)
      Text(String(format: fmt, value)).monospacedDigit().frame(width: 44, alignment: .trailing)
    }
  }

  private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ label: String) -> some View {
    LabeledContent(title) {
      Slider(value: value, in: range)
      Text(label).monospacedDigit().frame(width: 44, alignment: .trailing)
    }
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
