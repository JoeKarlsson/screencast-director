import CoreImage
import Foundation
import JavaScriptCore

// Plain-swiftc checks for DirectorCore (Swift Testing and XCTest need Xcode). Run: macos/test.sh
// One long list of checks by design, so the body-length rules don't apply here.
// swiftlint:disable function_body_length type_body_length

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok {
    failures += 1
    print("FAIL line \(line): \(what)")
  }
}

/// One pixel's red, green and blue (0...1) at a point in Core Image coordinates (bottom-left origin).
func pixel(_ image: CIImage, x: Double, y: Double) -> [Double] {
  var px = [UInt8](repeating: 0, count: 4)
  CIContext().render(
    image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  return px.prefix(3).map { Double($0) / 255 }
}

/// The animation engine and templates in JavaScriptCore with a stand-in page, so template logic is
/// checked without WebKit. Every element `el` makes is kept in `made`, and `logoHTML` gives "@name".
func animationScripts(_ animations: URL) -> JSContext {
  let js = JSContext()!
  js.exceptionHandler = { _, e in expect(false, "animation script threw: \(e?.toString() ?? "?")") }
  js.evaluateScript("""
    const fake = () => ({ className: "", innerHTML: "", textContent: "", style: { setProperty() {} },
      setAttribute() {}, appendChild() {}, querySelector() { return fake(); } });
    var window = globalThis;
    var document = { createElement: fake, createElementNS: fake, getElementById: fake, documentElement: fake(), images: [] };
    """)
  let templateFiles = ((try? FileManager.default.contentsOfDirectory(atPath: animations.appendingPathComponent("templates").path)) ?? [])
    .filter { $0.hasSuffix(".js") }.sorted().map { "templates/" + $0 }
  for file in ["engine.js"] + templateFiles {
    let source = (try? String(contentsOf: animations.appendingPathComponent(file), encoding: .utf8)) ?? ""
    expect(!source.isEmpty, "\(file) loads")
    js.evaluateScript(source, withSourceURL: URL(string: file))
  }
  js.evaluateScript("""
    cam = fake(); lines = fake();
    var made = [];
    const makeElement = el;
    el = (cls, html) => { const d = makeElement(cls, html); made.push(d); return d; };
    logoHTML = name => "@" + name;
    """)
  return js
}

@main
struct Checks {
  static func main() {
    let fps = 30
    let segs = [Segment(start: 0, end: 2, speed: 1), Segment(start: 5, end: 11, speed: 3), Segment(start: 12, end: 13, speed: 1)]
    let m = mapSegments(segs, fps: fps)
    expect(m.map { [$0.outStart, $0.frames] } == [[0, 60], [60, 60], [120, 30]], "segments map to consecutive frames")
    expect(totalFrames(m) == 150, "total frames")
    expect(srcToOut(m, 8, fps: fps) == 90, "3 s into a 3x segment is 1 s of output")
    expect(outToSrc(m, 90, fps: fps) == 8, "round trip")
    expect(srcToOut(m, 3, fps: fps) == nil, "cut moment is nil")
    expect(srcToOutClamped(m, 3, fps: fps) == 60 && srcToOutClamped(m, 11.5, fps: fps) == 120, "clamped")

    let one = mapSegments([Segment(start: 0, end: 10, speed: 1)], fps: fps)
    expect(cameraAt(10, zooms: [], halfWidth: 12) == CameraState(scale: 1, x: 0.5, y: 0.5), "camera rests at center")
    let z = zoomsToOut([Zoom(start: 2, end: 8, x: 0.6, y: 0.4, scale: 2)], one, fps: fps)
    let mid = cameraAt(150, zooms: z, halfWidth: 12)
    expect(abs(mid.scale - 2) < 1e-9 && abs(mid.x - 0.6) < 1e-9 && abs(mid.y - 0.4) < 1e-9, "reaches zoom target")
    let easing = cameraAt(60, zooms: z, halfWidth: 12)
    expect(easing.scale > 1.3 && easing.scale < 1.7, "halfway at the zoom start")
    // The renderer's easing: 9 frames (0.3 s) of lead, a 1.6x ease-out tail. The zoom starts at
    // frame 60, so the move runs from frame 39 to 70 instead of 48 to 72.
    let eased = { (f: Int) in cameraAt(f, zooms: z, halfWidth: 12, lead: 9, tail: 1.6).scale }
    expect(eased(38) == 1 && eased(40) > 1, "eased zoom starts 21 frames before the zoom")
    expect(eased(48) > cameraAt(48, zooms: z, halfWidth: 12).scale + 0.1, "eased zoom is ahead of the symmetric one")
    expect(eased(60) > 1.7 && eased(60) < 2, "mostly in by the zoom start, still settling")
    expect(abs(eased(70) - 2) < 1e-9 && eased(69) < 2, "settles 10 frames after the zoom start")
    let steps = (40...70).map { eased($0) - eased($0 - 1) }
    let peak = steps.firstIndex(of: steps.max()!)! + 40
    expect(peak < 55, "fastest early, long ease-out (peak at frame \(peak))")
    let edge = cameraAt(150, zooms: zoomsToOut([Zoom(start: 0, end: 10, x: 0.98, y: 0.01, scale: 2)], one, fps: fps), halfWidth: 12)
    expect(edge.x == 0.75 && edge.y == 0.25, "viewport clamped inside the recording")

    let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 12, captureStart: nil, camera: nil)
    var p = Project(dir: URL(fileURLWithPath: "/tmp"), source: src)
    p.words = [
      Word(text: "Hello", start: 0.5, end: 1.0), Word(text: "um", start: 1.2, end: 1.5),
      Word(text: "there", start: 1.6, end: 2.0), Word(text: "done", start: 10.0, end: 10.5),
    ]
    p.events = (0..<15).map { InputEvent(t: 5 + Double($0) * 0.2, type: .key, x: 0.5, y: 0.5) }
    let s = buildSegments(p)
    func at(_ t: Double) -> Segment? { s.first { t >= $0.start && t < $0.end } }
    expect(at(0.7)?.speed == 1, "speech kept")
    expect(at(1.35) == nil, "filler cut")
    expect(at(3.5) == nil, "idle cut")
    expect(at(6)?.speed == 3, "typing sped up")
    expect(at(10.2)?.speed == 1, "speech kept at the end")
    var mp = p
    mp.events = (0..<12).map { InputEvent(t: 2.5 + Double($0) * 0.25, type: .move, x: 0.5, y: 0.5) }
      + (0..<8).map { InputEvent(t: 7.5 + Double($0) * 0.2, type: .move, x: 0.5, y: 0.5) }
    let ms = buildSegments(mp)
    expect(!ms.contains { $0.start < 4 && $0.end > 4 }, "long silent mouse cut when narrated")
    expect(ms.contains { $0.start <= 8 && $0.end >= 8 && $0.speed == 1.5 }, "short silent mouse kept at 1.5x")
    var sl = buildPlan(p)
    sl.segments = [Segment(start: 0, end: 3, speed: 1), Segment(start: 4, end: 4.5, speed: 1), Segment(start: 5, end: 6.5, speed: 1),
      Segment(start: 7, end: 7.6, speed: 1), Segment(start: 7.6, end: 8.4, speed: 1), Segment(start: 9, end: 12, speed: 1)]
    sl.dropSlivers(silences: [(5, 6.5)])
    expect(sl.segments.map(\.start) == [0, 7, 7.6, 9], "slivers dropped; back-to-back clips count together")
    var silentDemo = mp
    silentDemo.words = []
    expect(buildSegments(silentDemo).contains { $0.start <= 4 && $0.end >= 4 && $0.speed == 1.5 }, "no narration: mouse kept at 1.5x")

    var q = Project(dir: URL(fileURLWithPath: "/tmp"), source: src)
    q.events = [InputEvent(t: 2, type: .click, x: 0.2, y: 0.2), InputEvent(t: 3, type: .click, x: 0.8, y: 0.8)]
    let zooms = buildZooms(q)
    expect(zooms.count == 2 && zooms[0].end == zooms[1].start && zooms[1].x == 0.8, "zooms hand off")

    // Manual edits.
    var plan = buildPlan(p)
    plan.segments = [Segment(start: 0, end: 4, speed: 1), Segment(start: 6, end: 10, speed: 2)]
    expect(plan.gaps == [Gap(start: 4, end: 6), Gap(start: 10, end: 12)], "gaps are the cut ranges")
    expect(plan.split(at: 2) && plan.segments.count == 3 && plan.segments[0].end == 2 && plan.segments[1].start == 2, "split")
    expect(!plan.split(at: 5), "can't split inside a cut")
    plan.restore(Gap(start: 4, end: 6))
    expect(plan.gaps == [Gap(start: 10, end: 12)] && plan.segments.count == 4, "restore fills the cut")
    plan.trimSegment(3, start: 1)
    expect(plan.segments[3].start == 6, "trim stops at the neighbor")
    plan.zooms = [Zoom(start: 5, end: 30, x: 2, y: -1, scale: 9)]
    plan.normalize()
    expect(plan.zooms[0].end == 12 && plan.zooms[0].x == 1 && plan.zooms[0].y == 0 && plan.zooms[0].scale == 4, "normalize clamps zooms")
    let clicks = [InputEvent(t: 1, type: .click, x: 0.3, y: 0.7)]
    expect(zoomFocus(at: 5, clicks: clicks) == (0.3, 0.7) && zoomFocus(at: 20, clicks: clicks) == (0.5, 0.5), "zoom focus from last click")

    // Pause trimming: tight cuts a 1 s pause, gentle keeps it, and a cut with words stays cut.
    var pp = buildPlan(p)
    // Word-long clips are over a second, so dropping slivers doesn't take them.
    let w2 = [Word(text: "one", start: 0, end: 1), Word(text: "two", start: 2, end: 3), Word(text: "oops", start: 4, end: 4.6),
      Word(text: "three", start: 5.5, end: 6.5)]
    pp.segments = [Segment(start: 0, end: 3.8, speed: 1), Segment(start: 4.8, end: 7, speed: 1)]
    pp.retrimPauses(words: w2, level: .tight)
    expect(pp.segments.count >= 3 && !pp.segments.contains { $0.start < 1.5 && $0.end > 1.5 }, "tight cuts the 1 s pause")
    expect(!pp.segments.contains { $0.start < 4.3 && $0.end > 4.3 }, "the cut word stays cut")
    pp.retrimPauses(words: w2, level: .gentle)
    expect(pp.segments.contains { $0.start <= 1 && $0.end >= 2 }, "gentle gives the pause back")
    expect(!pp.segments.contains { $0.start < 4.3 && $0.end > 4.3 }, "and still keeps the word cut")
    // A silent stretch recorded while paused stays cut, even at gentle.
    pp.segments = [Segment(start: 0, end: 0.9, speed: 1), Segment(start: 1.4, end: 2.9, speed: 1)]
    pp.retrimPauses(words: w2, level: .gentle, paused: [(0.9, 1.4)])
    expect(!pp.segments.contains { $0.start < 1.1 && $0.end > 1.1 }, "a paused stretch stays cut")

    // Pausing while recording: the draft cuts the paused stretch even when you talk over it.
    var pz = Project(dir: URL(fileURLWithPath: "/tmp"), source: src)
    pz.source.pauses = [[1, 2]]
    pz.words = [Word(text: "Talking", start: 0.2, end: 0.8), Word(text: "through", start: 1.2, end: 1.8), Word(text: "it", start: 2.2, end: 2.6)]
    expect(!buildSegments(pz).contains { $0.start < 1.5 && $0.end > 1.5 }, "the paused stretch is out of the draft")

    // What an edit touched: one clip sped up and one zoom added, merged where they overlap.
    var before = buildPlan(p)
    before.segments = [Segment(start: 0, end: 4, speed: 1), Segment(start: 5, end: 9, speed: 1)]
    before.zooms = []
    var after = before
    after.segments[1].speed = 3
    after.zooms = [Zoom(start: 6, end: 10, x: 0.5, y: 0.5, scale: 2)]
    let touched = changedRanges(from: before, to: after)
    expect(touched.count == 1 && touched[0].0 == 5 && touched[0].1 == 10, "changed ranges merge the sped-up clip and the new zoom")
    expect(changedRanges(from: before, to: before).isEmpty, "no change, no ranges")

    // Retake marks: the phrase before the mark goes, the redo after it stays.
    let flub = [
      Word(text: "Welcome", start: 0, end: 0.4), Word(text: "everyone.", start: 0.5, end: 1.0),
      Word(text: "Click", start: 2.0, end: 2.3), Word(text: "the", start: 2.4, end: 2.5), Word(text: "buton", start: 2.6, end: 3.0),
      Word(text: "Click", start: 4.0, end: 4.3), Word(text: "the", start: 4.4, end: 4.5), Word(text: "button.", start: 4.6, end: 5.0),
    ]
    let rc = retakeCuts(words: flub, marks: [3.3])
    expect(rc.count == 1 && abs(rc[0].0 - 1.9) < 1e-9 && abs(rc[0].1 - 3.6) < 1e-9, "retake cuts the flubbed phrase only")
    let gapless = [Word(text: "Hi", start: 0, end: 0.5), Word(text: "all.", start: 0.5, end: 1), Word(text: "Clik", start: 1, end: 1.5),
      Word(text: "it", start: 1.5, end: 2)]
    let gc = retakeCuts(words: gapless, marks: [2.2])
    expect(gc.count == 1 && abs(gc[0].0 - 0.9) < 1e-9, "retake stops at the previous sentence end")
    var rp = Project(dir: URL(fileURLWithPath: "/tmp"), source: src)
    rp.words = flub
    rp.events = [InputEvent(t: 3.3, type: .retake, x: 0, y: 0)]
    let rs = buildSegments(rp)
    expect(!rs.contains { $0.start < 2.5 && $0.end > 2.5 }, "flub is out of the draft")
    expect(rs.contains { $0.start <= 4.0 && $0.end >= 5.0 } && rs.contains { $0.start <= 0.5 && $0.end >= 1.0 }, "redo and earlier line stay")

    // Script takes: an earlier attempt at a line is cut; halves of one long line are not.
    let script = scriptLines("""
      # Title
      ---
      *[open the app]* Click the record button to start.
      **Note**
      Then talk through your demo like normal.
      ---
      """)
    expect(script == ["Click the record button to start", "Then talk through your demo like normal"], "script lines skip directions and headers")
    let editPlan = scriptEditPlan("""
      # Title
      ## Edit plan (Screencast Director)

      **Sounds needed:** ding
      - at "Click the record button": zoom on Record · sfx ding
      ## Read-aloud flags
      None.
      ---
      Click the record button to start.
      ---
      """)
    expect(editPlan == ["**Sounds needed:** ding", "- at \"Click the record button\": zoom on Record · sfx ding"], "edit plan read from the header only")
    expect(scriptEditPlan("## Edit plan\n- zoom\n").isEmpty, "no header rule, no edit plan")

    // Audio libraries: each built-in manifest matches its files and is CC0; personal files win;
    // freezing copies once, into sfx/ or music/.
    do {
      for kind in [AudioLibrary.Kind.sounds, .music] {
        let builtIns = try AudioLibrary(kind, personal: URL(fileURLWithPath: "/nonexistent")).items()
        expect(builtIns.count >= (kind == .sounds ? 30 : 10), "built-in \(kind) load")
        expect(builtIns.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }, "every built-in \(kind) file exists")
        expect(builtIns.allSatisfy { $0.item.license == "CC0 1.0" && $0.item.source != nil && $0.item.author != nil }, "every built-in \(kind) item is CC0 with a source and author")
        expect(Set(builtIns.map(\.item.file)).count == builtIns.count, "built-in \(kind) files are unique")
      }
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sd-audio-\(UUID().uuidString)")
      let mine = tmp.appendingPathComponent("mine"), proj = tmp.appendingPathComponent("proj")
      try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }
      try Data("mine".utf8).write(to: mine.appendingPathComponent("ding.m4a"))
      try Data("x".utf8).write(to: mine.appendingPathComponent("notes.txt"))
      let lib = AudioLibrary(.sounds, personal: mine)
      let all = try lib.items()
      expect(all.first?.item.category == "My Sounds" && all.filter { $0.item.file == "ding.m4a" }.count == 1, "a personal sound replaces the built-in one")
      expect(!all.contains { $0.item.file == "notes.txt" }, "non-audio files are skipped")
      expect(try lib.entry(forPlanPath: "sfx/pop.m4a")?.item.name == "pop" && (try lib.entry(forPlanPath: "pop.m4a")) == nil, "sound paths resolve only under sfx/")
      var sp = buildPlan(Project(dir: proj, source: src))
      sp.sfx = [SoundEffect(t: 0.5, file: "sfx/ding.m4a"), SoundEffect(t: 0.8, file: "sfx/pop.m4a"), SoundEffect(t: 0.9, file: "sfx/nope.m4a")]
      var card = Callout(start: 0.2, end: 1, text: "Step 1")
      card.sound = Sound(file: "sfx/tada.m4a")
      sp.callouts = [card]
      let paths = sp.soundEffects.map(\.file)
      expect(try lib.freezeMissing(paths, project: proj) == ["sfx/ding.m4a", "sfx/pop.m4a", "sfx/tada.m4a"], "missing library sounds, attached ones too, are copied in")
      expect((try? String(contentsOf: proj.appendingPathComponent("sfx/ding.m4a"), encoding: .utf8)) == "mine", "the personal copy is the one frozen")
      expect(try lib.freezeMissing(paths, project: proj).isEmpty, "frozen sounds aren't copied again")
      let music = AudioLibrary(.music, personal: mine)
      expect(try music.entry(forPlanPath: "sfx/advertime.m4a") == nil, "music paths resolve only under music/")
      expect(try music.freezeMissing(["music/advertime.m4a"], project: proj) == ["music/advertime.m4a"], "a library track is copied into music/")
      expect(FileManager.default.fileExists(atPath: proj.appendingPathComponent("music/advertime.m4a").path), "the track is in the project")
    } catch {
      expect(false, "audio library: \(error)")
    }
    let takes = [
      Word(text: "Click", start: 0, end: 0.3), Word(text: "the", start: 0.35, end: 0.5), Word(text: "record", start: 0.55, end: 0.9),
      Word(text: "button", start: 0.95, end: 1.3), Word(text: "to", start: 1.35, end: 1.5), Word(text: "start", start: 1.55, end: 2.0),
      Word(text: "Click", start: 3, end: 3.3), Word(text: "the", start: 3.35, end: 3.5), Word(text: "record", start: 3.55, end: 3.9),
      Word(text: "button", start: 3.95, end: 4.3), Word(text: "to", start: 4.35, end: 4.5), Word(text: "start.", start: 4.55, end: 5.0),
      Word(text: "Then", start: 6, end: 6.3), Word(text: "talk", start: 6.35, end: 6.6), Word(text: "through", start: 6.65, end: 7.0),
      Word(text: "your", start: 8, end: 8.2), Word(text: "demo", start: 8.25, end: 8.6), Word(text: "like", start: 8.65, end: 8.9),
      Word(text: "normal.", start: 8.95, end: 9.4),
    ]
    let tc = earlierTakeCuts(words: takes, script: script)
    expect(tc.count == 1 && abs(tc[0].0 - -0.1) < 1e-9 && abs(tc[0].1 - 2.15) < 1e-9, "earlier take cut, split halves kept")

    // Window capture: positions are fractions of the window, not the display.
    let win = CGRect(x: 200, y: 100, width: 800, height: 600)
    let (nx, ny) = normalizedPoint(CGPoint(x: 600, y: 250), in: win)
    expect(nx == 0.5 && ny == 0.25, "point normalized to the window frame")
    // Transcript edits: cut a word range out of the middle of a clip, then put it back.
    var tp = buildPlan(p)
    tp.source.duration = 30
    tp.segments = [Segment(start: 0, end: 10, speed: 1), Segment(start: 12, end: 20, speed: 3)]
    tp.cut(range: 4..<6)
    expect(tp.segments.count == 3 && tp.speed(at: 5) == nil && tp.speed(at: 3.9) == 1 && tp.speed(at: 6) == 1, "cut splits a clip")
    tp.cut(range: 9..<14)
    expect(tp.speed(at: 9.5) == nil && tp.speed(at: 13) == nil && tp.speed(at: 14) == 3, "cut across a gap trims both sides")
    tp.restore(range: 4..<6)
    expect(tp.speed(at: 5) == 1, "restore puts the range back at 1x")
    tp.restore(range: 9..<14)
    expect(tp.speed(at: 11) == 1 && tp.speed(at: 13) == 1 && tp.speed(at: 14) == 3, "restore fills only the cut parts")

    // Plan history: snapshots skip duplicates and keep only the newest N.
    let hdir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-history-check-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: hdir, withIntermediateDirectories: true)
    let planURL = hdir.appendingPathComponent("plan.json")
    for i in 0..<8 {
      PlanHistory.snapshot(Data("v\(i)".utf8), planURL: planURL, keep: 5, now: Date(timeIntervalSince1970: 1_000_000 + Double(i)))
    }
    PlanHistory.snapshot(Data("v7".utf8), planURL: planURL, keep: 5, now: Date(timeIntervalSince1970: 2_000_000))
    let versions = PlanHistory.list(planURL: planURL)
    expect(versions.count == 5, "history keeps the newest 5 (got \(versions.count))")
    expect(
      (try? String(contentsOf: versions[0].url, encoding: .utf8)) == "v7"
        && versions.last.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } == "v3",
      "history is newest first and skips a duplicate")
    var changed = tp
    changed.zooms.append(Zoom(start: 1, end: 3, x: 0.5, y: 0.5, scale: 2))
    changed.cut(range: 1..<2)
    expect(PlanHistory.summary(from: tp, to: changed) == "2 clips, 1 zoom", "history summary (got \(PlanHistory.summary(from: tp, to: changed)))")
    try? FileManager.default.removeItem(at: hdir)

    // AI double-check notes: a zoom lists what was said, a cut edge inside a word is flagged.
    var ep = buildPlan(p)
    ep.segments = [Segment(start: 0, end: 0.8, speed: 1), Segment(start: 1.5, end: 12, speed: 1)]
    ep.zooms = [Zoom(start: 0, end: 2, x: 0.5, y: 0.5, scale: 2)]
    let review = editReview(p, ep)
    expect(review.contains("said \"Hello um there\"") && review.contains("splits the word \"Hello\"") && !review.contains("\"um\" ("),
      "edit review (got \(review))")
    expect(ep.changesCutsOrZooms(from: buildPlan(p)) && !ep.changesCutsOrZooms(from: ep), "edit changes cuts or zooms")

    // Word timing: silence at a word's edges is trimmed off, never past its midpoint.
    var lv: [(Double, Double)] = []
    for i in 0..<60 {
      let t = Double(i) * 0.05
      lv.append((t, (t >= 1.0 && t < 1.6) ? -15 : -60))  // loud only from 1.0 to 1.6 s
    }
    let refined = WordTiming.refine([Word(text: "hi", start: 0.5, end: 2.5), Word(text: "quiet", start: 2.6, end: 2.9)], levels: lv)
    expect(abs(refined[0].start - 1.0) < 0.06 && abs(refined[0].end - 1.6) < 0.06, "word edges snap to the loud part")
    expect(refined[1].start <= 2.75 && refined[1].end >= 2.75, "a silent word keeps its midpoint")

    // Music ducking: talking spans in output time, short gaps bridged, sped-up clips ignored.
    var talk: [(Double, Double)] = []
    for i in 0..<260 {
      let t = Double(i) * 0.05
      let loud = (t >= 1 && t < 3) || (t >= 3.5 && t < 4) || (t >= 6 && t < 7) || (t >= 11 - 0.001 && t < 12)
      talk.append((t, loud ? -20 : -60))
    }
    let duckMap = mapSegments([Segment(start: 0, end: 5, speed: 1), Segment(start: 5, end: 8, speed: 3), Segment(start: 10, end: 12, speed: 1)], fps: fps)
    let spans = MusicDuck.speech(levels: talk, mapped: duckMap, fps: fps)
    expect(spans.count == 2, "a 0.5 s gap stays ducked, the 3x clip doesn't count (got \(spans))")
    if spans.count == 2 {
      expect(abs(spans[0].0 - 1) < 0.01 && abs(spans[0].1 - 4) < 0.01, "first span is 1-4 s")
      expect(abs(spans[1].0 - 7) < 0.01 && abs(spans[1].1 - 8) < 0.01, "source 11-12 s lands at 7-8 s of output")
    }
    // Intro and outro cards: everything placed in output time moves by the intro's length.
    var cp = buildPlan(p)
    cp.segments = segs
    cp.zooms = [Zoom(start: 1, end: 1.8, x: 0.5, y: 0.5, scale: 2)]
    cp.callouts = []
    expect(cardFrames(cp) == (0, 0) && planFrames(cp) == 150, "no cards: plan length is the segments")
    cp.intro = Card(title: "Hello")
    cp.outro = Card(duration: 2, title: "Bye")
    let cm = mapPlan(cp)
    expect(cardFrames(cp) == (75, 60), "2.5 s intro and 2 s outro at 30 fps")
    expect(cm.map(\.outStart) == [75, 135, 195], "segments start after the intro")
    expect(planFrames(cp) == 285, "intro + segments + outro")
    expect(srcToOut(cm, 8, fps: fps) == 165 && outToSrc(cm, 165, fps: fps) == 8, "round trip shifts by the intro")
    expect(outToSrc(cm, 10, fps: fps) == nil, "intro frames have no source")
    expect(srcToOutClamped(cm, 0, fps: fps, before: true) == 75, "clamping before the first segment lands after the intro")
    let cs = Scene(plan: cp, words: [Word(text: "hi", start: 0.5, end: 1.0)], clicks: [], shortcuts: [])
    expect(cs.frameCount == 285 && cs.introFrames == 75 && cs.outroStart == 225, "scene knows the card frames")
    expect(cs.pages.first?.startF == 90, "captions shift by the intro")
    expect(cs.zooms.first?.startF == 105, "zooms shift by the intro")
    expect(Publish.srt(cs).hasPrefix("1\n00:00:03,000 -->"), "SRT shifts by the intro")
    cp.intro?.enabled = false
    expect(cardFrames(cp).intro == 0 && mapPlan(cp)[0].outStart == 0, "a switched-off intro takes no time")
    var look = Look()
    look.intro = Card(title: "{title}", subtitle: "Joe Karlsson")
    var prof = buildPlan(p)
    Profile(name: "T", style: prof.style, look: look).apply(to: &prof, name: "Tour")
    expect(prof.intro?.title == "Tour" && prof.intro?.subtitle == "Joe Karlsson" && prof.outro == nil, "profile fills the intro title")

    // Joined takes: no segment or zoom runs across the join.
    var jp = p
    jp.source.joins = [6]
    expect(buildSegments(p).contains { $0.start < 6 && $0.end > 6 }, "without a join, a segment spans 6 s")
    expect(!buildSegments(jp).contains { $0.start < 6 && $0.end > 6 }, "segments split at a join")
    expect(!buildZooms(jp).contains { $0.start < 6 && $0.end > 6 }, "zooms end at a join")

    // SigV4 against AWS's published examples. Signing key: the IAM docs' example key derivation.
    let kSigning = SigV4.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", day: "20120215", region: "us-east-1", service: "iam")
    expect(
      kSigning.withUnsafeBytes { SigV4.hex(Array($0)) } == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d",
      "SigV4 signing key matches AWS's example")
    // S3 "GET Object" example from the Authorization-header SigV4 docs.
    let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let get = SigV4.sign(
      method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, headers: ["Range": "bytes=0-9"],
      payloadHash: emptyHash, date: Date(timeIntervalSince1970: 1_369_353_600), accessKey: "AKIAIOSFODNN7EXAMPLE",
      secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1", service: "s3")
    expect(get.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", "S3 GET example signature (\(get.signature))")
    expect(
      get.headers["authorization"]
        == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
      "S3 GET example Authorization header")
    let s3c = S3.Config(endpoint: URL(string: "http://192.168.0.202:9000/")!, bucket: "videos", accessKey: "a", secretKey: "b")
    expect(S3.objectURL(s3c, key: "my demo/clip 1.gif").absoluteString == "http://192.168.0.202:9000/videos/my%20demo/clip%201.gif", "object URL")
    expect(S3.key(for: URL(fileURLWithPath: "/x/out.MP4"), name: "2026-10-12 Demo: Take #2", date: Date(timeIntervalSince1970: 5), nonce: "0a1b2c3d") == "2026-10-12-demo-take-2-5-0a1b2c3d.mp4", "upload key")
    let k1 = S3.key(for: URL(fileURLWithPath: "/x/a.gif"), name: "a"), k2 = S3.key(for: URL(fileURLWithPath: "/x/a.gif"), name: "a")
    expect(k1 != k2 && k1.range(of: #"^a-\d+-[0-9a-f]{8}\.gif$"#, options: .regularExpression) != nil, "upload keys get a random suffix (\(k1))")

    // PathSafety: an AI edit can't point the plan's files outside the project.
    let proj = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sd-pathsafety-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: proj) }
    expect(PathSafety.path("screen.mp4", isInside: proj) && PathSafety.path(".checks/1.png", isInside: proj), "relative paths stay inside")
    expect(!PathSafety.path("../other/screen.mp4", isInside: proj) && !PathSafety.path("/etc/passwd", isInside: proj), "parent and absolute paths leave")
    expect(PathSafety.path(proj.path + "/cam.mov", isInside: proj), "an absolute path into the project is inside")
    try? FileManager.default.createSymbolicLink(atPath: proj.appendingPathComponent("link").path, withDestinationPath: "/etc")
    expect(!PathSafety.path("link/passwd", isInside: proj), "a symlink out of the project leaves")
    var prior = buildPlan(Project(dir: proj, source: src))
    prior.look = Look()
    prior.look?.fontFiles = ["/Library/Fonts/Brand.otf"]
    var evil = prior
    evil.source.video = "/Users/someone/secret.mov"
    evil.camera = Plan.Camera(video: "../cam.mov", offset: 0)
    evil.music = Music(file: "/etc/passwd")
    evil.look?.fontFiles = ["/Library/Fonts/Brand.otf", "/tmp/evil.otf", "fonts/ok.otf"]
    evil.zooms = []
    let (cleaned, reverted) = PathSafety.sanitize(evil, previous: prior, project: proj)
    expect(cleaned.source.video == prior.source.video && cleaned.camera == nil && cleaned.music == nil, "unsafe paths reverted")
    expect(cleaned.look?.fontFiles == ["/Library/Fonts/Brand.otf", "fonts/ok.otf"], "unchanged and in-project fonts kept")
    expect(Set(reverted) == ["source.video", "camera.video", "music.file", "look.fontFiles"], "reverted fields (\(reverted))")
    expect(cleaned.zooms == [] && PathSafety.sanitize(prior, previous: prior, project: proj).1.isEmpty, "other edits kept; unchanged plan untouched")

    // Motion: easing curves, eased steps and the camera's zoom path.
    for name in Ease.names {
      let e = Ease.named(name)!
      expect(e.at(0) == 0 && e.at(1) == 1, "\(name) runs 0 to 1")
    }
    let smoothEase = Ease.named("smooth")!
    expect((1...99).allSatisfy { smoothEase.at(Double($0) / 100) >= smoothEase.at(Double($0 - 1) / 100) }, "smooth never moves backward")
    expect(smoothEase.at(0.5) > 0.6, "smooth is front-loaded (\(smoothEase.at(0.5)))")
    expect((1...99).map { Ease.named("bouncy")!.at(Double($0) / 100) }.max()! > 1.05, "bouncy overshoots")
    expect(Ease.named("cubic-bezier(0.42, 0, 0.58, 1)") == Ease.named("ease-in-out"), "parses cubic-bezier")
    expect(Ease.named("spring(0.7)") == .spring(0.7) && Ease.named("wobble") == nil, "parses spring, rejects unknown names")
    // A zoom toward a point keeps that point at the same place on screen all the way in.
    let from = [1.0, 0.5, 0.5], to = [2.0, 0.75, 0.25]
    let fixed = (x: (to[1] * to[0] - from[1] * from[0]) / (to[0] - from[0]), y: (to[2] * to[0] - from[2] * from[0]) / (to[0] - from[0]))
    for u in [0.25, 0.5, 0.75] {
      let c = EasedSteps.camera(from, to, u)
      let screenX = (fixed.x - c[1]) * c[0], startX = (fixed.x - from[1]) * from[0]
      expect(abs(screenX - startX) < 1e-9, "zoom's fixed point holds still at \(u)")
      expect(abs(c[0] - pow(2, u)) < 1e-9, "scale moves evenly in log space at \(u)")
    }
    let camZ = zoomsToOut([Zoom(start: 2, end: 6, x: 0.6, y: 0.4, scale: 2), Zoom(start: 6, end: 9, x: 0.2, y: 0.7, scale: 1.6)], one, fps: fps)
    let path = cameraSteps(zooms: camZ, fps: fps, transition: 0.8, style: MotionStyle.named("smooth"), lead: 0.3, restClicks: nil)
    expect(path.at(0) == [1, 0.5, 0.5], "camera rests before the first zoom")
    expect(path.at(150) == [2, 0.6, 0.4], "camera holds the first zoom")
    expect(path.at(240) == [1.6, 0.2, 0.7], "touching zooms hand off without going out")
    let jumps = (1..<300).map { f in zip(path.at(Double(f)), path.at(Double(f - 1))).map { abs($0 - $1) }.max()! }
    expect(jumps.max()! < 0.12, "the camera never jumps (largest step \(jumps.max()!))")
    let pose = { (f: Double) in Motion.pose(frame: f, start: 30, end: 90, fps: fps, enter: nil, exit: nil, style: MotionStyle.named("smooth")) }
    expect(!pose(29).visible && pose(30).opacity < 0.05 && pose(60) == .full && pose(89).opacity < 0.3, "overlays fade in and out")
    expect(OverlayPose.of("slide-up", 0).dy > 1 && OverlayPose.of("wipe", 0.5).reveal == 0.5, "presets pose")
    let short = Motion.pose(frame: 33, start: 30, end: 36, fps: fps, enter: Motion(preset: "fade", seconds: 1), exit: nil, style: MotionStyle.named("smooth"))
    expect(short.opacity > 0.2 && short.opacity < 1, "a short overlay squeezes its moves to fit")

    // Reviewing an AI edit: each change can be undone on its own.
    var planA = buildPlan(p)
    planA.zooms = [Zoom(start: 1, end: 3, x: 0.5, y: 0.5, scale: 2), Zoom(start: 6, end: 8, x: 0.2, y: 0.2, scale: 1.6)]
    var planB = planA
    planB.zooms[0].scale = 1.8
    planB.zooms.remove(at: 1)
    planB.callouts.append(Callout(start: 4, end: 6, text: "Hi", style: "lower-third"))
    planB.style.motion = "snappy"
    planB.segments[0].speed = 2
    planB.animationList = [Animation(start: 2, end: 4, template: "hub", data: .null)]
    planB.sfxList = [SoundEffect(t: 5, file: "sounds/pop.m4a")]
    planB.insertList = [Insert(start: 40, end: 42, file: "broll/a.mp4")]
    let changes = planChanges(from: planA, to: planB)
    let kinds: [String] = changes.map { $0.kind }
    expect(Set(kinds) == Set(["clips", "zoom", "title", "insert", "animation", "sound", "style"]), "change kinds (\(changes.map { $0.label }))")
    let clipRange = changes.first { $0.kind == "clips" }?.range
    expect(clipRange.map { $0.1 <= planA.segments[0].end } == true, "the clips change covers only the clips (\(String(describing: clipRange)))")
    var withAnimation = planA
    withAnimation.animationList = [Animation(start: 30, end: 32, template: "hub", data: .null)]
    expect(changedRanges(from: planA, to: withAnimation).map { [$0.0, $0.1] } == [[30, 32]], "an added animation flashes on the timeline")
    let zoomVerbs: [String] = changes.filter { $0.kind == "zoom" }.map { String($0.label.split(separator: " ")[0]) }.sorted()
    expect(zoomVerbs == ["Changed", "Removed"], "zoom changed and removed")
    for c in changes {
      var undone = planB
      c.revert(&undone)
      let sameTitles = undone.callouts == planB.callouts
      let sameZooms = undone.zooms == planB.zooms
      switch c.kind {
      case "zoom" where c.label.hasPrefix("Changed"): expect(undone.zooms.contains(planA.zooms[0]) && sameTitles, "undo one zoom change only")
      case "zoom": expect(undone.zooms.count == 2, "undo a removed zoom puts it back")
      case "title": expect(undone.callouts == planA.callouts && sameZooms, "undo the added title only")
      case "style": expect(undone.style.motion == planA.style.motion && sameTitles && undone.animations == planB.animations, "undo style keeps the rest")
      case "animation": expect(undone.animations == nil && sameTitles, "undo the added animation only")
      case "sound": expect(undone.sfx == nil && undone.animations == planB.animations, "undo the added sound only")
      case "insert": expect(undone.inserts == nil && sameZooms, "undo the added B-roll only")
      default: expect(undone.segments == planA.segments && sameZooms, "undo clips keeps the rest")
      }
    }

    // What a click landed on, from text boxes read off the screen.
    let boxes = [ScreenText.Item(text: "Save", x: 0.40, y: 0.10, w: 0.05, h: 0.02), ScreenText.Item(text: String(repeating: "long ", count: 20), x: 0.1, y: 0.5, w: 0.3, h: 0.02)]
    expect(ScreenText.label(at: 0.42, 0.11, in: boxes) == "Save", "a click inside a box reads its text")
    expect(ScreenText.label(at: 0.47, 0.11, in: boxes) == "Save", "a click just beside a box still reads it")
    expect(ScreenText.label(at: 0.8, 0.8, in: boxes) == nil, "nothing near")
    expect(ScreenText.label(at: 0.2, 0.51, in: boxes)?.count == 41, "long lines are cut short")
    let samples = [ScreenText.Sample(t: 5, x: 0.42, y: 0.11, items: boxes)]
    expect(ScreenText.clicked(samples, at: 5.2) == "Save" && ScreenText.clicked(samples, at: 6) == nil, "matched by time")

    // Script lines missing from the edit.
    var sp = buildPlan(p)
    sp.segments = [Segment(start: 0, end: 2.1, speed: 1)]
    let scriptWords = [
      Word(text: "Hello", start: 0.2, end: 0.5), Word(text: "and", start: 0.5, end: 0.7), Word(text: "welcome", start: 0.7, end: 1.0),
      Word(text: "everyone", start: 1.0, end: 1.4), Word(text: "this", start: 5, end: 5.2), Word(text: "part", start: 5.2, end: 5.5),
      Word(text: "is", start: 5.5, end: 5.6), Word(text: "cut", start: 5.6, end: 6),
    ]
    let missing = missingScriptLines(["Hello and welcome, everyone", "This part is cut"], words: scriptWords, plan: sp)
    expect(missing == ["This part is cut"], "a line whose only take is cut is missing (\(missing))")

    // Speeding up a range splits the clips at its edges.
    var fast = buildPlan(p)
    fast.segments = [Segment(start: 0, end: 10, speed: 1)]
    fast.setSpeed(range: 2..<5, speed: 4)
    expect(fast.segments.map { [$0.start, $0.end, $0.speed] } == [[0, 2, 1], [2, 5, 4], [5, 10, 1]], "range sped up (\(fast.segments))")
    // Markers are kept in order and inside the recording.
    var pins = buildPlan(p)
    pins.markers = [Marker(t: 50, label: "end"), Marker(t: 3), Marker(t: -1)]
    pins.normalize()
    expect(pins.markerList.map(\.t) == [0, 3, pins.source.duration], "markers sorted and clamped (\(pins.markerList.map(\.t)))")

    // Crossfades: a quarter second each side, peaking at an even mix on the cut.
    let xm = mapSegments([Segment(start: 0, end: 4, speed: 1), Segment(start: 8, end: 12, speed: 1, transition: "crossfade")], fps: fps)
    let xf = crossfades(xm, fps: fps)
    expect(xf.count == 1 && xf[0].f == 120 && xf[0].half == 8, "one crossfade at the cut (\(xf.map { ($0.f, $0.half) }))")
    expect(crossfadeMix(xf, frame: 111) == nil && crossfadeMix(xf, frame: 128) == nil, "no mix outside the crossfade")
    let mixes = (112..<128).compactMap { crossfadeMix(xf, frame: $0) }
    expect(mixes.count == 16 && abs(mixes.max()! - 0.5) < 0.05 && mixes.first! < 0.05, "mix rises to an even blend at the cut")
    let shortClip = mapSegments([Segment(start: 0, end: 4, speed: 1), Segment(start: 8, end: 8.1, speed: 1, transition: "crossfade")], fps: fps)
    expect(crossfades(shortClip, fps: fps).isEmpty, "too short a clip for a crossfade skips it")

    // An AI edit can't point B-roll at a file outside the project.
    var brollOld = buildPlan(p)
    brollOld.inserts = [Insert(start: 1, end: 3, file: "broll/ok.png")]
    var brollNew = brollOld
    brollNew.inserts = [Insert(start: 1, end: 3, file: "broll/ok.png"), Insert(start: 4, end: 6, file: "/Users/someone/secret.png")]
    let (brollSafe, brollReverted) = PathSafety.sanitize(brollNew, previous: brollOld, project: URL(fileURLWithPath: "/tmp/sd-proj"))
    expect(brollSafe.insertList.map(\.file) == ["broll/ok.png"] && brollReverted == ["inserts.file"], "outside B-roll dropped (\(brollReverted))")

    // Lip sync: lips that open 0.3 s into the camera file for each word in the voice read as offset 0.3.
    var seed: UInt64 = 7
    func noise() -> Double {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Double(seed >> 33) / Double(1 << 31)
    }
    var level = 0.0
    let speech = (0..<9000).map { i -> (Double, Double) in
      level = 0.7 * level + 0.3 * (noise() > 0.6 ? 1 : 0)
      return (Double(i) * 0.02, level)
    }
    let lipWindows = [10.0...40.0, 60.0...90.0, 110.0...140.0]
    let lips = stride(from: 0.0, to: 179.0, by: 1.0 / 30).map { t in (t, LipSync.interpolate(speech, at: [t - 0.3])[0]) }
    let synced = LipSync.bestOffset(mouth: lips, voice: speech, windows: lipWindows, around: -0.06, search: 0.5)
    expect(synced.map { abs($0.offset - 0.3) < 0.02 && $0.confident } == true, "lip sync finds a 0.3 s camera lag (\(String(describing: synced)))")
    let unrelated = stride(from: 0.0, to: 179.0, by: 1.0 / 30).map { ($0, noise()) }
    let guess = LipSync.bestOffset(mouth: unrelated, voice: speech, windows: lipWindows, around: 0, search: 0.5)
    expect(guess?.confident == false, "lip sync isn't confident when the lips don't follow the voice (\(String(describing: guess)))")

    // Animations: the cached clip's name follows what changes its frames, and moving one keeps its beats.
    let anim = Animation(start: 10, end: 20, template: "hub", data: .object(["title": .string("One hub")]), cues: ["hub": 11.5])
    let out1080 = Plan.Output(width: 1920, height: 1080, fps: 30)
    var moved = anim
    moved.move(by: 5)
    expect(moved.start == 15 && moved.end == 25 && moved.cues == ["hub": 16.5], "moving an animation moves its cues")
    expect(moved.clipPath(out1080, dir: nil) == anim.clipPath(out1080, dir: nil), "a moved animation reuses its clip (same frames)")
    var retitled = anim
    retitled.data = .object(["title": .string("Two hubs")])
    expect(retitled.clipPath(out1080, dir: nil) != anim.clipPath(out1080, dir: nil), "new data renders a new clip")
    var recued = anim
    recued.cues = ["hub": 12]
    expect(recued.clipPath(out1080, dir: nil) != anim.clipPath(out1080, dir: nil), "a new beat renders a new clip")
    expect(anim.clipPath(Plan.Output(width: 1080, height: 1920, fps: 30), dir: nil) != anim.clipPath(out1080, dir: nil), "another size renders a new clip")
    let roundTrip = try? JSONDecoder().decode(Animation.self, from: JSONEncoder().encode(anim))
    expect(roundTrip == anim, "animations round-trip through JSON")
    var animPlan = buildPlan(p)
    animPlan.animations = [anim]
    expect(animPlan.animationInserts(dir: URL(fileURLWithPath: "/tmp/sd-no-such-project")).isEmpty, "an unrendered animation isn't B-roll yet")
    let noProject = URL(fileURLWithPath: "/tmp/sd-no-such-project")
    let fourK = ExportPreset.all.first { $0.id == "youtube-4k" }!.applied(to: animPlan)
    let keep = animPlan.animationClipNames(dir: noProject)
    let clipName = { (o: Plan.Output) in (anim.clipPath(o, dir: noProject) as NSString).lastPathComponent }
    expect(keep.contains(clipName(animPlan.output)) && keep.contains(clipName(fourK.output)), "clip cleanup keeps the preview's clips and a 4K export's")
    expect(!keep.contains((retitled.clipPath(fourK.output, dir: noProject) as NSString).lastPathComponent), "clip cleanup still drops clips of old data")
    expect(fourK.animationsToRender(dir: noProject).first?.path == anim.clipPath(fourK.output, dir: noProject), "a 4K export needs its own 4K clips")

    // Every bundled template has a manifest the editor can read, and a new one spreads its beats over its own stretch.
    let templateDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Resources/animations/templates")
    let templates = AnimationTemplate.all(in: templateDir)
    let scripts = ((try? FileManager.default.contentsOfDirectory(atPath: templateDir.path)) ?? []).filter { $0.hasSuffix(".js") }
    expect(templates.count == scripts.count && !templates.isEmpty, "each template script has a manifest (\(templates.map(\.name)) vs \(scripts))")
    for t in templates {
      let made = t.make(start: 100, end: 100 + t.length / 2)
      expect(made.cues?.values.allSatisfy { $0 >= 100 && $0 <= 100 + t.length / 2 } == true, "\(t.name): beats land inside a shorter animation")
      expect(t.fields.allSatisfy { t.data[path: $0.key] != nil }, "\(t.name): every field has a starting value")
    }
    // Template folders: the video's copy wins over the personal library over the app's; freezing copies
    // one into the video once, and editing that copy names a new clip.
    let lib = FileManager.default.temporaryDirectory.appendingPathComponent("sd-anim-\(getpid())")
    defer { try? FileManager.default.removeItem(at: lib) }
    let builtInDir = lib.appendingPathComponent("app"), personalDir = lib.appendingPathComponent("me"), video = lib.appendingPathComponent("video")
    func writeTemplate(_ folder: URL, _ name: String, _ title: String, script: String) {
      try? FileManager.default.createDirectory(at: folder.appendingPathComponent("templates"), withIntermediateDirectories: true)
      let manifest = #"{"name":"\#(name)","title":"\#(title)","summary":"","length":10,"fields":[],"cues":[],"data":{}}"#
      try? manifest.write(to: folder.appendingPathComponent("templates/\(name).json"), atomically: true, encoding: .utf8)
      try? script.write(to: folder.appendingPathComponent("templates/\(name).js"), atomically: true, encoding: .utf8)
    }
    writeTemplate(builtInDir, "hub", "Hub (app)", script: "// v1")
    writeTemplate(personalDir, "mine", "Mine", script: "// mine")
    try? FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
    let animSrc = AnimationSources(project: video, builtIn: builtInDir, personal: personalDir)
    expect(Set(animSrc.templates().map(\.template.name)) == ["hub", "mine"] && animSrc.template("mine")?.origin == .personal, "templates come from every folder")
    let hubAnim = Animation(start: 0, end: 10, template: "hub", data: .object([:]))
    let unfrozen = hubAnim.clipPath(out1080, dir: video)
    expect((try? animSrc.freeze("hub")) == true && (try? animSrc.freeze("hub")) == false, "a template freezes into the video once")
    expect(animSrc.template("hub")?.origin == .video && !animSrc.differsFromLibrary("hub"), "the frozen copy is used and matches the library")
    let frozen = hubAnim.clipPath(out1080, dir: video)
    expect(frozen != unfrozen, "freezing names the clip after the frozen copy")
    try? "// v2".write(to: builtInDir.appendingPathComponent("templates/hub.js"), atomically: true, encoding: .utf8)
    expect(animSrc.differsFromLibrary("hub") && hubAnim.clipPath(out1080, dir: video) == frozen, "a library change offers an update but doesn't touch the video")
    try? animSrc.updateFromLibrary("hub")
    expect(!animSrc.differsFromLibrary("hub") && hubAnim.clipPath(out1080, dir: video) != frozen, "updating takes the new version and re-renders")
    try? "// edited here".write(to: video.appendingPathComponent("animations/templates/hub.js"), atomically: true, encoding: .utf8)
    try? animSrc.saveToPersonal("hub")
    expect(animSrc.libraryFolder(for: "hub") == personalDir && !animSrc.differsFromLibrary("hub"), "saving puts the video's version in the personal library")

    var edited = JSONValue.object(["center": .object(["logo": .string("OpenAI")])])
    edited[path: "center.label"] = .string("your dot")
    edited[path: "title"] = .string("Hi")
    edited[path: "center.logo"] = nil
    expect(edited[path: "center.label"]?.string == "your dot" && edited[path: "title"]?.string == "Hi" && edited[path: "center.logo"] == nil, "dotted paths set and clear fields")

    // Recently opened: newest open first, never-opened recordings after in their own order.
    let recents = ["a", "b", "c", "d"].map { URL(fileURLWithPath: "/p/" + $0) }
    expect(byLastOpened(recents, opened: ["/p/c": 200, "/p/a": 100]) == [recents[2], recents[0], recents[1], recents[3]], "recordings order by when they were last opened")

    // Clips: a range of the edit in its own format, named after the project.
    var clipped = buildPlan(p)
    clipped.segments = [Segment(start: 0, end: 4, speed: 1), Segment(start: 6, end: 10, speed: 1, transition: "dip")]
    clipped.style.padding = 0
    var bigBubble = Plan.Camera(video: "camera.mp4", offset: 0)
    bigBubble.bubbleSize = 0.43
    clipped.camera = bigBubble
    clipped.animations = [Animation(start: 1, end: 2, template: "hub", data: .object([:])), Animation(start: 7, end: 8, template: "hub", data: .object([:]))]
    let hook = Clip(name: "Hook", start: 3, end: 8, format: "vertical", title: "Connect your dot", logo: "broll/logo.png")
    clipped.clips = [hook, Clip(name: "Gone", start: 4.5, end: 5.5)]
    let hookPlan = clipped.trimmed(to: hook)
    expect(hookPlan.segments.map { [$0.start, $0.end] } == [[3, 4], [6, 8]] && hookPlan.segments[1].transition == "dip", "a clip keeps the edit inside its range")
    expect(hookPlan.animationList.map(\.start) == [7] && hookPlan.clips == nil, "a clip keeps only the animations it overlaps")
    expect(clipped.trimmed(to: Clip(name: "late", start: 7.5, end: 10)).animationList.isEmpty, "a clip opening partway into an animation leaves it out")
    expect(hookPlan.output.width == 1080 && hookPlan.output.height == 1920, "a vertical clip renders vertical")
    expect(hookPlan.captions.style == "social" && hookPlan.captions.maxWords <= 3, "vertical captions are big, a few words at a time")
    expect(hookPlan.callouts.contains { $0.text == "Connect your dot" && $0.start == 3 && $0.end == 3 + Clip.titleSeconds }, "a clip's hook title opens it")
    expect(hookPlan.look?.watermark?.image == "broll/logo.png" && hookPlan.look?.watermark?.corner == "top", "a clip's logo sits at the top center")
    // Portrait: the screen card on the top square, the camera full width under it, or the whole frame.
    let split = layoutBoxes(.pip, plan: hookPlan), talking = layoutBoxes(.camera, plan: hookPlan)
    expect(socialTop(hookPlan) == 1080 && split.cam.y == 1080 && split.cam.w == 1080 && split.cam.h == 840, "the camera fills the width under the screen")
    expect(split.screen.y + split.screen.h <= 1080 && abs(split.screen.w - split.screen.h) < 1, "the screen card is square on the top")
    expect(talking.cam.x == 0 && talking.cam.y == 0 && talking.cam.h == 1920 && talking.screen.opacity == 0, "talking to the lens fills the frame")
    expect(socialTop(clipped) == nil, "landscape has no split")
    expect(hookPlan.animationOutput.width == Int(split.screen.w) && hookPlan.animationOutput.height == Int(split.screen.h), "portrait animations render at the card's size")
    let hookOut = layoutsToOut(hookPlan, mapSegments(hookPlan.segments, fps: 30))
    expect(hookOut.last?.mode == .pip && hookOut.last?.startF == 60, "the split shows while a portrait animation plays")
    expect(clipped.trimmed(to: clipped.clipList[1]).segments.isEmpty, "a clip inside a cut has nothing to export")
    // A clip that opens partway into an animation picks it up there; a clip's pace re-cuts its pauses.
    expect(hookPlan.animationSeek(hookPlan.animationList[0]) == nil, "an animation inside the clip plays from its start")
    var lateStart = clipped
    lateStart.segments = [Segment(start: 7.5, end: 10, speed: 1)]
    expect(lateStart.animationSeek(clipped.animationList[1]) == 0.5, "an animation whose start is cut picks up where the edit does")
    var paced = buildPlan(p)
    paced.segments = [Segment(start: 0, end: 10, speed: 1)]
    let gappy = [Word(text: "one", start: 1, end: 2), Word(text: "two", start: 4, end: 5), Word(text: "three", start: 6, end: 9)]
    let tight = paced.trimmed(to: Clip(name: "t", start: 0, end: 10, pace: .tight), words: gappy)
    expect(tight.segments.count > 1 && planSeconds(tight) < 9, "a tight clip cuts the edit's pauses (\(tight.segments.map { [$0.start, $0.end] }))")
    paced.animations = [Animation(start: 1.5, end: 4.5, template: "hub", data: .object([:]))]
    let guarded = paced.trimmed(to: Clip(name: "t", start: 0, end: 10, pace: .tight), words: gappy)
    expect(!guarded.segments.contains { $0.start > 1.6 && $0.start < 4.4 }, "a tight clip doesn't cut inside an animation")
    expect(paced.trimmed(to: Clip(name: "t", start: 0, end: 10), words: gappy).segments.count == 1, "no pace keeps the edit's pauses")
    let clipDir = URL(fileURLWithPath: "/m/Connect AI and Dots")
    expect(exportURL(dir: clipDir).lastPathComponent == "Connect AI and Dots.mp4", "exports are named after the project")
    expect(exportURL(dir: clipDir, preset: ExportPreset.all.first { $0.id == "youtube-4k" }).lastPathComponent == "Connect AI and Dots (4K).mp4", "a preset export says its format")
    expect(exportURL(dir: clipDir, clip: Clip(name: "Steps 1/3", start: 0, end: 1)).lastPathComponent == "Connect AI and Dots - Steps 1-3.mp4", "a clip export says its name")
    let tall = Plan.Output(width: 2160, height: 3840, fps: 30)
    expect(exportURL(dir: clipDir, size: tall).lastPathComponent == "Connect AI and Dots 2160x3840.mp4", "an export ends in its resolution")
    expect(exportURL(dir: clipDir, clip: Clip(name: "Hook", start: 0, end: 1), size: Plan.Output(width: 1080, height: 1920, fps: 30)).lastPathComponent == "Connect AI and Dots - Hook 1080x1920.mp4", "so does a clip's")
    expect(isExportFile("Connect AI and Dots - Hook.mp4", project: "Connect AI and Dots") && isExportFile("out.mp4", project: "x") && !isExportFile("screen.mp4", project: "x"), "exports are recognized, old and new names")
    let clipText = describe(p, clipped)
    expect(clipText.contains("\"Hook\" src 0:03.0-0:08.0") && clipText.contains("WARNING: entirely cut"), "describe lists clips and flags an empty one")

    // B-roll and animations cut in and out hard unless they ask for a motion: no fades by default.
    var seam = buildPlan(p)
    seam.segments = [Segment(start: 0, end: 4, speed: 1), Segment(start: 8, end: 12, speed: 1)]
    seam.inserts = [
      Insert(start: 2, end: 4, file: "a.mp4", placement: "full"), Insert(start: 8, end: 10, file: "b.mp4", placement: "full"),
    ]
    let ss = Scene(plan: seam, words: [], clicks: [], shortcuts: [])
    let partA = ss.inserts[0], partB = ss.inserts[1]
    expect(ss.insertPose(partA, frame: partA.e - 1).opacity == 1 && ss.insertPose(partB, frame: partB.s).opacity == 1, "no fade where animations meet")
    expect(ss.insertPose(partA, frame: partA.s).opacity == 1 && ss.insertPose(partB, frame: partB.e - 1).opacity == 1, "outer edges cut hard too")
    expect(ss.fullFrameCovers(partA.s) && ss.fullFrameCovers(partA.e - 1), "screen marks hide for the whole insert")
    var faded = seam
    faded.inserts?[0].enter = Motion(preset: "fade", seconds: 0.3)
    let fs = Scene(plan: faded, words: [], clicks: [], shortcuts: [])
    expect(fs.insertPose(fs.inserts[0], frame: fs.inserts[0].s).opacity < 0.5 && !fs.fullFrameCovers(fs.inserts[0].s), "an insert that asks for a fade still fades")

    // An end card that runs past the last segment holds to the final frame instead of fading out.
    var ending = seam
    ending.inserts = [Insert(start: 10, end: 14, file: "end.mp4", placement: "full")]
    let es = Scene(plan: ending, words: [], clicks: [], shortcuts: [])
    let endCard = es.inserts[0]
    expect(endCard.e == Double(es.frameCount), "an end card past the last segment ends on the video's last frame")
    expect(es.insertPose(endCard, frame: endCard.e - 1).opacity == 1 && es.insertPose(endCard, frame: endCard.s).opacity == 1, "an end card cuts in and holds to the end")

    // A camera range on the first and last frames holds there: no ease in at 0 or out at the end.
    var opener = buildPlan(p)
    opener.camera = Plan.Camera(video: "camera.mp4", offset: 0)
    opener.defaultLayout = .pip
    let cameraBoxes = layoutBoxes(.camera, plan: opener)
    let full = cameraBoxes.screen.vec + cameraBoxes.cam.vec
    let openerSteps = Scene.layoutSteps(opener, [OutLayout(startF: 0, endF: 60, mode: .camera), OutLayout(startF: 200, endF: 300, mode: .camera)], frames: 300, style: MotionStyle.named(nil))
    expect(openerSteps.at(0) == full && openerSteps.at(299) == full, "full camera from the first frame to the last")
    expect(openerSteps.at(130) != full, "the middle still eases to pip")

    // Full camera over a demo is flagged.
    var hide = p
    hide.source.camera = nil
    var hp = buildPlan(p)
    hp.camera = Plan.Camera(video: "camera.mp4", offset: 0)
    hp.defaultLayout = .camera
    hp.layouts = [LayoutRange(start: 0, end: 4, mode: .camera)]
    hide.events = [InputEvent(t: 1, type: .click, x: 0.5, y: 0.5), InputEvent(t: 5.2, type: .key, x: 0.5, y: 0.5)]
    let flagged = cameraHidesScreen(hide, hp)
    expect(flagged.count == 1 && flagged[0].count == 2, "full-camera demo flagged (\(flagged))")
    hp.defaultLayout = .pip
    hp.layouts = []
    expect(cameraHidesScreen(hide, hp).isEmpty, "pip over the demo is fine")

    // Sound effects: clamped and sorted, outside paths dropped, cut ones flagged in describe.
    var fx = buildPlan(p)
    fx.segments = [Segment(start: 0, end: 4, speed: 1), Segment(start: 6, end: 12, speed: 2)]
    fx.sfx = [SoundEffect(t: 99, file: "sfx/ding.m4a"), SoundEffect(t: 1, file: "sfx/whoosh.m4a", gainDB: -6), SoundEffect(t: 5, file: "sfx/pop.m4a")]
    fx.normalize()
    expect(fx.sfx?.map(\.t) == [1, 5, 12], "sound effects clamped to the recording and sorted")
    var fxEvil = fx
    fxEvil.sfx?.append(SoundEffect(t: 2, file: "/etc/passwd"))
    let (fxClean, fxReverted) = PathSafety.sanitize(fxEvil, previous: fx, project: URL(fileURLWithPath: "/tmp/fx-project"))
    expect(fxClean.sfx == fx.sfx && fxReverted == ["sfx.file"], "a sound effect outside the project is dropped")
    let fxText = describe(p, fx)
    expect(fxText.contains("## Sound effects") && fxText.contains("out 0:01.0 sfx/whoosh.m4a") && fxText.contains("-6 dB"), "describe lists effects")
    expect(fxText.contains("src 0:05.0 CUT (won't play) sfx/pop.m4a"), "describe flags a cut effect")
    expect(fxText.contains("WARNING: sfx #1 at src 0:05.0 is in a cut"), "describe warns about a free-standing effect in a cut")
    // A camera LUT: an outside path is undone, and describe warns when the file can't be used.
    var graded = fx
    graded.camera = Plan.Camera(video: "camera.mp4", offset: 0)
    graded.camera?.grade = Grade(lut: "luts/look.cube")
    var lutEvil = graded
    lutEvil.camera?.grade?.lut = "/etc/passwd"
    let (lutClean, lutReverted) = PathSafety.sanitize(lutEvil, previous: graded, project: URL(fileURLWithPath: "/tmp/fx-project"))
    expect(lutClean.camera?.grade?.lut == "luts/look.cube" && lutReverted == ["camera.grade.lut"], "a LUT outside the project is undone")
    expect(describe(p, graded).contains("WARNING: camera LUT luts/look.cube isn't applied"), "describe warns about a LUT it can't read")
    // Fonts: a file that isn't a font and a name that isn't installed are warned about; an installed one isn't.
    let notAFont = FileManager.default.temporaryDirectory.appendingPathComponent("sd-not-a-font-\(UUID().uuidString).ttf")
    try? Data("nope".utf8).write(to: notAFont)
    defer { try? FileManager.default.removeItem(at: notAFont) }
    var fonted = fx
    fonted.look = Look()
    fonted.look?.fontFiles = [notAFont.path]
    fonted.look?.titleFont = "No Such Font Sans"
    fonted.look?.captionFont = "Helvetica"
    let fontText = describe(p, fonted)
    expect(fontText.contains("font file \(notAFont.path) isn't used"), "describe warns about a font file CoreText can't read")
    expect(fontText.contains("titleFont \"No Such Font Sans\" isn't installed") && !fontText.contains("captionFont"), "describe warns about a missing font name only")
    expect(!describe(p, fx).contains("## Fonts"), "no Fonts section when the fonts are fine")
    // An attached sound plays when its title appears, and follows it when the title moves.
    var attached = fx
    attached.sfx = nil
    var card = Callout(start: 1, end: 3, text: "Step 1", style: "chapter")
    card.sound = Sound(file: "sfx/pop.m4a", gainDB: -8)
    attached.callouts = [card]
    expect(attached.soundEffects.map(\.t) == [1] && attached.soundEffects.first?.gainDB == -8, "a title's sound plays at its start")
    attached.callouts[0].start = 2.5
    expect(attached.soundEffects.map(\.t) == [2.5], "the sound moves with its title")
    let (attachedClean, attachedReverted) = PathSafety.sanitize(
      { var p = attached; p.callouts[0].sound = Sound(file: "/etc/passwd"); return p }(), previous: attached, project: URL(fileURLWithPath: "/tmp/fx-project"))
    expect(attachedClean.callouts[0].sound == nil && attachedReverted == ["sound.file"], "an attached sound outside the project is removed")

    // Attached sounds on annotations and animation beats: each plays when its mark or beat appears
    // (an unknown beat at the animation's start), moves with it, and is removed when it points outside.
    var marked = attached
    marked.callouts = []
    var mark = Annotation(start: 4, end: 6, kind: "box", x: 0.1, y: 0.1, w: 0.2, h: 0.2, text: "here")
    mark.sound = Sound(file: "sfx/ding.m4a")
    marked.annotations = [mark]
    var beats = Animation(start: 8, end: 12, template: "hub", data: .object([:]), cues: ["hub": 9.5])
    beats.sounds = ["start": Sound(file: "sfx/whoosh.m4a"), "hub": Sound(file: "sfx/pop.m4a", gainDB: -4), "nope": Sound(file: "sfx/x.m4a")]
    marked.animations = [beats]
    let markedFx = marked.soundEffects
    expect(markedFx.map(\.t) == [4, 8, 8, 9.5], "annotation and beat sounds play when they appear (\(markedFx.map(\.t)))")
    expect(markedFx.first { $0.t == 9.5 }?.file == "sfx/pop.m4a" && markedFx.first { $0.t == 9.5 }?.gainDB == -4, "a beat's sound keeps its level")
    marked.annotations?[0].start = 5
    marked.animations?[0].move(by: 2)
    expect(marked.soundEffects.map(\.t) == [5, 10, 10, 11.5], "sounds move with their mark and animation")
    var markedEvil = marked
    markedEvil.annotations?[0].sound = Sound(file: "/etc/passwd")
    markedEvil.animations?[0].sounds?["hub"] = Sound(file: "/etc/hosts")
    let (markedClean, markedReverted) = PathSafety.sanitize(markedEvil, previous: marked, project: URL(fileURLWithPath: "/tmp/fx-project"))
    expect(
      markedClean.annotations?[0].sound == nil && markedClean.animations?[0].sounds?["hub"] == nil
        && markedClean.animations?[0].sounds?["start"] != nil && markedReverted == ["sound.file"],
      "outside sounds on marks and beats are removed, the rest kept")

    // Camera punch-ins: the camera snaps tighter for the punch's span only, and describe lists them.
    var punchPlan = buildPlan(p)
    punchPlan.intro = nil
    punchPlan.outro = nil
    punchPlan.segments = [Segment(start: 0, end: 12, speed: 1)]
    punchPlan.camera = Plan.Camera(video: "camera.mp4", offset: 0)
    punchPlan.camera?.zoom = 1.2
    punchPlan.camera?.punchIns = [PunchIn(start: 2, end: 4, scale: 2, note: "the reveal")]
    let punchScene = Scene(plan: punchPlan, words: [], clicks: [], shortcuts: [])
    let pipCam = layoutBoxes(.pip, plan: punchPlan).cam, fullCam = layoutBoxes(.camera, plan: punchPlan).cam
    let zoomAt = { (f: Double) in punchScene.cameraFraming(pipCam, frame: f, cameraWidth: 1280, cameraHeight: 720).zoom }
    expect(zoomAt(59) == 1.2 && abs(zoomAt(60) - 2.4) < 1e-9 && abs(zoomAt(119) - 2.4) < 1e-9 && zoomAt(120) == 1.2, "a punch-in snaps in and out with no ease")
    let punchText = describe(p, punchPlan)
    expect(punchText.contains("## Camera punch-ins") && punchText.contains("src 0:02.0-0:04.0 2x") && punchText.contains("the reveal"), "describe lists punch-ins")

    // Cutout: the bubble cuts out the background, widens to the camera's shape and drops the framing
    // zoom (no sliced-off shoulders); the full camera keeps the room and the zoom.
    var cutPlan = punchPlan
    cutPlan.camera?.punchIns = nil
    cutPlan.camera?.cutout = true
    let cutScene = Scene(plan: cutPlan, words: [], clicks: [], shortcuts: [])
    expect(cutScene.cutoutWeight(fullCam) == 0 && cutScene.cutoutWeight(pipCam) == 1 && punchScene.cutoutWeight(pipCam) == 0, "only a cutout bubble cuts out")
    let bubble = cutScene.cameraFraming(pipCam, frame: 0, cameraWidth: 1280, cameraHeight: 720)
    let pipRect = cutScene.ciRect(pipCam)
    expect(
      abs(bubble.rect.width - pipRect.height * 16 / 9) < 0.5 && abs(bubble.rect.midX - pipRect.midX) < 0.5 && bubble.rect.height == pipRect.height
        && bubble.zoom == 1, "a cutout bubble widens around its center to the camera's shape (\(bubble.rect) from \(pipRect))")
    let room = cutScene.cameraFraming(fullCam, frame: 0, cameraWidth: 1280, cameraHeight: 720)
    expect(room.rect == cutScene.ciRect(fullCam) && room.zoom == 1.2, "the full camera keeps its box and framing zoom")

    // Chapter cards: the scrim (72% black, blended in linear light) takes a white screen to about 0.57
    // in sRGB, so the title reads over a busy screen; the old 45% scrim left it at about 0.77.
    var scrimPlan = punchPlan
    scrimPlan.camera = nil
    let whiteScreen = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let bare = Scene(plan: scrimPlan, words: [], clicks: [], shortcuts: []).render(frame: 90, screen: whiteScreen, camera: nil)
    scrimPlan.callouts = [Callout(start: 1, end: 5, text: "Chapter one", style: "chapter")]
    let carded = Scene(plan: scrimPlan, words: [], clicks: [], shortcuts: []).render(frame: 90, screen: whiteScreen, camera: nil)
    let spotX = Double(scrimPlan.output.width) * 0.3, spotY = Double(scrimPlan.output.height) * 0.3
    let bareGreen = pixel(bare, x: spotX, y: spotY)[1], cardGreen = pixel(carded, x: spotX, y: spotY)[1]
    expect(bareGreen > 0.5 && cardGreen < 0.65, "the chapter scrim darkens the screen (\(bareGreen) to \(cardGreen))")

    // Timeline zoom keeps the playhead where it is on screen, centers it when it's out of view, and
    // stays inside the content; zooming again from where the last zoom asked (a slider drag) doesn't drift.
    let zoomX = timelineZoomScroll(around: 50, from: 10, to: 20, scrollX: 300, visibleWidth: 800, minContentWidth: 800, axisSeconds: 120)
    expect(zoomX == 800, "the playhead stays 200 pt from the left (scrolled to \(zoomX))")
    let hiddenX = timelineZoomScroll(around: 50, from: 10, to: 20, scrollX: 0, visibleWidth: 400, minContentWidth: 400, axisSeconds: 120)
    expect(hiddenX == 800, "an off-screen playhead lands centered (scrolled to \(hiddenX))")
    expect(timelineZoomScroll(around: 119, from: 10, to: 5, scrollX: 400, visibleWidth: 800, minContentWidth: 800, axisSeconds: 120) == 0, "zooming out clamps to the content")
    var dragX = 300.0, dragPx = 10.0
    for _ in 0..<20 {
      dragX = timelineZoomScroll(around: 50, from: dragPx, to: dragPx * 1.1, scrollX: dragX, visibleWidth: 800, minContentWidth: 800, axisSeconds: 120)
      dragPx *= 1.1
    }
    expect(abs(50 * dragPx - dragX - 200) < 1e-6, "a slider drag keeps the playhead in place (\(50 * dragPx - dragX) pt)")

    // Zoomed-out Words row: a mark per word, faint where it's cut, and none for cut words on the output axis.
    let markMap = mapSegments([Segment(start: 0, end: 2, speed: 1), Segment(start: 4, end: 6, speed: 1)], fps: fps)
    let markWords = [Word(text: "kept", start: 0.5, end: 1), Word(text: "cut", start: 3, end: 3.2), Word(text: "later", start: 4.5, end: 5)]
    let srcMarks = speechMarks(markWords, mapped: markMap, fps: fps, pxPerSec: 4, outputTime: false)
    expect(srcMarks == [SpeechMark(x: 2, width: 2, kept: true), SpeechMark(x: 12, width: 1, kept: false), SpeechMark(x: 18, width: 2, kept: true)], "source-axis speech marks (\(srcMarks))")
    let outMarks = speechMarks(markWords, mapped: markMap, fps: fps, pxPerSec: 4, outputTime: true)
    expect(outMarks.map(\.x) == [2, 10], "output-axis speech marks skip cut words (\(outMarks.map(\.x)))")

    // Space reaches the editor from an empty text field only; typing a space and ⌘/⇧ keys stay with the field.
    expect(shortcutTakesKeyInTextField(keyCode: 49, hasModifiers: false, fieldText: ""), "Space plays from the empty Claude box")
    expect(!shortcutTakesKeyInTextField(keyCode: 49, hasModifiers: false, fieldText: "zoom in"), "Space types into a field with text")
    expect(!shortcutTakesKeyInTextField(keyCode: 49, hasModifiers: true, fieldText: ""), "⌘Space and ⇧Space stay with the field")
    expect(!shortcutTakesKeyInTextField(keyCode: 1, hasModifiers: false, fieldText: ""), "other keys stay with the field")

    // AI edits close out: silence becomes the outcome, a failure is added after what Claude said,
    // a normal finish keeps Claude's words, and the error carries the end of stderr.
    let signedOut = claudeErrorOutcome(status: 1, errors: (1...12).map { "line \($0)" }.joined(separator: "\n"))
    expect(signedOut.hasPrefix("Claude Code stopped with an error (exit status 1):\nline 5\n") && signedOut.hasSuffix("line 12"), "the error keeps the last 8 lines of stderr")
    expect(claudeErrorOutcome(status: 2, errors: "") == "Claude Code stopped with an error (exit status 2).", "an error with no stderr")
    expect(closingReply("", outcome: "Claude finished without saying anything.") == "Claude finished without saying anything.", "a silent finish says so")
    expect(closingReply("Zoomed in.", outcome: signedOut) == "Zoomed in.\n\n" + signedOut, "a failure after a reply is added to it")
    expect(closingReply("Zoomed in.", outcome: "OpenAI couldn't make the edit: timeout").hasSuffix("timeout"), "an API failure is added too")
    expect(closingReply("Zoomed in.", outcome: "Claude finished without saying anything.") == "Zoomed in.", "a normal finish keeps the reply")
    // A Claude that exits before the app starts waiting still wakes the wait (it used to hang on "editing").
    let early = ExitSignal()
    early.fire()
    let woke = DispatchSemaphore(value: 0)
    Task.detached {
      await early.wait()
      woke.signal()
    }
    expect(woke.wait(timeout: .now() + 2) == .success, "an exit before the wait is still noticed")
    let late = ExitSignal()
    let wokeLate = DispatchSemaphore(value: 0)
    Task.detached {
      await late.wait()
      wokeLate.signal()
    }
    expect(wokeLate.wait(timeout: .now() + 0.2) == .timedOut, "the wait holds until the exit")
    late.fire()
    expect(wokeLate.wait(timeout: .now() + 2) == .success, "an exit after the wait wakes it")
    let tail = TailBuffer(limit: 10)
    tail.append(Data("0123456789".utf8))
    tail.append(Data("abcde\n".utf8))
    expect(tail.text == "6789abcde", "stderr keeps its last bytes (\(tail.text))")

    // Logo pickers list aliases (OpenAI and ChatGPT), so every logo a template starts with has an entry.
    let bundledLogos = AnimationSources(project: lib, builtIn: templateDir.deletingLastPathComponent()).logos()
    expect(bundledLogos["OpenAI"] != nil && bundledLogos["ChatGPT"] != nil, "both names of one logo are listed")
    for t in templates {
      let named = t.fields.flatMap { f -> [String] in
        switch f.type {
        case "logo": return t.data[path: f.key]?.string.map { [$0] } ?? []
        case "logos": return t.data[path: f.key]?.strings ?? []
        default: return []
        }
      }
      let missing = named.filter { bundledLogos[$0] == nil }
      expect(missing.isEmpty, "\(t.name): every starting logo is in the picker (missing \(missing))")
    }

    // Animation scripts run in JavaScriptCore: every template's frames draw without throwing, and the
    // hub's background field shows its own apps, each once before any repeats, never the grid's.
    let templateScripts = animationScripts(templateDir.deletingLastPathComponent())
    expect(templateScripts.evaluateScript("stageTransform(1920, 1080)").toString() == "translate(0px, 0px) scale(1)", "a 16:9 clip fills the frame with the stage")
    expect(templateScripts.evaluateScript("stageTransform(1080, 1920)").toString() == "translate(0px, 656.25px) scale(0.5625)", "a vertical clip fits the stage evenly and centers it instead of stretching it")
    expect(templateScripts.evaluateScript("JSON.stringify(stageSize(1000, 1000, true))").toString() == #"{"w":1350,"h":1350,"reflow":true}"#, "a template that reflows gets a square board for a square card")
    expect(templateScripts.evaluateScript("JSON.stringify(stageSize(1000, 1000, false))").toString() == #"{"w":1920,"h":1080,"reflow":false}"#, "one that doesn't keeps the 16:9 board")
    expect(templateScripts.evaluateScript("JSON.stringify(stageSize(1920, 1080, true))").toString() == #"{"w":1920,"h":1080,"reflow":false}"#, "16:9 always gets the classic board")
    expect(templateScripts.evaluateScript("TEMPLATES.storyboard.reflows").toBool(), "the storyboard lays itself out on any board")
    for t in templates {
      let data = String(decoding: (try? JSONEncoder().encode(t.data)) ?? Data("{}".utf8), as: UTF8.self)
      let cues = "{" + t.cues.map { "\"\($0.key)\": \($0.at)" }.joined(separator: ", ") + "}"
      let drawn = templateScripts.evaluateScript("""
        (() => { const seek = TEMPLATES["\(t.name)"](\(data), \(cues), \(t.length));
          for (let s = 0; s <= \(t.length); s += 0.25) seek(s); return true; })()
        """)
      expect(drawn?.toBool() == true, "\(t.name): every frame draws")
    }
    func hubField(_ grid: [String], _ own: [String]) -> [String] {
      let data = String(decoding: (try? JSONEncoder().encode(["apps": grid, "moreApps": own])) ?? Data(), as: UTF8.self)
      let result = templateScripts.evaluateScript("""
        (() => { made = []; const d = \(data); d.more = "+ more"; TEMPLATES.hub(d, {}, 17);
          return made.filter(e => e.className.includes("ghost")).map(e => e.innerHTML.slice(1)); })()
        """)
      return result?.toArray() as? [String] ?? []
    }
    let hubGrid = ["Salesforce", "Slack", "Jira"]
    let hubOwn = (1...10).map { "App \($0)" }
    let hubSpots = hubField(hubGrid, hubOwn + ["Slack"])
    let cycled = hubSpots.indices.map { hubOwn[$0 % hubOwn.count] }
    expect(hubSpots.count > hubOwn.count && hubSpots == cycled, "the hub's field shows each of its apps once before repeating (\(hubSpots))")
    expect(!hubSpots.contains { hubGrid.contains($0) }, "the hub's field leaves out the grid's apps")
    let hubMany = (1...40).map { "App \($0)" }
    let hubFull = hubField(hubGrid, hubMany)
    expect(Set(hubFull).count == hubFull.count, "with more apps than spots, none repeats (\(hubFull.count) spots)")
    expect(Set(hubField(hubGrid, [])) == Set(hubGrid), "with no apps of its own, the field repeats the grid's")

    let mutedMap = mapSegments([Segment(start: 0, end: 2, speed: 1), Segment(start: 2, end: 10, speed: 8)], fps: fps)
    let mutedPages = Scene.captionPages(
      [Word(text: "heard", start: 0.5, end: 1), Word(text: "muted", start: 4, end: 4.5)], mutedMap, fps: fps, maxWords: 7)
    expect(mutedPages.flatMap { $0.words.map(\.0) } == ["heard"], "no captions for words in a muted sped-up segment")

    // Warm voice, at the leveled voice's levels: more chest (80 Hz) and less boxiness (350 Hz) than
    // 1 kHz, normal speech keeps about its level, and loud speech is pulled in a few dB.
    func warmLevel(_ hz: Double, _ amp: Double) -> Double {
      let chain = WarmVoice(sampleRate: 48000, channels: 1)
      var sum = 0.0
      for i in 0..<48000 {
        let y = Double(chain.process(Float(amp * sin(2 * Double.pi * hz * Double(i) / 48000)), channel: 0))
        if i >= 24000 { sum += y * y }
      }
      return 10 * log10(sum / 24000)
    }
    let quiet = 0.03, normal = 0.14, loud = 0.5  // about -33, -20 and -9 dBFS RMS
    let ref = warmLevel(1000, quiet)
    expect(warmLevel(80, quiet) - ref > 1.5, "warm voice adds chest below 120 Hz (\(warmLevel(80, quiet) - ref))")
    expect(warmLevel(350, quiet) - ref < -1.5, "warm voice cuts boxiness around 350 Hz (\(warmLevel(350, quiet) - ref))")
    expect(warmLevel(8000, quiet) - ref < -1, "warm voice softens the top end (\(warmLevel(8000, quiet) - ref))")
    let normalOut = warmLevel(1000, normal) - 20 * log10(normal / sqrt(2))
    expect(normalOut > -1 && normalOut < 4.5, "normal speech keeps about its level (\(normalOut) dB)")
    let squeezed = (warmLevel(1000, loud) - warmLevel(1000, normal)) - 20 * log10(loud / normal)
    expect(squeezed < -3 && squeezed > -9, "loud speech is pulled in a few dB (\(squeezed))")
    let polished = AudioSettings.polished(AudioSettings(gainDB: 2))
    expect(polished.normalize == true && polished.warm == true && polished.gainDB == 2, "new recordings can start leveled and warm")

    // Leveling: a phrase 10 dB quieter gets about 7 dB more than a normal one, and the pause between
    // them (room noise) doesn't pull the gain up. Built in steps so CI's compiler can type-check it.
    var phrases: [(Double, Double)] = []
    for i in 0..<600 {
      let level: Double = i < 200 ? -20 : i < 240 ? -60 : i < 440 ? -30 : -20
      phrases.append((Double(i) * 0.05, level))
    }
    let curve = AudioGain.levelingCurve(phrases)
    let loudG = curve[100].gainDB, quietG = curve[340].gainDB, pauseG = curve[220].gainDB
    expect(abs((quietG - loudG) - 7) < 0.5, "a quieter phrase is raised by most of the difference (\(quietG - loudG))")
    expect(pauseG <= quietG + 0.01 && pauseG >= loudG - 0.01, "a pause holds the gain between its phrases instead of boosting the noise")

    fileAndFormatChecks()
    sceneDrawingChecks()
    audioChecks()
    editorActionChecks()
    recordedBrollChecks()
    reorderChecks()
    flashChecks()
    coverChecks()
    inputEventChecks()

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
  }
}
