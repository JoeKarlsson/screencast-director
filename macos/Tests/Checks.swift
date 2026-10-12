import Foundation

// Plain-swiftc checks for DirectorCore (Swift Testing and XCTest need Xcode). Run: macos/test.sh

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok {
    failures += 1
    print("FAIL line \(line): \(what)")
  }
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
    let w2 = [Word(text: "one", start: 0, end: 0.5), Word(text: "two", start: 1.5, end: 2), Word(text: "oops", start: 3, end: 3.4),
      Word(text: "three", start: 4, end: 4.5)]
    pp.segments = [Segment(start: 0, end: 2.9, speed: 1), Segment(start: 3.6, end: 5, speed: 1)]
    pp.retrimPauses(words: w2, level: .tight)
    expect(pp.segments.count >= 3 && !pp.segments.contains { $0.start < 1.0 && $0.end > 1.0 }, "tight cuts the 1 s pause")
    expect(!pp.segments.contains { $0.start < 3.2 && $0.end > 3.2 }, "the cut word stays cut")
    pp.retrimPauses(words: w2, level: .gentle)
    expect(pp.segments.contains { $0.start <= 0.5 && $0.end >= 1.5 }, "gentle gives the pause back")
    expect(!pp.segments.contains { $0.start < 3.2 && $0.end > 3.2 }, "and still keeps the word cut")

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
    expect(S3.key(for: URL(fileURLWithPath: "/x/out.MP4"), name: "2026-10-12 Demo: Take #2", date: Date(timeIntervalSince1970: 5)) == "2026-10-12-demo-take-2-5.mp4", "upload key")

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
  }
}
