import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Effects: shader plugins loaded from an effect folder, frozen into the video and drawn per layer.
// Called from Checks.main; run with macos/test.sh.

private func writeEffect(_ folder: URL, _ name: String, layer: String = "frame", tracking: Bool = false, metal: String, params: String = "[]") {
  let dir = folder.appendingPathComponent(name)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try? #"{ "title": "\#(name)", "layer": "\#(layer)", "tracking": \#(tracking), "params": \#(params) }"#.write(
    to: dir.appendingPathComponent("effect.json"), atomically: true, encoding: .utf8)
  try? metal.write(to: dir.appendingPathComponent("effect.metal"), atomically: true, encoding: .utf8)
}

func effectChecks() {
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sd-effects-\(UUID().uuidString)")
  let personal = tmp.appendingPathComponent("Effects"), project = tmp.appendingPathComponent("video")
  try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmp) }
  // Red marks the layer's top-left 10 px square (so orientation shows) and is the param elsewhere;
  // green is seconds since the last click / 10; blue is the clip's speed / 4.
  writeEffect(
    personal, "probe",
    metal: """
      float4 effect(Layer src, float2 pos, Signals s, constant float *p) {
        float r = (pos.x < 10 && pos.y < 10) ? 1.0 : p[0];
        return float4(r, clamp(s.sinceClick / 10.0, 0.0, 1.0), s.speed / 4.0, 1.0);
      }
      """,
    params: #"[{ "name": "level", "default": 0.25, "min": 0, "max": 1 }]"#)
  writeEffect(personal, "broken", metal: "float4 effect(Layer src, float2 pos, Signals s, constant float *p) { return nope; }")
  let sources = EffectSources(project: project, personal: personal)

  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 12, captureStart: nil, camera: nil)
  var plan = buildPlan(Project(dir: project, source: src))
  plan.segments = [Segment(start: 0, end: 12, speed: 2)]
  plan.zooms = []
  plan.clickRipples = false
  plan.shortcutChips = false
  plan.captions.enabled = false
  let fps = Double(plan.output.fps), W = Double(plan.output.width), H = Double(plan.output.height)

  do {
    let loaded = try Effects.load([EffectUse(name: "probe", params: ["level": 0.75])], sources: sources)
    expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("effects/probe/effect.metal").path), "a used effect is frozen into the video")
    // A click at source 1 s plays at output 0.5 s (2x); frame at output 1.5 s is 1 s after it.
    let click = InputEvent(t: 1, type: .click, x: 0.5, y: 0.5, label: nil)
    let scene = Scene(plan: plan, words: [], clicks: [click], shortcuts: [], dir: project, effects: loaded)
    let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let frame = scene.render(frame: Int(1.5 * fps), screen: screen, camera: nil)
    let corner = pixel(frame, x: 2, y: H - 3), middle = pixel(frame, x: W / 2, y: H / 2), bottomLeft = pixel(frame, x: 2, y: 2)
    expect(corner[0] > 0.97, "pos starts at the layer's top-left corner (\(corner))")
    expect(abs(bottomLeft[0] - 0.75) < 0.03, "the bottom-left isn't the marked corner, and a plan param overrides the default (\(bottomLeft))")
    expect(abs(middle[1] - 0.1) < 0.03, "sinceClick counts output seconds since the click (\(middle))")
    expect(abs(middle[2] - 0.5) < 0.03, "speed is the clip's playback speed (\(middle))")
  } catch {
    expect(false, "the probe effect loads: \(error.localizedDescription)")
  }

  // toCut counts any visible change, not just cuts between clips: here a layout change at source 3 s
  // in a video with one clip (red is toCut / 10, green is cutTime / 10, blue is whether cutIndex is 0).
  writeEffect(personal, "cutprobe", metal: "float4 effect(Layer src, float2 pos, Signals s, constant float *p) { return float4(clamp(s.toCut / 10.0, 0.0, 1.0), clamp(s.cutTime / 10.0, 0.0, 1.0), s.cutIndex == 0.0 ? 1.0 : 0.0, 1); }")
  do {
    var single = plan
    single.segments = [Segment(start: 0, end: 12, speed: 1)]
    single.layouts = [LayoutRange(start: 3, end: 6, mode: .screen)]
    let loaded = try Effects.load([EffectUse(name: "cutprobe")], sources: sources)
    let scene = Scene(plan: single, words: [], clicks: [], shortcuts: [], dir: project, effects: loaded)
    let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let probe = pixel(scene.render(frame: Int(2 * fps), screen: screen, camera: nil), x: W / 2, y: H / 2)
    expect(abs(probe[0] - 0.1) < 0.03, "toCut counts a layout change as a cut (\(probe))")
    expect(abs(probe[1] - 0.3) < 0.03, "cutTime is when that nearest change happens (\(probe))")
    expect(probe[2] > 0.97, "cutIndex counts the first change as 0 (\(probe))")
  } catch {
    expect(false, "the cutprobe effect loads: \(error.localizedDescription)")
  }

  // cutKind names what each change is: back from a cold open is a jump back, a chapter title a new
  // section (red is cutKind / 10, read just before the title, which dims the frame under it).
  writeEffect(personal, "kindprobe", metal: "float4 effect(Layer src, float2 pos, Signals s, constant float *p) { return float4(clamp(s.cutKind / 10.0, 0.0, 1.0), 0, 0, 1); }")
  do {
    var cold = plan
    cold.segments = [Segment(start: 6, end: 12, speed: 1), Segment(start: 0, end: 6, speed: 1)]
    cold.callouts = [Callout(start: 9, end: 10, text: "Part two", style: "chapter")]
    let loaded = try Effects.load([EffectUse(name: "kindprobe")], sources: sources)
    let scene = Scene(plan: cold, words: [], clicks: [], shortcuts: [], dir: project, effects: loaded)
    let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    func kind(_ seconds: Double) -> Double { pixel(scene.render(frame: Int(seconds * fps), screen: screen, camera: nil), x: W - 40, y: 40)[0] * 10 }
    expect(abs(kind(6.1) - 1) < 0.2, "playing an earlier moment after a cold open is a jump back (\(kind(6.1)))")
    expect(abs(kind(2.9) - 5) < 0.2, "a chapter title starts a new section (\(kind(2.9)))")
  } catch {
    expect(false, "the kindprobe effect loads: \(error.localizedDescription)")
  }

  func failure(_ uses: [EffectUse]) -> String {
    do {
      _ = try Effects.load(uses, sources: sources)
      return ""
    } catch { return error.localizedDescription }
  }
  expect(failure([EffectUse(name: "missing")]).contains("\"missing\" isn't in"), "a missing effect fails, naming it")
  expect(failure([EffectUse(name: "../probe")]).contains("can only use"), "an effect name can't climb out of the effects folder")
  expect(failure([EffectUse(name: "probe", params: ["nope": 1])]).contains("no param \"nope\""), "an unknown param fails")
  expect(failure([EffectUse(name: "probe", layer: "sky")]).contains("layer \"sky\""), "an unknown layer fails")
  expect(failure([EffectUse(name: "broken")]).contains("\"broken\" doesn't compile"), "a shader that doesn't compile fails, naming the effect")

  // Tracking: blobs reach only effects that ask. On the screen they're the pointer (red is the first
  // blob's x / the layer's width, green its id / 200, blue how many there are / 4).
  writeEffect(personal, "blobprobe", layer: "screen", tracking: true,
    metal: "float4 effect(Layer src, float2 pos, Signals s, constant float *p) { return s.blobs > 0 ? float4(src.blobs[0].x / s.size.x, src.blobs[0].w / 200, s.blobs / 4, 1) : float4(0, 0, 0, 1); }")
  do {
    var still = plan
    still.segments = [Segment(start: 0, end: 12, speed: 1)]
    let pointer = (0..<40).map { InputEvent(t: Double($0) * 0.25, type: .move, x: 0.25, y: 0.5) }
    let loaded = try Effects.load([EffectUse(name: "blobprobe")], sources: sources)
    let scene = Scene(plan: still, words: [], clicks: [], shortcuts: [], cursorPath: pointer, dir: project, effects: loaded)
    let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let probe = pixel(scene.render(frame: Int(3 * fps), screen: screen, camera: nil), x: W / 2, y: H / 2)
    expect(abs(probe[0] - 0.25) < 0.03 && abs(probe[1] - 0.5) < 0.03 && abs(probe[2] - 0.25) < 0.03,
      "a tracking effect on the screen gets one blob, the pointer, at its pixel (\(probe))")
  } catch {
    expect(false, "the blobprobe effect loads: \(error.localizedDescription)")
  }
  // An effect range draws only inside its stretch (the probe paints red with its param).
  do {
    var ranged = plan
    ranged.segments = [Segment(start: 0, end: 12, speed: 1)]
    ranged.effectRanges = [EffectRange(start: 4, end: 6, name: "probe", params: ["level": 1])]
    let loaded = try Effects.load(ranged.effectRangeList.map(\.use), sources: sources)
    let scene = Scene(plan: ranged, words: [], clicks: [], shortcuts: [], dir: project, rangeEffects: loaded)
    let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let inside = pixel(scene.render(frame: Int(5 * fps), screen: screen, camera: nil), x: W / 2, y: H / 2)
    let before = pixel(scene.render(frame: Int(3 * fps), screen: screen, camera: nil), x: W / 2, y: H / 2)
    let after = pixel(scene.render(frame: Int(7 * fps), screen: screen, camera: nil), x: W / 2, y: H / 2)
    expect(inside[0] > 0.97 && before[0] < 0.9 && after[0] < 0.9, "an effect range draws only from its start to its end (\(before) \(inside) \(after))")
  } catch {
    expect(false, "the ranged probe loads: \(error.localizedDescription)")
  }
  // Camera tracking moves each point between samples, shows a point seen in only one sample for half
  // a step, and survives tracking.json.
  let tracking = Tracking(samples: [
    .init(t: 1, points: [.init(id: 0, x: 0.2, y: 0.4, size: 0.05), .init(id: 6, x: 0.3, y: 0.7, size: 0.05)]),
    .init(t: 1.1, points: [.init(id: 0, x: 0.4, y: 0.4, size: 0.07)]),
  ])
  let mid = tracking.points(at: 1.05)
  expect(mid.count == 1 && abs(mid[0].x - 0.3) < 1e-9 && abs(mid[0].size - 0.06) < 1e-9, "a tracked point moves linearly between samples (\(mid))")
  expect(tracking.points(at: 1.02).count == 2, "a point missing from the next sample holds for half a step")
  expect(tracking.points(at: 3).isEmpty, "no points long after the last sample")
  let saved = tmp.appendingPathComponent(Tracking.fileName)
  try? Tracking.write(tracking, video: "camera.mp4", to: saved)
  let readBack = Result { try Tracking.read(saved, video: "camera.mp4") }
  let same = (try? readBack.get()).flatMap { $0 }.map { back in
    back.samples.count == tracking.samples.count
      && zip(back.samples, tracking.samples).allSatisfy { a, b in
        abs(a.t - b.t) < 1e-4 && a.points.count == b.points.count
          && zip(a.points, b.points).allSatisfy { $0.id == $1.id && abs($0.x - $1.x) < 1e-4 && abs($0.y - $1.y) < 1e-4 && abs($0.size - $1.size) < 1e-4 }
      }
  }
  expect(same == true, "tracking.json reads back the same, to 4 decimals (\(readBack))")
  expect((try? Tracking.read(saved, video: "other.mp4")) == .some(nil), "tracking.json for another camera file is found again")

  // The frozen copy wins over a later library change.
  writeEffect(personal, "probe", metal: "float4 effect(Layer src, float2 pos, Signals s, constant float *p) { return float4(0,0,0,1); }")
  let frozen = (try? String(contentsOf: project.appendingPathComponent("effects/probe/effect.metal"), encoding: .utf8)) ?? ""
  _ = try? Effects.load([EffectUse(name: "probe")], sources: sources)
  expect(frozen.contains("sinceClick") && frozen == (try? String(contentsOf: project.appendingPathComponent("effects/probe/effect.metal"), encoding: .utf8)),
    "changing the library doesn't change a video's frozen effect")

  // describe lists the effects and flags one that isn't anywhere.
  var described = plan
  described.effects = [EffectUse(name: "probe", params: ["level": 0.5]), EffectUse(name: "gone")]
  let text = describe(Project(dir: project, source: src), described)
  expect(text.contains("## Effects") && text.contains("probe") && text.contains("level=0.5"), "describe lists effects with their params")
  expect(text.split(separator: "\n").contains { $0.contains("gone") && $0.contains("MISSING") }, "describe flags a missing effect")

  // B-roll with no motion of its own takes the style's: here an interlace wipe, half done a quarter
  // of the way in, shows the red B-roll on alternate bands at the left and nothing at the right.
  let red = tmp.appendingPathComponent("red.png")
  let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
  let dest = CGImageDestinationCreateWithURL(red as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
  var wiped = plan
  wiped.segments = [Segment(start: 0, end: 12, speed: 1)]
  wiped.inserts = [Insert(start: 2, end: 6, file: red.path, placement: "full")]
  wiped.style.brollMotion = Motion(preset: "interlace", seconds: 1)
  let wipeScene = Scene(plan: wiped, words: [], clicks: [], shortcuts: [])
  let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
  let quarter = wipeScene.render(frame: Int(2.25 * fps), screen: gray, camera: nil)
  let band = max(2, (4 * min(W, H) / 1080).rounded())
  let rows = (0..<4).map { pixel(quarter, x: W * 0.2, y: H / 2 + Double($0) * band)[0] > 0.9 }
  expect(rows.contains(true) && rows.contains(false), "a quarter in, alternate bands at the left show the B-roll (\(rows))")
  expect((0..<4).allSatisfy { pixel(quarter, x: W * 0.8, y: H / 2 + Double($0) * band)[0] < 0.9 }, "a quarter in, the right side doesn't show it yet")
  expect(pixel(wipeScene.render(frame: Int(4 * fps), screen: gray, camera: nil), x: W * 0.8, y: H / 2)[0] > 0.9, "once in, the B-roll shows everywhere")
  var brollProfile = Profile(name: "Wipes", style: wiped.style, look: Look())
  brollProfile.style.brollMotion = Motion(preset: "interlace", seconds: 0.25)
  var withWipes = plan
  brollProfile.apply(to: &withWipes)
  expect(withWipes.style.brollMotion?.preset == "interlace", "a profile sets how B-roll comes and goes")
  expect(plan.brollDefaultMotion.preset == "none" && withWipes.brollDefaultMotion.preset == "interlace",
    "B-roll without its own motion cuts unless the style sets one (the inspector shows the same default)")
  let cutIn = Scene(plan: { var p = wiped; p.style.brollMotion = nil; return p }(), words: [], clicks: [], shortcuts: [])
  expect(pixel(cutIn.render(frame: Int(2.05 * fps), screen: gray, camera: nil), x: W * 0.8, y: H / 2)[0] > 0.9, "default B-roll is fully in on its first frames")

  // Intro and outro cards take the frame's effects (the probe paints the top-left corner red).
  do {
    var carded = plan
    carded.segments = [Segment(start: 0, end: 12, speed: 1)]
    carded.intro = Card(title: "Hello")
    let loaded = try Effects.load([EffectUse(name: "probe")], sources: sources)
    let scene = Scene(plan: carded, words: [], clicks: [], shortcuts: [], dir: project, effects: loaded)
    let screen = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    expect(pixel(scene.render(frame: 2, screen: screen, camera: nil), x: 2, y: H - 3)[0] > 0.97, "the intro card takes the frame's effects")
  } catch {
    expect(false, "the probe effect loads for the card: \(error.localizedDescription)")
  }

  // A profile's effects go into the plan it's applied to.
  var profile = Profile(name: "Glitch", style: plan.style, look: Look())
  profile.effects = [EffectUse(name: "analog")]
  var applied = plan
  profile.apply(to: &applied)
  expect(applied.effects == [EffectUse(name: "analog")], "applying a profile sets its effects")
}
