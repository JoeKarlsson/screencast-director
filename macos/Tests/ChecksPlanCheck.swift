import Foundation

// What `director validate` (PlanCheck) adds beyond positions, overlaps, styles and files (those are
// in ChecksFiles): keys the decoder ignores, eases and presets, items too short to read, and
// describe's warnings. Called from Checks.main; run with macos/test.sh.

func planCheckExtraChecks() {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-validate-extra-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let project = Project(dir: dir, source: Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 30, captureStart: nil, camera: nil))
  var plan = buildPlan(project)
  plan.intro = nil
  plan.outro = nil
  plan.segments = [Segment(start: 0, end: 10, speed: 1), Segment(start: 12, end: 20, speed: 2)]
  plan.zooms = [Zoom(start: 2, end: 5, x: 0.5, y: 0.5, scale: 2)]
  plan.callouts = [Callout(start: 3, end: 6, text: "Open Settings", style: "chapter")]
  guard let clean = try? JSONEncoder().encode(plan), var json = (try? JSONSerialization.jsonObject(with: clean)) as? [String: Any],
    var callout = (json["callouts"] as? [[String: Any]])?.first
  else {
    expect(false, "a plan encodes to JSON with a callout")
    return
  }
  let sound = PlanCheck.check(plan, project: project, templates: nil, raw: clean).problems
  expect(sound.isEmpty, "a sound plan, as encoded, has no problems (\(sound))")
  var offPlan = plan
  offPlan.music = Music(file: "/tmp/track.m4a", off: [MusicOff(start: 5, end: 8), MusicOff(start: 9, end: 7), MusicOff(start: 40, end: 45)])
  let offProblems = PlanCheck.check(offPlan, project: project, templates: nil).problems.filter { $0.hasPrefix("music.off") }
  expect(offProblems.count == 2 && offProblems[0].hasPrefix("music.off[1]: start 9") && offProblems[1].hasPrefix("music.off[2]: starts at 40"),
    "validate flags a music.off range that ends before it starts or lies outside the recording (\(offProblems))")

  // A misspelled key decodes to nothing; validate names it, and suggests the near one it knows.
  callout["styl"] = "slate"
  callout["sound"] = NSNull()
  json["callouts"] = [callout]
  json["captionz"] = ["enabled": true]
  guard let typo = try? JSONSerialization.data(withJSONObject: json), let typoPlan = try? JSONDecoder().decode(Plan.self, from: typo) else {
    expect(false, "a plan with unknown keys still loads")
    return
  }
  let ignored = PlanCheck.ignoredKeys(raw: typo, plan: typoPlan)
  expect(ignored.count == 2, "two ignored keys, and a null isn't one (\(ignored))")
  expect(ignored.contains { $0.hasPrefix("callouts[0].styl isn't a field") }, "the misspelled callout key is named by its path")
  expect(ignored.contains { $0.hasPrefix("captionz") && $0.contains("\"captions\"") }, "a near miss suggests the real key")
  expect(PlanCheck.check(typoPlan, project: project, templates: nil, raw: typo).problems.count == 2, "validate reports the ignored keys")
  expect(PlanCheck.check(typoPlan, project: project, templates: nil).problems.isEmpty, "without the file there are no keys to compare")

  var bad = plan
  bad.zooms.append(Zoom(start: 6, end: 6.5, x: 0.5, y: 0.5, scale: 2, ease: "wobbly"))
  bad.callouts.append(Callout(start: 8, end: 9.5, text: " ", exit: Motion(preset: "spin")))
  bad.inserts = [Insert(start: 1, end: 3, file: "screen.mp4", placement: "corner")]
  bad.camera = Plan.Camera(video: "screen.mp4", offset: 0)
  bad.camera?.punchIns = [PunchIn(start: 2, end: 3, scale: 2, x: 1.5)]
  bad.markers = [Marker(t: 31)]
  bad.captions.style = "comic"
  let problems = PlanCheck.check(bad, project: project, templates: nil).problems
  func has(_ text: String) -> Bool { problems.contains { $0.contains(text) } }
  expect(has("zooms[1] is on screen for only 0.5 s"), "a half-second zoom is too short (\(problems))")
  expect(has("zooms[1].ease is \"wobbly\""), "an unknown ease is a problem")
  expect(has("callouts[1].text is empty"), "an empty title is a problem")
  expect(has("callouts[1].exit.preset is \"spin\""), "an unknown exit preset is a problem")
  expect(has("inserts[0].placement is \"corner\""), "an unknown B-roll placement is a problem")
  expect(has("camera.punchIns[0].x is 1.5"), "a punch-in framed off the camera is a problem")
  expect(has("markers[0].t is 31"), "a marker after the end is a problem")
  expect(has("captions.style is \"comic\""), "an unknown caption style is a problem")

  // describe's warnings come along: full camera over typing.
  var covered = plan
  covered.camera = Plan.Camera(video: "screen.mp4", offset: 0)
  covered.layouts = [LayoutRange(start: 0, end: 10, mode: .camera)]
  let coveredProject = Project(
    dir: project.dir, source: project.source, events: [InputEvent(t: 4, type: .key, x: 0.5, y: 0.5)])
  let warned = PlanCheck.check(covered, project: coveredProject, templates: nil).problems
  expect(warned.contains { $0.hasPrefix("full camera hides screen activity") }, "describe's WARNING lines are problems (\(warned))")
  expect(PlanCheck.editDistance("captionz", "captions") == 1 && PlanCheck.editDistance("", "ab") == 2, "edit distance")
}
