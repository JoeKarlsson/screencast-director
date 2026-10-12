import Foundation

// Plain-swiftc checks for DirectorCore (Swift Testing and XCTest need Xcode). Run: macos/test.sh
// Mirrors test/timeline.test.ts so the Swift and TypeScript ports stay in step.

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

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
  }
}
