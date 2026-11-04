import Foundation

// plan.json loading: fields missing from an older plan or one written by hand take defaults instead
// of failing to load, and saving writes the same JSON back. Called from Checks.main; run with macos/test.sh.

func planFileChecks() {
  let src = Project.Source(video: "screen.mp4", width: 1920, height: 1080, duration: 30, captureStart: nil, camera: nil)
  var plan = buildPlan(Project(dir: URL(fileURLWithPath: "/tmp/sd-plan-file"), source: src))
  plan.callouts = [Callout(start: 2, end: 3, text: "Hi")]
  plan.captions.style = "bold"
  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys]
  guard let data = try? enc.encode(plan), let full = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
    expect(false, "a plan encodes to a JSON object")
    return
  }
  let roundTrip = try? JSONDecoder().decode(Plan.self, from: data)
  expect(roundTrip == plan, "a plan round-trips through JSON")
  expect(roundTrip.flatMap { try? enc.encode($0) } == data, "defaulted fields encode as plain values, so the file doesn't change")

  // Every field but the recording, the output size and the clips may be missing.
  let required: Set<String> = ["source", "output", "segments"]
  for key in full.keys.sorted() where !required.contains(key) {
    var partial = full
    partial.removeValue(forKey: key)
    let decoded = (try? JSONSerialization.data(withJSONObject: partial)).flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
    expect(decoded != nil, "a plan without \"\(key)\" still loads")
  }
  for key in required {
    var partial = full
    partial.removeValue(forKey: key)
    let decoded = (try? JSONSerialization.data(withJSONObject: partial)).flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
    expect(decoded == nil, "a plan without \"\(key)\" doesn't load")
  }

  // The defaults: a plan from before `version` plays in recording order; the rest match a new plan.
  let bare: [String: Any] = ["source": full["source"]!, "output": full["output"]!, "segments": full["segments"]!, "captions": [:] as [String: Any]]
  let minimal = (try? JSONSerialization.data(withJSONObject: bare)).flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
  expect(minimal?.version == 1, "a plan with no version is a version 1 plan (recording order)")
  expect(minimal?.style == .standard && minimal?.clickRipples == true && minimal?.shortcutChips == true, "missing style and overlays get the built-in defaults")
  expect(minimal?.captions.enabled == false && minimal?.captions.maxWords == 7, "an empty captions object is off, 7 words a page")
  expect(minimal?.zooms == [] && minimal?.layouts == [] && minimal?.callouts == [] && minimal?.defaultLayout == .screen, "missing lists are empty")

  // Bold and social captions share their big-word rules (Scene, the overlay drawing and the inspector).
  var caps = Plan.Captions(enabled: true, maxWords: 7)
  expect(!caps.isBold, "pill captions aren't bold")
  caps.style = "social"
  expect(caps.isBold, "social captions are bold")

  // Save as Profile keeps the effects and layout, and music, voice and camera only when asked.
  var branded = plan
  branded.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  branded.camera?.bubbleShape = "rounded"
  branded.defaultLayout = .side
  branded.effects = [EffectUse(name: "analog", params: ["bloom": 2])]
  branded.music = Music(file: "/tmp/track.m4a", volumeDB: -20)
  branded.audio = AudioSettings(normalize: true, warm: true)
  let lean = Profile.saved(from: branded, name: "Lean", extras: [])
  expect(lean.effects == branded.effects && lean.defaultLayout == .side, "a saved profile keeps the effects and the default layout")
  expect(lean.music == nil && lean.audio == nil && lean.camera == nil, "music, voice and camera stay out unless asked for")
  let fullProfile = Profile.saved(from: branded, name: "Full", extras: Set(Profile.Extra.allCases))
  var fresh = plan
  fresh.camera = Plan.Camera(video: "camera.mp4", offset: 0)
  fullProfile.apply(to: &fresh)
  expect(fresh.music == branded.music && fresh.audio?.warm == true && fresh.camera?.bubbleShape == "rounded" && fresh.effects == branded.effects,
    "applying a full profile brings back its music, voice, camera and effects")
  expect(Profile.saved(from: plan, name: "Screen", extras: []).defaultLayout == nil, "a screen-only video's profile sets no layout")
}
