import Foundation

// The editor's plan logic (DirectorCore/EditorActions.swift): timeline selection, delete, group
// moves, the keyboard edits, transcript selection and the context sent with an AI ask. Called from
// Checks.main; run with macos/test.sh.

func editorActionChecks() {
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 20, captureStart: nil, camera: nil)
  var base = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp/sd-editor"), source: src))
  base.intro = nil
  base.outro = nil
  base.segments = [Segment(start: 0, end: 8, speed: 1), Segment(start: 10, end: 20, speed: 1)]
  base.zooms = [Zoom(start: 1, end: 3, x: 0.5, y: 0.5, scale: 2), Zoom(start: 5, end: 7, x: 0.5, y: 0.5, scale: 2), Zoom(start: 12, end: 14, x: 0.5, y: 0.5, scale: 2)]
  base.callouts = [Callout(start: 2, end: 4, text: "Hi")]
  base.markers = [Marker(t: 4, label: "setup"), Marker(t: 12)]
  base.sfx = [SoundEffect(t: 6, file: "sfx/pop.m4a")]
  base.normalize()

  // Clicking: a plain click selects one item; ⇧/⌘-click adds or takes out; taking out the
  // inspector's item hands the inspector to the next one.
  var sel = TimelineSelection(primary: nil)
  sel.click(.zoom(0), adding: true)
  expect(sel == TimelineSelection(primary: .zoom(0)), "adding to nothing selects it")
  sel.click(.zoom(1), adding: true)
  sel.click(.callout(0), adding: true)
  expect(sel.all == [.zoom(0), .zoom(1), .callout(0)], "⇧-click adds (\(sel.all))")
  sel.click(.zoom(1), adding: true)
  expect(sel.all == [.zoom(0), .callout(0)], "⇧-click on a selected item takes it out")
  sel.click(.zoom(0), adding: true)
  expect(sel.primary == .callout(0) && sel.others.isEmpty, "taking out the inspector's item promotes the next")
  sel.click(.marker(1), adding: false)
  expect(sel == TimelineSelection(primary: .marker(1)), "a plain click replaces the selection")
  sel.box([.zoom(2), .marker(1), .zoom(0)], adding: true)
  expect(sel.all == [.marker(1), .zoom(2), .zoom(0)], "a ⇧-drag box adds what it touches, once each (\(sel.all))")
  sel.box([.zoom(1)], adding: false)
  expect(sel.all == [.zoom(1)], "a drag box without ⇧ replaces the selection")

  // What a selection points at, and the time it covers.
  expect(base.has(.zoom(2)) && !base.has(.zoom(3)) && !base.has(.sfx(1)) && base.has(.gap(Gap(start: 8, end: 10))), "selections check their index")
  expect(!base.has(.gap(Gap(start: 3, end: 4))), "a gap that isn't a cut doesn't exist")
  expect(base.timeRange(of: .zoom(1))! == (5, 7) && base.timeRange(of: .marker(0))! == (4, 4) && base.timeRange(of: .sfx(0))! == (6, 6), "time ranges")
  expect(base.timeRange(of: .callout(5)) == nil, "no range for a stale selection")
  let segs = base.segments.indices.map { Selection.segment($0) }
  expect(
    base.allItems == segs + [.zoom(0), .zoom(1), .zoom(2), .callout(0), .marker(0), .marker(1), .sfx(0)],
    "every item, track by track (\(base.allItems))")
  expect(base.allItems.filter(\.movable) == [.zoom(0), .zoom(1), .zoom(2), .callout(0), .marker(0), .marker(1), .sfx(0)], "⌘A picks every movable item, markers and sounds too")
  expect(base.allItems.allSatisfy { base.timeRange(of: $0) != nil }, "every item has a time range")

  // Delete: several kinds at once, by index last first; a clip is cut and a cut restored by time.
  var del = base
  del.delete([.zoom(0), .zoom(2), .marker(0), .sfx(0), .callout(9)])
  expect(del.zooms.map(\.start) == [5] && del.markerList.map(\.t) == [12] && del.sfx == nil && del.callouts.count == 1, "delete removes by index, last first")
  var cutRestore = base
  cutRestore.delete([.segment(1), .gap(Gap(start: 8, end: 10))])
  expect(cutRestore.speed(at: 9) == 1 && cutRestore.speed(at: 15) == nil, "deleting a clip cuts it and deleting a cut restores it")

  // Moving a group: clamped so nothing leaves the recording; non-movable items don't count.
  let group: [Selection] = [.zoom(0), .zoom(2), .segment(0)]
  expect(base.groupShift(group, by: -5) == -1, "the group stops at the start (the first zoom starts at 1 s)")
  expect(base.groupShift(group, by: 10) == 6, "and at the end (the last zoom ends at 14 of 20 s)")
  expect(base.groupShift([.segment(0)], by: 1) == nil && base.groupShift(group, by: 0) == nil, "nothing to move, or no distance")
  // A zoom moved past another is re-sorted, and the move says where it went.
  var moved = base
  let found = moved.shift([.zoom(0), .marker(0)], by: 5)
  expect(moved.zooms.map(\.start) == [5, 6, 12] && Set(found.map { "\($0)" }) == ["zoom(1)", "marker(0)"], "moved items are found after re-sorting (\(found))")
  expect(moved.markerList[0].t == 9, "a marker moves too")
  // Dragging or trimming a bar retimes it and finds it again after re-sorting.
  var dragged = base
  expect(dragged.retime(.zoom(0), start: 8, end: 9) == .zoom(1) && dragged.zooms.map(\.start) == [5, 8, 12], "a dragged zoom is found after re-sorting")
  expect(dragged.retime(.segment(0), start: 0, end: 1) == nil && dragged.segments == base.segments, "clips aren't retimed here (they're trimmed)")
  dragged.animationList = [Animation(start: 2, end: 4, template: "hub", data: .null, cues: ["lock": 3])]
  _ = dragged.retime(.animation(0), start: 6, end: 8)
  expect(dragged.animationList[0].cues == ["lock": 7], "dragging an animation takes its beats along")
  _ = dragged.retime(.animation(0), start: 6, end: 9)
  expect(dragged.animationList[0].end == 9 && dragged.animationList[0].cues == ["lock": 7], "trimming an animation leaves its beats")

  // Keyboard edits.
  expect(base.duplicateOfZoom(1).map { [$0.start, $0.end] } == [7.5, 9.5], "⌘D puts the copy half a second after")
  var late = base
  late.zooms = [Zoom(start: 17, end: 19, x: 0.5, y: 0.5, scale: 2)]
  expect(late.duplicateOfZoom(0).map { [$0.start, $0.end] } == [18, 20] && late.duplicateOfZoom(1) == nil, "a copy near the end stays inside")
  expect(base.marker(from: 4.02, step: 1)?.t == 12 && base.marker(from: 12, step: -1)?.t == 4 && base.marker(from: 13, step: 1) == nil, "marker jumps skip the one you're on")
  var speeds = [1.0]
  for _ in 0..<6 { speeds.append(nextClipSpeed(after: speeds.last!)) }
  expect(speeds == [1, 1.5, 2, 3, 4, 8, 1] && nextClipSpeed(after: 2.5) == 3, "S cycles clip speeds (\(speeds))")
  expect(nudgedZoomScale(2.95, by: 0.1) == 3 && nudgedZoomScale(1.2, by: -0.2) == 1.1 && nudgedZoomScale(1.84, by: 0.1) == 1.9, "zoom nudges clamp and round")
  expect(markedRange(in: 2, out: 5) == 2..<5 && markedRange(in: 5, out: 2) == nil && markedRange(in: 2, out: 2.03) == nil && markedRange(in: nil, out: 5) == nil, "in/out range")

  // Transcript selection.
  let words = [
    Word(text: "Hello", start: 0.5, end: 1), Word(text: "there", start: 1.2, end: 1.6), Word(text: "cut", start: 8.5, end: 9),
    Word(text: "back", start: 11, end: 11.5),
  ]
  expect(wordIndex(at: 1.3, in: words) == 1 && wordIndex(at: 1.1, in: words) == nil && wordIndex(at: 11, in: words) == 3 && wordIndex(at: 1, in: []) == nil, "word under the playhead")
  expect(wordRange(0...1, in: words) == 0.5..<1.6 && wordRange(2...4, in: words) == nil, "selected words' range")
  expect(wordsAreCut(2...2, in: words, plan: base) && !wordsAreCut(1...2, in: words, plan: base), "Restore only when every selected word is cut")
  expect(extendWordSelection(1...1, by: 1, wordCount: 4) == 1...2 && extendWordSelection(1...3, by: 1, wordCount: 4) == 1...3, "⇧→ grows to the last word")
  expect(extendWordSelection(1...2, by: -5, wordCount: 4) == 1...1, "⇧← shrinks to the first word")

  // What the AI hears about where you are.
  let context = editorContext(
    plan: base, words: words, playhead: 1.3, selection: TimelineSelection(primary: .zoom(1), others: [.marker(0)]), wordSelection: 0...1, marked: 10..<12)
  expect(
    context == """
      Playhead: source 0:01.3, around "Hello there"
      Selected transcript: source 0:00.5-0:01.6 "Hello there"
      Selected zoom #1: source 0:05.0-0:07.0
      Also selected: 1 more item(s) at source 0:04.0-0:04.0
      In/out range: source 0:10.0-0:12.0 "back"
      """, "ask context (\(context))")
  let stale = editorContext(plan: base, words: [], playhead: 5, selection: TimelineSelection(primary: .callout(7)), wordSelection: nil, marked: nil)
  expect(stale == "Playhead: source 0:05.0", "a stale selection adds nothing (\(stale))")
}
