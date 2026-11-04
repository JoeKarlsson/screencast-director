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
  // Effect ranges are timeline bars too: selected, retimed, moved and deleted like B-roll; one
  // left under 0.2 s or past the recording is trimmed or dropped.
  var ranged = base
  ranged.effectRangeList = [EffectRange(start: 9, end: 12, name: "track"), EffectRange(start: 3, end: 5, name: "track"), EffectRange(start: 18, end: 25, name: "track")]
  ranged.normalize()
  expect(ranged.effectRangeList.map(\.start) == [3, 9, 18] && ranged.effectRangeList[2].end == 20, "effect ranges are sorted and kept inside the recording")
  expect(ranged.allItems.suffix(3) == [.effectRange(0), .effectRange(1), .effectRange(2)] && ranged.timeRange(of: .effectRange(1))! == (9, 12), "effect ranges are timeline items")
  expect(ranged.retime(.effectRange(0), start: 13, end: 15) == .effectRange(1), "a dragged effect range is found after re-sorting")
  expect(ranged.shift([.effectRange(0)], by: 1) == [.effectRange(0)] && ranged.effectRangeList[0].start == 10, "an effect range moves with the group")
  ranged.delete([.effectRange(0), .effectRange(1), .effectRange(2)])
  expect(ranged.effectRanges == nil, "deleting every effect range clears the list")

  // Settings accessors start from the defaults and create the setting on first write.
  var settings = base
  settings.audio = nil
  settings.cursor = nil
  settings.audioSettings.normalize = true
  settings.cursorSettings.size = 40
  expect(settings.audio?.normalize == true && settings.cursor?.size == 40 && base.audioSettings == (base.audio ?? AudioSettings()), "audio and cursor settings write through")

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

  // Dragging a clip on the output timeline: three clips of 30, 60 and 30 frames, played at
  // 0-30, 30-90, 90-120. The drop lands at the nearest clip edge.
  let clips = mapSegments([Segment(start: 0, end: 1, speed: 1), Segment(start: 5, end: 7, speed: 1), Segment(start: 10, end: 11, speed: 1)], fps: 30)
  expect(clipDrop(moving: 2, atFrame: 5, mapped: clips)! == (0, 0), "dropping the last clip near the start plays it first")
  expect(clipDrop(moving: 0, atFrame: 100, mapped: clips)! == (2, 1), "dropping the first clip past the middle one's center puts it second")
  expect(clipDrop(moving: 0, atFrame: 119, mapped: clips)! == (3, 2), "dropping the first clip at the end plays it last")
  expect(clipDrop(moving: 1, atFrame: 50, mapped: clips) == nil, "dropping a clip onto itself does nothing")
  expect(clipDrop(moving: 1, atFrame: 20, mapped: clips) == nil, "dropping a clip at its own leading edge does nothing")
  expect(clipDrop(moving: 0, atFrame: 40, mapped: clips) == nil, "dropping a clip just after itself does nothing")
  expect(clipDrop(moving: 3, atFrame: 5, mapped: clips) == nil, "a stale clip index does nothing")
  var dropped = base
  dropped.moveSegment(1, to: clipDrop(moving: 1, atFrame: 0, mapped: mapPlan(base))!.target)
  expect(dropped.segments.map(\.start) == [10, 0], "the drop's target is what moveSegment takes (\(dropped.segments.map(\.start)))")
}

// Record B-roll: the file it records into and the full-frame insert it adds at the playhead.
func recordedBrollChecks() {
  let utc = TimeZone(identifier: "UTC")!
  let date = Date(timeIntervalSince1970: 1_793_712_345)  // 2026-11-03 13:25:45 UTC
  let first = RecordedBroll.file(at: date, timeZone: utc) { _ in false }
  expect(first == "broll/broll-20261103-132545.mov", "B-roll file name (\(first))")
  let taken: Set = ["broll/broll-20261103-132545.mov", "broll/broll-20261103-132545-2.mov"]
  let third = RecordedBroll.file(at: date, timeZone: utc) { taken.contains($0) }
  expect(third == "broll/broll-20261103-132545-3.mov", "a name taken in the same second gets a number (\(third))")

  let mid = RecordedBroll.insert(file: "broll/a.mov", playhead: 4, length: 2.5, duration: 20)
  expect(mid == Insert(start: 4, end: 6.5, file: "broll/a.mov", placement: "full"), "full-frame at the playhead for the clip's length (\(mid))")
  let late = RecordedBroll.insert(file: "broll/a.mov", playhead: 19, length: 3, duration: 20)
  expect(late.start == 17 && late.end == 20, "near the end it starts earlier to fit (\(late))")
  let long = RecordedBroll.insert(file: "broll/a.mov", playhead: 5, length: 30, duration: 20)
  expect(long.start == 0 && long.end == 20, "a clip longer than the recording covers it all (\(long))")
  let before = RecordedBroll.insert(file: "broll/a.mov", playhead: -1, length: 2, duration: 20)
  expect(before.start == 0 && before.end == 2, "a playhead before the start clamps to 0 (\(before))")
}

// The timeline's rows: ruler, clips and audio always; words with a transcript; the rest only while
// they have items, stacked without gaps for the hidden ones.
func timelineRowChecks() {
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 20, captureStart: nil, camera: nil)
  var plan = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp/sd-rows"), source: src))
  plan.intro = nil
  plan.outro = nil
  expect(TimelineRows(plan: nil, hasWords: true).visible == [.ruler, .clips, .audio], "with no plan, only the fixed rows show")
  let bare = TimelineRows(plan: plan, hasWords: false)
  expect(bare.visible == [.ruler, .clips, .audio], "an empty plan shows only the ruler, clips and audio (\(bare.visible))")
  expect(TimelineRows(plan: plan, hasWords: true).visible == [.ruler, .clips, .audio, .words], "a transcript adds the words row")
  plan.zooms = [Zoom(start: 1, end: 3, x: 0.5, y: 0.5, scale: 2)]
  plan.callouts = [Callout(start: 5, end: 6, text: "Hi")]
  var rows = TimelineRows(plan: plan, hasWords: false)
  expect(rows.visible == [.ruler, .clips, .audio, .zooms, .titles], "a zoom and a title add their rows (\(rows.visible))")
  expect(rows.y(.titles) == rows.y(.zooms) + TimelineTrack.zooms.height + TimelineRows.gap, "titles sit right under zooms when layouts are hidden")
  expect(rows.total == rows.y(.titles) + TimelineTrack.titles.height + TimelineRows.gap, "the timeline is as tall as its shown rows")
  plan.callouts[0].sound = Sound(file: "sfx/pop.m4a")
  rows = TimelineRows(plan: plan, hasWords: false)
  expect(rows.visible.last == .sounds, "a sound attached to a title shows the Sound FX row")
  expect(rows.y(.broll) == rows.total, "a hidden row sits below the shown ones")
}
