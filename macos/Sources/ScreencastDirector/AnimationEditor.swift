import AppKit
import DirectorCore
import SwiftUI

/// The inspector for one animation: its template (and where that template comes from), the content
/// fields the template's manifest lists, and its beats, each set from the playhead. A "steps" field
/// (the storyboard template) gets a step list instead. Edits re-render the clip once typing pauses.
struct AnimationEditor: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: InspectorUI
  let i: Int

  private var item: DirectorCore.Animation? {
    guard let list = project.plan?.animationList, list.indices.contains(i) else { return nil }
    return list[i]
  }
  private var sources: AnimationSources { AnimationLibrary.sources(project.dir) }

  var body: some View {
    if let a = item {
      let found = sources.template(a.template)
      let template = found?.template
      VStack(alignment: .leading, spacing: 14) {
        InspectorSection("Template", detail: template?.summary ?? "No template named \"\(a.template)\" in this video, your library or the app.") {
          Picker(
            "Template",
            selection: Binding(
              get: { a.template },
              set: { name in if let t = AnimationLibrary.template(name, project.dir) { project.setAnimationTemplate(i, t) } })
          ) {
            ForEach(AnimationLibrary.templates(project.dir).map(\.template), id: \.name) { t in Text(t.title).tag(t.name) }
          }
          .labelsHidden()
          templateOrigin(a.template, found?.origin)
          if a.sticker == nil {
            Toggle("Over the video (transparent)", isOn: Binding(get: { a.isOverlay }, set: { on in project.editAnimation(i) { $0.overlay = on ? true : nil } }))
              .help("Float the graphics over the screen and camera instead of filling the frame with paper")
          }
          Button {
            project.fillAnimationFromTranscript(i)
          } label: {
            Label("Fill In From What I Say", systemImage: "sparkles").frame(maxWidth: .infinity)
          }
          .disabled(project.busy)
          .help("Claude writes the content in your words and cues each beat to the word that names it")
          if project.animating, project.plan?.animationsToRender(dir: project.dir).contains(where: { $0.index == i }) == true {
            Label("Rendering… it shows in the preview when it's done.", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
          }
        }
        if a.floats, let plan = project.plan {
          InspectorSection("Pop On and Off", detail: "How it appears over the video. Changing it doesn't re-render.") {
            MotionPicker(
              title: "In", motion: Binding(get: { item?.enter }, set: { m in project.editAnimation(i, coalesce: "animIn\(i)") { $0.enter = m } }),
              fallback: plan.defaultEnter(sticker: a.sticker != nil))
            MotionPicker(
              title: "Out", motion: Binding(get: { item?.exit }, set: { m in project.editAnimation(i, coalesce: "animOut\(i)") { $0.exit = m } }),
              fallback: plan.defaultExit(sticker: a.sticker != nil))
          }
        }
        if let template {
          InspectorSection("Content") {
            ForEach(template.fields.filter { $0.type != "steps" }, id: \.key) { field in fieldView(field, a) }
          }
          if let steps = template.fields.first(where: { $0.type == "steps" }) {
            InspectorSection("Steps", detail: "Each step happens on a word. Play or scrub to it and press ⊙ to set the step there.") {
              stepsEditor(steps.key, a)
            }
          } else {
            InspectorSection("Beats", detail: "Play or scrub to the word, then press ⊙ to set the beat there. Click a beat to jump to it.") {
              ForEach(template.cues, id: \.key) { cue in beatRow(cue.key, cue.label, a) }
            }
          }
        }
      }
    }
  }

  // MARK: Where the template comes from

  @ViewBuilder
  private func templateOrigin(_ name: String, _ origin: AnimationSources.Origin?) -> some View {
    let video = origin == .video
    let inLibrary = sources.libraryFolder(for: name) != nil
    VStack(alignment: .leading, spacing: 6) {
      Text(
        video
          ? (inLibrary ? "This video keeps its own copy, so library changes never change it." : "Made for this video. Save it to reuse it in others.")
          : origin == .personal ? "From your library." : "Built into the app."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        if video, inLibrary, sources.differsFromLibrary(name) {
          Button("Update Template") { project.updateAnimationTemplate(name) }
            .help("Replace this video's copy with the library's latest. Its animations re-render.")
        }
        if video {
          Button("Save to My Templates") { project.saveAnimationTemplate(name) }
            .help("Copy this video's version to your library, for other videos")
          Button {
            project.revealAnimationTemplate(name)
          } label: {
            Image(systemName: "folder")
          }
          .help("Show this video's copy in the Finder")
        }
      }
      .controlSize(.small)
    }
  }

  // MARK: Content fields

  @ViewBuilder
  private func fieldView(_ field: AnimationTemplate.Field, _ a: DirectorCore.Animation) -> some View {
    switch field.type {
    case "text":
      VStack(alignment: .leading, spacing: 3) {
        TextField(field.label, text: textBinding(field.key))
        if let help = field.help { Text(help).font(.caption).foregroundStyle(.secondary) }
      }
    case "number":
      let n = Int(a.data[path: field.key]?.number ?? 0)
      Stepper(
        "\(field.label): \(n)",
        value: Binding(get: { n }, set: { v in set(field.key, .number(Double(v)), coalesce: "anim\(i)\(field.key)") }),
        in: 0...(field.max ?? 99))
    case "logo":
      logoPicker(field.label, textBinding(field.key))
    case "lottie":
      lottiePicker(field, a)
    case "texts":
      let lines = a.data[path: field.key]?.strings ?? []
      VStack(alignment: .leading, spacing: 4) {
        Text(field.label).font(.callout)
        ForEach(0..<(field.max ?? 3), id: \.self) { k in
          TextField(
            "\(field.label) \(k + 1)",
            text: Binding(
              get: { k < lines.count ? lines[k] : "" },
              set: { v in setLine(field.key, k, v) }))
        }
      }
    case "logos":
      logosField(field, a.data[path: field.key]?.strings ?? [])
    default:
      Text("\(field.label): \(field.type) fields can't be edited here yet.").font(.caption).foregroundStyle(.secondary)
    }
  }

  private func logoPicker(_ label: String, _ value: Binding<String>) -> some View {
    Picker(label, selection: value) {
      Text("None").tag("")
      ForEach(AnimationLibrary.logoNames(project.dir), id: \.self) { name in Text(name).tag(name) }
    }
  }

  /// The Lottie files on offer (the video's, the library's, built in), and Import for one from anywhere.
  private func lottiePicker(_ field: AnimationTemplate.Field, _ a: DirectorCore.Animation) -> some View {
    let lotties = sources.lotties()
    let current = a.data[path: field.key]?.string ?? ""
    return VStack(alignment: .leading, spacing: 4) {
      Picker(field.label, selection: textBinding(field.key)) {
        if !lotties.contains(where: { $0.name == current }) { Text(current.isEmpty ? "None" : "\(current) (missing)").tag(current) }
        ForEach(lotties, id: \.name) { l in Text((l.name as NSString).deletingPathExtension).tag(l.name) }
      }
      if let l = lotties.first(where: { $0.name == current }) {
        Text("\(l.about). \(String(format: "%.1f", l.seconds)) s, \(l.loops ? "loops" : "plays once").").font(.caption).foregroundStyle(.secondary)
      }
      Button("Import Lottie File…") { importLottie(field.key) }
        .controlSize(.small)
        .help("Add a Lottie .json (an After Effects export, e.g. from LottieFiles) to this video")
    }
  }

  private func importLottie(_ key: String) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.message = "Choose a Lottie animation (.json)"
    presentPanel(panel) { response in
      guard response == .OK, let file = panel.url else { return }
      do {
        set(key, .string(try sources.addLottie(file).name))
      } catch {
        Notices.shared.show(error, "Couldn't add \(file.lastPathComponent)")
      }
    }
  }

  private func logosField(_ field: AnimationTemplate.Field, _ names: [String]) -> some View {
    let full = names.count >= (field.max ?? 99)
    return VStack(alignment: .leading, spacing: 6) {
      Text("\(field.label) (\(names.count)\(field.max.map { " of \($0)" } ?? ""))").font(.callout)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
        ForEach(Array(names.enumerated()), id: \.offset) { k, name in
          HStack(spacing: 5) {
            if let img = AnimationLibrary.image(name, project.dir) {
              Image(nsImage: img).resizable().scaledToFit().frame(width: 16, height: 16)
            }
            Text(name).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Button {
              var list = names
              list.remove(at: k)
              set(field.key, .array(list.map { .string($0) }))
            } label: {
              Image(systemName: "xmark").font(Theme.glyph(9, .bold))
            }
            .buttonStyle(.plain)
            .help("Remove \(name)")
          }
          .padding(.horizontal, 7).padding(.vertical, 4)
          .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Color.secondary.opacity(0.14)))
        }
      }
      HStack {
        Menu("Add App") {
          ForEach(AnimationLibrary.logoNames(project.dir).filter { !names.contains($0) }, id: \.self) { name in
            Button(name) { set(field.key, .array((names + [name]).map { .string($0) })) }
          }
        }
        .disabled(full)
        TextField("Another app, by name", text: $ui.newAnimationApp)
          .onSubmit {
            let name = ui.newAnimationApp.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !full else { return }
            set(field.key, .array((names + [name]).map { .string($0) }))
            ui.newAnimationApp = ""
          }
          .disabled(full)
          .help("An app with no logo in the library shows its name in the sticker")
      }
    }
  }

  // MARK: Beats

  private func beatRow(_ key: String, _ label: String, _ a: DirectorCore.Animation) -> some View {
    let t = a.cues?[key]
    return HStack(spacing: 8) {
      Button {
        if let t { project.seek(src: t) }
      } label: {
        HStack {
          Text(label).font(.callout)
          Spacer()
          if let t {
            Text(project.words.first { $0.end > t }.map { "“\($0.text)”" } ?? "").font(.caption).foregroundStyle(.secondary)
            Text(fmtTime(t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          } else {
            Text("not set").font(.caption).foregroundStyle(.tertiary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(t == nil)
      .help("Jump to this beat")
      Button {
        setCue(key, project.playheadSrc)
      } label: {
        Image(systemName: "scope")
      }
      .buttonStyle(.borderless)
      .help("Set \(label.lowercased()) to the playhead")
      beatSound(key, label, a)
    }
  }

  /// The sound a beat plays (`sounds[cue]`), picked from the sound library and copied into sfx/.
  private func beatSound(_ key: String, _ label: String, _ a: DirectorCore.Animation) -> some View {
    let current = a.sounds?[key]
    return Menu {
      if current != nil {
        Button("No Sound") { project.editAnimation(i) { $0.sounds?.removeValue(forKey: key); if $0.sounds?.isEmpty == true { $0.sounds = nil } } }
        Divider()
      }
      ForEach(project.plan.flatMap { try? AudioLibrary(.sounds, for: $0).items() } ?? [], id: \.url) { entry in
        Button(entry.item.name) {
          do {
            let file = try AudioLibrary(.sounds).freeze(entry, project: project.dir)
            project.editAnimation(i) { $0.sounds = ($0.sounds ?? [:]).merging([key: Sound(file: file, gainDB: current?.gainDB)]) { $1 } }
          } catch {
            Notices.shared.show(error, "Couldn't add \(entry.item.name)")
          }
        }
      }
    } label: {
      Image(systemName: current == nil ? "speaker" : "speaker.wave.2.fill")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(current.map { "Plays \(($0.file as NSString).lastPathComponent) on \(label.lowercased())" } ?? "Play a sound on \(label.lowercased())")
  }

  private func setCue(_ key: String, _ t: Double) {
    project.editAnimation(i) { $0.cues = ($0.cues ?? [:]).merging([key: (t * 100).rounded() / 100]) { $1 } }
  }

  // MARK: Steps (storyboard)

  static let stepKinds: [(name: String, label: String)] = [
    ("show", "Show"), ("connect", "Connect"), ("note", "Note"), ("count", "Count"), ("highlight", "Highlight"),
    ("dim", "Dim"), ("hide", "Hide"), ("tangle", "Tangle"), ("circle", "Circle"), ("clear", "Clear the Board"),
  ]

  private func steps(_ key: String) -> [[String: JSONValue]] {
    guard case .array(let a)? = item?.data[path: key] else { return [] }
    return a.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
  }

  private func setSteps(_ key: String, _ list: [[String: JSONValue]], coalesce: String? = nil) {
    set(key, .array(list.map { .object($0) }), coalesce: coalesce)
  }

  private func editStep(_ key: String, _ k: Int, coalesce: String? = nil, _ change: (inout [String: JSONValue]) -> Void) {
    var list = steps(key)
    guard list.indices.contains(k) else { return }
    change(&list[k])
    setSteps(key, list, coalesce: coalesce)
  }

  private func stepsEditor(_ key: String, _ a: DirectorCore.Animation) -> some View {
    let list = steps(key)
    let ids = list.filter { $0["do"]?.string == "show" }.compactMap { $0["id"]?.string }
    return VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(list.enumerated()), id: \.offset) { k, step in
        stepCard(key, k, step, count: list.count, ids: ids, a)
      }
      Menu {
        ForEach(Self.stepKinds, id: \.name) { kind in
          Button(kind.label) { addStep(key, kind.name, ids: ids) }
        }
      } label: {
        Label("Add Step at the Playhead", systemImage: "plus")
      }
    }
  }

  private func stepCard(_ key: String, _ k: Int, _ step: [String: JSONValue], count: Int, ids: [String], _ a: DirectorCore.Animation) -> some View {
    let kind = step["do"]?.string ?? "show"
    let cueKey = step["cue"]?.string ?? ""
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("\(k + 1)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(width: 16)
        Picker(
          "Step", selection: Binding(get: { kind }, set: { v in editStep(key, k) { $0["do"] = .string(v) } })
        ) {
          ForEach(Self.stepKinds, id: \.name) { Text($0.label).tag($0.name) }
        }
        .labelsHidden()
        Spacer(minLength: 0)
        Button { moveStep(key, k, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(k == 0).help("Earlier in the list")
        Button { moveStep(key, k, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(k == count - 1).help("Later in the list")
        Button(role: .destructive) { removeStep(key, k, cue: cueKey) } label: { Image(systemName: "trash") }.help("Remove this step")
      }
      .buttonStyle(.borderless)
      if !cueKey.isEmpty { beatRow(cueKey, "On", a) }
      stepFields(key, k, kind, step, ids: ids)
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
  }

  @ViewBuilder
  private func stepFields(_ key: String, _ k: Int, _ kind: String, _ step: [String: JSONValue], ids: [String]) -> some View {
    switch kind {
    case "show":
      stepText(key, k, "id", "Name (for connecting)")
      Picker("Looks like", selection: stepString(key, k, "kind", fallback: "sticker")) {
        Text("Logo sticker").tag("sticker")
        Text("Big dot").tag("dot")
        Text("Card").tag("card")
        Text("Handwritten label").tag("label")
      }
      if step["kind"]?.string != "label" { logoPicker("Logo", stepString(key, k, "logo", fallback: "")) }
      stepText(key, k, "label", "Label")
      stepPosition(key, k, step)
    case "connect":
      Picker("From", selection: stepString(key, k, "from", fallback: "")) { ForEach(ids, id: \.self) { Text($0).tag($0) } }
      Picker("To", selection: stepString(key, k, "to", fallback: "")) { ForEach(ids, id: \.self) { Text($0).tag($0) } }
      stepText(key, k, "label", "Tag on the line")
      Toggle("Dashed", isOn: Binding(get: { step["dashed"] == .bool(true) }, set: { v in editStep(key, k) { $0["dashed"] = v ? .bool(true) : nil } }))
    case "note":
      stepText(key, k, "text", "Note")
      stepPosition(key, k, step)
    case "count":
      stepText(key, k, "label", "What's counted")
      stepText(key, k, "value", "Number")
    case "highlight", "dim", "hide":
      Picker("Which", selection: stepString(key, k, "target", fallback: "")) { ForEach(ids, id: \.self) { Text($0).tag($0) } }
    default:
      EmptyView()
    }
  }

  private func stepString(_ key: String, _ k: Int, _ field: String, fallback: String) -> Binding<String> {
    Binding(
      get: {
        let s = steps(key)
        guard s.indices.contains(k) else { return fallback }
        switch s[k][field] {
        case .string(let v)?: return v
        case .number(let n)?: return n.formatted()
        default: return fallback
        }
      },
      set: { v in
        editStep(key, k, coalesce: "step\(i)-\(k)-\(field)") { step in
          // A number field stays a number in the plan, so the template can count up to it.
          if field == "value", let n = Double(v) { step[field] = .number(n) } else { step[field] = v.isEmpty ? nil : .string(v) }
        }
      })
  }

  private func stepText(_ key: String, _ k: Int, _ field: String, _ label: String) -> some View {
    TextField(label, text: stepString(key, k, field, fallback: ""))
  }

  /// Placed by hand (x, y in % of the frame) or laid out around the board's first node.
  @ViewBuilder
  private func stepPosition(_ key: String, _ k: Int, _ step: [String: JSONValue]) -> some View {
    let placed = step["x"]?.number != nil && step["y"]?.number != nil
    Toggle(
      "Place by hand",
      isOn: Binding(
        get: { placed },
        set: { on in
          editStep(key, k) { s in
            s["x"] = on ? .number(50) : nil
            s["y"] = on ? .number(50) : nil
          }
        }))
    if placed {
      ForEach(["x", "y"], id: \.self) { axis in
        LabeledContent(axis == "x" ? "Across" : "Down") {
          Slider(
            value: Binding(
              get: { steps(key).indices.contains(k) ? steps(key)[k][axis]?.number ?? 50 : 50 },
              set: { v in editStep(key, k, coalesce: "step\(i)-\(k)-\(axis)") { $0[axis] = .number(v.rounded()) } }),
            in: 0...100
          )
          .controlSize(.small)
        }
      }
    }
  }

  private func addStep(_ key: String, _ kind: String, ids: [String]) {
    let used = Set(item?.cues?.keys.map { $0 } ?? [])
    var n = steps(key).count + 1
    while used.contains("s\(n)") { n += 1 }
    var step: [String: JSONValue] = ["do": .string(kind), "cue": .string("s\(n)")]
    switch kind {
    case "show":
      step["id"] = .string("item\(n)")
      step["kind"] = .string("sticker")
    case "connect":
      if ids.count >= 2 {
        step["from"] = .string(ids[0])
        step["to"] = .string(ids[ids.count - 1])
      }
    case "highlight", "dim", "hide":
      if let last = ids.last { step["target"] = .string(last) }
    case "count":
      step["value"] = .number(1)
    default: break
    }
    let t = min(max(project.playheadSrc, item?.start ?? 0), item?.end ?? .infinity)
    project.editAnimation(i) { a in
      var list: [JSONValue] = []
      if case .array(let existing)? = a.data[path: key] { list = existing }
      list.append(.object(step))
      a.data[path: key] = .array(list)
      a.cues = (a.cues ?? [:]).merging(["s\(n)": (t * 100).rounded() / 100]) { $1 }
    }
  }

  private func moveStep(_ key: String, _ k: Int, by d: Int) {
    var list = steps(key)
    guard list.indices.contains(k), list.indices.contains(k + d) else { return }
    list.swapAt(k, k + d)
    setSteps(key, list)
  }

  private func removeStep(_ key: String, _ k: Int, cue: String) {
    project.editAnimation(i) { a in
      guard case .array(var list)? = a.data[path: key], list.indices.contains(k) else { return }
      list.remove(at: k)
      a.data[path: key] = .array(list)
      a.cues?.removeValue(forKey: cue)
    }
  }

  // MARK: Data

  private func textBinding(_ key: String) -> Binding<String> {
    Binding(
      get: { item?.data[path: key]?.string ?? "" },
      set: { v in set(key, v.isEmpty ? nil : .string(v), coalesce: "anim\(i)\(key)") })
  }

  private func setLine(_ key: String, _ k: Int, _ v: String) {
    var lines = item?.data[path: key]?.strings ?? []
    while lines.count <= k { lines.append("") }
    lines[k] = v
    while lines.last == "" { lines.removeLast() }
    set(key, .array(lines.map { .string($0) }), coalesce: "anim\(i)\(key)\(k)")
  }

  private func set(_ key: String, _ v: JSONValue?, coalesce: String? = nil) {
    project.editAnimation(i, coalesce: coalesce) { $0.data[path: key] = v }
  }
}
