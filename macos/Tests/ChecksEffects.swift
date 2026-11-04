import CoreImage
import Foundation

// Effects: shader plugins loaded from an effect folder, frozen into the video and drawn per layer.
// Called from Checks.main; run with macos/test.sh.

private func writeEffect(_ folder: URL, _ name: String, layer: String = "frame", metal: String, params: String = "[]") {
  let dir = folder.appendingPathComponent(name)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try? #"{ "title": "\#(name)", "layer": "\#(layer)", "params": \#(params) }"#.write(
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

  // A profile's effects go into the plan it's applied to.
  var profile = Profile(name: "Glitch", style: plan.style, look: Look())
  profile.effects = [EffectUse(name: "analog")]
  var applied = plan
  profile.apply(to: &applied)
  expect(applied.effects == [EffectUse(name: "analog")], "applying a profile sets its effects")
}
