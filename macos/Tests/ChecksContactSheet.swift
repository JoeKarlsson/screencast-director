import Foundation

// Animation motion blur timing (Animation.subframeTimes, subframeCount) and the contact sheet's beats
// (ContactSheet.beats). Called from Checks.main; run with macos/test.sh.

func contactSheetChecks() {
  // Subframes stay inside their frame, so stepped boil, grain and shake (6, 3 and 12 steps a
  // second) never mix two steps in one blurred frame, and never pass the clip's end.
  var mixed: [Int] = []
  for f in 0..<240 {
    let times = Animation.subframeTimes(frame: f, fps: 12, duration: 20, count: Animation.maxSubframes)
    for steps in [12.0, 6, 3] where Set(times.map { Int(($0 * steps).rounded(.down)) }) != [Int((Double(f) * steps / 12).rounded(.down))] {
      mixed.append(f)
    }
  }
  expect(mixed.isEmpty, "every subframe lands on its own frame's boil, grain and shake step (mixed at frames \(Array(Set(mixed)).sorted().prefix(5)))")
  let lastTimes = Animation.subframeTimes(frame: 23, fps: 12, duration: 23.0 / 12 + 0.001, count: 4)
  expect(lastTimes.count == 4 && lastTimes.allSatisfy { $0 <= 23.0 / 12 + 0.001 }, "the last frame's subframes stop at the clip's end (\(lastTimes))")
  // Still or slowly drifting frames take one snapshot; moving ones enough to keep copies 6 px apart, up to ten.
  expect(Animation.subframeCount(motion: 0.3) == 1 && Animation.subframeCount(motion: 5) == 1, "a still or slowly drifting frame takes one snapshot")
  expect(Animation.subframeCount(motion: 12) == 3, "12 px of movement takes three (\(Animation.subframeCount(motion: 12)))")
  expect(Animation.subframeCount(motion: 500) == Animation.maxSubframes && Animation.subframeCount(motion: .infinity) == Animation.maxSubframes,
    "a fast pop-in, or elements coming and going, takes the most")

  // Beats: the first and last frames, after a cut, after a zoom lands, after each animation cue,
  // nothing for an item that's cut, and beats close together share one frame.
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 60, captureStart: nil, camera: nil)
  var plan = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp/sd-sheet"), source: src))
  plan.intro = nil
  plan.outro = nil
  plan.layouts = []
  plan.callouts = []
  plan.segments = [Segment(start: 0, end: 10, speed: 1), Segment(start: 20, end: 40, speed: 1)]
  plan.zooms = [Zoom(start: 4, end: 8, x: 0.5, y: 0.5, scale: 2), Zoom(start: 12, end: 15, x: 0.5, y: 0.5, scale: 2)]
  plan.animations = [Animation(start: 25, end: 32, template: "storyboard", data: .object([:]), cues: ["s1": 26, "s2": 26.1])]
  let beats = ContactSheet.beats(plan)
  let fps = plan.output.fps
  func at(_ out: Double) -> Int { Int((out * Double(fps)).rounded()) }
  expect(beats.first == ContactSheet.Beat(frame: 0, label: "start"), "the sheet opens on the first frame (\(beats.prefix(1)))")
  expect(beats.last == ContactSheet.Beat(frame: at(30) - 1, label: "end"), "and ends on the last (\(beats.suffix(1)))")
  expect(beats.contains(ContactSheet.Beat(frame: at(4.5), label: "zoom")), "a zoom is looked at once it lands (\(beats))")
  expect(beats.contains(ContactSheet.Beat(frame: at(10.5), label: "cut")), "half a second after the cut")
  expect(!beats.contains { $0.label.contains("zoom") && $0.frame > at(10) }, "a zoom in a cut stretch gets no beat")
  expect(beats.contains(ContactSheet.Beat(frame: at(15.5), label: "storyboard")), "an animation gets a beat as it starts")
  expect(beats.contains { $0.frame == at(16.4) && $0.label == "storyboard s1, storyboard s2" }, "two cues a tenth apart share a frame (\(beats))")
}
