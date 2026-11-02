import DirectorCore
import SwiftUI

/// The inspector for one animation: its template, the content fields the template's manifest lists,
/// and its beats, each set from the playhead. Edits re-render the clip once typing pauses.
struct AnimationEditor: View {
  @ObservedObject var project: ProjectModel
  @ObservedObject var ui: InspectorUI
  let i: Int

  private var item: DirectorCore.Animation? {
    guard let list = project.plan?.animationList, list.indices.contains(i) else { return nil }
    return list[i]
  }

  var body: some View {
    if let a = item {
      let template = AnimationLibrary.template(a.template)
      VStack(alignment: .leading, spacing: 14) {
        InspectorSection("Template", detail: template?.summary ?? "No template named \"\(a.template)\" is installed.") {
          Picker(
            "Template",
            selection: Binding(
              get: { a.template },
              set: { name in if let t = AnimationLibrary.template(name) { project.setAnimationTemplate(i, t) } })
          ) {
            ForEach(AnimationLibrary.templates, id: \.name) { t in Text(t.title).tag(t.name) }
          }
          .labelsHidden()
          Button {
            project.fillAnimationFromTranscript(i)
          } label: {
            Label("Fill In From What I Say", systemImage: "sparkles").frame(maxWidth: .infinity)
          }
          .disabled(project.busy)
          .help("Claude writes the heading, labels and apps in your words and cues each beat to the word that names it")
          if project.animating, project.plan?.animationsToRender(dir: project.dir).contains(where: { $0.index == i }) == true {
            Label("Rendering… it shows in the preview when it's done.", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
          }
        }
        if let template {
          InspectorSection("Content") {
            ForEach(template.fields, id: \.key) { field in fieldView(field, a) }
          }
          InspectorSection("Beats", detail: "Play or scrub to the word, then set the beat there. Click a beat to jump to it.") {
            ForEach(template.cues, id: \.key) { cue in beatRow(cue, a) }
          }
        }
      }
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
      Picker(field.label, selection: textBinding(field.key)) {
        Text("None").tag("")
        ForEach(AnimationLibrary.logoNames, id: \.self) { name in Text(name).tag(name) }
      }
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

  private func logosField(_ field: AnimationTemplate.Field, _ names: [String]) -> some View {
    let full = names.count >= (field.max ?? 99)
    return VStack(alignment: .leading, spacing: 6) {
      Text("\(field.label) (\(names.count)\(field.max.map { " of \($0)" } ?? ""))").font(.callout)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
        ForEach(Array(names.enumerated()), id: \.offset) { k, name in
          HStack(spacing: 5) {
            if let img = AnimationLibrary.image(name) {
              Image(nsImage: img).resizable().scaledToFit().frame(width: 16, height: 16)
            }
            Text(name).font(.caption).lineLimit(1)
            Spacer(minLength: 0)
            Button {
              var list = names
              list.remove(at: k)
              set(field.key, .array(list.map { .string($0) }))
            } label: {
              Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Remove \(name)")
          }
          .padding(.horizontal, 7).padding(.vertical, 4)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.14)))
        }
      }
      HStack {
        Menu("Add App") {
          ForEach(AnimationLibrary.logoNames.filter { !names.contains($0) }, id: \.self) { name in
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

  private func beatRow(_ cue: AnimationTemplate.Cue, _ a: DirectorCore.Animation) -> some View {
    let t = a.cues?[cue.key]
    return HStack(spacing: 8) {
      Button {
        if let t { project.seek(src: t) }
      } label: {
        HStack {
          Text(cue.label).font(.callout)
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
        let now = project.playheadSrc
        project.editAnimation(i) { $0.cues = ($0.cues ?? [:]).merging([cue.key: (now * 100).rounded() / 100]) { $1 } }
      } label: {
        Image(systemName: "scope")
      }
      .buttonStyle(.borderless)
      .help("Set \(cue.label.lowercased()) to the playhead")
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
