import Foundation

// Clips played out of recording order (a cold open): mapping, editing, and everything placed by
// source time following its clip. Called from Checks.main; run with macos/test.sh.

func reorderChecks() {
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 30, captureStart: nil, camera: nil)
  var plan = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp/sd-reorder"), source: src))
  plan.intro = nil
  plan.outro = nil
  plan.segments = [Segment(start: 0, end: 5, speed: 1), Segment(start: 5, end: 12, speed: 1), Segment(start: 20, end: 25, speed: 1)]
  plan.zooms = [Zoom(start: 3, end: 11, x: 0.5, y: 0.5, scale: 2)]
  plan.callouts = [Callout(start: 20.5, end: 22, text: "Cold open")]
  plan.normalize()
  let fps = plan.output.fps

  // Old plans play in recording order until they're normalized; new ones play as listed.
  var old = plan
  old.version = 1
  old.segments = [plan.segments[2], plan.segments[0], plan.segments[1]]
  expect(mapPlan(old).map(\.start) == [0, 5, 20], "a version 1 plan plays in recording order")
  old.normalize()
  expect(old.version == 2 && old.segments.map(\.start) == [0, 5, 20], "normalizing an old plan sorts it once and moves it to version 2")

  // Move 9-12 and 20-25 around: a cold open of 20-25, then 9-12 before the start.
  var moved = plan
  expect(moved.move(range: 20..<25, before: nil), "move a range to the front")
  expect(moved.segments.map(\.start) == [20, 0, 5], "the moved clip plays first (\(moved.segments.map(\.start)))")
  let m = mapPlan(moved)
  expect(m.map(\.start) == [20, 0, 5] && m[1].outStart == 5 * fps, "mapping keeps play order (\(m.map(\.start)))")
  expect(srcToOut(m, 21, fps: fps) == Double(fps), "a moved moment maps to its new place")
  // Titles, zooms and captions follow their clip.
  let scene = Scene(plan: moved, words: [], clicks: [], shortcuts: [])
  expect(scene.callouts.first.map { $0.s == 0.5 * Double(fps) } == true, "a title moves with its clip")
  moved.normalize()
  expect(moved.segments.map(\.start) == [20, 0, 5], "normalize keeps play order")

  // A zoom spanning two clips that no longer play back to back splits into two pieces.
  var split = plan
  _ = split.move(range: 5..<12, before: nil)
  let pieces = zoomsToOut(split.zooms, mapPlan(split), fps: fps)
  // 5-12 plays first (0-7 s), then 0-5 (7-12 s): the zoom's 5-11 is at 0-6 s and its 3-5 at 10-12 s.
  expect(pieces.map { [$0.startF, $0.endF] } == [[0, 6 * Double(fps)], [10 * Double(fps), 12 * Double(fps)]],
    "a zoom across a moved boundary plays in two pieces (\(pieces.map { [$0.startF, $0.endF] }))")
  expect(srcRangeToOut(mapPlan(plan), 3, 11, fps: fps).count == 1, "in recording order a range is one piece")

  // Moving before a moment, restoring and trimming go by the recording.
  var before = plan
  expect(before.move(range: 20..<25, before: 5), "move a range before a moment")
  expect(before.segments.map(\.start) == [0, 20, 5], "it plays just before that moment (\(before.segments.map(\.start)))")
  expect(!before.move(range: 0..<10, before: 3), "can't move a range before a moment inside it")
  before.restore(Gap(start: 12, end: 20))
  expect(before.segments.map(\.start) == [0, 20, 5, 12], "a restored cut plays after its neighbor in the recording (\(before.segments.map(\.start)))")
  var trim = moved
  trim.trimSegment(0, start: 2)
  expect(trim.segments[0].start == 12, "a moved clip trims back only to its neighbor in the recording (\(trim.segments[0].start))")

  // Captions don't run a page across a jump; pages come out in play order.
  let words = [Word(text: "first", start: 4, end: 4.4), Word(text: "second", start: 4.5, end: 4.9), Word(text: "open", start: 21, end: 21.4)]
  let pages = Scene.captionPages(words, mapPlan(moved), fps: fps, maxWords: 7)
  expect(pages.map { $0.words.map(\.text) } == [["open"], ["first", "second"]], "caption pages split at a jump, in play order (\(pages.map { $0.words.map(\.text) }))")
  // A word straddling a cut captions in the clip holding most of it. The cold open's "shows" was
  // timed 13.19-13.26 against a clip from 13.22, so it started in the clip before, which plays later.
  var coldOpen = plan
  coldOpen.segments = [Segment(start: 10, end: 15, speed: 1), Segment(start: 0, end: 10, speed: 1)]
  let straddling = Scene.captionPages([Word(text: "shows", start: 9.97, end: 10.05)], mapPlan(coldOpen), fps: fps, maxWords: 7)
  expect(straddling.first?.startF == 0, "a word straddling a cut captions where most of it plays (\(straddling.map(\.startF)))")
  // Mostly in a cut: cut on purpose, so no caption.
  let mostlyCut = Scene.captionPages([Word(text: "um", start: 19.7, end: 20.05)], mapPlan(moved), fps: fps, maxWords: 7)
  expect(mostlyCut.isEmpty, "a word mostly in a cut stays uncaptioned")
  // A word running past its clip's end ends with the clip, not where the rest of it plays.
  let straddle = Scene.captionPages([Word(text: "last", start: 24.8, end: 26)], mapPlan(moved), fps: fps, maxWords: 7)
  expect(straddle.first.map { $0.endF == 5 * Double(fps) } == true, "a word past its clip ends with the clip (\(straddle.map(\.endF)))")

  // Describe marks the jump and lists the cuts.
  let text = describe(Project(dir: URL(fileURLWithPath: "/tmp/sd-reorder"), source: src), moved)
  expect(text.contains("MOVED") && text.contains("CUT  src 0:12.0-0:20.0"), "describe marks moved clips and lists the cuts")

  // Repeats: a moment plays again first and still in its place. Zooms and captions play with both
  // showings; titles only with the first (the original).
  var twice = plan
  twice.captions.enabled = true
  twice.zooms = [Zoom(start: 21, end: 22, x: 0.5, y: 0.5, scale: 2)]
  expect(twice.repeatRange(20.5..<22, before: nil), "repeat a range at the start")
  twice.normalize()
  expect(twice.segments.count == 4 && twice.segments[0].repeats == true && twice.segments[0].start == 20.5, "the repeat plays first and survives normalize (\(twice.segments.map { [$0.start, $0.end] }))")
  let tm = mapPlan(twice)
  expect(abs(planSeconds(twice) - planSeconds(plan) - 1.5) < 0.05, "the video is longer by the repeat")
  expect(srcToOut(tm, 21, fps: fps) == (1.5 + 12 + 1) * Double(fps), "a repeated moment maps to its original showing (\(String(describing: srcToOut(tm, 21, fps: fps))))")
  expect(zoomsToOut(twice.zooms, tm, fps: fps).count == 2, "a zoom inside a repeat plays in both showings")
  let twiceScene = Scene(plan: twice, words: [Word(text: "open", start: 21, end: 21.4)], clicks: [], shortcuts: [])
  expect(twiceScene.callouts.count == 1 && twiceScene.callouts[0].s == (1.5 + 12.5) * Double(fps), "a title plays only at the original")
  expect(twiceScene.pages.count == 2, "captions play in both showings (\(twiceScene.pages.map(\.startF)))")
  var moveAround = twice
  _ = moveAround.move(range: 20..<25, before: nil)
  expect(moveAround.segments.filter { $0.repeats == true }.count == 1 && moveAround.segments[0].repeats != true, "moving a range leaves its repeat alone")
  var trimRepeat = twice
  trimRepeat.trimSegment(0, start: 19)
  expect(trimRepeat.segments[0].start == 19, "a repeat trims freely over the clips it repeats")
  expect(describe(Project(dir: URL(fileURLWithPath: "/tmp/sd-reorder"), source: src), twice).contains("REPEAT"), "describe marks a repeat")
  expect(!twice.repeatRange(13..<18, before: nil), "can't repeat a range that's entirely cut")
}
