import Foundation

// Flashes (DirectorCore/Flashes.swift): under a second of one thing between two others, like the
// face for half a second between two B-roll clips, or a clip too short to register. Called from
// Checks.main; run with macos/test.sh.

func flashChecks() {
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 30, captureStart: nil, camera: nil)
  var plan = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp/sd-flash"), source: src))
  plan.intro = nil
  plan.outro = nil
  plan.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  plan.defaultLayout = .camera
  plan.layouts = []
  plan.zooms = []
  plan.segments = [Segment(start: 0, end: 20, speed: 1)]
  plan.inserts = [
    Insert(start: 2, end: 5, file: "broll/a.mov", placement: "full"),
    Insert(start: 5.5, end: 8, file: "broll/b.mov", placement: "full"),
  ]
  let found = flashes(plan)
  expect(found.count == 1 && found[0].what.contains("face") && abs(found[0].startF - 150) < 1 && abs(found[0].endF - 165) < 1,
    "half a second of face between two B-roll clips is a flash (\(found.map { describeFlash($0, plan) }))")

  // Back to back, a long stretch, or at the very start or end: no flash.
  plan.inserts?[1].start = 5
  expect(flashes(plan).isEmpty, "B-roll clips back to back don't flash")
  plan.inserts?[1].start = 6.5
  expect(flashes(plan).isEmpty, "a second and a half of face between clips is fine")
  plan.inserts = [Insert(start: 0, end: 19.5, file: "broll/a.mov", placement: "full")]
  expect(flashes(plan).isEmpty, "half a second at the very end has nothing after it, so it isn't a flash")

  // A layout held for a moment between two others flashes too, and so does a clip under half a second.
  plan.inserts = nil
  plan.layouts = [LayoutRange(start: 4, end: 4.4, mode: .pip)]
  expect(flashes(plan).count == 1, "a split for 0.4 s between full-camera stretches is a flash")
  plan.layouts = []
  plan.segments = [Segment(start: 0, end: 5, speed: 1), Segment(start: 8, end: 8.3, speed: 1), Segment(start: 12, end: 20, speed: 1)]
  let clip = flashes(plan)
  expect(clip.count == 1 && clip[0].what.contains("clip src 0:08.0"), "a 0.3 s clip is a flash (\(clip.map(\.what)))")
  expect(describeFlash(clip[0], plan).contains("0.3 s"), "a flash is told in seconds (\(describeFlash(clip[0], plan)))")
  // A frame or two of face between B-roll clips, as happened when one began a hair late.
  plan.segments = [Segment(start: 0, end: 20, speed: 1)]
  plan.inserts = [Insert(start: 2, end: 5, file: "broll/a.mov", placement: "full"), Insert(start: 5.034, end: 9, file: "broll/b.mov", placement: "full")]
  let blip = flashes(plan)
  expect(blip.count == 1 && describeFlash(blip[0], plan).contains("2 frames"), "a two-frame flash is caught and told in frames (\(blip.map { describeFlash($0, plan) }))")

  // Punch-ins change the shot too. One ending a moment before its clip's cut runs to the cut (no
  // sliver of the wide shot); one under a second is a flash; a cut between two clips of the face
  // half a second apart is a flash.
  plan.inserts = nil
  plan.segments = [Segment(start: 0, end: 10, speed: 1), Segment(start: 12, end: 20, speed: 1)]
  plan.camera?.punchIns = [PunchIn(start: 7, end: 9.7, scale: 2)]
  let snapped = Scene(plan: plan, words: [], clicks: [], shortcuts: [])
  expect(snapped.punchIns.first.map { $0.e == 10 * 30 } == true, "a punch-in ending 0.3 s before a cut runs to the cut (\(snapped.punchIns.map(\.e)))")
  expect(flashes(plan).isEmpty, "so there's no sliver of the wide shot")
  plan.camera?.punchIns = [PunchIn(start: 4, end: 4.6, scale: 2)]
  expect(flashes(plan).count == 1, "a 0.6 s punch-in is a flash")
  plan.camera?.punchIns = nil
  plan.segments = [Segment(start: 0, end: 5, speed: 1), Segment(start: 6, end: 6.5, speed: 1), Segment(start: 8, end: 20, speed: 1)]
  expect(flashes(plan).contains { $0.what.contains("clip src 0:06.0") }, "half a second of another clip of the face is a flash")
}
