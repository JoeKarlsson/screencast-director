import AppKit
import DirectorCore
import SwiftUI

// The inspector's Camera tab, and the pickers it uses to aim zooms and frame the camera.
extension InspectorView {
  // MARK: Camera

  @ViewBuilder
  func cameraPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Camera")
    if let camera = plan.camera {
      InspectorSection("Split screen", detail: "The default; add Layout ranges on the timeline to switch for part of the video.") {
        layoutPicker(bind("defaultLayout", { $0.defaultLayout }, { $0.defaultLayout = $1 }), hasCamera: true)
      }
      InspectorSection("Framing", detail: "Drag to pick what stays centered; zoom in to reframe.") {
        CameraFramer(project: project, ui: ui)
        slider("Zoom", bind("camZoom", { $0.camera?.zoom ?? 1 }, { $0.camera?.zoom = ($1 * 20).rounded() / 20 }), 1...2.5, "\((plan.camera?.zoom ?? 1).formatted())×")
        Button(action: project.centerCameraOnFace) {
          Label("Center on My Face", systemImage: "face.smiling").frame(maxWidth: .infinity)
        }
      }
      InspectorSection(
        "Lip sync", detail: "Slide right if your lips move after you speak, left if before.", isOpen: fold("lipSync", open: false)
      ) {
        let offset = plan.camera?.offset ?? 0
        slider("Offset", bind("camOffset", { $0.camera?.offset ?? 0 }, { $0.camera?.offset = ($1 * 100).rounded() / 100 }), min(-1, offset)...max(1, offset), String(format: "%+.2f s", offset))
        Button(action: project.syncCameraToVoice) {
          Label("Sync to My Voice", systemImage: "waveform.and.person.filled").frame(maxWidth: .infinity)
        }
      }
      // The bubble only matters while a layout shows it; otherwise it starts folded.
      let showsBubble = plan.defaultLayout == .pip || plan.layouts.contains { $0.mode == .pip }
      InspectorSection(
        "Bubble", detail: "The camera while you demo. Drag it anywhere in the preview, or set it here.",
        isOpen: fold("bubble", open: showsBubble)
      ) {
        let cam = plan.camera
        let place = bubblePlacement(plan)
        slider(
          "Size", bind("bubbleSize", { $0.camera?.bubbleSize ?? Plan.Camera.defaultBubbleSize }, { $0.camera?.bubbleSize = ($1 * 100).rounded() / 100 }), 0.12...0.6, "\(Int((cam?.bubbleSize ?? Plan.Camera.defaultBubbleSize) * 100))%")
        slider("Across", Binding(get: { project.plan.map { bubblePlacement($0).x } ?? place.x }, set: { v in
          project.apply(coalesce: "bubbleMove") { p in
            let y = bubblePlacement(p).y
            p.camera?.bubbleX = (v * 1000).rounded() / 1000
            p.camera?.bubbleY = y
          }
        }), 0...1, "\(Int(place.x * 100))%")
        slider("Down", Binding(get: { project.plan.map { bubblePlacement($0).y } ?? place.y }, set: { v in
          project.apply(coalesce: "bubbleMove") { p in
            let x = bubblePlacement(p).x
            p.camera?.bubbleX = x
            p.camera?.bubbleY = (v * 1000).rounded() / 1000
          }
        }), 0...1, "\(Int(place.y * 100))%")
        LabeledContent("Corner") {
          HStack(spacing: 4) {
            ForEach(
              [("topLeft", "arrow.up.left"), ("topRight", "arrow.up.right"), ("bottomLeft", "arrow.down.left"), ("bottomRight", "arrow.down.right")],
              id: \.0
            ) { corner, symbol in
              Button {
                project.apply { p in
                  let c = bubbleCorner(corner, plan: p)
                  p.camera?.bubbleX = c.x
                  p.camera?.bubbleY = c.y
                }
              } label: { Image(systemName: symbol).frame(width: 22) }
              .help("Move the bubble to the \(corner.replacingOccurrences(of: "top", with: "top ").replacingOccurrences(of: "bottom", with: "bottom ").lowercased()) corner")
            }
          }
          .controlSize(.small)
        }
        toggle(
          "Cut out background", "Just you, with no shape around you.",
          bind(nil, { $0.camera?.cutout == true }, { $0.camera?.cutout = $1 ? true : nil }))
        // A cutout has no shape, border or shadow to set.
        if cam?.cutout != true {
          LabeledContent("Shape") {
            Picker("Shape", selection: bind(nil, { $0.camera?.bubbleShape ?? "circle" }, { $0.camera?.bubbleShape = $1 == "circle" ? nil : $1 })) {
              ForEach(Plan.Camera.shapes, id: \.name) { Text($0.label).tag($0.name) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          }
          toggle("Border", bind(nil, { $0.camera?.bubbleBorder != false }, { $0.camera?.bubbleBorder = $1 ? nil : false }))
          toggle("Shadow", bind(nil, { $0.camera?.bubbleShadow != false }, { $0.camera?.bubbleShadow = $1 ? nil : false }))
        }
        toggle(
          "Mirror", "Flip left to right, for a camera that records mirrored.",
          bind(nil, { $0.camera?.mirror == true }, { $0.camera?.mirror = $1 ? true : nil }))
      }
      InspectorSection("Color", detail: "Start from a preset, then fine-tune.") {
        FlowLayout(spacing: 6, lineSpacing: 6) {
          ForEach(Grade.presets, id: \.name) { preset in
            Button(preset.name) {
              project.apply { p in
                var g = preset.grade
                g.lut = p.camera?.grade?.lut
                p.camera?.grade = g
              }
            }
            .controlSize(.small)
            .help("Grade the camera with the \(preset.name) preset")
          }
        }
        DisclosureGroup("Fine-tune", isExpanded: fold("gradeFineTune", open: camera.grade != nil)) {
          VStack(alignment: .leading, spacing: 12) { gradeSliders(plan) }.padding(.top, 8)
        }
        .font(.callout)
      }
    } else {
      emptyState("video.slash", "No camera", "This recording has no camera video. Turn on \"Record camera\" in Settings for the next one.")
    }
  }

  /// The grade's sliders and LUT, under Color's Fine-tune.
  @ViewBuilder
  func gradeSliders(_ plan: Plan) -> some View {
    gradeSlider("Exposure", \.exposure, 0, -1...1, "%+.2f")
    gradeSlider("Highlights", \.highlights, 0, -1...0, "%+.2f")
    gradeSlider("Shadows", \.shadows, 0, -1...1, "%+.2f")
    gradeSlider("Contrast", \.contrast, 1, 0.7...1.4, "%.2f")
    gradeSlider("Saturation", \.saturation, 1, 0...1.6, "%.2f")
    gradeSlider("Vibrance", \.vibrance, 0, -1...1, "%+.2f")
    gradeSlider("Warmth", \.warmth, 0, -1...1, "%+.2f")
    LabeledContent("LUT") {
      Text(plan.camera?.grade?.lut.map { ($0 as NSString).lastPathComponent } ?? "None")
        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
      Button("Choose…") { project.chooseLUT() }
        .controlSize(.small).help("Choose a .cube LUT")
      if plan.camera?.grade?.lut != nil {
        Button("Remove") { project.apply { $0.camera?.grade?.lut = nil } }
          .controlSize(.small).help("Remove the LUT")
      }
    }
  }

  func gradeSlider(
    _ title: String, _ kp: WritableKeyPath<Grade, Double?>, _ neutral: Double, _ range: ClosedRange<Double>, _ fmt: String
  ) -> some View {
    let value = project.plan?.camera?.grade?[keyPath: kp] ?? neutral
    let binding = bind("grade\(title)", { $0.camera?.grade?[keyPath: kp] ?? neutral }) { p, v in
      var g = p.camera?.grade ?? Grade()
      g[keyPath: kp] = (v * 100).rounded() / 100
      p.camera?.grade = g
    }
    return slider(title, binding, range, String(format: fmt, value))
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
