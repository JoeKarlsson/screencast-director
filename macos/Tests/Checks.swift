import CoreImage
import ImageIO
import Foundation
import JavaScriptCore

// Plain-swiftc checks for DirectorCore (Swift Testing and XCTest need Xcode). Run: macos/test.sh

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
      classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
      setAttribute() {}, appendChild() {}, querySelector() { return fake(); }, querySelectorAll() { return []; },
      before() {}, after() {}, childNodes: [] });
    var window = globalThis;
    var document = { createElement: fake, createElementNS: fake, getElementById: fake, documentElement: fake(), body: fake(), images: [] };
    """)
  let templateFiles = ((try? FileManager.default.contentsOfDirectory(atPath: animations.appendingPathComponent("templates").path)) ?? [])
    .filter { $0.hasSuffix(".js") }.sorted().map { "templates/" + $0 }
  for file in ["engine.js"] + templateFiles {
    let source = (try? String(contentsOf: animations.appendingPathComponent(file), encoding: .utf8)) ?? ""
    expect(!source.isEmpty, "\(file) loads")
    js.evaluateScript(source, withSourceURL: URL(string: file))
  }
  // The marks the renderer hands the page (config.marks).
  let marks = (try? JSONSerialization.data(withJSONObject: MarkSet.builtIn.json)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  js.evaluateScript("SCRIBBLES = \(marks);")
  js.evaluateScript("""
    cam = fake(); lines = fake();
    var made = [];
    const makeElement = el;
    el = (cls, html) => { const d = makeElement(cls, html); made.push(d); return d; };
    logoHTML = name => "@" + name;
    // lottie-web isn't loaded here: a stand-in records the frames the lottie template asks for.
    var lottieFrames = [];
    var lottie = { loadAnimation: () => ({ goToAndStop: f => lottieFrames.push(f) }) };
    LOTTIE = { w: 400, h: 200, ip: 0, op: 60, fr: 30 };
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
    let blinks = s.indices.filter { i in
      let len = s[i].end - s[i].start
      let touches = (i > 0 && abs(s[i - 1].end - s[i].start) < 1e-6) || (i + 1 < s.count && abs(s[i + 1].start - s[i].end) < 1e-6)
      return len < 1 && touches && !(s[i].note ?? "").contains("speech")
    }
    expect(blinks.isEmpty, "no sub-second non-speech clip plays straight into another: \(blinks.map { s[$0] })")
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
    func clicks(_ list: [(Double, Double, Double)]) -> Project {
      var z = Project(dir: URL(fileURLWithPath: "/tmp"), source: src)
      z.events = list.map { InputEvent(t: $0.0, type: .click, x: $0.1, y: $0.2) }
      return z
    }
    let stop = buildZooms(clicks([(5, 0.5, 0.5), (src.duration - 0.5, 0.9, 0.1)]))
    expect(stop.count == 1 && stop[0].x == 0.5, "the click that stops the recording gets no zoom (\(stop))")
    // Each step is within zoomDistance, but the walk ends up further than one 1.6x view can show.
    let drift = buildZooms(clicks([(5, 0.1, 0.5), (5.5, 0.28, 0.5), (6, 0.46, 0.5), (6.5, 0.64, 0.5)]))
    expect(drift.count == 2, "clicks that don't fit one zoom's view split into two zooms (\(drift.map(\.x)))")
    let close = buildZooms(clicks([(4, 0.2, 0.2), (7.5, 0.8, 0.8)]))
    expect(close.count == 2 && close[0].end == close[1].start, "zooms a moment apart pan instead of popping out and back (\(close))")
    let apart = buildZooms(clicks([(4, 0.2, 0.2), (10, 0.8, 0.8)]))
    expect(apart.count == 2 && apart[0].end < apart[1].start, "zooms far apart still go back to wide between them")
    var opening = clicks([(0.5, 0.3, 0.3), (6, 0.7, 0.7)])
    opening.source.duration = 12
    let opened = buildPlan(opening).zooms
    expect(opened.allSatisfy { $0.start >= 2.5 }, "the video opens wide: no zoom in its first 2.5 s (\(opened.map(\.start)))")

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
        expect(builtIns.allSatisfy { $0.item.license == "CC0 1.0" && $0.item.source != nil && $0.item.author != nil },
          "every built-in \(kind) item is CC0 with a source and author")
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
      let memes = mine.appendingPathComponent("Meme")
      try FileManager.default.createDirectory(at: memes, withIntermediateDirectories: true)
      try Data("oof".utf8).write(to: memes.appendingPathComponent("Meme - Oof.wav"))
      let grouped = try lib.items()
      expect(grouped.map(\.item.category).prefix(2) == ["My Sounds", "Meme"], "loose personal sounds come first, then each subfolder as its own category")
      let oof = try lib.entry(forPlanPath: "sfx/Meme - Oof.wav")
      expect(oof?.url == memes.appendingPathComponent("Meme - Oof.wav"), "a sound in a subfolder resolves by file name alone")
      if let oof { try lib.freeze(oof, project: proj) }
      expect(FileManager.default.fileExists(atPath: proj.appendingPathComponent("sfx/Meme - Oof.wav").path), "a subfolder sound freezes flat into sfx/")
      try Data("again".utf8).write(to: mine.appendingPathComponent("Meme - Oof.wav"))
      expect((try? lib.items()) == nil, "two personal sounds with the same file name are an error")
      try FileManager.default.removeItem(at: mine.appendingPathComponent("Meme - Oof.wav"))
      try FileManager.default.removeItem(at: proj.appendingPathComponent("sfx"))
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

      // Work-only files: listed and usable only for a video whose profile is a work profile.
      let work = tmp.appendingPathComponent("work"), licensed = work.appendingPathComponent("PremiumBeat")
      try FileManager.default.createDirectory(at: licensed, withIntermediateDirectories: true)
      try Data("pb".utf8).write(to: licensed.appendingPathComponent("Theme - full.wav"))
      let personalMusic = AudioLibrary(.music, personal: mine, workOnly: work)
      let workMusic = AudioLibrary(.music, personal: mine, workOnly: work, allowsWork: true)
      expect(!(try personalMusic.items()).contains { $0.item.file == "Theme - full.wav" }, "a non-work video doesn't list work-only music")
      expect(try workMusic.items().first { $0.item.file == "Theme - full.wav" }?.item.category == "PremiumBeat", "a work video lists it under its folder")
      expect(personalMusic.workOnlyPaths(["music/Theme - full.wav", "music/advertime.m4a"]) == ["music/Theme - full.wav"], "work-only paths are found by file name")
      expect((try? personalMusic.freezeMissing(["music/Theme - full.wav"], project: proj)) == nil, "a non-work video can't build with work-only music")
      expect(try workMusic.freezeMissing(["music/Theme - full.wav"], project: proj) == ["music/Theme - full.wav"], "a work video copies it in")
      expect((try? personalMusic.freezeMissing(["music/Theme - full.wav"], project: proj)) == nil, "a copy already in the project still can't build without a work profile")
      let profiles = ProfileLibrary(root: tmp.appendingPathComponent("profiles"))
      var workProfile = Profile(name: "Work", style: sp.style, look: Look())
      workProfile.work = true
      for p in [workProfile, Profile(name: "Home", style: sp.style, look: Look())] {
        try FileManager.default.createDirectory(at: profiles.folder(p.name), withIntermediateDirectories: true)
        try JSONEncoder().encode(p).write(to: profiles.folder(p.name).appendingPathComponent("profile.json"))
      }
      workProfile.apply(to: &sp, name: "Demo")
      expect(sp.profile == "Work", "applying a profile records its name")
      expect(try AudioLibrary(.music, for: sp, profiles: profiles).allowsWork, "a work profile's video gets the work-only files")
      sp.profile = "Home"
      expect(try !AudioLibrary(.music, for: sp, profiles: profiles).allowsWork, "another profile's doesn't")
      sp.profile = "Gone"
      expect(try !AudioLibrary(.music, for: sp, profiles: profiles).allowsWork, "nor does a profile that's gone")
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
      try? PlanHistory.snapshot(Data("v\(i)".utf8), planURL: planURL, keep: 5, now: Date(timeIntervalSince1970: 1_000_000 + Double(i)))
    }
    try? PlanHistory.snapshot(Data("v7".utf8), planURL: planURL, keep: 5, now: Date(timeIntervalSince1970: 2_000_000))
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
    look.intro = Card(title: "{title}", subtitle: "Sam Rivera")
    var prof = buildPlan(p)
    Profile(name: "T", style: prof.style, look: look).apply(to: &prof, name: "Tour")
    expect(prof.intro?.title == "Tour" && prof.intro?.subtitle == "Sam Rivera" && prof.outro == nil, "profile fills the intro title")

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
        == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",  // swiftlint:disable:this line_length
      "S3 GET example Authorization header")
    let s3c = S3.Config(endpoint: URL(string: "http://minio.local:9000/")!, bucket: "videos", accessKey: "a", secretKey: "b")
    expect(S3.objectURL(s3c, key: "my demo/clip 1.gif").absoluteString == "http://minio.local:9000/videos/my%20demo/clip%201.gif", "object URL")
    expect(S3.key(for: URL(fileURLWithPath: "/x/out.MP4"), name: "2026-10-12 Demo: Take #2", date: Date(timeIntervalSince1970: 5),
      nonce: "0a1b2c3d") == "2026-10-12-demo-take-2-5-0a1b2c3d.mp4", "upload key")
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
    // A saved profile's assets live in the user's library (the support folder), so Claude may apply one.
    let library = FileManager.default.temporaryDirectory.appendingPathComponent("sd-library-\(UUID().uuidString)")
    var profiled = prior
    profiled.music = Music(file: library.appendingPathComponent("Profiles/Work/track.m4a").path)
    profiled.look?.fontFiles = [library.appendingPathComponent("Profiles/Work/Brand.otf").path, "/tmp/evil.otf"]
    let (withProfile, profileReverted) = PathSafety.sanitize(profiled, previous: prior, project: proj, library: library)
    expect(withProfile.music == profiled.music && withProfile.look?.fontFiles == [profiled.look!.fontFiles![0]],
      "a profile's library assets are kept, other paths still reverted (\(profileReverted))")
    // A clip's logo becomes its export's watermark, so it's a plan file path like the rest.
    var clipEvil = prior
    clipEvil.clips = [Clip(name: "c", start: 0, end: 1, logo: "/tmp/sd-outside/marker.png"), Clip(name: "d", start: 1, end: 2, logo: "logos/ok.png")]
    let (clipCleaned, clipReverted) = PathSafety.sanitize(clipEvil, previous: prior, project: proj)
    expect(clipCleaned.clips?.map(\.logo) == [nil, "logos/ok.png"] && clipReverted == ["clips.logo"], "a clip logo outside the project is reverted (\(clipReverted))")

    // A project someone sent can ship its working folders as symlinks: nothing is written or deleted through one.
    let victim = proj.deletingLastPathComponent().appendingPathComponent("sd-victim-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: victim.appendingPathComponent("dir"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: victim) }
    try? Data("keep".utf8).write(to: victim.appendingPathComponent("a.txt"))
    try? Data("keep".utf8).write(to: victim.appendingPathComponent("dir/b.txt"))
    try? FileManager.default.createSymbolicLink(atPath: proj.appendingPathComponent(".animations").path, withDestinationPath: "../" + victim.lastPathComponent)
    var cleanupThrew = false
    do { _ = try prior.removeUnusedAnimationClips(dir: proj) } catch { cleanupThrew = true }
    expect(cleanupThrew, "the clip cleanup refuses a symlinked .animations")
    expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("dir/b.txt").path), "nothing in the symlink's target is deleted")
    expect((try? PathSafety.ownedFolder(".animations", in: proj)) == nil && (try? PathSafety.ownedFolder("../x", in: proj)) == nil,
      "ownedFolder refuses a symlink and a parent path")
    expect((try? PathSafety.ownedFolder("animations/logos", in: proj)).map { PathSafety.url($0, isInside: proj) } == true, "ownedFolder makes a real folder")
    try? FileManager.default.createSymbolicLink(atPath: proj.appendingPathComponent("broll").path, withDestinationPath: victim.path)
    let pick = victim.appendingPathComponent("a.txt")
    expect((try? Project.importFile(pick, into: "broll", dir: proj)) == nil, "an import refuses a symlinked broll/")
    try? FileManager.default.createSymbolicLink(atPath: proj.appendingPathComponent("animations/logos/x.svg").path, withDestinationPath: pick.path)
    expect((try? PathSafety.ownedFile(proj.appendingPathComponent("animations/logos/x.svg"))) == nil, "ownedFile refuses a symlink")
    // Template names become file names: "../" in one once let `template update` delete any .js file.
    expect(PathSafety.isPlainName("storyboard") && PathSafety.isPlainName("my_hub-2") && !PathSafety.isPlainName("../x") && !PathSafety.isPlainName("a/b")
      && !PathSafety.isPlainName(""), "plain names")
    let templateLib = proj.appendingPathComponent("lib")
    try? FileManager.default.createDirectory(at: templateLib.appendingPathComponent("templates"), withIntermediateDirectories: true)
    try? Data("//".utf8).write(to: victim.appendingPathComponent("keep.js"))
    let sources = AnimationSources(project: proj, builtIn: templateLib, personal: templateLib)
    let traversal = String(repeating: "../", count: 30) + victim.appendingPathComponent("keep").path.dropFirst()
    expect(sources.libraryFolder(for: traversal) == nil && sources.script(traversal) == nil, "a ../ template name finds nothing")
    expect((try? sources.updateFromLibrary(traversal)) != nil && FileManager.default.fileExists(atPath: victim.appendingPathComponent("keep.js").path),
      "updating a ../ template name deletes nothing")

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
    var terminal = Look()
    terminal.animationTheme = "terminal"
    var mint = terminal
    mint.accent = "#9EF0B8"
    expect(anim.clipPath(out1080, dir: nil, look: terminal) != anim.clipPath(out1080, dir: nil), "a theme renders a new clip")
    expect(anim.clipPath(out1080, dir: nil, look: mint) != anim.clipPath(out1080, dir: nil, look: terminal), "a new accent renders a new clip")
    expect(anim.clipPath(out1080, dir: nil, look: mint) == anim.clipPath(out1080, dir: nil, look: mint), "the same look reuses its clip")
    // A Lottie file comes from the first folder with it, never from outside one, and its contents name the clip.
    let lottieRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sd-lottie-\(UUID().uuidString)")
    let lottieVideo = AnimationSources.videoFolder(lottieRoot).appendingPathComponent("lottie")
    try? FileManager.default.createDirectory(at: lottieVideo, withIntermediateDirectories: true)
    try? Data("{\"op\": 60}".utf8).write(to: lottieVideo.appendingPathComponent("a.json"))
    let lottieSources = AnimationSources(project: lottieRoot, builtIn: lottieRoot, personal: lottieRoot)
    expect(lottieSources.lottie("a.json") != nil && lottieSources.lottie("../lottie/a.json") == nil, "a Lottie is found by name only")
    let playing = Animation(start: 0, end: 4, template: "lottie", data: .object(["lottie": .string("a.json")]))
    let lottieClip = playing.clipPath(out1080, dir: lottieRoot)
    try? Data("{\"op\": 90}".utf8).write(to: lottieVideo.appendingPathComponent("a.json"))
    expect(playing.clipPath(out1080, dir: lottieRoot) != lottieClip, "editing the video's Lottie file renders a new clip")
    // Listing reads only real Lotties, the video's copy first; adding one checks it and never replaces a different file.
    let lottieLibrary = lottieRoot.appendingPathComponent("library")
    let real = lottieRoot.appendingPathComponent("wave.json")
    try? Data(#"{"fr": 30, "ip": 0, "op": 45, "w": 100, "h": 100, "layers": [], "loop": false, "meta": {"d": "A wave"}}"#.utf8).write(to: real)
    let libSources = AnimationSources(project: lottieRoot, builtIn: lottieRoot, personal: lottieLibrary)
    expect(libSources.lotties().isEmpty, "a .json that isn't a Lottie isn't listed")
    let toLibrary = try? libSources.addLottie(real, toLibrary: true)
    expect(toLibrary?.origin == .personal && libSources.lotties().first?.origin == .personal, "a Lottie added to the library lists from there")
    let added = try? libSources.addLottie(real)
    expect(
      added.map { [$0.name, $0.about, "\($0.seconds)", "\($0.loops)"] } == ["wave.json", "A wave", "1.5", "false"]
        && libSources.lotties().map(\.origin) == [.video],
      "an added Lottie lists from the video first, with its description, length and loop (\(String(describing: added)))")
    expect((try? libSources.addLottie(lottieVideo.appendingPathComponent("a.json"))) == nil, "a file that isn't a Lottie is refused")
    try? Data(#"{"fr": 30, "op": 90, "w": 100, "h": 100, "layers": []}"#.utf8).write(to: real)
    expect((try? libSources.addLottie(real)) == nil, "a different file never replaces the video's Lottie of that name")
    let bundledTemplates = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Resources/animations/templates")
    expect(AnimationTemplate.all(in: bundledTemplates).first { $0.name == "lottie" }?.make(start: 0, end: 2).overlay == true,
      "a new Lottie animation floats over the video")
    try? FileManager.default.removeItem(at: lottieRoot)
    // Text contrast: WCAG ratios, and the backdrop is what's around the text, even when its glyphs fill its box.
    expect(abs(TextContrast.ratio([0, 0, 0], [1, 1, 1]) - 21) < 0.01 && abs(TextContrast.ratio([0.5, 0.5, 0.5], [0.5, 0.5, 0.5]) - 1) < 0.01, "contrast runs 1:1 to 21:1")
    // A 40x40 white card (premultiplied BGRA) with a black glyph filling 10x10 of a 12x12 text box at (15, 15).
    var textCard = [UInt8](repeating: 255, count: 40 * 40 * 4)
    for y in 15..<25 { for x in 15..<25 { let i = (y * 40 + x) * 4; textCard[i] = 0; textCard[i + 1] = 0; textCard[i + 2] = 0 } }
    expect(TextContrast.backdrop(bgra: textCard, width: 40, height: 40, x: 15, y: 15, w: 12, h: 12, text: [0, 0, 0]) == [1, 1, 1, 1],
      "a bold glyph covering most of its box still reads its card")
    expect(TextContrast.backdrop(bgra: [UInt8](repeating: 0, count: 6400), width: 40, height: 40, x: 15, y: 15, w: 10, h: 10)?[3] == 0, "text on nothing has a see-through backdrop")
    expect(TextContrast.backdrop(bgra: textCard, width: 40, height: 40, x: 100, y: 0, w: 5, h: 5) == nil, "a box off the frame has no backdrop")
    let greyOnWhite = TextContrast.rows([["Faint", 5.0, 5.0, 30.0, 30.0, 0.8, 0.8, 0.8, 0.0]], bgra: textCard, width: 40, height: 40)
    expect(greyOnWhite.count == 1 && greyOnWhite[0][0] as? String == "contrast" && greyOnWhite[0][2] as? String == "4.5"
      && abs((greyOnWhite[0][3] as? Double ?? 0) - 4.5 / TextContrast.ratio([0.8, 0.8, 0.8], [1, 1, 1])) < 0.001, "light grey on white is too faint to read")
    expect(TextContrast.rows([["Ink", 5.0, 5.0, 30.0, 30.0, 0.1, 0.1, 0.1, 0.0]], bgra: textCard, width: 40, height: 40).isEmpty, "dark ink on white reads fine")
    // An overlay floats over the whole video: its own clip, with alpha (.mov), and it covers nothing.
    var floating = anim
    floating.overlay = true
    expect(floating.clipPath(out1080, dir: nil).hasSuffix(".mov") && anim.clipPath(out1080, dir: nil).hasSuffix(".mp4"), "an overlay renders to a .mov with alpha")
    expect(floating.clipPath(out1080, dir: nil) != anim.clipPath(out1080, dir: nil), "making an animation an overlay renders a new clip")
    floating.alternates = [Animation.Alternate(template: "sprawl", data: .object([:]), cues: nil, note: nil)]
    expect(floating.versions.count == 2 && floating.versions.allSatisfy(\.isOverlay), "an overlay's alternates render as overlays too")
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
    // Clip cleanup deletes clips no plan uses, but keeps everything while plan.json is half-written.
    let cleanDir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-anim-clean-\(UUID().uuidString)")
    let clipsDir = cleanDir.appendingPathComponent(".animations")
    try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
    let usedClip = (anim.clipPath(animPlan.animationOutput, dir: cleanDir, look: animPlan.look, safeTop: animPlan.animationSafeTop) as NSString).lastPathComponent
    for f in [usedClip, "old.mp4"] { FileManager.default.createFile(atPath: clipsDir.appendingPathComponent(f).path, contents: Data()) }
    try? Data("{ \"segments\": [".utf8).write(to: cleanDir.appendingPathComponent("plan.json"))
    expect((try? animPlan.removeUnusedAnimationClips(dir: cleanDir)) == .some(nil), "clip cleanup is skipped while plan.json doesn't load")
    expect(FileManager.default.fileExists(atPath: clipsDir.appendingPathComponent("old.mp4").path), "a half-written plan.json deletes no clips")
    try? FileManager.default.removeItem(at: cleanDir.appendingPathComponent("plan.json"))
    // Another process's render in progress is kept; one left by a render that died an hour ago isn't.
    let inProgress = ".rendering-123-\(usedClip)", leftover = ".rendering-456-gone.mp4"
    for f in [inProgress, leftover] { FileManager.default.createFile(atPath: clipsDir.appendingPathComponent(f).path, contents: Data()) }
    try? FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: clipsDir.appendingPathComponent(leftover).path)
    let removed = (try? animPlan.removeUnusedAnimationClips(dir: cleanDir)) ?? nil
    expect(removed.map(Set.init) == ["old.mp4", leftover], "clip cleanup deletes the clip no plan uses and a dead render's leftover (\(removed ?? []))")
    expect(FileManager.default.fileExists(atPath: clipsDir.appendingPathComponent(inProgress).path), "clip cleanup keeps another render in progress")
    expect(FileManager.default.fileExists(atPath: clipsDir.appendingPathComponent(usedClip).path), "clip cleanup keeps the plan's own clip")
    try? FileManager.default.removeItem(at: cleanDir)

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
    // A fresh folder each run: main exits before this defer runs, so a reused pid would find an old run's files.
    let lib = FileManager.default.temporaryDirectory.appendingPathComponent("sd-anim-\(UUID().uuidString)")
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

    // The library: the projects folder's projects plus ones opened from elsewhere that still exist.
    let libRoot = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
    let inside = libRoot.appendingPathComponent("folder/rec"), outside = libRoot.appendingPathComponent("other/plant-rack")
    let notProject = libRoot.appendingPathComponent("folder/notes"), gone = libRoot.appendingPathComponent("other/deleted")
    for d in [inside, outside, notProject] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    for d in [inside, outside] { FileManager.default.createFile(atPath: d.appendingPathComponent("source.json").path, contents: Data("{}".utf8)) }
    let listed = Set(libraryProjects(folder: libRoot.appendingPathComponent("folder"), opened: [outside.path: 1, gone.path: 2, inside.path: 3]).map(\.standardizedFileURL.path))
    expect(listed == [inside.standardizedFileURL.path, outside.standardizedFileURL.path], "the library lists opened projects from other folders, not missing ones or non-projects")
    // Thumbnails show the newest export once there is one, else the recording.
    expect(thumbnailVideo(project: inside, source: "screen.mp4").lastPathComponent == "screen.mp4", "a thumbnail shows the recording before any export")
    FileManager.default.createFile(atPath: inside.appendingPathComponent("rec 1920x1080.mp4").path, contents: Data())
    FileManager.default.createFile(atPath: inside.appendingPathComponent("notes.mp4").path, contents: Data())
    expect(thumbnailVideo(project: inside, source: "screen.mp4").lastPathComponent == "rec 1920x1080.mp4", "a thumbnail shows the export, not other videos")
    // New exports go in publish/; older ones loose in the project folder still count.
    let published = exportURL(dir: inside)
    try? FileManager.default.createDirectory(at: published.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: published.path, contents: Data())
    expect(published.deletingLastPathComponent().lastPathComponent == "publish", "exports go in the publish folder")
    expect(Set(exportFiles(project: inside).map(\.lastPathComponent)) == ["rec 1920x1080.mp4", "rec.mp4"], "exports are found in publish/ and the project folder")
    expect(thumbnailVideo(project: inside, source: "screen.mp4").standardizedFileURL == published.standardizedFileURL, "a thumbnail shows the newest export in publish/")
    try? FileManager.default.removeItem(at: libRoot)

    // A thumbnail montage spreads its frames across the video, clear of the ends.
    let montage = montageTimes(duration: 100, count: 4)
    expect(montage.count == 4 && montage.first! > 5 && montage.last! < 95 && zip(montage, montage.dropFirst()).allSatisfy { $0 < $1 }, "montage frames spread across the video")
    expect(montageTimes(duration: 0, count: 4) == [0], "a video without a length gets one frame")

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
    // A portrait overlay floats over the whole frame below the app UI, and doesn't split the frame.
    var floatingHook = hookPlan
    floatingHook.animationList[0].overlay = true
    let floatingAnim = floatingHook.animationList[0]
    expect(floatingHook.animationOutput(floatingAnim) == floatingHook.output, "a portrait overlay renders at the frame's size")
    expect(floatingHook.animationSafeTop(floatingAnim) == Int(SafeArea.rect(floatingHook)!.minY.rounded()), "a portrait overlay keeps clear of the app UI at the top")
    expect(layoutsToOut(floatingHook, mapSegments(floatingHook.segments, fps: 30)).last?.mode != .pip, "a portrait overlay doesn't split the frame")
    // A sticker animation is shown like a meme sticker: its clip is the sticker's width (its height the
    // card's), placed and posed by the sticker code, and it never splits a vertical video either.
    var stickerHook = hookPlan
    stickerHook.animationList[0].sticker = Animation.Sticker(x: 0.25, y: 0.2, w: 0.4)
    let stickerAnim = stickerHook.animationList[0]
    expect(stickerHook.animationOutput(stickerAnim).width == 432 && stickerHook.animationSafeTop(stickerAnim) == 0, "a sticker renders at its width on the frame")
    expect(layoutsToOut(stickerHook, mapSegments(stickerHook.segments, fps: 30)).last?.mode != .pip, "a sticker animation doesn't split the frame")
    var resized = stickerAnim
    resized.sticker?.w = 0.3
    expect(resized.clipPath(out1080, dir: nil) != stickerAnim.clipPath(out1080, dir: nil), "a sticker's width renders a new clip")
    // Where captions sit, for an animation to keep clear of: none in a portrait card, around 64% down over a portrait frame.
    var captioned = floatingHook
    captioned.captions.enabled = true
    let cardBand = captioned.captionBand(hookPlan.animationList[0]), overBand = captioned.captionBand(floatingAnim)
    expect(cardBand == nil && overBand.map { $0.top < 0.64 && $0.bottom > 0.7 } == true, "a portrait overlay keeps clear of the captions, a card animation needn't (\(String(describing: overBand)))")
    captioned.captions.y = 0.3
    expect(captioned.captionBand(floatingAnim).map { $0.top < 0.3 && $0.bottom > 0.3 } == true, "captions dragged up move the band with them")
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
    let clipDir = URL(fileURLWithPath: "/m/Plant Rack Demo")
    expect(exportURL(dir: clipDir).lastPathComponent == "Plant Rack Demo.mp4", "exports are named after the project")
    expect(exportURL(dir: clipDir, preset: ExportPreset.all.first { $0.id == "youtube-4k" }).lastPathComponent == "Plant Rack Demo (4K).mp4",
      "a preset export says its format")
    expect(exportURL(dir: clipDir, clip: Clip(name: "Steps 1/3", start: 0, end: 1)).lastPathComponent == "Plant Rack Demo - Steps 1-3.mp4", "a clip export says its name")
    let tall = Plan.Output(width: 2160, height: 3840, fps: 30)
    expect(exportURL(dir: clipDir, size: tall).lastPathComponent == "Plant Rack Demo 2160x3840.mp4", "an export ends in its resolution")
    expect(exportURL(dir: clipDir, clip: Clip(name: "Hook", start: 0, end: 1), size: Plan.Output(width: 1080, height: 1920,
      fps: 30)).lastPathComponent == "Plant Rack Demo - Hook 1080x1920.mp4", "so does a clip's")
    expect(isExportFile("Plant Rack Demo - Hook.mp4", project: "Plant Rack Demo") && isExportFile("out.mp4", project: "x") && !isExportFile("screen.mp4", project: "x"),
      "exports are recognized, old and new names")
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
    var floatingOver = seam
    floatingOver.inserts = [Insert(start: 2, end: 4, file: "a.mov", placement: "overlay")]
    let os = Scene(plan: floatingOver, words: [], clicks: [], shortcuts: [])
    expect(!os.fullFrameCovers(os.inserts[0].s) && !os.cardCovers(os.inserts[0].s), "an overlay hides neither the screen's marks nor the card")
    expect(!os.cutFrames.contains(os.inserts[0].s), "an overlay appearing isn't a cut")
    // A sticker animation becomes a sticker insert with its place, and pops like a meme sticker.
    let noteDir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-note-\(UUID().uuidString)")
    var notePlan = seam
    notePlan.inserts = nil
    var noteAnim = Animation(start: 2, end: 4, template: "note", data: .object(["big": .string("4")]))
    noteAnim.sticker = Animation.Sticker(x: 0.2, y: 0.25, w: 0.4, rotation: 3)
    notePlan.animations = [noteAnim]
    let noteClip = noteDir.appendingPathComponent(noteAnim.clipPath(in: notePlan, dir: noteDir))
    try? FileManager.default.createDirectory(at: noteClip.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: noteClip.path, contents: Data())
    let noteIns = notePlan.animationInserts(dir: noteDir).first
    expect(noteIns.map { $0.isSticker && $0.x == 0.2 && $0.y == 0.25 && $0.w == 0.4 && $0.rotation == 3 } == true, "a sticker animation plays as a sticker insert in its place")
    let ns = Scene(plan: notePlan, words: [], clicks: [], shortcuts: [], dir: noteDir)
    expect(ns.inserts.first.map { ns.insertPose($0, frame: $0.s).scale < 0.2 && ns.insertPose($0, frame: $0.s + 30).scale > 0.95 } == true,
      "a sticker animation springs on like a meme sticker")
    try? FileManager.default.removeItem(at: noteDir)
    // A fitted overlay leaves the frame around it see-through instead of letterboxing it on black.
    var fitted = floatingOver
    fitted.inserts?[0].fit = "fit"
    let fs2 = Scene(plan: fitted, words: [], clicks: [], shortcuts: [])
    let tallPicture = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 400))
    let fittedFrame = fs2.broll(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: fs2.W, height: fs2.H)), frame: fs2.inserts[0].s,
      full: true, overlay: true, box: Box(x: 0, y: 0, w: 1, h: 1, r: 0, opacity: 1), frames: [0: tallPicture])
    expect(pixel(fittedFrame, x: 2, y: 2)[2] > 0.9, "a fitted overlay doesn't letterbox the video on black")
    // A sticker (a reaction GIF) floats like an overlay, in its own box kept clear of the frame's edges.
    var stuck = seam
    var meme = Insert(start: 2, end: 4, file: "a.mp4", placement: "sticker")
    meme.x = 0.98
    meme.topText = "when the build"
    stuck.inserts = [meme]
    let st = Scene(plan: stuck, words: [], clicks: [], shortcuts: [])
    expect(!st.fullFrameCovers(st.inserts[0].s) && !st.cardCovers(st.inserts[0].s), "a sticker hides neither the screen's marks nor the card")
    let stickerBox = st.stickerRect(meme, imageSize: CGSize(width: 400, height: 400))
    expect(abs(stickerBox.width - st.W * 0.32) < 0.5 && abs(stickerBox.height - stickerBox.width) < 0.5, "a sticker is a third of the frame wide, at the clip's shape")
    expect(st.W - stickerBox.maxX >= st.stickerBorder + st.H * 0.04 - 0.5, "a sticker pushed past the edge stays inside the frame (\(stickerBox))")
    // Over the captions, a sticker moves up out of their way.
    var captionedStuck = stuck
    captionedStuck.captions.enabled = true
    var low = meme
    low.y = 0.9
    let lowBox = Scene(plan: captionedStuck, words: [], clicks: [], shortcuts: []).stickerRect(low, imageSize: CGSize(width: 400, height: 300))
    expect(st.H - lowBox.minY <= st.H * (1 - 150.0 / 1080), "a sticker over the captions moves up clear of them (\(lowBox))")
    let tallSticker = st.stickerRect(meme, imageSize: CGSize(width: 100, height: 1000))
    expect(tallSticker.height <= st.H * 0.8 + 0.5 && abs(tallSticker.width / tallSticker.height - 0.1) < 0.01, "a tall clip is capped at 80% of the frame's height, keeping its shape")
    let text = st.memeText(meme, size: CGSize(width: 400, height: 400))
    expect(text != nil && st.memeText(Insert(start: 0, end: 1, file: "a.mp4"), size: CGSize(width: 400, height: 400)) == nil, "meme text draws only when there is some")
    // A sticker springs on from nothing (past full size) and shrinks back to nothing, even when B-roll cuts by default.
    let stuckIn = st.inserts[0]
    let entering = (0..<14).map { st.insertPose(stuckIn, frame: stuckIn.s + Double($0)).scale }
    expect(entering[0] < 0.1 && entering.max()! > 1.02 && abs(entering[13] - 1) < 0.01, "a sticker grows from nothing and overshoots on its way in (\(entering))")
    expect(st.insertPose(stuckIn, frame: stuckIn.e - 1).scale < 0.2, "a sticker shrinks away on its last frames")
    // Tilted by default: a turned sticker's bounding box is wider than a square one's.
    let square = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
    let tilted = st.sticker(square, meme, pose: .full).extent, flat = { () -> CGRect in
      var level = meme
      level.rotation = 0
      return st.sticker(square, level, pose: .full).extent
    }()
    expect(tilted.width > flat.width + 10, "a sticker is tilted by default and sits square with rotation 0 (\(tilted.width) vs \(flat.width))")
    // The preview's handles: a sticker's box is the one drawn, and moving, sizing and turning write its place.
    var placedPlan = stuck
    let handle = placedPlan.placedItems(dir: nil)
    expect(handle.count == 1 && handle[0].selection == .insert(0) && handle[0].isSticker && handle[0].rotation == Insert.stickerTilt, "a sticker gets handles at its tilt")
    expect(placedPlan.placedItems(dir: nil, at: 3).count == 1 && placedPlan.placedItems(dir: nil, at: 4).isEmpty, "only what's on screen at the playhead gets handles")
    let handleBox = handle[0].box(in: placedPlan, mediaSize: CGSize(width: 400, height: 400))!
    expect(abs(handleBox.center.x - stickerBox.midX) < 0.5 && abs(handleBox.size.width - stickerBox.width - 2 * st.stickerBorder) < 0.5,
      "the handles' box sits on the drawn sticker, border and all (\(handleBox), \(stickerBox))")
    placedPlan.place(handle[0].moved(by: CGSize(width: -st.W / 2, height: 0), from: handleBox, in: placedPlan).sized(by: 1.5, from: handleBox, in: placedPlan))
    let movedMeme = placedPlan.inserts![0]
    expect(abs(movedMeme.x! - (stickerBox.midX / st.W - 0.5)) < 0.001 && movedMeme.w == 0.48, "dragging moves the sticker from where it's drawn, and the corner sizes it (\(movedMeme))")
    expect(handle[0].turned(to: 2, from: handleBox, in: placedPlan).rotation == 0 && handle[0].turned(to: 370, from: handleBox, in: placedPlan).rotation == 10,
      "turning snaps square near 0 and wraps a full turn")
    // An overlay's layer is scaled and turned about its content's center (a Lottie's box), where the renderer draws it.
    var overPlan = seam
    overPlan.inserts = [Insert(start: 2, end: 4, file: "a.png", placement: "overlay")]
    expect(overPlan.inserts![0].overlayTransform(W: st.W, H: st.H) == nil, "an unplaced overlay fills the frame")
    var over = overPlan.placedItems(dir: nil)[0]
    over.content = CGRect(x: 100, y: 100, width: 200, height: 100)
    let overBox = over.box(in: overPlan, mediaSize: nil)!
    let small = over.sized(by: 0.5, from: overBox, in: overPlan)
    let turned = small.turned(to: 30, from: small.box(in: overPlan, mediaSize: nil)!, in: overPlan)
    let turnedBox = turned.box(in: overPlan, mediaSize: nil)!
    expect(hypot(turnedBox.center.x - 200, turnedBox.center.y - 150) < 3 && abs(turnedBox.size.width - 100) < 0.5, "sizing and turning an overlay keep its content in place (\(turnedBox))")
    overPlan.place(turned)
    let drawnCenter = CGPoint(x: 200, y: st.H - 150).applying(overPlan.inserts![0].overlayTransform(W: st.W, H: st.H)!)
    expect(abs(drawnCenter.x - turnedBox.center.x) < 0.5 && abs(st.H - drawnCenter.y - turnedBox.center.y) < 0.5, "the renderer draws the overlay where its handles are (\(drawnCenter))")
    var backToFull = turned
    (backToFull.x, backToFull.y, backToFull.w, backToFull.rotation) = (0.5, 0.5, 1, 0)
    overPlan.place(backToFull)
    expect(overPlan.inserts![0].x == nil && overPlan.inserts![0].rotation == nil, "an overlay put back over the whole frame drops its place")

    // The preview's other handles: annotations follow the zoom, titles move and size, the watermark snaps to a corner.
    var handled = seam
    handled.inserts = nil
    handled.annotations = [Annotation(start: 0, end: 4, kind: "box", x: 0.2, y: 0.2, w: 0.1, h: 0.1)]
    handled.callouts = [Callout(start: 0, end: 4, text: "Hello there")]
    let hs = Scene(plan: handled, words: [], clicks: [], shortcuts: [])
    let markRect = hs.annotationRect(handled.annotations![0], frame: 60)!
    expect(hs.annotation(handled.annotations![0], covering: markRect, frame: 60) == handled.annotations![0], "an annotation's box saves back to the same place")
    var zoomedMark = handled
    zoomedMark.zooms = [Zoom(start: 0, end: 4, x: 0.25, y: 0.25, scale: 2)]
    let zs = Scene(plan: zoomedMark, words: [], clicks: [], shortcuts: [])
    let zoomedRect = zs.annotationRect(handled.annotations![0], frame: 60)!
    expect(abs(zoomedRect.width - 2 * markRect.width) < 1, "an annotation's box follows the zoom (\(markRect.width) → \(zoomedRect.width))")
    let movedMark = zs.annotation(handled.annotations![0], covering: zoomedRect.offsetBy(dx: zoomedRect.width, dy: 0), frame: 60)
    expect(abs(movedMark.x - 0.3) < 0.001 && movedMark.w == 0.1, "dragging a box one width over in a 2x zoom moves it one width on the recording (\(movedMark))")
    let titleBox = hs.calloutRect(handled.callouts[0])!
    expect(abs(titleBox.midX - hs.W / 2) < 0.5, "a title's box starts where its style centers it")
    let wanted = CGRect(x: 100, y: hs.H * 0.6, width: titleBox.width * 1.5, height: titleBox.height * 1.5)
    let placedTitle = hs.callout(handled.callouts[0], covering: wanted)
    expect(placedTitle.size == 1.5 && hs.calloutRect(placedTitle).map { abs($0.midX - wanted.midX) < 1 && abs($0.midY - wanted.midY) < 1 } == true,
      "a dragged and sized title saves where it was dropped (\(placedTitle))")
    let titlePose = hs.placedPose(placedTitle, .full, titleBox)
    expect(abs(titleBox.midX + titlePose.dx * titleBox.width - wanted.midX) < 1 && titlePose.scale == 1.5, "the renderer draws the title where its handle is")
    let markDir = FileManager.default.temporaryDirectory.appendingPathComponent("handles-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: markDir, withIntermediateDirectories: true)
    if let logo = Scene.context(40, 20)?.makeImage(), let dest = CGImageDestinationCreateWithURL(markDir.appendingPathComponent("logo.png") as CFURL, "public.png" as CFString, 1, nil) {
      CGImageDestinationAddImage(dest, logo, nil)
      CGImageDestinationFinalize(dest)
    }
    var logoPlan = handled
    logoPlan.look = Look()
    logoPlan.look?.watermark = Look.Watermark(image: "logo.png", corner: "topLeft")
    let ls = Scene(plan: logoPlan, words: [], clicks: [], shortcuts: [], dir: markDir)
    let logoBox = ls.watermarkRect(frame: 60)!
    let dropped = ls.watermark(covering: CGRect(x: ls.W - 300, y: ls.H - 200, width: logoBox.width * 2, height: logoBox.height * 2))!
    expect(dropped.corner == "bottomRight" && abs(dropped.height! - 2 * logoBox.height / min(ls.W, ls.H)) < 0.002, "the watermark snaps to the corner it's dropped near, at its new size (\(dropped))")
    try? FileManager.default.removeItem(at: markDir)

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
    let openerSteps = Scene.layoutSteps(opener, [OutLayout(startF: 0, endF: 60, mode: .camera), OutLayout(startF: 200, endF: 300, mode: .camera)], frames: 300,
      style: MotionStyle.named(nil))
    expect(openerSteps.at(0) == full && openerSteps.at(299) == full, "full camera from the first frame to the last")
    expect(openerSteps.at(130) != full, "the middle still eases to pip")

    // In portrait, an animation's split starts easing on the animation's first frame (the card never
    // shows the screen first) and takes 1.1 s, not the snappy 0.8 s centered on the cut.
    var portrait = opener
    portrait.output = Plan.Output(width: 1080, height: 1920, fps: 30)
    portrait.defaultLayout = LayoutMode.camera
    portrait.segments = [Segment(start: 0, end: 20, speed: 1)]
    portrait.animations = [Animation(start: 5, end: 10, template: "storyboard", data: .object([:]))]
    let splitSteps = Scene.layoutSteps(portrait, layoutsToOut(portrait, mapPlan(portrait)), frames: 600, style: MotionStyle.named("snappy"))
    let fullBoxes = layoutBoxes(LayoutMode.camera, plan: portrait), pipBoxes = layoutBoxes(LayoutMode.pip, plan: portrait)
    let camVec: [Double] = fullBoxes.screen.vec + fullBoxes.cam.vec
    let splitVec: [Double] = pipBoxes.screen.vec + pipBoxes.cam.vec
    let atStart: [Double] = splitSteps.at(150), partway: [Double] = splitSteps.at(160), settled: [Double] = splitSteps.at(183)
    let beforeEnd: [Double] = splitSteps.at(267), atEnd: [Double] = splitSteps.at(300)
    expect(atStart == camVec, "the face is still full frame on the animation's first frame")
    expect(partway != camVec && partway != splitVec, "a third of a second in, it's on its way")
    expect(settled == splitVec, "and has settled in the split 1.1 s after the animation starts")
    expect(beforeEnd == splitVec, "it holds the split until the animation's last 1.1 s")
    expect(atEnd == camVec, "and is back to full frame as the animation ends")

    // A transition of 0 switches layouts on the edge's frame, with no half-way frame in between.
    var hard = portrait
    hard.animations = []
    hard.style.transition = 0
    let hardSteps = Scene.layoutSteps(hard, [OutLayout(startF: 100, endF: 200, mode: .pip)], frames: 600, style: MotionStyle.named("snappy"))
    expect(hardSteps.at(99) == camVec && hardSteps.at(100) == splitVec, "a 0 transition cuts straight to the split")
    expect(hardSteps.at(199) == splitVec && hardSteps.at(200) == camVec, "and straight back")

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
    // The preview and an export register fonts at once; many threads at once must not crash or lose a result.
    let raceFonts = (0..<64).map { "\(notAFont.path).\($0)" }
    DispatchQueue.concurrentPerform(iterations: 64) { i in Fonts.register([raceFonts[i], raceFonts[(i + 1) % 64]]) }
    var raced = Look()
    raced.fontFiles = raceFonts
    expect(Fonts.problems(raced).count == 64, "fonts registered from many threads at once are each remembered once")
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

    laterChecks()

    fileAndFormatChecks()
    sceneDrawingChecks()
    scribbleChecks()
    packChecks()
    audioChecks()
    stockChecks()
    editorActionChecks()
    recordedBrollChecks()
    reorderChecks()
    planFileChecks()
    planCheckExtraChecks()
    polishChecks()
    retentionChecks()
    faceCoverChecks()
    scanPolishChecks()
    wordCheckChecks()
    claudeEditChecks()
    timelineRowChecks()
    punchInChecks()
    checkEditChecks()
    flashChecks()
    coverChecks()
    inputEventChecks()
    effectChecks()
    safeAreaChecks()
    cameraFormatChecks()
    contactSheetChecks()
    secretChecks()

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
  }
}
