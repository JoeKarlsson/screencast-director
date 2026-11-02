import Foundation

// The editor's plan logic: what's selected on the timeline, and the edits the timeline, keyboard
// and transcript make to the plan. The app's ProjectModel holds the state and calls these, so
// macos/test.sh checks them without the app.

/// What's selected on the timeline; the inspector edits it.
public enum Selection: Equatable {
  case segment(Int)
  case gap(Gap)
  case zoom(Int)
  case layout(Int)
  case callout(Int)
  case annotation(Int)
  case marker(Int)
  case insert(Int)
  case animation(Int)
  case sfx(Int)

  /// Items that can be dragged or nudged in time (clips are trimmed, cuts restored).
  public var movable: Bool {
    switch self {
    case .zoom, .layout, .callout, .annotation, .marker, .insert, .animation, .sfx: return true
    default: return false
    }
  }
}

/// The timeline's selection: the item the inspector shows, plus more picked with ⇧/⌘-click or a drag box.
public struct TimelineSelection: Equatable {
  public var primary: Selection?
  public var others: [Selection]

  public init(primary: Selection?, others: [Selection] = []) {
    self.primary = primary
    self.others = others
  }

  /// Everything selected, the inspector's item first.
  public var all: [Selection] { (primary.map { [$0] } ?? []) + others }

  /// A click selects one item; ⇧/⌘-click adds it to (or takes it out of) the selection.
  public mutating func click(_ s: Selection, adding: Bool) {
    guard adding else {
      primary = s
      others = []
      return
    }
    if primary == s {
      primary = others.first
      if !others.isEmpty { others.removeFirst() }
    } else if let i = others.firstIndex(of: s) {
      others.remove(at: i)
    } else if primary == nil {
      primary = s
    } else {
      others.append(s)
    }
  }

  /// A drag box selects what it touches (added to the selection with ⇧).
  public mutating func box(_ items: [Selection], adding: Bool) {
    var picked = adding ? all : []
    for s in items where !picked.contains(s) { picked.append(s) }
    primary = picked.first
    others = Array(picked.dropFirst())
  }
}

extension Plan {
  /// Whether a selection still points at something in this plan.
  public func has(_ s: Selection) -> Bool {
    switch s {
    case .segment(let i): return segments.indices.contains(i)
    case .zoom(let i): return zooms.indices.contains(i)
    case .layout(let i): return layouts.indices.contains(i)
    case .callout(let i): return callouts.indices.contains(i)
    case .annotation(let i): return annotationList.indices.contains(i)
    case .marker(let i): return markerList.indices.contains(i)
    case .insert(let i): return insertList.indices.contains(i)
    case .animation(let i): return animationList.indices.contains(i)
    case .sfx(let i): return (sfx ?? []).indices.contains(i)
    case .gap(let g): return gaps.contains(g)
    }
  }

  /// The source range of a selected item (a marker or sound effect is a point).
  public func timeRange(of s: Selection) -> (Double, Double)? {
    guard has(s) else { return nil }
    switch s {
    case .segment(let i): return (segments[i].start, segments[i].end)
    case .zoom(let i): return (zooms[i].start, zooms[i].end)
    case .layout(let i): return (layouts[i].start, layouts[i].end)
    case .callout(let i): return (callouts[i].start, callouts[i].end)
    case .annotation(let i): return (annotationList[i].start, annotationList[i].end)
    case .marker(let i): return (markerList[i].t, markerList[i].t)
    case .insert(let i): return (insertList[i].start, insertList[i].end)
    case .animation(let i): return (animationList[i].start, animationList[i].end)
    case .sfx(let i): return (sfx![i].t, sfx![i].t)
    case .gap(let g): return (g.start, g.end)
    }
  }

  /// ⌘A: every zoom, layout, title and annotation (the things that move as a group).
  public var allMovableItems: [Selection] {
    zooms.indices.map { .zoom($0) } + layouts.indices.map { .layout($0) } + callouts.indices.map { .callout($0) }
      + annotationList.indices.map { .annotation($0) }
  }

  /// Deletes the selected items: clips are cut and cuts restored by time (indices shift as the
  /// clips change); the rest are removed by index, last first.
  public mutating func delete(_ items: [Selection]) {
    var cuts: [Range<Double>] = [], restores: [Gap] = []
    var zoomIdx: [Int] = [], layoutIdx: [Int] = [], calloutIdx: [Int] = [], markIdx: [Int] = [], markerIdx: [Int] = []
    var insertIdx: [Int] = [], animationIdx: [Int] = [], effectIdx: [Int] = []
    for s in items {
      switch s {
      case .segment(let i) where segments.indices.contains(i): cuts.append(segments[i].start..<segments[i].end)
      case .gap(let g): restores.append(g)
      case .zoom(let i): zoomIdx.append(i)
      case .layout(let i): layoutIdx.append(i)
      case .callout(let i): calloutIdx.append(i)
      case .annotation(let i): markIdx.append(i)
      case .marker(let i): markerIdx.append(i)
      case .insert(let i): insertIdx.append(i)
      case .animation(let i): animationIdx.append(i)
      case .sfx(let i): effectIdx.append(i)
      default: break
      }
    }
    func removing<T>(_ list: [T], _ idx: [Int]) -> [T] {
      var list = list
      for i in idx.sorted(by: >) where list.indices.contains(i) { list.remove(at: i) }
      return list
    }
    insertList = removing(insertList, insertIdx)
    animationList = removing(animationList, animationIdx)
    zooms = removing(zooms, zoomIdx)
    layouts = removing(layouts, layoutIdx)
    callouts = removing(callouts, calloutIdx)
    annotationList = removing(annotationList, markIdx)
    markerList = removing(markerList, markerIdx)
    let effects = removing(sfx ?? [], effectIdx)
    sfx = effects.isEmpty ? nil : effects
    for g in restores { restore(g) }
    for r in cuts { cut(range: r) }
  }

  /// How far the movable items among `items` can shift by `delta` seconds as a group without
  /// leaving the recording; nil when they can't move at all.
  public func groupShift(_ items: [Selection], by delta: Double) -> Double? {
    let ranges = items.filter(\.movable).compactMap { timeRange(of: $0) }
    guard let lo = ranges.map(\.0).min(), let hi = ranges.map(\.1).max() else { return nil }
    let d = min(max(delta, -lo), source.duration - hi)
    return abs(d) > 1e-9 ? d : nil
  }

  /// Shifts the movable items among `items` by `d` seconds, normalizes, and returns where each
  /// moved item is now (normalizing re-sorts the lists).
  public mutating func shift(_ items: [Selection], by d: Double) -> [Selection] {
    var marks = annotationList, pins = markerList, clips = insertList, anims = animationList, effects = sfx ?? []
    var moved: [(Selection, Any)] = []
    for s in items {
      switch s {
      case .zoom(let i) where zooms.indices.contains(i):
        zooms[i].start += d
        zooms[i].end += d
        moved.append((s, zooms[i]))
      case .layout(let i) where layouts.indices.contains(i):
        layouts[i].start += d
        layouts[i].end += d
        moved.append((s, layouts[i]))
      case .callout(let i) where callouts.indices.contains(i):
        callouts[i].start += d
        callouts[i].end += d
        moved.append((s, callouts[i]))
      case .annotation(let i) where marks.indices.contains(i):
        marks[i].start += d
        marks[i].end += d
        moved.append((s, marks[i]))
      case .marker(let i) where pins.indices.contains(i):
        pins[i].t += d
        moved.append((s, pins[i]))
      case .insert(let i) where clips.indices.contains(i):
        clips[i].start += d
        clips[i].end += d
        moved.append((s, clips[i]))
      case .animation(let i) where anims.indices.contains(i):
        anims[i].move(by: d)
        moved.append((s, anims[i]))
      case .sfx(let i) where effects.indices.contains(i):
        effects[i].t += d
        moved.append((s, effects[i]))
      default: break
      }
    }
    annotationList = marks
    markerList = pins
    insertList = clips
    animationList = anims
    sfx = effects.isEmpty ? nil : effects
    normalize()
    return moved.compactMap { s, value in
      switch (s, value) {
      case (.zoom, let z as Zoom): return zooms.firstIndex(of: z).map { .zoom($0) }
      case (.layout, let l as LayoutRange): return layouts.firstIndex(of: l).map { .layout($0) }
      case (.callout, let c as Callout): return callouts.firstIndex(of: c).map { .callout($0) }
      case (.annotation, let a as Annotation): return annotationList.firstIndex(of: a).map { .annotation($0) }
      case (.marker, let m as Marker): return markerList.firstIndex(of: m).map { .marker($0) }
      case (.insert, let c as Insert): return insertList.firstIndex(of: c).map { .insert($0) }
      case (.animation, let a as Animation): return animationList.firstIndex(of: a).map { .animation($0) }
      case (.sfx, let e as SoundEffect): return (sfx ?? []).firstIndex(of: e).map { .sfx($0) }
      default: return nil
      }
    }
  }

  /// A copy of zoom `i` placed half a second after it, kept inside the recording.
  public func duplicateOfZoom(_ i: Int) -> Zoom? {
    guard zooms.indices.contains(i) else { return nil }
    var z = zooms[i]
    let len = z.end - z.start
    z.start = min(z.end + 0.5, source.duration - len)
    z.end = z.start + len
    return z
  }

  /// ; and ': the marker before or after source time `t` (a 0.05 s margin skips the one you're on).
  public func marker(from t: Double, step: Int) -> Marker? {
    step > 0 ? markerList.first { $0.t > t + 0.05 } : markerList.last { $0.t < t - 0.05 }
  }
}

/// S: the clip speed after `speed` in 1, 1.5, 2, 3, 4, 8, then back to 1.
public func nextClipSpeed(after speed: Double) -> Double {
  [1.0, 1.5, 2, 3, 4, 8].first { $0 > speed + 0.01 } ?? 1
}

/// = and -: a zoom level moved by `delta`, kept within 1.1-3 and rounded to tenths.
public func nudgedZoomScale(_ scale: Double, by delta: Double) -> Double {
  (min(max(scale + delta, 1.1), 3) * 10).rounded() / 10
}

/// The in/out range, when both ends are set the right way round.
public func markedRange(in inPoint: Double?, out outPoint: Double?) -> Range<Double>? {
  guard let a = inPoint, let b = outPoint, b > a + 0.05 else { return nil }
  return a..<b
}

/// The word being said at source time `t`, if any (binary search; words are in order).
public func wordIndex(at t: Double, in words: [Word]) -> Int? {
  var lo = 0, hi = words.count - 1
  while lo <= hi {
    let mid = (lo + hi) / 2
    if t < words[mid].start { hi = mid - 1 } else if t >= words[mid].end { lo = mid + 1 } else { return mid }
  }
  return nil
}

/// The source time range selected words cover, from the first word's start to the last's end.
public func wordRange(_ sel: ClosedRange<Int>, in words: [Word]) -> Range<Double>? {
  guard sel.lowerBound >= 0, sel.upperBound < words.count else { return nil }
  let a = words[sel.lowerBound].start, b = words[sel.upperBound].end
  return b > a ? a..<b : nil
}

/// Whether every selected word is already cut (then the transcript's action is Restore).
public func wordsAreCut(_ sel: ClosedRange<Int>, in words: [Word], plan: Plan) -> Bool {
  guard sel.upperBound < words.count else { return false }
  return words[sel].allSatisfy { plan.speed(at: ($0.start + $0.end) / 2) == nil }
}

/// ⇧← and ⇧→ with words selected: grow or shrink the selection by a word at its end, never past
/// its first word or the last word.
public func extendWordSelection(_ sel: ClosedRange<Int>, by step: Int, wordCount: Int) -> ClosedRange<Int> {
  sel.lowerBound...min(max(sel.upperBound + step, sel.lowerBound), wordCount - 1)
}

/// Where you are in the editor, so "zoom here" or "cut this" mean something to the AI.
public func editorContext(
  plan: Plan?, words: [Word], playhead t: Double, selection: TimelineSelection, wordSelection: ClosedRange<Int>?, marked: Range<Double>?
) -> String {
  var lines: [String] = []
  let near = words.filter { $0.end > t - 2 && $0.start < t + 2 }.map(\.text).joined(separator: " ")
  lines.append("Playhead: source \(fmtTime(t))\(near.isEmpty ? "" : ", around \"\(near)\"")")
  if let sel = wordSelection, let r = wordRange(sel, in: words) {
    let text = words[sel].map(\.text).joined(separator: " ")
    lines.append("Selected transcript: source \(fmtTime(r.lowerBound))-\(fmtTime(r.upperBound)) \"\(text)\"")
  }
  if let plan, let selected = selection.primary, let line = selectedLine(selected, plan) { lines.append(line) }
  if !selection.others.isEmpty {
    let ranges = selection.others.compactMap { plan?.timeRange(of: $0) }.map { "\(fmtTime($0.0))-\(fmtTime($0.1))" }
    lines.append("Also selected: \(selection.others.count) more item(s) at source \(ranges.joined(separator: ", "))")
  }
  if let r = marked {
    let text = words.filter { $0.start < r.upperBound && $0.end > r.lowerBound }.map(\.text).joined(separator: " ")
    lines.append("In/out range: source \(fmtTime(r.lowerBound))-\(fmtTime(r.upperBound))\(text.isEmpty ? "" : " \"\(text)\"")")
  }
  return lines.joined(separator: "\n")
}

private func selectedLine(_ selection: Selection, _ plan: Plan) -> String? {
  guard plan.has(selection) else { return nil }
  switch selection {
  case .segment(let i):
    let s = plan.segments[i]
    return "Selected clip: source \(fmtTime(s.start))-\(fmtTime(s.end)) at \(s.speed.formatted())x"
  case .zoom(let i):
    return "Selected zoom #\(i): source \(fmtTime(plan.zooms[i].start))-\(fmtTime(plan.zooms[i].end))"
  case .layout(let i):
    return "Selected layout #\(i): source \(fmtTime(plan.layouts[i].start))-\(fmtTime(plan.layouts[i].end))"
  case .callout(let i):
    return "Selected title #\(i): \"\(plan.callouts[i].text)\""
  case .annotation(let i):
    let a = plan.annotationList[i]
    return "Selected annotation #\(i): \(a.kind) source \(fmtTime(a.start))-\(fmtTime(a.end))"
  case .gap(let g):
    return "Selected cut: source \(fmtTime(g.start))-\(fmtTime(g.end))"
  case .insert(let i):
    let c = plan.insertList[i]
    return "Selected B-roll #\(i): \(c.file) source \(fmtTime(c.start))-\(fmtTime(c.end))"
  case .animation(let i):
    let a = plan.animationList[i]
    return "Selected animation #\(i): \(a.template) source \(fmtTime(a.start))-\(fmtTime(a.end))"
  case .marker(let i):
    let m = plan.markerList[i]
    return "Selected marker #\(i) at source \(fmtTime(m.t))\(m.label.map { " \"\($0)\"" } ?? "")"
  case .sfx(let i):
    let e = plan.sfx![i]
    return "Selected sound effect #\(i): \(e.file) at source \(fmtTime(e.t))"
  }
}
