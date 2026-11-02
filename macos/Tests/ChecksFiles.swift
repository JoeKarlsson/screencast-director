import CoreImage
import Foundation

// Project files, export formats, the export queue and publishing helpers. Called from Checks.main;
// run with macos/test.sh.

func fileAndFormatChecks() {
  formatChecks()
  projectFileChecks()
  exportQueueChecks()
  publishHelperChecks()
}

/// A plan over a `duration`-second recording in `dir`, with no cards.
private func plainPlan(_ dir: URL, duration: Double, words: [Word] = []) -> (Project, Plan) {
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: duration, captureStart: nil, camera: nil)
  let project = Project(dir: dir, source: src, words: words)
  var plan = buildPlan(project)
  plan.intro = nil
  plan.outro = nil
  return (project, plan)
}

private func formatChecks() {
  // Every shape at every resolution: the short side is the resolution, both sides even, the ratio held.
  for aspect in Aspect.allCases {
    for res in Resolution.allCases {
      let size = outputSize(aspect, res)
      let ratio = Double(aspect.ratio.w) / Double(aspect.ratio.h)
      expect(min(size.width, size.height) == res.rawValue, "\(aspect.label) \(res.label): short side is \(res.rawValue) (\(size))")
      expect(size.width % 2 == 0 && size.height % 2 == 0, "\(aspect.label) \(res.label): even sides (\(size))")
      expect(abs(Double(size.width) / Double(size.height) - ratio) < 0.01, "\(aspect.label) \(res.label): keeps its ratio (\(size))")
      let output = Plan.Output(width: size.width, height: size.height, fps: 30)
      expect(Aspect.of(output) == aspect && Resolution.of(output) == res, "\(aspect.label) \(res.label) reads back from its size")
    }
  }
  expect(outputSize(.landscape, .p1080) == (1920, 1080) && outputSize(.vertical, .p1080) == (1080, 1920), "1080p landscape and vertical")
  expect(outputSize(.feed, .p1080) == (1080, 1350) && outputSize(.landscape, .p2160) == (3840, 2160), "4:5 feed and 4K")
  expect(outputSize(.landscape, .p720) == (1280, 720), "720p")
  // An odd size reads as the nearest shape and resolution.
  expect(Aspect.of(Plan.Output(width: 1366, height: 768, fps: 30)) == .landscape, "1366x768 is landscape")
  expect(Resolution.of(Plan.Output(width: 2560, height: 1600, fps: 30)) == .p1440, "1600 short side is nearest 1440p")
  expect(Resolution.p2160.label == "4K" && Resolution.p720.label == "720p", "resolution labels")

  // Presets reshape a copy of the plan: size and screen crop, nothing else.
  let (_, plan) = plainPlan(URL(fileURLWithPath: "/tmp/sd-formats"), duration: 10)
  expect(Set(ExportPreset.all.map(\.id)).count == ExportPreset.all.count, "preset ids are unique")
  for preset in ExportPreset.all {
    let shaped = preset.applied(to: plan)
    let size = outputSize(preset.aspect, preset.resolution)
    expect(shaped.output.width == size.width && shaped.output.height == size.height, "\(preset.id) sets the output size")
    expect(shaped.style.screenAspect == preset.screenAspect, "\(preset.id) sets the screen crop")
    expect(shaped.output.fps == plan.output.fps && shaped.segments == plan.segments, "\(preset.id) keeps the edit")
    expect((preset.aspect == .landscape) == (preset.screenAspect == nil), "\(preset.id): only non-landscape shapes crop the screen")
  }
}

private func projectFileChecks() {
  let fm = FileManager.default
  let dir = fm.temporaryDirectory.appendingPathComponent("sd-project-\(UUID().uuidString)")
  try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: dir) }
  func write(_ name: String, _ text: String) {
    try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  // Loading a recording folder: words, events on the video's clock, motion and the script.
  write("source.json", #"{"video":"screen.mp4","width":1920,"height":1080,"duration":20,"captureStart":100}"#)
  write(
    "transcript.json",
    #"{"segments":[{"words":[{"word":" Hello","start":1,"end":1.5},{"word":"  ","start":2,"end":2.2},{"word":"nostart","end":3}]},"#
      + #"{"words":[{"word":"there","start":4,"end":4.5}]}]}"#)
  write(
    "events.jsonl",
    [
      #"{"t":101.5,"type":"click","x":0.25,"y":0.75,"label":"Save"}"#,
      #"{"t":99,"type":"click","x":0,"y":0}"#,  // before the first frame
      #"{"t":121,"type":"key","x":0,"y":0}"#,  // after the end
      #"{"t":103,"type":"telepathy","x":0,"y":0}"#,  // unknown kind
      "not json",
      #"{"t":105,"type":"key","label":"⌘S"}"#,
    ].joined(separator: "\n"))
  write("motion.json", "[[0,0.5],[0.1],[0.2,0.75]]")
  write("script.md", "# Title\n---\nClick the record button.\n---\n")
  do {
    let loaded = try Project.load(dir)
    expect(loaded.words.map(\.text) == ["Hello", "there"], "words load trimmed, blank and untimed ones skipped (\(loaded.words.map(\.text)))")
    expect(loaded.events.count == 2 && loaded.events[0].t == 1.5 && loaded.events[0].x == 0.25 && loaded.events[0].label == "Save",
      "events move to the video's clock; early, late, unknown and broken lines are dropped (\(loaded.events))")
    expect(loaded.events[1].x == 0 && loaded.shortcuts.map(\.label) == ["⌘S"], "missing coordinates read as 0; ⌘ keys are shortcuts")
    expect(loaded.motion.map(\.0) == [0, 0.2] && loaded.motion.map(\.1) == [0.5, 0.75], "motion keeps only (time, value) pairs")
    expect(loaded.script == ["Click the record button"], "the script's lines load (\(loaded.script))")
    expect(loaded.clicks.count == 1 && loaded.cursorPath.isEmpty, "clicks; no drawn cursor unless the real one was hidden")
  } catch {
    expect(false, "project loads: \(error)")
  }
  // Measured loudness snaps word edges at load; transcript.json stays as it was.
  let levels = (0..<100).map { i -> [Double] in
    let t = Double(i) * 0.05
    return [t, t >= 1.2 && t < 1.5 ? -15 : -60]
  }
  write("loudness.json", String(data: (try? JSONSerialization.data(withJSONObject: levels)) ?? Data(), encoding: .utf8) ?? "")
  let snapped = try? Project.load(dir)
  expect(snapped.map { abs($0.words[0].start - 1.2) < 0.06 && abs($0.words[0].end - 1.5) < 0.06 } == true,
    "cached loudness snaps word edges (\(snapped?.words.first.map { "\($0.start)-\($0.end)" } ?? "none"))")
  // An imported video has no capture clock, so its input log can't be placed.
  write("source.json", #"{"video":"screen.mp4","width":1920,"height":1080,"duration":20}"#)
  expect((try? Project.load(dir))?.events.isEmpty == true, "no capture start, no events")
  write("source.json", "{")
  expect((try? Project.load(dir)) == nil, "a broken source.json fails to load")

  // Writing a plan: pretty JSON ending in a newline that loads back the same; replacing a plan
  // saves the old one to history, and writing the same plan again doesn't.
  let (_, plan) = plainPlan(dir, duration: 20)
  let planURL = dir.appendingPathComponent("plan.json")
  do {
    try plan.write(to: planURL)
    let text = try String(contentsOf: planURL, encoding: .utf8)
    expect(text.hasSuffix("}\n") && text.contains("\n  \"") && !text.contains("\\/"), "plan.json is pretty, unescaped and ends in a newline")
    expect(try Plan.load(planURL) == plan, "a written plan loads back the same")
    expect(PlanHistory.list(planURL: planURL).isEmpty, "the first write has nothing to save")
    var edited = plan
    edited.zooms = [Zoom(start: 1, end: 3, x: 0.5, y: 0.5, scale: 2)]
    try edited.write(to: planURL)
    try edited.write(to: planURL)
    let saved = PlanHistory.list(planURL: planURL)
    expect(saved.count == 1 && (try? Plan.load(saved[0].url)) == plan, "replacing a plan saves the old one once (\(saved.count))")
  } catch {
    expect(false, "plan write: \(error)")
  }

  // A profile's relative asset paths resolve against its folder; absolute ones are kept.
  var look = Look()
  look.fontFiles = ["fonts/Brand.otf", "/Library/Fonts/Other.otf"]
  look.watermark = Look.Watermark(image: "logo.png", corner: "topRight", height: 0.1, opacity: 0.8)
  look.intro = Card(title: "{title}", logo: "intro.png")
  look.outro = Card(title: "Bye", logo: "/abs/outro.png")
  let profile = Profile(name: "Brand", style: plan.style, look: look, music: Music(file: "music/bed.m4a"))
  do {
    try JSONEncoder().encode(profile).write(to: dir.appendingPathComponent("profile.json"))
    let loaded = try Profile.load(dir)
    let base = dir.path
    expect(loaded.look.fontFiles == [base + "/fonts/Brand.otf", "/Library/Fonts/Other.otf"], "font paths resolve (\(loaded.look.fontFiles ?? []))")
    expect(loaded.look.watermark?.image == base + "/logo.png" && loaded.look.watermark?.corner == "topRight", "watermark path resolves")
    expect(loaded.music?.file == base + "/music/bed.m4a", "music path resolves")
    expect(loaded.look.intro?.logo == base + "/intro.png" && loaded.look.outro?.logo == "/abs/outro.png", "card logos resolve")
  } catch {
    expect(false, "profile load: \(error)")
  }
  // A card written by hand without "enabled" shows; only "enabled": false switches it off.
  let handCard = try? JSONDecoder().decode(Card.self, from: Data(#"{"title":"Hi"}"#.utf8))
  let offCard = try? JSONDecoder().decode(Card.self, from: Data(#"{"title":"Hi","enabled":false}"#.utf8))
  expect(handCard?.isOn == true && offCard?.isOn == false, "a card is on unless it says enabled: false")
  var handPlan = plan
  handPlan.intro = handCard
  expect(cardFrames(handPlan).intro == 75, "a hand-written intro takes its 2.5 s")
  var handLook = Look()
  handLook.outro = handCard
  var profiled = plan
  Profile(name: "Hand", style: plan.style, look: handLook).apply(to: &profiled, name: "Demo")
  expect(profiled.outro?.title == "Hi", "a profile's hand-written card is applied")
  expect((try? Profile.load(dir.appendingPathComponent("missing"))) == nil, "a folder without profile.json fails to load")

  // A profile's voice, camera and layout defaults: its LUT resolves against the folder, and applying it
  // changes only the fields it sets (and the camera only on a video that has one).
  var series = Profile(
    name: "Series", style: plan.style, look: Look(), audio: AudioSettings(normalize: true, gainDB: 3, warm: true),
    camera: .init(grade: Grade(lut: "luts/soft-film.cube"), bubbleSize: 0.43), defaultLayout: .pip)
  do {
    try JSONEncoder().encode(series).write(to: dir.appendingPathComponent("profile.json"))
    series = try Profile.load(dir)
    expect(series.camera?.grade?.lut == dir.path + "/luts/soft-film.cube", "a profile's LUT resolves (\(series.camera?.grade?.lut ?? "nil"))")
  } catch {
    expect(false, "profile load: \(error)")
  }
  var filmed = plan
  filmed.defaultLayout = .side
  filmed.audio = AudioSettings(cleanup: true)
  filmed.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  filmed.camera?.grade = Grade(exposure: 0.5)
  filmed.camera?.bubbleShape = "square"
  series.apply(to: &filmed)
  expect(
    filmed.audio == AudioSettings(normalize: true, gainDB: 3, cleanup: true, warm: true),
    "a profile sets its voice settings and keeps the video's others (\(String(describing: filmed.audio)))")
  expect(
    filmed.camera?.grade == Grade(lut: dir.path + "/luts/soft-film.cube") && filmed.camera?.bubbleSize == 0.43
      && filmed.camera?.bubbleShape == "square" && filmed.camera?.video == "camera.mp4",
    "a profile sets its camera grade and bubble size and keeps the shape it doesn't name")
  expect(filmed.defaultLayout == .pip, "a profile sets the default layout")
  var screenOnly = plan
  series.apply(to: &screenOnly)
  expect(screenOnly.camera == nil, "a profile's camera settings don't add a camera to a screen-only video")
  var plain = plan
  plain.defaultLayout = .side
  Profile(name: "Plain", style: plan.style, look: Look()).apply(to: &plain)
  expect(plain.defaultLayout == .side && plain.audio == plan.audio, "a profile without these fields leaves them alone")

  // Times in describe's timeline: minutes and tenths, rolling over cleanly at the minute and ten seconds.
  expect(fmtTime(0) == "0:00.0" && fmtTime(5.4) == "0:05.4" && fmtTime(65.4) == "1:05.4", "times format as m:ss.s")
  expect(fmtTime(9.97) == "0:10.0" && fmtTime(59.97) == "1:00.0", "times round up across ten seconds and the minute (\(fmtTime(9.97)), \(fmtTime(59.97)))")
}

private func exportQueueChecks() {
  // Waits on the main run loop (where the queue's tasks run) until `done` or `seconds` pass.
  func runMainLoop(_ seconds: Double, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
  }
  MainActor.assumeIsolated {
    let queue = ExportQueue()
    let missing = URL(fileURLWithPath: "/tmp/sd-no-such-project-\(UUID().uuidString)")
    let (_, plan) = plainPlan(missing, duration: 10)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("sd-export-\(UUID().uuidString).mp4")
    var finished: [String] = []
    queue.onFinished = { finished.append($0.label) }

    let first = queue.enqueue(projectDir: missing, plan: plan, label: "first", url: out)
    let second = queue.enqueue(projectDir: missing, plan: plan, label: "second", url: out)
    let third = queue.enqueue(projectDir: missing, plan: plan, label: "third", url: out)
    expect(first.state == .running && second.state == .queued && third.state == .queued, "one export runs at a time; the rest wait")
    expect(queue.activeCount == 3, "three exports are active")
    queue.cancel(second)
    expect(second.state == .cancelled && second.isFinished, "a waiting export cancels at once")
    runMainLoop(10) { queue.activeCount == 0 }
    if case .failed(let why) = first.state {
      expect(!why.isEmpty, "a failed export says why")
    } else {
      expect(false, "an export of a missing project fails (\(first.state))")
    }
    if case .failed = third.state {} else { expect(false, "the queue moves on after a failure (\(third.state))") }
    expect(second.state == .cancelled && finished.isEmpty, "a cancelled export never runs, and failures don't count as finished")
    queue.clearFinished()
    expect(queue.jobs.isEmpty, "clearing removes finished exports")

    // Cancelling the running export stops it as cancelled, not failed.
    let running = queue.enqueue(projectDir: missing, plan: plan, label: "running", url: out)
    queue.cancel(running)
    runMainLoop(10) { running.isFinished }
    expect(running.state == .cancelled, "cancelling the running export cancels it (\(running.state))")
    expect(!FileManager.default.fileExists(atPath: out.path), "no file is written for a failed or cancelled export")
  }
}

private func publishHelperChecks() {
  // Chapters: one per title at least 10 s apart in output time, the first replacing "Intro" when it
  // comes in the first 10 s, and none in the last 10 s; under three chapters, none at all.
  let (_, base) = plainPlan(URL(fileURLWithPath: "/tmp/sd-publish"), duration: 90)
  var plan = base
  plan.segments = [Segment(start: 0, end: 30, speed: 1), Segment(start: 40, end: 80, speed: 1)]
  plan.callouts = [
    Callout(start: 45, end: 47, text: "Part two"),  // output 0:35
    Callout(start: 5, end: 7, text: "Setup"),  // first 10 s
    Callout(start: 20, end: 22, text: "Details"),  // 0:20
    Callout(start: 22, end: 24, text: "Too close"),  // 2 s after Details
    Callout(start: 35, end: 37, text: "In the cut"),
    Callout(start: 75, end: 77, text: "Last moment"),  // 0:65 of 70 s
  ]
  let chapters = Publish.chapters(Scene(plan: plan, words: [], clicks: [], shortcuts: []))
  expect(chapters == "0:00 Setup\n0:20 Details\n0:35 Part two", "chapters (\(chapters ?? "nil"))")
  plan.callouts = [Callout(start: 20, end: 22, text: "Only one")]
  expect(Publish.chapters(Scene(plan: plan, words: [], clicks: [], shortcuts: [])) == nil, "too few titles, no chapters")

  // The timed transcript skips cut words and stamps each line in output time.
  plan.callouts = []
  let words = [
    Word(text: "Hello", start: 1, end: 1.4), Word(text: "everyone.", start: 1.5, end: 2),
    Word(text: "cut", start: 33, end: 33.4), Word(text: "Welcome", start: 50, end: 50.5), Word(text: "back.", start: 50.6, end: 51),
  ]
  let transcript = Publish.timedTranscript(Scene(plan: plan, words: words, clicks: [], shortcuts: []))
  expect(transcript.hasPrefix("[0:01] Hello everyone.") && transcript.contains("[0:40] Welcome back.") && !transcript.contains("cut"),
    "timed transcript (\(transcript))")
  expect(Publish.stamp(3_725.5, srt: true) == "01:02:05,500" && Publish.stamp(3_725.5, srt: false) == "1:02:05", "stamps with and without hours, cut to the second")

  // Auto-framing zooms the camera just enough that the face can sit in the middle, within limits.
  expect(Publish.centeringZoom(x: 0.5, y: 0.5) == 1.15, "a centered face gets the gentlest zoom")
  expect(Publish.centeringZoom(x: 0.3, y: 0.5) == 1.7, "a face 0.3 in needs 1.7x (0.5 / 1.7 = 0.294 fits)")
  expect(Publish.centeringZoom(x: 0.5, y: 0.9) == 1.8 && Publish.centeringZoom(x: 0.02, y: 0.5) == 1.8, "near the edge, capped at 1.8x")

  // Upload content types and where the uploaded file is read from.
  let types = ["a.MP4", "b.m4v", "c.mov", "d.gif", "e.png", "f.JPG", "g.jpeg", "h.srt", "i.md", "j.zip"].map {
    S3.contentType(URL(fileURLWithPath: "/x/" + $0))
  }
  expect(
    types == [
      "video/mp4", "video/mp4", "video/quicktime", "image/gif", "image/png", "image/jpeg", "image/jpeg", "application/x-subrip",
      "text/plain; charset=utf-8", "application/octet-stream",
    ], "upload content types (\(types))")
  var bucket = S3.Config(endpoint: URL(string: "http://minio.local:9000")!, bucket: "videos", accessKey: "a", secretKey: "b")
  expect(S3.publicURL(bucket, key: "my demo/a.gif") == S3.objectURL(bucket, key: "my demo/a.gif"), "no public base: the object URL")
  bucket.publicBase = "  https://media.example.com/ "
  expect(S3.publicURL(bucket, key: "my demo/a.gif").absoluteString == "https://media.example.com/my%20demo/a.gif", "public base, trimmed and encoded")
  bucket.publicBase = " "
  expect(S3.publicURL(bucket, key: "a.gif") == S3.objectURL(bucket, key: "a.gif"), "a blank public base is ignored")

  // Lip sync looks where the talking is: each quarter's 30 s window slides to the most words.
  let talk = stride(from: 12.0, to: 40, by: 1).map { Word(text: "w", start: $0, end: $0 + 0.5) }
  let windows = LipSync.speechWindows(words: talk, duration: 200)
  expect(windows == [10...40, 50...80, 100...130, 150...180], "speech windows (\(windows))")
  expect(LipSync.speechWindows(words: talk, duration: 2).isEmpty, "too short to measure")
  expect(LipSync.speechWindows(words: [], duration: 40) == [0...10, 10...20, 20...30, 30...40], "short videos split into quarters")

  // The classic layout path: the default layout outside a range, the range's inside it, eased between.
  var cam = base
  cam.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  cam.defaultLayout = .pip
  let ranges = [OutLayout(startF: 30, endF: 60, mode: .camera)]
  let pip = layoutBoxes(.pip, plan: cam), full = layoutBoxes(.camera, plan: cam)
  func close(_ a: LayoutBoxes, _ b: LayoutBoxes) -> Bool {
    zip(a.screen.vec + a.cam.vec, b.screen.vec + b.cam.vec).allSatisfy { abs($0 - $1) < 1e-9 }
  }
  expect(close(layoutAt(0, plan: cam, ranges: ranges, halfWidth: 6), pip), "pip before the range")
  expect(close(layoutAt(45, plan: cam, ranges: ranges, halfWidth: 6), full), "full camera inside the range")
  let edge = layoutAt(30, plan: cam, ranges: ranges, halfWidth: 6)
  expect(!close(edge, pip) && !close(edge, full) && edge.cam.w > pip.cam.w && edge.cam.w < full.cam.w, "eased at the range's edge")
}
