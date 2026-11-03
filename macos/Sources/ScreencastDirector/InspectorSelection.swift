import AppKit
import DirectorCore
import SwiftUI

// The inspector's Selection tab: the selected item's controls, or tips when nothing is selected.
extension InspectorView {
  // MARK: Selection

  /// The selected item's kind as a colored chip, its name, and its time range.
  func itemHeader(_ kind: String, _ icon: String, _ color: Color, _ range: String) -> some View {
    HStack(spacing: 10) {
      KindChip(icon: icon, color: color)
      VStack(alignment: .leading, spacing: 1) {
        Text(kind).font(.title3.weight(.semibold))
        Text(range).font(.callout).monospacedDigit().foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }

  func range(_ start: Double, _ end: Double) -> String { "\(fmtTime(start))–\(fmtTime(end))" }

  func removeButton(_ title: String = "Remove") -> some View {
    Button(role: .destructive, action: project.deleteSelection) {
      Label(title, systemImage: "trash").frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  func selectionPane(_ plan: Plan) -> some View {
    if !project.multi.isEmpty {
      multiPane
    } else {
      singlePane(plan)
    }
  }

  /// Several items selected: what they are, and what you can do with them together.
  var multiPane: some View {
    let items = project.selectedItems
    func count(_ kind: String) -> Int {
      items.filter {
        switch ($0, kind) {
        case (.segment, "clip"), (.gap, "cut"), (.zoom, "zoom"), (.layout, "layout"), (.callout, "title"), (.annotation, "annotation"),
          (.marker, "marker"), (.insert, "B-roll"), (.animation, "animation"):
          return true
        default: return false
        }
      }.count
    }
    let parts = ["clip", "cut", "zoom", "layout", "title", "annotation", "marker", "B-roll", "animation"].compactMap { k -> String? in
      let n = count(k)
      return n == 0 ? nil : "\(n) \(k)\(n == 1 ? "" : "s")"
    }
    return VStack(alignment: .leading, spacing: 14) {
      itemHeader("\(items.count) Selected", "square.stack.3d.up", Theme.accent, parts.joined(separator: ", "))
      InspectorSection("Together", detail: "Drag any of them to move them all; ⌥← and ⌥→ nudge by a frame. ⇧-click adds or removes one.") {
        HStack(spacing: 8) {
          Button { project.nudgeSelection(frames: -Double(project.fps) / 2) } label: { Label("½ s Earlier", systemImage: "arrow.left").frame(maxWidth: .infinity) }
            .disabled(!items.contains(where: \.movable))
          Button { project.nudgeSelection(frames: Double(project.fps) / 2) } label: { Label("½ s Later", systemImage: "arrow.right").frame(maxWidth: .infinity) }
            .disabled(!items.contains(where: \.movable))
        }
        Button {
          project.instruction = "For the selected items: "
        } label: {
          Label("Ask AI About These", systemImage: "sparkles").frame(maxWidth: .infinity)
        }
      }
      removeButton("Remove All")
    }
  }

  @ViewBuilder
  func singlePane(_ plan: Plan) -> some View {
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
      if i > 0 {
        InspectorSection("Cut into this clip", detail: "A styled cut for a new section. Plain cuts suit trimmed pauses.") {
          Picker("Transition", selection: bindItem("transition\(i)", \.segments, i, \.transition)) {
            Text("Plain cut").tag(String?.none)
            ForEach(Segment.transitions, id: \.name) { Text($0.label).tag(String?.some($0.name)) }
          }
          .labelsHidden()
          previewButton(s.start)
        }
      }
      InspectorSection("Order", detail: "Clip \(i + 1) of \(plan.segments.count). Move it to play somewhere else, like a cold open. Its zooms, titles and captions move with it.") {
        HStack(spacing: 6) {
          Button { project.moveSelectedClip(to: 0) } label: { Label("First", systemImage: "arrow.left.to.line") }
            .help("Play this clip first")
          Button { project.moveSelectedClip(to: i - 1) } label: { Label("Earlier", systemImage: "arrow.left") }
            .help("Play this clip one place earlier")
          Button { project.moveSelectedClip(to: i + 1) } label: { Label("Later", systemImage: "arrow.right") }
            .help("Play this clip one place later")
          Button { project.moveSelectedClip(to: plan.segments.count - 1) } label: { Label("Last", systemImage: "arrow.right.to.line") }
            .help("Play this clip last")
        }
        .controlSize(.small)
        .disabled(plan.segments.count < 2)
        if s.repeats == true {
          Text("A repeat: this moment also plays in its own place.").font(.caption).foregroundStyle(.secondary)
        } else {
          Button {
            let range = s.start..<s.end
            project.apply { _ = $0.repeatRange(range, before: nil) }
            project.selection = .segment(0)
          } label: { Label("Repeat as Cold Open", systemImage: "repeat").frame(maxWidth: .infinity) }
          .controlSize(.small)
          .help("Play this clip again at the very start, keeping it where it is too")
        }
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
      InspectorSection("Motion", detail: "How this zoom moves in and out. Default follows the motion style.") {
        LabeledContent("Ease") {
          Picker("Ease", selection: bindItem("zoomEase\(i)", \.zooms, i, \.ease)) {
            Text("Style (\(MotionStyle.named(plan.style.motion).label))").tag(String?.none)
            ForEach(Ease.names, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
          }
          .labelsHidden()
          EaseCurve(ease: Ease.named(z.ease) ?? MotionStyle.named(plan.style.motion).ease, active: true).frame(width: 44, height: 24)
        }
        slider(
          "Length",
          bindItem("zoomSeconds\(i)", \.zooms, i, \.seconds, or: plan.style.transition) { ($0 * 10).rounded() / 10 }, 0.2...2, "\((z.seconds ?? plan.style.transition).formatted()) s")
        previewButton(z.start)
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
      let c = plan.callouts[i]
      let motion = MotionStyle.named(plan.style.motion)
      itemHeader("Title", "textformat", Theme.title, range(c.start, c.end))
      InspectorSection("Style") {
        ChoiceTiles(choices: ChoiceTiles.calloutStyles, selected: c.style ?? "title") { style in
          project.apply {
            guard $0.callouts.indices.contains(i) else { return }
            $0.callouts[i].style = style == "title" ? nil : style
          }
        }
      }
      InspectorSection("Text") {
        TextField("Title", text: bindItem("callout\(i)", \.callouts, i, \.text)).textFieldStyle(.roundedBorder)
        if (c.style ?? "title") != "title" {
          TextField(
            c.style == "chapter" ? "Label above, e.g. Part 2" : c.style == "lower-third" ? "Second line, e.g. a role" : "Second line",
            text: bindItem("calloutSub\(i)", \.callouts, i, \.subtitle, or: "", store: emptyAsNil)
          )
          .textFieldStyle(.roundedBorder)
        }
      }
      InspectorSection("Animation") {
        MotionPicker(title: "In", motion: bindItem("calloutIn\(i)", \.callouts, i, \.enter), fallback: motion.enter)
        MotionPicker(title: "Out", motion: bindItem("calloutOut\(i)", \.callouts, i, \.exit), fallback: motion.exit)
        previewButton(c.start)
      }
      soundSection(bindItem("calloutSound\(i)", \.callouts, i, \.sound))
      removeButton()
    case .insert(let i) where plan.insertList.indices.contains(i):
      let c = plan.insertList[i]
      itemHeader("B-roll", "photo.on.rectangle", Theme.broll, range(c.start, c.end))
      InspectorSection((c.file as NSString).lastPathComponent, detail: c.isImage ? "A picture." : "A clip, played at real time and muted.") {
        Picker("Where", selection: bindItem("insertWhere\(i)", \.insertList, i, \.placement)) {
          Text("In the screen").tag(String?.none)
          Text("Full frame").tag(String?.some("full"))
        }
        .pickerStyle(.segmented)
        Picker("Fit", selection: bindItem("insertFit\(i)", \.insertList, i, \.fit)) {
          Text("Fill").tag(String?.none)
          Text("Show all").tag(String?.some("fit"))
        }
        .pickerStyle(.segmented)
        if !c.isImage {
          slider(
            "Start at",
            bindItem("insertFrom\(i)", \.insertList, i, \.from, or: 0) { ($0 * 10).rounded() / 10 }, 0...30, "\((c.from ?? 0).formatted()) s")
        }
      }
      InspectorSection("Animation") {
        MotionPicker(title: "In", motion: bindItem("insertIn\(i)", \.insertList, i, \.enter), fallback: Motion(preset: "fade", seconds: 0.3, ease: "smooth"))
        MotionPicker(title: "Out", motion: bindItem("insertOut\(i)", \.insertList, i, \.exit), fallback: Motion(preset: "fade", seconds: 0.25, ease: "ease-in"))
        previewButton(c.start)
      }
      removeButton()
    case .animation(let i) where plan.animationList.indices.contains(i):
      let a = plan.animationList[i]
      itemHeader(a.note ?? "Animation", "sparkles", Theme.animation, range(a.start, a.end))
      AnimationEditor(project: project, ui: ui, i: i)
      previewButton(a.start)
      removeButton()
    case .sfx(let i) where plan.sfxList.indices.contains(i):
      let e = plan.sfxList[i]
      itemHeader(e.note ?? "Sound Effect", "speaker.wave.2", Theme.sfx, fmtTime(e.t))
      InspectorSection("Sound", detail: (e.file as NSString).lastPathComponent) {
        slider(
          "Volume",
          bindItem("sfxGain\(i)", \.sfxList, i, \.gainDB, or: 0) { $0.rounded() }, -24...6, "\(Int((e.gainDB ?? 0).rounded())) dB")
      }
      previewButton(e.t)
      removeButton()
    case .marker(let i) where plan.markerList.indices.contains(i):
      let m = plan.markerList[i]
      itemHeader("Marker", "flag", Theme.accent, fmtTime(m.t))
      InspectorSection("Name", detail: "A note to yourself, or to the AI: \"zoom in after the intro marker\". ; and ' jump between markers.") {
        TextField(
          "Intro ends",
          text: bindItem("markerLabel\(i)", \.markerList, i, \.label, or: "", store: emptyAsNil)
        )
        .textFieldStyle(.roundedBorder)
      }
      removeButton()
    case .annotation(let i) where plan.annotationList.indices.contains(i):
      let a = plan.annotationList[i]
      let motion = MotionStyle.named(plan.style.motion)
      itemHeader("Annotation", "scribble", Theme.mark, range(a.start, a.end))
      InspectorSection("Kind") {
        ChoiceTiles(choices: ChoiceTiles.annotationKinds, selected: a.kind, pick: { kind in
          project.apply {
            guard $0.annotationList.indices.contains(i) else { return }
            $0.annotationList[i].kind = kind
          }
        }, columns: 5)
      }
      InspectorSection("Where", detail: "Drag across the frame to draw the area. It follows zooms.") {
        RectPicker(project: project, ui: ui, index: i, mark: a)
      }
      if a.kind == "box" || a.kind == "arrow" {
        InspectorSection("Label") {
          TextField(
            "Optional label",
            text: bindItem("markText\(i)", \.annotationList, i, \.text, or: "", store: emptyAsNil)
          )
          .textFieldStyle(.roundedBorder)
        }
      }
      InspectorSection("Animation") {
        MotionPicker(title: "In", motion: bindItem("markIn\(i)", \.annotationList, i, \.enter), fallback: motion.enter)
        MotionPicker(title: "Out", motion: bindItem("markOut\(i)", \.annotationList, i, \.exit), fallback: motion.exit)
        previewButton(a.start)
      }
      soundSection(bindItem("markSound\(i)", \.annotationList, i, \.sound))
      removeButton()
    default:
      nothingSelected
    }
  }

  /// The sound an item plays as it appears: any audio file in the project's sfx folder.
  func soundSection(_ sound: Binding<Sound?>) -> some View {
    var files = soundFiles()
    if let current = sound.wrappedValue?.file, !files.contains(current) { files.append(current) }
    return InspectorSection("Sound", detail: "Plays as it appears, and moves with it. Add files to the project's sfx folder.") {
      Picker(
        "Sound",
        selection: Binding(
          get: { sound.wrappedValue?.file ?? "" },
          set: { f in sound.wrappedValue = f.isEmpty ? nil : Sound(file: f, gainDB: sound.wrappedValue?.gainDB) })
      ) {
        Text("None").tag("")
        ForEach(files, id: \.self) { f in Text(((f as NSString).lastPathComponent as NSString).deletingPathExtension).tag(f) }
      }
      if let s = sound.wrappedValue {
        slider(
          "Volume", Binding(get: { s.gainDB ?? 0 }, set: { v in sound.wrappedValue?.gainDB = v.rounded() }), -24...6,
          "\(Int((s.gainDB ?? 0).rounded())) dB")
      }
    }
  }

  /// Audio files in the project's sfx folder, as plan paths ("sfx/pop.mp3").
  func soundFiles() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: project.dir.appendingPathComponent("sfx").path)) ?? []
    let audio: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "caf"]
    return names.filter { audio.contains(($0 as NSString).pathExtension.lowercased()) }.sorted().map { "sfx/\($0)" }
  }

  /// Plays from just before `t`, to see an animation or cut.
  func previewButton(_ t: Double) -> some View {
    Button {
      project.seek(src: max(0, t - 0.7))
      project.player.play()
    } label: {
      Label("Preview", systemImage: "play.circle").frame(maxWidth: .infinity)
    }
  }

  var nothingSelected: some View {
    VStack(alignment: .leading, spacing: 14) {
      emptyState("cursorarrow.click.2", "Nothing selected", "Click a clip, zoom, layout, title or annotation on the timeline to edit it.")
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

  func tip(_ icon: String, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
      Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  func shortcut(_ keys: [String], _ text: String) -> some View {
    HStack(spacing: 10) {
      HStack(spacing: 3) { ForEach(keys, id: \.self) { Keycap($0) } }
        .frame(width: 78, alignment: .leading)
      Text(text).font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }

  /// The four layouts as icon tiles.
  func layoutPicker(_ binding: Binding<LayoutMode>, hasCamera: Bool) -> some View {
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
            .foregroundStyle(on ? Theme.accent : Color.primary)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.04)))
            .overlay(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(on ? Theme.accent : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
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

  func layoutIcon(_ m: LayoutMode) -> String {
    switch m {
    case .screen: return "rectangle"
    case .pip: return "rectangle.inset.bottomtrailing.filled"
    case .side: return "rectangle.split.2x1"
    case .camera: return "person.crop.rectangle"
    }
  }
}
