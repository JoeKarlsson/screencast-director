import CoreImage
import Foundation

// The Pink Scribble look: crayon marks from joekarlsson.com drawn natively, the halftone room and
// big type chapters. Called from Checks.main; run with macos/test.sh.

func scribbleChecks() {
  // Paths: one polyline per M, curves flattened, pairs after an M read as lines.
  let parsed = Scribble.parse("M0,0 L10,0 Q20,0 20,10 M5,5 6,6")
  expect(parsed.count == 2 && parsed[0].count == 14 && parsed[1].count == 2, "a path splits into its strokes, curves flattened (\(parsed.map(\.count)))")
  expect(parsed[0].last == CGPoint(x: 20, y: 10), "a curve ends on its end point")
  expect(Scribble.parse("M1,-2 L-3,4")[0] == [CGPoint(x: 1, y: -2), CGPoint(x: -3, y: 4)], "negative numbers parse, with or without a comma before them")
  expect(!Scribble.coil.strokes.isEmpty && !Scribble.rays.strokes.isEmpty, "the site's coil and rays parse")
  let coilXs = Scribble.coil.strokes.flatMap { $0 }.map(\.x)
  expect((coilXs.min() ?? -1) >= 0 && (coilXs.max() ?? 1e9) <= 900, "the coil stays in its 900-wide box")

  // Drawing in and erasing trim a stroke by length.
  let line = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
  let half = Scribble.trimmed(line, from: 0, to: 0.5)
  expect(half.first == CGPoint(x: 0, y: 0) && half.last == CGPoint(x: 10, y: 0), "half a stroke ends halfway along it (\(half))")
  let erased = Scribble.trimmed(line, from: 0.75, to: 1)
  expect(erased.first == CGPoint(x: 10, y: 5) && erased.last == CGPoint(x: 10, y: 10), "erasing takes the stroke from its start (\(erased))")
  expect(Scribble.trimmed(line, from: 0, to: 0).isEmpty, "nothing drawn is nothing")
  let three = Scribble(size: CGSize(width: 10, height: 10), path: "M0,0 L1,1 M2,2 L3,3 M4,4 L5,5")
  expect(three.shares(0.5).map(\.to) == [1, 0.5, 0], "strokes draw one after another, like one pen")

  // The halftone: a bright picture comes out as ink dots on black, a black one stays black.
  let ink = "#FF4FD8"
  let bright = Scene.halftone(CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), cell: 8, ink: ink)
  let samples = (0..<64).map { pixel(bright, x: Double($0 % 8) * 8 + 3, y: Double($0 / 8) * 8 + 2) }
  let reddest = samples.max { $0[0] < $1[0] } ?? [0, 0, 0]
  expect(reddest[0] > 0.9 && abs(reddest[2] / max(0.01, reddest[0]) - 0.847) < 0.08, "bright tones become ink-colored dots (\(reddest))")
  expect(samples.contains { $0[0] < reddest[0] * 0.8 }, "with gaps between them, not a flat fill")
  let dark = Scene.halftone(CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)), cell: 8, ink: ink)
  expect(pixel(dark, x: 30, y: 30).allSatisfy { $0 < 0.02 }, "black stays black")

  // A profile carries the room and the outline to the video's camera.
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 12, captureStart: nil, camera: nil)
  var withCamera = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp"), source: src))
  var profile = Profile(name: "Scribble", style: withCamera.style, look: Look())
  profile.camera = Profile.CameraDefaults()
  profile.camera?.room = "halftone"
  profile.camera?.outline = true
  withCamera.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  profile.apply(to: &withCamera)
  expect(withCamera.camera?.room == "halftone" && withCamera.camera?.outline == true, "a profile sets the halftone room and the outline")

  // Big type chapters: the black block rises over the bottom of the frame for the chapter, and
  // captions move above it.
  var plan = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp"), source: src))
  plan.segments = [Segment(start: 0, end: 12, speed: 1)]
  plan.zooms = []
  plan.clickRipples = false
  plan.shortcutChips = false
  var look = Look()
  look.chapterStyle = "big"
  plan.look = look
  plan.callouts = [Callout(start: 1, end: 4, text: "Jailbreak it", style: "chapter", subtitle: "Step 1")]
  let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
  let scene = Scene(plan: plan, words: [], clicks: [], shortcuts: [])
  let H = Double(plan.output.height), W = Double(plan.output.width)
  let during = scene.render(frame: 75, screen: screen, camera: nil), before = scene.render(frame: 15, screen: screen, camera: nil)
  // Bottom-right corner, low in the block: clear of the words and marks (pixel() counts y from the bottom).
  expect(pixel(during, x: W * 0.97, y: H * 0.03).allSatisfy { $0 < 0.03 }, "the block is black over the bottom of the frame (\(pixel(during, x: W * 0.97, y: H * 0.03)))")
  expect(pixel(before, x: W * 0.97, y: H * 0.03).reduce(0, +) > 0.3, "before the chapter the frame shows there, not the block")
  let top = scene.bigChapterTop(at: 75, camBox: nil) ?? 0
  expect(top > H * 0.65 && top < H * 0.85, "the block is only as tall as its words, not a third of the frame (\(top))")
  expect(scene.bigChapterTop(at: 15, camBox: nil) == nil, "no block outside the chapter")
  let rising = scene.bigChapterTop(at: 33, camBox: nil) ?? 0
  expect(rising > top && rising < H, "it rises at the start (\(rising))")
  // Portrait split: the camera is a band across the bottom, and the block stands on its top edge,
  // off the face.
  let band = Box(x: 0, y: H * 0.56, w: W, h: H * 0.44, r: 0, opacity: 1)
  let ch = scene.bigChapter(at: 75)!
  expect(scene.bigChapterLayout(ch, camBox: band).block.maxY == H * 0.56, "over a camera band, the block stands on the camera's top edge")
  let side = Box(x: W * 0.6, y: H * 0.05, w: W * 0.35, h: H * 0.9, r: 0, opacity: 1)
  expect(scene.bigChapterLayout(ch, camBox: side).block.maxY == H, "beside a side camera, it stands on the frame's bottom")
  let (long, longSize) = scene.bigChapterWords("LanguageBreak", maxWidth: W * 0.9, maxHeight: H * 0.26, size: H * 0.4)
  let oneLine = Scene.measure(long, maxWidth: .greatestFiniteMagnitude)
  expect(oneLine.width <= W * 0.9 && abs(longSize.height - oneLine.height) < 1, "a long word shrinks to fit on one line instead of wrapping mid-word (\(oneLine), \(longSize))")
  var chip = plan
  chip.look?.chapterStyle = nil
  expect(Scene(plan: chip, words: [], clicks: [], shortcuts: []).bigChapterTop(at: 75, camBox: nil) == nil, "the usual chapter style has no block")
}
