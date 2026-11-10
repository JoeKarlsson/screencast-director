import Foundation

// `director review`'s polish notes (Polish.swift) and the camera timing they measure: moves timed
// by distance, settled before clicks; and pauses cut with a breath after sentences. Called from
// Checks.main; run with macos/test.sh.

func polishChecks() {
  // A cut pause keeps a breath after a sentence, a longer landing after a long one, and only the
  // usual edges mid-sentence.
  let pauseProject = Project(
    dir: URL(fileURLWithPath: "/tmp"), source: Project.Source(video: "s.mp4", width: 1920, height: 1080, duration: 20, captureStart: nil, camera: nil))
  let spoken = [
    Word(text: " so", start: 0, end: 1), Word(text: " this", start: 2, end: 3),  // 1 s mid-sentence
    Word(text: " works.", start: 3.2, end: 4), Word(text: " Next", start: 4.9, end: 5.5),  // 0.9 s after a sentence
    Word(text: " step.", start: 5.6, end: 6.5), Word(text: " Now", start: 9, end: 10),  // 2.5 s: a new thought
  ]
  var paced = buildPlan(pauseProject)
  paced.segments = [Segment(start: 0, end: 10, speed: 1)]
  paced.retrimPauses(words: spoken, level: .normal)
  func kept(_ a: Double, _ b: Double) -> Double {
    paced.segments.reduce(0.0) { $0 + max(0, min($1.end, b) - max($1.start, a)) }
  }
  expect(abs(kept(1, 2) - 0.24) < 0.01, "a mid-sentence pause keeps 0.12 s each side (\(kept(1, 2)))")
  expect(abs(kept(4, 4.9) - 0.45) < 0.01, "a pause after a sentence keeps a 0.45 s breath (\(kept(4, 4.9)))")
  expect(abs(kept(6.5, 9) - 0.7) < 0.01, "a long pause after a sentence lands softly in 0.7 s (\(kept(6.5, 9)))")
  expect(paced.segments.contains { $0.start <= 4 && $0.end >= 4.33 }, "the breath sits after the sentence, not before the next")
  // Whisper stretched "But" into the pause: it's still a pause mid-sentence, not after "years."
  var stretched = buildPlan(pauseProject)
  stretched.segments = [Segment(start: 0, end: 6, speed: 1)]
  let quiet = [(2.2, 3.2)]
  stretched.retrimPauses(
    words: [Word(text: " years.", start: 1, end: 1.9), Word(text: " But", start: 2.0, end: 2.6), Word(text: " now", start: 3.2, end: 4)],
    level: .normal, silences: quiet)
  let left = stretched.segments.reduce(0.0) { $0 + max(0, min($1.end, 3.2) - max($1.start, 2.2)) }
  expect(abs(left - 0.24) < 0.01, "a pause after a stretched word mid-sentence keeps only the edges (\(left))")

  // Move time follows distance: one octave is the transition, a nudge is quicker, a trip slower.
  expect(abs(cameraMoveFactor(from: [1, 0.5, 0.5], to: [2, 0.5, 0.5]) - 1) < 1e-9, "a 1x-2x zoom takes the transition")
  expect(cameraMoveFactor(from: [2, 0.5, 0.5], to: [2, 0.52, 0.5]) == 0.6, "a small nudge is quick (floor 0.6)")
  expect(cameraMoveFactor(from: [1, 0.5, 0.5], to: [3, 0.1, 0.9]) == 1.35, "a long trip is slower (cap 1.35)")

  let fps = 30
  let one = mapSegments([Segment(start: 0, end: 20, speed: 1)], fps: fps)
  func arrival(_ z: Zoom) -> Int {
    let path = cameraSteps(zooms: zoomsToOut([z], one, fps: fps), fps: fps, transition: 0.8, style: .named("smooth"), lead: 0.3, restClicks: nil)
    return (0..<600).first { path.at(Double($0)) == [z.scale, z.x, z.y] } ?? -1
  }
  let near = arrival(Zoom(start: 5, end: 9, x: 0.52, y: 0.5, scale: 1.2)), far = arrival(Zoom(start: 5, end: 9, x: 0.8, y: 0.2, scale: 2.4))
  expect(near > 0 && near == far, "a short and a long zoom-in arrive on the same frame (\(near), \(far))")
  let farPath = cameraSteps(
    zooms: zoomsToOut([Zoom(start: 5, end: 9, x: 0.8, y: 0.2, scale: 2.4)], one, fps: fps), fps: fps, transition: 0.8, style: .named("smooth"), lead: 0.3,
    restClicks: nil)
  let nearPath = cameraSteps(
    zooms: zoomsToOut([Zoom(start: 5, end: 9, x: 0.52, y: 0.5, scale: 1.2)], one, fps: fps), fps: fps, transition: 0.8, style: .named("smooth"), lead: 0.3,
    restClicks: nil)
  let farStart = (0..<600).first { farPath.at(Double($0)) != [1, 0.5, 0.5] } ?? -1
  let nearStart = (0..<600).first { nearPath.at(Double($0)) != [1, 0.5, 0.5] } ?? -1
  expect(farStart < nearStart, "the longer move starts earlier (\(farStart) vs \(nearStart))")

  // A cropped screen parks on each click before it lands.
  let rest = cameraSteps(zooms: [], fps: fps, transition: 0.8, style: .named("smooth"), lead: 0.3, restClicks: [(f: 150, x: 0.2, y: 0.7)])
  expect(rest.at(150 - 0.15 * Double(fps)) == [1, 0.2, 0.7] && rest.at(150) == [1, 0.2, 0.7], "the camera is parked on the click before it")

  // Polish notes on a plan that does each thing wrong once.
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-polish-\(UUID().uuidString)")
  let project = Project(
    dir: dir, source: Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 60, captureStart: nil, camera: nil),
    events: [InputEvent(t: 5, type: .click, x: 0.8, y: 0.2), InputEvent(t: 40, type: .click, x: 0.3, y: 0.3)])
  var plan = buildPlan(project)
  plan.intro = nil
  plan.outro = nil
  plan.style.motion = "smooth"
  plan.segments = [
    Segment(start: 0, end: 10, speed: 1), Segment(start: 12, end: 20, speed: 1, transition: "whip"), Segment(start: 22, end: 30, speed: 1, transition: "whip"),
    Segment(start: 32, end: 50, speed: 1),
  ]
  // Starts on the click, so the camera is still flying in as it lands; the one at 40 is settled.
  plan.zooms = [Zoom(start: 5, end: 8, x: 0.8, y: 0.2, scale: 2), Zoom(start: 39.2, end: 43, x: 0.3, y: 0.3, scale: 1.6)]
  plan.callouts = [
    Callout(start: 14, end: 15.5, text: "Connect every app your agent needs in one place"),
    Callout(start: 24, end: 27, text: "Plugins", style: "chapter"),
  ]
  plan.annotations = [Annotation(start: 24, end: 27, kind: "box", x: 0.1, y: 0.1, w: 0.2, h: 0.2)]
  plan.sfxList = (0..<4).map { SoundEffect(t: 33 + Double($0), file: "sfx/tick.wav") }
  var anim = Animation(start: 44, end: 49, template: "storyboard", data: .null, cues: (0..<6).reduce(into: [:]) { $0["s\($1)"] = 44.5 + Double($1) * 0.5 })
  anim.sounds = (0..<6).reduce(into: [:]) { $0["s\($1)"] = Sound(file: "sfx/pop.wav") }
  plan.animationList = [anim]
  let notes = Polish.notes(project, plan)
  func has(_ kind: String, _ text: String) -> Bool { notes.contains { $0.kind == kind && $0.text.contains(text) } }
  expect(has("camera", "click at out 0:05"), "a zoom that lands on its click is flagged (\(notes.map(\.text)))")
  expect(!notes.contains { $0.text.contains("click at out 0:3") }, "a zoom settled before its click isn't")
  expect(has("reading", "\"Connect every app"), "a nine-word title up 1.5 s is too short to read")
  expect(!has("reading", "\"Plugins\""), "a one-word title up 3 s is fine")
  expect(has("transitions", "two whip transitions in a row"), "the same transition twice in a row")
  expect(has("transitions", "2 of 3 cuts"), "styled transitions on most cuts")
  expect(has("sound", "4 sound effects in 10 s"), "four free sounds in four seconds is busy")
  expect(notes.filter { $0.kind == "sound" }.count == 1, "an animation's beat sounds don't count as busy")
  expect(has("overlays", "enter together"), "a title and a box entering on the same frame")

  // Speed limits follow the motion style: snappy moves faster before a move reads as a whip.
  var snappy = plan
  snappy.style.motion = "snappy"
  expect(Polish.speedLimits(snappy).zoom > Polish.speedLimits(plan).zoom, "snappy allows faster zooms than smooth")
  var whip = plan
  whip.zooms = [Zoom(start: 2, end: 6, x: 0.9, y: 0.1, scale: 2.5, seconds: 0.25), Zoom(start: 6, end: 8, x: 0.1, y: 0.9, scale: 2.5, seconds: 0.25)]
  let whipNotes = Polish.notes(project, whip)
  expect(whipNotes.contains { $0.text.contains("screens/s") } && whipNotes.contains { $0.text.contains("octaves/s") }, "quarter-second moves are too fast (\(whipNotes.map(\.text)))")
}

/// `director scan`'s hitches and black frames, and review's camera frame-rate note.
func scanPolishChecks() {
  let times = (0..<90).map { Double($0) / 30 }
  // Moving throughout, with one repeated frame at 1 s: a hitch.
  var diffs = [Double](repeating: 0.02, count: 90)
  diffs[0] = 0
  diffs[30] = 0
  expect(ShotScan.hitches(times: times, diffs: diffs) == [1], "a repeated frame mid-move is a hitch")
  // A 25 fps source in 30 fps: one frame in six repeats, steadily. Each is a hitch.
  let cadence = (0..<90).map { $0 > 0 && $0 % 6 == 0 ? 0.0 : 0.02 }
  expect(ShotScan.hitches(times: times, diffs: cadence).count >= 12, "a 25-in-30 cadence repeats every sixth frame")
  // An animation stepping on twos and threes (12 fps in 30): its repeats are the look, not hitches.
  let stepped = (0..<90).map { [0.02, 0.0, 0.02, 0.0, 0.0][$0 % 5] }
  expect(ShotScan.hitches(times: times, diffs: stepped).isEmpty, "stepped animation isn't a hitch")
  // Black mid-video counts; a fade from black in the first second doesn't.
  let levels = (0..<90).map { $0 < 10 || (45...50).contains($0) ? 0.0 : 0.5 }
  let black = ShotScan.blackStretches(times: times, levels: levels)
  expect(black.count == 1 && abs(black[0].start - 1.5) < 1e-9 && abs(black[0].end - 51.0 / 30) < 1e-9, "black frames mid-video (\(black))")

  // A 25 fps camera in a 30 fps video judders; 60 or 30 doesn't.
  let dir = FileManager.default.temporaryDirectory
  let project = Project(dir: dir, source: Project.Source(video: "s.mp4", width: 1920, height: 1080, duration: 10, captureStart: nil, camera: nil))
  var plan = buildPlan(project)
  plan.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  expect(Polish.frameRate(plan, cameraFPS: 24.97).first?.text.contains("output.fps 25") == true, "a 25 fps camera in 30 fps is named")
  expect(Polish.frameRate(plan, cameraFPS: 60).isEmpty && Polish.frameRate(plan, cameraFPS: 29.97).isEmpty, "60 and 29.97 fps cameras are fine")
}
