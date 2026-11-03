import AppKit
import DirectorCore
import SwiftUI

// The inspector's look tabs: background and frame, cursor and overlays, format and cards.
extension InspectorView {
  // MARK: Background & Frame

  @ViewBuilder
  func lookPane(_ plan: Plan) -> some View {
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
      if plan.style.padding == 0 {
        toggle(
          "Fill the frame", "Crop the screen so no background shows. It pans to follow zooms and clicks.",
          bind("fill", { $0.style.fill == true }, { $0.style.fill = $1 ? true : nil }))
      }
      slider("Corners", bind("radius", { $0.style.radius }, { $0.style.radius = $1.rounded() }), 0...40, "\(Int(plan.style.radius)) pt")
    }
    InspectorSection("Motion", detail: "One style for every move: how zooms ease and how titles come and go.") {
      MotionStyleGrid(selected: MotionStyle.named(plan.style.motion).name) { name in
        project.apply { $0.style.motion = name == "smooth" ? nil : name }
      }
      slider("Zoom speed", bind("transition", { $0.style.transition }, { $0.style.transition = ($1 * 10).rounded() / 10 }), 0.3...1.6,
        "\(plan.style.transition.formatted()) s")
    }
  }

  // MARK: Cursor & Overlays

  @ViewBuilder
  func overlaysPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Cursor & Overlays")
    InspectorSection("Cursor", detail: project.project?.source.cursorHidden == true
      ? "Drawn from your mouse moves, so it glides instead of jittering."
      : "This recording has the system cursor baked in. Record with the cursor hidden to restyle and smooth it.") {
      if project.project?.source.cursorHidden == true {
        toggle("Show cursor", bind(nil, { !($0.cursorSettings.hidden ?? false) }, { $0.cursorSettings.hidden = $1 ? nil : true }))
        slider("Size", bind("cursorSize", { $0.cursorSettings.size ?? 32 }, { $0.cursorSettings.size = $1.rounded() }), 16...72, "\(Int(plan.cursor?.size ?? 32)) pt")
        slider("Smoothing", bind("cursorSmoothing", { $0.cursorSettings.smoothing ?? 0.12 }, { $0.cursorSettings.smoothing = ($1 * 100).rounded() / 100 }), 0...0.4, String(format: "%.2f s", plan.cursor?.smoothing ?? 0.12))
      }
      toggle("Click ripples", "A ring where you click.", bind("ripples", { $0.clickRipples }, { $0.clickRipples = $1 }))
    }
    InspectorSection("Captions", detail: "Burned in from the transcript, in the profile's fonts.") {
      toggle("Captions", bind("captions", { $0.captions.enabled }, { $0.captions.enabled = $1 }))
      Picker("Style", selection: bind("captionStyle", { $0.captions.style ?? "pill" }, { $0.captions.style = $1 == "pill" ? nil : $1 })) {
        ForEach(Plan.Captions.styles, id: \.name) { Text($0.label).tag($0.name) }
      }
      .pickerStyle(.segmented)
      .disabled(!plan.captions.enabled)
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
  func formatPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Format", detail: "\(plan.output.width)×\(plan.output.height) at \(plan.output.fps) fps")
    InspectorSection("Shape", detail: "The Export menu also renders other formats without changing this one.") {
      LabeledContent("Shape") {
        Picker("Shape", selection: Binding(get: { project.plan.map { Aspect.of($0.output) } ?? Aspect.of(plan.output) }, set: { project.setFormat(aspect: $0) })) {
          ForEach(Aspect.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()
      }
      LabeledContent("Resolution") {
        Picker("Resolution", selection: Binding(get: { project.plan.map { Resolution.of($0.output) } ?? Resolution.of(plan.output) }, set: { project.setFormat(resolution: $0) })) {
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
  func cardControls(_ plan: Plan, _ kp: WritableKeyPath<Plan, Card?>, _ title: String) -> some View {
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
      slider("Length", bind("\(title)Length", { $0[keyPath: kp]?.seconds ?? Card.defaultDuration }, { $0[keyPath: kp]?.duration = ($1 * 10).rounded() / 10 }), 1...6, String(format: "%.1f s", plan[keyPath: kp]?.seconds ?? Card.defaultDuration))
    }
  }

  func cardText(_ kp: WritableKeyPath<Plan, Card?>, _ field: WritableKeyPath<Card, String?>) -> Binding<String> {
    bind("card\(kp.hashValue)\(field.hashValue)", { $0[keyPath: kp]?[keyPath: field] ?? "" }, { $0[keyPath: kp]?[keyPath: field] = $1 })
  }
}
