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
    InspectorSection("Background", detail: "The color behind the screen.") {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: 4), spacing: Theme.Space.s) {
        ForEach(BackgroundPreset.all, id: \.name) { p in
          Button {
            project.apply { $0.style.background = p.colors }
          } label: {
            ColorSwatch(color: hexColor(p.colors[0]), selected: plan.style.background == p.colors)
          }
          .buttonStyle(.plain)
          .help(p.name)
          .accessibilityLabel(p.name)
        }
      }
      LabeledContent("Custom") {
        ColorPicker("Color", selection: bind("bg0", { hexColor($0.style.background.first ?? "#000000") }, { $0.style.background = [hexString($1)] }))
          .labelsHidden()
          .help("Background color")
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
      LabeledContent("Style") {
        ChoiceRow(
          [("none", "Plain", "No frame"), ("brackets", "Brackets", "Brackets draw corners around the screen"),
           ("window", "Window", "Window gives the screen a title bar")],
          selection: lookValue(nil, \.frame, "none"))
      }
      LabeledContent("Accent") {
        ColorPicker("Accent", selection: lookColor("accent", \.accent, "#FFE500")).labelsHidden()
          .help("Click ripples, brackets and highlights")
        Spacer(minLength: 0)
      }
    }
    logoSection(plan)
    effectsSection(plan)
    InspectorSection("Titles & chips", detail: "Fonts and colors for titles, chapter cards and shortcut chips.", isOpen: fold("titles", open: false)) {
      fontPicker("Title font", \.titleFont, plan)
      fontPicker("Chip font", \.chipFont, plan)
      Button("Add Font File…") { project.chooseFontFile() }
        .help("Copy a .ttf or .otf into this video so its fonts can be picked")
      LabeledContent("Titles") {
        ColorPicker("Title text", selection: lookColor("titleText", \.titleText, "#ffffff")).labelsHidden().help("Title text")
        ColorPicker("Title panel", selection: lookColor("titleBG", \.titleBackground, "#0f0f14")).labelsHidden().help("Title panel")
        Spacer(minLength: 0)
      }
      LabeledContent("Chips") {
        ColorPicker("Chip text", selection: lookColor("chipText", \.chipText, "#ffffff")).labelsHidden().help("Chip text")
        ColorPicker("Chip box", selection: lookColor("chipBG", \.chipBackground, "#0f0f14")).labelsHidden().help("Chip box")
        Spacer(minLength: 0)
      }
      if plan.camera != nil {
        LabeledContent("Camera") {
          ColorPicker("Camera border", selection: lookColor("camBorder", \.cameraBorder, "#ffffff")).labelsHidden()
            .help("The camera bubble's border")
          Spacer(minLength: 0)
        }
      }
    }
    InspectorSection("Motion", detail: "One style for every move: how zooms ease and how titles come and go.") {
      MotionStyleGrid(selected: MotionStyle.named(plan.style.motion).name) { name in
        project.apply { $0.style.motion = name == "smooth" ? nil : name }
      }
      slider("Zoom speed", bind("transition", { $0.style.transition }, { $0.style.transition = ($1 * 10).rounded() / 10 }), 0.3...1.6,
        "\(plan.style.transition.formatted()) s")
      MotionPicker(
        title: "B-roll", motion: bind("brollMotion", { $0.style.brollMotion }, { $0.style.brollMotion = $1 }),
        fallback: Motion(preset: "none"), defaultTitle: "Default"
      )
      .help("How B-roll and animations without their own motion come and go")
      LabeledContent("Animations") {
        ChoiceRow(
          [("", "Paper", "Paper collage animations (changing the theme re-renders them)"),
           ("terminal", "Terminal", "Terminal animations (changing the theme re-renders them)"),
           ("zine", "Zine", "Zine animations (changing the theme re-renders them)")],
          selection: lookValue(nil, \.animationTheme, ""))
      }
    }
  }

  /// Social clips cut from this edit: each a range in its own format, exported from the Export menu.
  func clipsSection(_ plan: Plan) -> some View {
    InspectorSection(
      "Clips", detail: plan.clipList.isEmpty
        ? "Pieces of this edit exported on their own, like a vertical short. Mark a range with I and O, then press the clip button on the timeline."
        : "Pieces of this edit exported on their own. Export them from the Export menu."
    ) {
      ForEach(Array(plan.clipList.enumerated()), id: \.offset) { i, c in
        if i > 0 { Divider() }
        HStack(spacing: Theme.Space.s) {
          TextField("Name", text: bindItem("clipName\(i)", \.clipList, i, \.name)).textFieldStyle(.roundedBorder)
          Button { project.seek(src: c.start) } label: { Text("\(fmtTime(c.start))-\(fmtTime(c.end))").monospacedDigit() }
            .buttonStyle(.borderless).help("Go to the clip's start")
          Button { project.apply { p in if p.clipList.indices.contains(i) { p.clipList.remove(at: i) } } } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(c.name)")
        }
        LabeledContent("Format") {
          Picker("Format", selection: bindItem("clipFormat\(i)", \.clipList, i, \.format)) {
            Text("This video's").tag(String?.none)
            ForEach(ExportPreset.all, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
          }
          .labelsHidden()
        }
        LabeledContent("Hook") {
          TextField("A title for the first \(Int(Clip.titleSeconds)) s", text: bindItem("clipTitle\(i)", \.clipList, i, \.title, or: "", store: emptyAsNil))
            .textFieldStyle(.roundedBorder)
        }
        LabeledContent("Pauses") {
          ChoiceRow([(PauseLevel?.none, "Edit", "Keep the edit's pauses")] + PauseLevel.allCases.map { (PauseLevel?.some($0), $0.label, $0.label) },
            selection: bindItem("clipPace\(i)", \.clipList, i, \.pace))
        }
        LabeledContent("Logo") {
          Text(c.logo.map { ($0 as NSString).lastPathComponent } ?? "None").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("Choose…") { project.chooseLogo { p, file in if p.clipList.indices.contains(i) { p.clipList[i].logo = file } } }
            .controlSize(.small).help("A logo shown small at the top of this clip")
          if c.logo != nil {
            Button("Remove") { project.apply { p in if p.clipList.indices.contains(i) { p.clipList[i].logo = nil } } }.controlSize(.small)
          }
        }
      }
    }
  }

  /// Effects drawn on the whole video (timeline effect bars are for one stretch).
  func effectsSection(_ plan: Plan) -> some View {
    let sources = EffectSources(project: project.dir)
    let installed = sources.available()
    return InspectorSection(
      "Effects", detail: "Shaders drawn over the whole video. The wand on the timeline adds one for a stretch instead.",
      isOpen: fold("effects", open: !plan.effectList.isEmpty)
    ) {
      ForEach(Array(plan.effectList.enumerated()), id: \.offset) { i, e in
        let manifest = sources.manifest(e.name)
        if i > 0 { Divider() }
        HStack(spacing: Theme.Space.s) {
          Image(systemName: "wand.and.stars").foregroundStyle(Theme.effect)
          Text(manifest?.title ?? e.name).lineLimit(1)
          if manifest == nil { Text("missing").font(.caption).foregroundStyle(Theme.warning) }
          Spacer(minLength: 4)
          Button { project.apply { p in if p.effectList.indices.contains(i) { p.effectList.remove(at: i) } } } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(manifest?.title ?? e.name)")
        }
        LabeledContent("On") {
          ChoiceRow(
            [(String?.none, "Default", "The effect's own layer (\(manifest?.layer ?? "frame"))")]
              + Effects.layers.map { (String?.some($0), $0.capitalized, "Draw it on the \($0)") },
            selection: bindItem("effectLayer\(i)", \.effectList, i, \.layer))
        }
        if let params = manifest?.params, !params.isEmpty {
          effectParamSliders("allEffectParam\(i)", params, \.effectList, i, \.params)
        }
      }
      Menu {
        if installed.isEmpty {
          Text("No effects installed")
          Button("Open Effects Folder") { openEffectsFolder() }
        }
        ForEach(installed, id: \.self) { name in
          Button(sources.manifest(name)?.title ?? name) { project.apply { $0.effectList.append(EffectUse(name: name)) } }
        }
      } label: {
        Label("Add Effect", systemImage: "plus")
      }
      .help("Draw an installed effect over the whole video")
    }
  }

  /// The logo drawn over the video (the look's watermark), also the default on intro and outro cards.
  func logoSection(_ plan: Plan) -> some View {
    InspectorSection("Logo", detail: "Drawn in a corner of the video, and on intro and outro cards.") {
      if let w = plan.look?.watermark {
        HStack(spacing: Theme.Space.s) {
          Image(systemName: "photo").foregroundStyle(.secondary)
          Text((w.image as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 4)
          Button("Change…") { project.chooseLogo { $0.look?.watermark?.image = $1 } }.controlSize(.small)
          Button { project.apply { $0.look?.watermark = nil } } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove the logo")
        }
        LabeledContent("Corner") {
          ChoiceRow(
            [("", "Auto", "The profile's corner"), ("topLeft", "↖", "Top left"), ("topRight", "↗", "Top right"),
             ("bottomLeft", "↙", "Bottom left"), ("bottomRight", "↘", "Bottom right")],
            selection: watermarkValue(nil, \.corner, ""))
        }
        slider("Size", watermarkValue("logoSize", \.height, 0.035), 0.02...0.15, "\(Int(((w.height ?? 0.035) * 1000).rounded()) / 10)%")
        slider("Opacity", watermarkValue("logoOpacity", \.opacity, 0.9), 0.1...1, "\(Int(((w.opacity ?? 0.9) * 100).rounded()))%")
      } else {
        Button { project.chooseLogo { p, file in
          var look = p.look ?? Look()
          look.watermark = Look.Watermark(image: file)
          p.look = look
        } } label: { Label("Choose Logo…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
          .help("Pick a PNG to draw in a corner of the video")
      }
    }
  }

  /// A binding to one of the look's colors, creating the look when it's the first change.
  func lookColor(_ key: String, _ field: WritableKeyPath<Look, String?>, _ fallback: String) -> Binding<Color> {
    bind(key, { hexColor($0.look?[keyPath: field] ?? fallback) }, { p, c in
      var look = p.look ?? Look()
      look[keyPath: field] = hexString(c)
      p.look = look
    })
  }

  /// A binding to one of the look's settings; choosing `fallback` clears it back to the default.
  func lookValue<T: Equatable>(_ key: String?, _ field: WritableKeyPath<Look, T?>, _ fallback: T) -> Binding<T> {
    bind(key, { $0.look?[keyPath: field] ?? fallback }, { p, v in
      var look = p.look ?? Look()
      look[keyPath: field] = v == fallback ? nil : v
      p.look = look
    })
  }

  /// A binding to one of the logo's settings; choosing `fallback` clears it back to the default.
  func watermarkValue<T: Equatable>(_ key: String?, _ field: WritableKeyPath<Look.Watermark, T?>, _ fallback: T) -> Binding<T> {
    bind(key, { $0.look?.watermark?[keyPath: field] ?? fallback }, { p, v in p.look?.watermark?[keyPath: field] = v == fallback ? nil : v })
  }

  /// A font menu over the look's font files and installed fonts.
  func fontPicker(_ title: String, _ field: WritableKeyPath<Look, String?>, _ plan: Plan) -> some View {
    LabeledContent(title) {
      Picker(title, selection: lookValue(nil, field, "")) {
        Text("System").tag("")
        ForEach(Fonts.choices(plan.look), id: \.self) { Text($0).tag($0) }
      }
      .labelsHidden()
    }
  }

  // MARK: Cursor & Overlays

  @ViewBuilder
  func overlaysPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Cursor & Overlays")
    InspectorSection("Cursor", detail: project.project?.source.cursorHidden == true
      ? "Drawn from your mouse moves, so it glides instead of jittering."
      : "This recording has the system cursor baked in. Record with the cursor hidden to restyle and smooth it.") {
      if project.project?.source.cursorHidden != true {
        hint("This recording has the system cursor baked in. Record with the cursor hidden to restyle and smooth it.")
      }
      if project.project?.source.cursorHidden == true {
        toggle("Show cursor", bind(nil, { !($0.cursorSettings.hidden ?? false) }, { $0.cursorSettings.hidden = $1 ? nil : true }))
      }
      if project.project?.source.cursorHidden == true && plan.cursor?.hidden != true {
        slider("Size", bind("cursorSize", { $0.cursorSettings.size ?? 32 }, { $0.cursorSettings.size = $1.rounded() }), 16...72, "\(Int(plan.cursor?.size ?? 32)) pt")
        LabeledContent("Smoothing") {
          // Named levels; a value set between them (by an agent, or an older plan) shows as Custom.
          let levels: [(Double, String)] = [(0, "Off"), (0.06, "Light"), (0.12, "Medium"), (0.25, "Strong")]
          let now = plan.cursor?.smoothing ?? 0.12
          ChoiceRow(levels + (levels.contains { $0.0 == now } ? [] : [(now, "Custom")]),
            selection: bind(nil, { $0.cursorSettings.smoothing ?? 0.12 }, { $0.cursorSettings.smoothing = $1 }))
        }
        toggle("Hide when still", "Fades out after 1.5 s without moving.", bind(nil, { $0.cursorSettings.idleHide ?? true }, { $0.cursorSettings.idleHide = $1 ? nil : false }))
      }
      toggle("Click ripples", "A ring where you click.", bind("ripples", { $0.clickRipples }, { $0.clickRipples = $1 }))
      toggle("Shortcut labels", "Shows chips like ⌘K when you press a shortcut.", bind("chips", { $0.shortcutChips }, { $0.shortcutChips = $1 }))
    }
    let hasWords = !(project.project?.words.isEmpty ?? true)
    InspectorSection(
      "Captions", detail: hasWords ? "Burned in from the transcript, in the profile's fonts." : "This recording has no transcript to caption."
    ) {
      toggle("Captions", bind("captions", { $0.captions.enabled }, { $0.captions.enabled = $1 }))
      // Off, the caption settings have nothing to change; they come back as they were.
      if plan.captions.enabled {
        LabeledContent("Style") {
          Picker("Style", selection: bind("captionStyle", { $0.captions.style ?? "pill" }, { $0.captions.style = $1 == "pill" ? nil : $1 })) {
            ForEach(Plan.Captions.styles, id: \.name) { Text($0.label).tag($0.name) }
          }
          .pickerStyle(.menu)
          .labelsHidden()
        }
        LabeledContent("Words") {
          Text("\(plan.captions.maxWords) per caption").monospacedDigit()
          Spacer(minLength: 0)
          Stepper("Words per caption", value: bind("maxWords", { $0.captions.maxWords }, { $0.captions.maxWords = $1 }), in: 3...14)
            .labelsHidden()
        }
        captionLook(plan)
      }
    }
    if plan.callouts.contains(where: { $0.style == "chapter" }) {
      chaptersSection(plan)
    }
  }

  func chaptersSection(_ plan: Plan) -> some View {
    InspectorSection("Chapters") {
      LabeledContent("Style") {
        ChoiceRow([("", "Chip"), ("big", "Big type")], selection: bind("chapterStyle", { $0.look?.chapterStyle ?? "" }, { p, v in
          var look = p.look ?? Look()
          look.chapterStyle = v.isEmpty ? nil : v
          p.look = look
        }))
      }
      .help("Big type: a black block rises under the picture with the chapter in huge letters and crayon marks.")
      // The checklist lists earlier chapter chips, so it needs at least two.
      if plan.callouts.filter({ $0.style == "chapter" }).count >= 2, plan.look?.chapterStyle != "big" {
        toggle("Checklist", "Vertical step chips list the earlier steps under them, ticked.", bind("checklist", { $0.look?.chapterChecklist == true }, { p, on in
        var look = p.look ?? Look()
        look.chapterChecklist = on ? true : nil
        p.look = look
      }))
      }
    }
  }

  /// Caption colors, box, font, size and place. Colors and font live in the look (the profile's),
  /// size, box and place in the captions.
  @ViewBuilder
  func captionLook(_ plan: Plan) -> some View {
    let bold = plan.captions.isBold
    let lookBind = { (key: String, get: @escaping (Look) -> String?, set: @escaping (inout Look, String) -> Void, fallback: String) in
      self.bind(key, { hexColor(get($0.look ?? Look()) ?? fallback) }, { p, c in
        var look = p.look ?? Look()
        set(&look, hexString(c))
        p.look = look
      })
    }
    // Swatches without labels beside them, so the row fits the inspector column; the names are under them.
    LabeledContent("Colors") {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Theme.Space.m) {
          ColorPicker("Text", selection: lookBind("capText", { $0.captionText }, { $0.captionText = $1 }, "#ffffff"))
            .labelsHidden().help("Text")
          ColorPicker("Highlight", selection: lookBind("capHL", { $0.captionHighlight }, { $0.captionHighlight = $1 }, plan.look?.accent ?? "#ffe500"))
            .labelsHidden().help("The word being spoken")
          ColorPicker("Box", selection: lookBind("capBG", { $0.captionBackground }, { $0.captionBackground = $1 }, "#0a0a0e"))
            .labelsHidden().help("Box")
        }
        Text("Text · spoken word · box").font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    LabeledContent("Emphasis") {
      HStack(spacing: Theme.Space.s) {
        TextField("home lab, Linux", text: bind("capEmphasis", { ($0.captions.emphasis ?? []).joined(separator: ", ") }, { p, text in
          let words = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
          p.captions.emphasis = words.isEmpty ? nil : words
        }))
        .lineLimit(1)
        .frame(minWidth: 0, maxWidth: .infinity)
        .help("Words or phrases drawn bigger in the emphasis color, separated by commas")
        ColorPicker("Emphasis color", selection: lookBind("capEmph", { $0.captionEmphasis }, { $0.captionEmphasis = $1 }, plan.look?.accent ?? "#ffe500"))
          .labelsHidden().fixedSize()
      }
    }
    if bold {
      toggle("Box behind the words", "A box in the box color, for words over a busy picture.",
        bind("capBox", { $0.captions.box == true }, { $0.captions.box = $1 ? true : nil }))
    }
    // Bold captions draw no box unless asked for one, so there's no opacity to set.
    if !bold || plan.captions.box == true {
      slider("Box opacity", bind("capOpacity", { $0.look?.captionBackgroundOpacity ?? 0.78 }, { p, v in
        var look = p.look ?? Look()
        look.captionBackgroundOpacity = (v * 100).rounded() / 100
        p.look = look
      }), 0...1, "\(Int(((plan.look?.captionBackgroundOpacity ?? 0.78) * 100).rounded()))%")
    }
    LabeledContent("Font") {
      Picker("Font", selection: bind("capFont", { $0.look?.captionFont ?? "" }, { p, name in
        var look = p.look ?? Look()
        look.captionFont = name.isEmpty ? nil : name
        p.look = look
      })) {
        Text("System").tag("")
        ForEach(Fonts.choices(plan.look), id: \.self) { Text($0).tag($0) }
      }
      .labelsHidden()
    }
    slider("Size", bind("capSize", { $0.captions.size ?? 1 }, { $0.captions.size = abs($1 - 1) < 0.02 ? nil : ($1 * 20).rounded() / 20 }), 0.5...2,
      "\(Int(((plan.captions.size ?? 1) * 100).rounded()))%")
    LabeledContent("Place") {
      Text(plan.captions.y == nil ? "Style's own (drag them in the preview)" : "Dragged").foregroundStyle(.secondary)
      Spacer(minLength: 0)
      if plan.captions.y != nil {
        Button("Reset") { project.apply { $0.captions.x = nil; $0.captions.y = nil } }.controlSize(.small)
          .help("Put the captions back in the style's place")
      }
    }
  }

  // MARK: Format

  @ViewBuilder
  func formatPane(_ plan: Plan) -> some View {
    PaneTitle(title: "Format", detail: "\(plan.output.width)×\(plan.output.height) at \(plan.output.fps) fps")
    InspectorSection("Shape", detail: "The Export menu also renders other formats without changing this one.") {
      LabeledContent("Shape") {
        ChoiceRow(Aspect.allCases.map { ($0, $0.rawValue, $0.label) },
          selection: Binding(get: { project.plan.map { Aspect.of($0.output) } ?? Aspect.of(plan.output) }, set: { project.setFormat(aspect: $0) }))
      }
      LabeledContent("Resolution") {
        ChoiceRow(Resolution.allCases.map { ($0, $0.label) },
          selection: Binding(get: { project.plan.map { Resolution.of($0.output) } ?? Resolution.of(plan.output) }, set: { project.setFormat(resolution: $0) }))
      }
      LabeledContent("Frame rate") {
        ChoiceRow([(30, "30 fps"), (60, "60 fps")], selection: bind("fps", { $0.output.fps }, { $0.output.fps = $1 }))
      }
    }
    InspectorSection("Screen crop", detail: "Cropped screens pan to follow zooms and clicks.") {
      LabeledContent("Screen") {
        ChoiceRow(
          [(0.0, "Full", "The whole screen"), (4.0 / 3, "4:3", "Crop to 4:3"), (1.25, "5:4", "Crop to 5:4"), (1.0, "1:1", "Crop square"),
           (0.8, "4:5", "Crop to 4:5")],
          selection: bind("screenAspect", { $0.style.screenAspect ?? 0 }, { $0.style.screenAspect = $1 == 0 ? nil : $1 }))
      }
    }
    clipsSection(plan)
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
      LabeledContent("Logo") {
        Text(plan[keyPath: kp]?.logo.map { ($0 as NSString).lastPathComponent } ?? (plan.look?.watermark == nil ? "None" : "The video's logo"))
          .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button("Choose…") { project.chooseLogo { $0[keyPath: kp]?.logo = $1 } }.controlSize(.small)
          .help("A PNG for this card only")
        if plan[keyPath: kp]?.logo != nil {
          Button("Reset") { project.apply { $0[keyPath: kp]?.logo = nil } }.controlSize(.small)
            .help("Use the video's logo")
        }
      }
      slider("Length", bind("\(title)Length", { $0[keyPath: kp]?.seconds ?? Card.defaultDuration }, { $0[keyPath: kp]?.duration = ($1 * 10).rounded() / 10 }), 1...6,
        String(format: "%.1f s", plan[keyPath: kp]?.seconds ?? Card.defaultDuration))
    }
  }

  func cardText(_ kp: WritableKeyPath<Plan, Card?>, _ field: WritableKeyPath<Card, String?>) -> Binding<String> {
    bind("card\(kp.hashValue)\(field.hashValue)", { $0[keyPath: kp]?[keyPath: field] ?? "" }, { $0[keyPath: kp]?[keyPath: field] = $1 })
  }
}

/// Opens the personal Effects folder in Finder, making it first if needed.
func openEffectsFolder() {
  do {
    try FileManager.default.createDirectory(at: EffectSources.personalFolder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(EffectSources.personalFolder)
  } catch {
    Notices.shared.show(error, "Couldn't make the Effects folder")
  }
}
