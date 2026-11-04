import AVFoundation
import AppKit
import DirectorCore
import Foundation
import UniformTypeIdentifiers

// Adding and editing timeline items: effect ranges, markers, the in/out range, zooms, animations,
// layouts, punch-ins, titles and annotations.
extension ProjectModel {
  // MARK: Effect ranges

  /// An effect drawn over the in/out range, or for 5 s from the playhead.
  func addEffectRange(_ name: String) {
    guard let plan else { return }
    let t = playheadSrc
    let span = markedRange ?? t..<min(plan.source.duration, t + 5)
    let r = EffectRange(start: span.lowerBound, end: span.upperBound, name: name)
    apply { $0.effectRangeList.append(r) }
    if let i = self.plan?.effectRangeList.firstIndex(of: r) { select(.effectRange(i), adding: false) }
  }

  // MARK: Markers

  /// M: a marker at the playhead.
  func addMarker() {
    let t = playheadSrc
    let m = Marker(t: t)
    apply { $0.markerList.append(m) }
    if let i = plan?.markerList.firstIndex(of: m) { select(.marker(i), adding: false) }
    status = "Marker at \(fmtTime(t)). Name it in the inspector."
  }

  /// ; and ': the previous or next marker.
  func jumpMarker(_ step: Int) {
    let t = playheadSrc
    if let target = plan?.marker(from: t, step: step) { seek(src: target.t) }
  }

  // MARK: In and out

  /// The marked range, when both ends are set the right way round.
  var markedRange: Range<Double>? { DirectorCore.markedRange(in: inPoint, out: outPoint) }

  /// I: the range starts at the playhead.
  func markIn() {
    inPoint = playheadSrc
    if let o = outPoint, o <= playheadSrc { outPoint = nil }
  }

  /// O: the range ends at the playhead.
  func markOut() {
    outPoint = playheadSrc
    if let i = inPoint, i >= playheadSrc { inPoint = nil }
  }

  func clearInOut() {
    inPoint = nil
    outPoint = nil
  }

  func cutMarked() {
    guard let r = markedRange else { return }
    apply { $0.cut(range: r) }
    status = "Cut \(fmtTime(r.upperBound - r.lowerBound)). ⌘Z puts it back."
    clearInOut()
  }

  /// Speeds up the marked range (talking stays muted when sped up, so this is for typing and waiting).
  func speedMarked(_ speed: Double) {
    guard let r = markedRange else { return }
    apply { $0.setSpeed(range: r, speed: speed) }
    status = "\(fmtTime(r.upperBound - r.lowerBound)) at \(speed.formatted())×"
    clearInOut()
  }

  func restore(_ gap: Gap) {
    apply { $0.restore(gap) }
    selection = nil
  }

  func addZoom() {
    guard let plan else { return }
    let t = playheadSrc
    let f = zoomFocus(at: t, clicks: project?.clicks ?? [])
    let z = Zoom(start: t, end: min(plan.source.duration, t + 2.5), x: f.x, y: f.y, scale: 1.8, note: "manual")
    apply { $0.zooms.append(z) }
    if let i = self.plan?.zooms.firstIndex(of: z) { selection = .zoom(i) }
  }

  /// A new animation over the in/out range, the selected words, or the template's length from the
  /// playhead, with the template's starting content and its beats spread over that stretch.
  func addAnimation(_ template: AnimationTemplate) {
    guard let plan else { return }
    let span = markedRange ?? transcriptRange ?? playheadSrc..<min(plan.source.duration, playheadSrc + template.length)
    guard span.upperBound - span.lowerBound > 0.5 else {
      Notices.shared.show("There's not enough recording after the playhead for an animation.")
      return
    }
    let a = template.make(start: span.lowerBound, end: span.upperBound)
    freezeTemplate(template.name)
    apply { $0.animationList.append(a) }
    if let i = self.plan?.animationList.firstIndex(of: a) { select(.animation(i), adding: false) }
    status = "Added \(template.title). Fill it in on the right, or let Claude fill it from what you say."
  }

  /// Changes one animation, bounds-checked (an undo can remove it while its editor is open).
  func editAnimation(_ i: Int, coalesce: String? = nil, _ change: (inout Animation) -> Void) {
    apply(coalesce: coalesce) { p in
      guard p.animationList.indices.contains(i) else { return }
      var list = p.animationList
      change(&list[i])
      p.animationList = list
    }
  }

  /// Switches an animation to another template, starting over with that template's content.
  func setAnimationTemplate(_ i: Int, _ template: AnimationTemplate) {
    freezeTemplate(template.name)
    editAnimation(i) { a in
      guard a.template != template.name else { return }
      a = template.make(start: a.start, end: a.end)
    }
  }

  /// Copies a template into this video's animations folder (once), so later changes to the
  /// library never change this video.
  private func freezeTemplate(_ name: String) {
    do {
      try AnimationLibrary.sources(dir).freeze(name)
    } catch {
      Notices.shared.show(error, "Couldn't copy the \(name) template into this video")
    }
  }

  /// Replaces this video's copy of a template with the library's latest; its animations re-render.
  func updateAnimationTemplate(_ name: String) {
    do {
      try AnimationLibrary.sources(dir).updateFromLibrary(name)
      objectWillChange.send()
      rebuild(now: true)
      status = "Updated the \(name) template. Its animations re-render with the new version."
    } catch {
      Notices.shared.show(error, "Couldn't update the \(name) template")
    }
  }

  /// Saves this video's copy of a template to the personal library, for future videos.
  func saveAnimationTemplate(_ name: String) {
    do {
      try AnimationLibrary.sources(dir).saveToPersonal(name)
      objectWillChange.send()
      status = "Saved the \(name) template to your library. New animations in any video can use it."
    } catch {
      Notices.shared.show(error, "Couldn't save the \(name) template to your library")
    }
  }

  /// Shows this video's copy of a template in the Finder, to edit it by hand or with Claude.
  func revealAnimationTemplate(_ name: String) {
    let file = AnimationSources.videoFolder(dir).appendingPathComponent("templates/\(name).js")
    NSWorkspace.shared.activateFileViewerSelecting([file])
  }

  /// Has Claude write the animation's text and time its beats from what's said over it.
  func fillAnimationFromTranscript(_ i: Int) {
    guard let list = plan?.animationList, list.indices.contains(i) else { return }
    let a = list[i]
    instruction =
      "Fill in animation #\(i) (the \"\(a.template)\" template, \(fmtTime(a.start))–\(fmtTime(a.end))) from what I say in that stretch: "
      + "write its heading, labels and apps in my words, and cue each beat to the word that names it. Keep its start and end."
    askClaude()
  }

  func addLayout(_ mode: LayoutMode) {
    guard let plan else { return }
    let t = playheadSrc
    let l = LayoutRange(start: t, end: min(plan.source.duration, t + 4), mode: mode, note: nil)
    apply { $0.layouts.append(l) }
    if let i = self.plan?.layouts.firstIndex(of: l) { selection = .layout(i) }
  }

  /// A camera punch-in over the in/out range, or 1.5 s from the playhead.
  func addPunchIn() {
    guard let p = plan?.newPunchIn(at: playheadSrc, over: markedRange) else { return }
    apply { $0.punchInList.append(p) }
    if let i = plan?.punchInList.firstIndex(of: p) { select(.punchIn(i), adding: false) }
  }

  func addCallout(style: String = "title") {
    guard let plan else { return }
    let t = playheadSrc
    let text = style == "lower-third" ? "Your Name" : style == "chapter" ? "Section" : "Title"
    let c = Callout(
      start: t, end: min(plan.source.duration, t + (style == "slate" || style == "chapter" ? 2.5 : 3)), text: text,
      style: style == "title" ? nil : style, subtitle: style == "lower-third" ? "Your role" : style == "chapter" ? "Part 1" : nil)
    apply { $0.callouts.append(c) }
    if let i = self.plan?.callouts.firstIndex(of: c) { selection = .callout(i) }
  }

  /// Adds a spotlight, box, arrow, highlight or blur at the playhead, around the last click.
  func addAnnotation(_ kind: String, from start: Double? = nil, to end: Double? = nil) {
    guard let plan else { return }
    let t = start ?? playheadSrc
    let f = zoomFocus(at: end ?? t, clicks: project?.clicks ?? [])
    let w = kind == "highlight" ? 0.2 : 0.16, h = kind == "highlight" ? 0.04 : 0.1
    let a = Annotation(
      start: t, end: min(plan.source.duration, end ?? t + 2.5), kind: kind, x: min(max(f.x - w / 2, 0), 1 - w), y: min(max(f.y - h / 2, 0), 1 - h),
      w: w, h: h)
    apply { $0.annotationList.append(a) }
    if let i = self.plan?.annotationList.firstIndex(of: a) { select(.annotation(i), adding: false) }
  }

  /// ⌥← and ⌥→: moves the selected zoom, layout, title or annotation by whole frames.
  func nudgeSelection(frames n: Double) {
    moveSelected(by: n / Double(fps), coalesce: "nudge")
  }
}
