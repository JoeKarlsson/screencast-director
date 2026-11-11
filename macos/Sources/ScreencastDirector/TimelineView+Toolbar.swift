import AppKit
import DirectorCore
import SwiftUI

// The timeline's toolbar: editing tools, adding items, the in/out range actions and zoom.

extension TimelineView {
  // MARK: Toolbar

  var toolRow: some View {
    HStack(spacing: Theme.Space.m) {
      toolGroup {
        iconButton("Split", "scissors", help: "Split the clip at the playhead (C)", action: project.splitAtPlayhead)
        iconButton(
          isGap ? "Restore" : "Delete", isGap ? "arrow.uturn.backward" : "trash",
          help: isGap ? "Restore the selected cut (⌫)" : "Cut the selected clip, or remove the selected zoom, layout or title (⌫)",
          action: project.deleteSelection)
          .disabled(project.selectedItems.isEmpty)
      }
      if project.markedRange != nil { rangeActions }
      toolGroup {
        iconButton("Zoom", "plus.magnifyingglass", help: "Add a zoom at the playhead, aimed at the last click (Z)", action: project.addZoom)
        Menu {
          ForEach(LayoutMode.allCases, id: \.self) { m in Button(modeName(m)) { project.addLayout(m) } }
        } label: {
          Image(systemName: "rectangle.split.2x1")
        }
        .toolMenu()
        .accessibilityLabel("Layout")
        .help("Change the camera layout from the playhead (⌃L, or 1-4)")
        iconButton(
          "Punch-in", "plus.viewfinder", help: "Punch in on the camera over the in/out range, or for 1.5 s from the playhead",
          action: project.addPunchIn
        )
        .disabled(project.plan?.camera == nil)
        Menu {
          ForEach(ChoiceTiles.calloutStyles, id: \.name) { c in
            Button { project.addCallout(style: c.name) } label: { Label(c.label, systemImage: c.icon) }
          }
        } label: {
          Image(systemName: "textformat")
        } primaryAction: {
          project.addCallout()
        }
        .toolMenu()
        .accessibilityLabel("Title")
        .help("Add a title at the playhead (T); hold for lower thirds, slates and chapters")
        Menu {
          ForEach(ChoiceTiles.annotationKinds, id: \.name) { k in
            Button { project.addAnnotation(k.name) } label: { Label(k.label, systemImage: k.icon) }
          }
        } label: {
          Image(systemName: "scribble")
        }
        .toolMenu()
        .accessibilityLabel("Annotate")
        .help("Add a spotlight, box, arrow, highlight or blur at the playhead, around the last click (A)")
        Menu {
          Button { project.addInsert() } label: { Label("Pick a Picture or Clip…", systemImage: "photo") }
          Button { project.recordBroll() } label: { Label("Record B-roll…", systemImage: "video.badge.plus") }
        } label: {
          Image(systemName: "photo.on.rectangle")
        } primaryAction: {
          project.addInsert()
        }
        .toolMenu()
        .accessibilityLabel("B-roll")
        .help("Show a picture or clip over the video from the playhead; hold to record B-roll from the camera or screen")
        Menu {
          ForEach(AnimationLibrary.templates(project.dir).map(\.template), id: \.name) { t in
            Button { project.addAnimation(t) } label: { Text("\(t.title): \(t.summary)") }
          }
          // A template whose manifest can't be read would otherwise just be missing from this list.
          ForEach(AnimationLibrary.sources(project.dir).templateProblems(), id: \.self) { Text($0) }
        } label: {
          Image(systemName: "sparkles")
        }
        .toolMenu()
        .accessibilityLabel("Animate")
        .help("Add an animation over the in/out range, the selected words, or from the playhead")
        Menu {
          let sources = EffectSources(project: project.dir)
          let names = sources.available()
          if names.isEmpty {
            Text("No effects installed")
            Button("Open Effects Folder") { openEffectsFolder() }
          }
          ForEach(names, id: \.self) { name in
            Button(sources.manifest(name)?.title ?? name) { project.addEffectRange(name) }
          }
        } label: {
          Image(systemName: "wand.and.stars")
        }
        .toolMenu()
        .accessibilityLabel("Effect")
        .help("Turn an effect on for the in/out range, or 5 s from the playhead (effects you installed in the Effects folder)")
      }
      Spacer(minLength: 4)
      HStack(spacing: Theme.Space.s) {
        Image(systemName: "minus.magnifyingglass").font(Theme.glyph(11)).foregroundStyle(.secondary)
        Slider(
          value: Binding(get: { ui.pxPerSec }, set: { ui.zoom(by: $0 / ui.pxPerSec, around: axis(project.playheadSrc)) }), in: ui.minPxPerSec...400)
          .accessibilityLabel("Timeline zoom")
          .controlSize(.small)
          .frame(minWidth: 60, maxWidth: 120)
          .help("Timeline zoom")
        Image(systemName: "plus.magnifyingglass").font(Theme.glyph(11)).foregroundStyle(.secondary)
      }
      toolGroup {
        Toggle(isOn: Binding(get: { ui.outputTime }, set: { on in
          ui.outputTime = on
          ui.fit(axisLength(on))
        })) {
          Image(systemName: "rectangle.compress.vertical").frame(width: 28, height: 22)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Output time")
        .help(ui.outputTime ? "Showing the finished video's length; click for the whole recording" : "Show the finished video's length: cuts collapse, sped-up clips shrink")
        iconButton("Fit", "arrow.left.and.right", help: "Fit the whole timeline") {
          ui.fit(axisLength)
        }
      }
    }
    .font(Theme.font(.body))
    .disabled(!project.hasPlan)
  }

  /// What to do with the in/out range: cut, speed up, zoom, title, annotate, or clear it.
  var rangeActions: some View {
    toolGroup {
      Text("In/Out").font(Theme.font(.label, .semibold)).foregroundStyle(Theme.accent).padding(.horizontal, Theme.Space.s)
      iconButton("Cut range", "scissors.badge.ellipsis", help: "Cut the in/out range", action: project.cutMarked)
      Menu {
        ForEach([1.5, 2, 3, 4, 8], id: \.self) { s in Button("\(s.formatted())×") { project.speedMarked(s) } }
      } label: {
        Image(systemName: "hare")
      }
      .toolMenu()
      .accessibilityLabel("Speed up range")
      .help("Speed up the range (sped-up parts are muted, so use it for typing and waiting)")
      iconButton("Zoom range", "plus.magnifyingglass", help: "Zoom in over the range", action: project.zoomOverRange)
      Menu {
        ForEach(ChoiceTiles.calloutStyles, id: \.name) { c in
          Button { project.titleOverRange(style: c.name) } label: { Label(c.label, systemImage: c.icon) }
        }
      } label: {
        Image(systemName: "textformat")
      } primaryAction: {
        project.titleOverRange(style: "title")
      }
      .toolMenu()
      .accessibilityLabel("Title over range")
      .help("A title over the range, worded from what's said")
      Menu {
        ForEach(ChoiceTiles.annotationKinds, id: \.name) { k in
          Button { project.annotateRange(k.name) } label: { Label(k.label, systemImage: k.icon) }
        }
      } label: {
        Image(systemName: "scribble")
      }
      .toolMenu()
      .accessibilityLabel("Annotate range")
      .help("An annotation over the range")
      iconButton("Make clip", "rectangle.portrait.on.rectangle.portrait", help: "Make a vertical social clip of the range (set it up in Format › Clips)",
        action: project.makeClipFromRange)
      iconButton("Clear range", "xmark", help: "Clear the in/out range (⌥X)", action: project.clearInOut)
    }
  }

  /// A borderless icon button of the toolbar's standard size.
  func iconButton(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: 28, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(title)
    .help(help)
  }

  /// Related toolbar buttons on one shared rounded backing.
  func toolGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 0) { content() }
      .padding(2)
      .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.055)))
      .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
  }
}
