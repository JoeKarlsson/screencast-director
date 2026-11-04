import CoreImage
import Foundation
import JavaScriptCore

// Checks moved out of Checks.main: the timeline zoom, editor keys, AI ask outcomes, logos and
// animation scripts in JavaScriptCore, and voice leveling. Called from Checks.main; run with macos/test.sh.

func laterChecks() {
  let fps = 30
  let templateDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Resources/animations/templates")
  let templates = AnimationTemplate.all(in: templateDir)
  // A video folder with no animations of its own, so only the library's and the app's logos count.
  let lib = FileManager.default.temporaryDirectory.appendingPathComponent("sd-later-\(UUID().uuidString)")
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
  expect(srcMarks == [SpeechMark(x: 2, width: 2, kept: true), SpeechMark(x: 12, width: 1, kept: false), SpeechMark(x: 18, width: 2, kept: true)],
    "source-axis speech marks (\(srcMarks))")
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
  let bundledLogos = (try? AnimationSources(project: lib, builtIn: templateDir.deletingLastPathComponent()).logos()) ?? [:]
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
  expect(templateScripts.evaluateScript("stageTransform(1080, 1920)").toString() == "translate(0px, 656.25px) scale(0.5625)",
    "a vertical clip fits the stage evenly and centers it instead of stretching it")
  expect(templateScripts.evaluateScript("JSON.stringify(stageSize(1000, 1000, true))").toString() == #"{"w":1350,"h":1350,"reflow":true}"#,
    "a template that reflows gets a square board for a square card")
  expect(templateScripts.evaluateScript("JSON.stringify(stageSize(1000, 1000, false))").toString() == #"{"w":1920,"h":1080,"reflow":false}"#,
    "one that doesn't keeps the 16:9 board")
  expect(templateScripts.evaluateScript("JSON.stringify(stageSize(1920, 1080, true))").toString() == #"{"w":1920,"h":1080,"reflow":false}"#,
    "16:9 always gets the classic board")
  expect(templateScripts.evaluateScript("TEMPLATES.storyboard.reflows").toBool(), "the storyboard lays itself out on any board")
  // The terminal theme routes lines at right angles and holds them still; its entrances flicker on, no bounce.
  let route = templateScripts.evaluateScript(#"THEME = "terminal"; handCurve([0, 0], [100, 50], 0.3, 1).d"#).toString() ?? ""
  expect(route.range(of: #"^M0,0 L(4[89]|5[012]),0 L\1,50 L100,50$"#, options: .regularExpression) != nil,
    "terminal lines run across, down, across, the bend jittering a little (\(route))")
  let halfway = templateScripts.evaluateScript("handCurve([0, 0], [100, 50], 0, 1).at(0.5)[1]").toDouble()
  expect(abs(halfway - 25) < 3, "a terminal line's midpoint is about halfway along its route (\(halfway))")
  expect(templateScripts.evaluateScript("[popScale(1.04, 1), popScale(1.06, 1), popScale(1.5, 1)].join()").toString() == "1,0,1",
    "terminal entrances flicker, then hold at full size")
  templateScripts.evaluateScript(#"THEME = """#)
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
}
