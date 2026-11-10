import AVFoundation
import Foundation

// `director review`'s polish notes: what makes an edit feel template-made rather than produced,
// measured from the plan. The camera notes walk the camera path the renderer draws, frame by frame;
// the rest read the plan's items. None of these stops a build (validate's job), they're judgment calls.

/// One polish note: what's off, where (output seconds), and what to do about it.
public struct PolishNote: Equatable, Sendable {
  public var kind: String
  public var outSeconds: Double
  public var text: String
}

public enum Polish {
  /// The camera counts as moving above these (per second): 1% of a screen, or 1/100 of an octave.
  static let stillPan = 0.01
  static let stillZoom = 0.01
  /// Settle the camera this long before a click and hold it this long after: the viewer's eye
  /// lands on the control, sees the press, then sees what changed.
  public static let settleBeforeClick = 0.15
  public static let holdAfterClick = 0.3
  /// A move faster than this many times a standard one in the video's own motion style reads as a
  /// whip: standard is a 1x-2x zoom (one octave) or a pan of `standardPan` screens (visible widths)
  /// over `style.transition` on the style's ease, measured at the ease's peak speed. In the smooth
  /// style at 0.8 s, that limits a pan to about 3.5 screens/s and a zoom to about 5.9 octaves/s.
  public static let fasterThanStandard = 1.5
  public static let standardPan = 0.6
  /// A camera that stops for less than this between two moves reads as a stutter.
  public static let stutterGap = 0.3
  /// Reading time for on-screen text: at least this, and a third of a second a word plus half a second.
  public static let minReadSeconds = 1.5
  /// More sounds than this in any 10 s of output reads as busy (top channels use under one).
  public static let maxSoundsPer10s = 3
  /// Hard cuts are the norm (over 90% of cuts in measured pro edits): more than this share with a
  /// styled transition reads as a template.
  public static let maxTransitionShare = 0.25

  /// Every polish note for a plan, in output order. `cameraFPS` is the camera file's frame rate
  /// (`cameraFrameRate`), when known.
  public static func notes(_ project: Project, _ plan: Plan, cameraFPS: Double? = nil) -> [PolishNote] {
    let scene = Scene(plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts)
    return (frameRate(plan, cameraFPS: cameraFPS) + camera(scene, plan) + reading(scene, plan) + transitions(scene, plan) + sounds(scene, plan)
      + together(scene, plan)).sorted { $0.outSeconds < $1.outSeconds }
  }

  /// The camera recording's frame rate, or nil without a camera (or a file that won't open).
  public static func cameraFrameRate(_ project: Project, _ plan: Plan) async -> Double? {
    guard let video = plan.camera?.video, let url = Scene.fileURL(video, dir: project.dir),
      let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
      let rate = try? await track.load(.nominalFrameRate), rate > 0
    else { return nil }
    return Double(rate)
  }

  /// A camera frame rate that doesn't divide into the output's (25 into 30) repeats or drops frames
  /// unevenly, which judders on a face: `director scan` finds the repeats in an export.
  static func frameRate(_ plan: Plan, cameraFPS: Double?) -> [PolishNote] {
    guard let cam = cameraFPS, plan.camera != nil else { return [] }
    let out = Double(plan.output.fps), r = out / cam
    guard abs(r - r.rounded()) > 0.05, abs(1 / r - (1 / r).rounded()) > 0.05 else { return [] }
    let camText = cam.formatted(.number.precision(.fractionLength(0...2)))
    return [
      PolishNote(
        kind: "frame rate", outSeconds: 0,
        text: "the camera recorded at \(camText) fps but the video renders at \(plan.output.fps), so the face judders (frames repeat or drop unevenly). Set the camera to \(plan.output.fps)p (NTSC, not PAL) for new recordings; for this one, output.fps \(Int(cam.rounded())) plays the camera smoothly")
    ]
  }

  // MARK: Camera

  /// The camera's speed at each output frame: pan in screens a second, zoom in octaves a second.
  static func cameraSpeeds(_ scene: Scene) -> [(pan: Double, zoom: Double, dx: Double, dy: Double)] {
    let fps = Double(scene.fps)
    let base = scene.cameraBase
    var out: [(pan: Double, zoom: Double, dx: Double, dy: Double)] = [(0, 0, 0, 0)]
    guard scene.frameCount > 1 else { return out }
    var prev = scene.cameraState(0, base: base)
    for f in 1..<scene.frameCount {
      let c = scene.cameraState(f, base: base)
      // Pan measured in visible widths: at 2x, a quarter of the recording is half a screen.
      let dx = (c.x - prev.x) * c.scale * fps, dy = (c.y - prev.y) * c.scale * fps
      out.append(((dx * dx + dy * dy).squareRoot(), abs(log2(c.scale / prev.scale)) * fps, dx, dy))
      prev = c
    }
    return out
  }

  /// Output frames where the screen isn't what the viewer sees: full camera, or a full-frame animation.
  static func screenHidden(_ scene: Scene, _ plan: Plan) -> (Double) -> Bool {
    let fps = scene.fps
    let covered = plan.animationList.filter { !$0.isOverlay }.flatMap { srcRangeToOut(scene.mapped, $0.start, $0.end, fps: fps) }
      + plan.insertList.filter(\.isFull).flatMap { srcRangeToOut(scene.mapped, $0.start, $0.end, fps: fps) }
      + plan.layouts.filter { $0.mode == .camera }.flatMap { srcRangeToOut(scene.mapped, $0.start, $0.end, fps: fps) }
    return { f in covered.contains { f >= $0.startF && f < $0.endF } }
  }

  /// The fastest an ease moves, as a multiple of its average speed (a cubic like smooth is about 3).
  static func peakSlope(_ ease: Ease) -> Double {
    let n = 400
    return (0..<n).map { i in (ease.at(Double(i + 1) / Double(n)) - ease.at(Double(i) / Double(n))) * Double(n) }.max() ?? 1
  }

  /// The fastest pan (screens/s) and zoom (octaves/s) this plan's motion style should make.
  public static func speedLimits(_ plan: Plan) -> (pan: Double, zoom: Double) {
    let peak = peakSlope(MotionStyle.named(plan.style.motion).ease) / max(plan.style.transition, 0.1)
    return (fasterThanStandard * standardPan * peak, fasterThanStandard * peak)
  }

  static func camera(_ scene: Scene, _ plan: Plan) -> [PolishNote] {
    let speeds = cameraSpeeds(scene)
    let fps = Double(scene.fps)
    let (maxPan, maxZoom) = speedLimits(plan)
    let hidden = screenHidden(scene, plan)
    func moving(_ f: Int) -> Bool { f >= 0 && f < speeds.count && (speeds[f].pan > stillPan || speeds[f].zoom > stillZoom) }
    var out: [PolishNote] = []

    // Clicks while the camera moves: the press should land on a still frame.
    var lastNoted = -Double.infinity
    for c in scene.focusClicks where !hidden(c.f) && c.f - lastNoted > fps {
      let from = Int((c.f - settleBeforeClick * fps).rounded()), to = Int((c.f + holdAfterClick * fps).rounded())
      guard let f = (from...max(from, to)).first(where: moving) else { continue }
      lastNoted = c.f
      let when = f < Int(c.f.rounded()) ? "is still moving as it lands" : "starts moving right after it"
      out.append(
        PolishNote(
          kind: "camera", outSeconds: c.f / fps,
          text: "click at out \(fmtTime(c.f / fps)): the camera \(when); settle the zoom \(fmtSeconds(settleBeforeClick)) s before the click and hold \(fmtSeconds(holdAfterClick)) s after (move the zoom's start earlier or its end later)"))
    }

    // Moves: runs of moving frames. Too fast, stop-start, or a reversal mid-move.
    var runs: [(a: Int, b: Int)] = []
    var f = 1
    while f < speeds.count {
      guard moving(f) else { f += 1; continue }
      var e = f
      while e + 1 < speeds.count && moving(e + 1) { e += 1 }
      runs.append((f, e))
      f = e + 1
    }
    for (i, r) in runs.enumerated() where !hidden(Double(r.a)) {
      let at = Double(r.a) / fps
      let peakPan = speeds[r.a...r.b].map(\.pan).max() ?? 0, peakZoom = speeds[r.a...r.b].map(\.zoom).max() ?? 0
      if peakPan > maxPan {
        out.append(
          PolishNote(
            kind: "camera", outSeconds: at,
            text: "camera move at out \(fmtTime(at)) pans \(fmtSeconds(peakPan)) screens/s at its peak, past \(fmtSeconds(maxPan)) for this motion style: give it a longer move (zoom seconds) or zoom out between far-apart targets"))
      }
      if peakZoom > maxZoom {
        out.append(
          PolishNote(
            kind: "camera", outSeconds: at,
            text: "camera move at out \(fmtTime(at)) zooms \(fmtSeconds(peakZoom)) octaves/s at its peak, past \(fmtSeconds(maxZoom)) for this motion style: use a smaller scale change or a longer move"))
      }
      if i + 1 < runs.count, case let gap = Double(runs[i + 1].a - r.b - 1) / fps, gap > 0, gap < stutterGap, !hidden(Double(runs[i + 1].a)) {
        out.append(
          PolishNote(
            kind: "camera", outSeconds: Double(r.b) / fps,
            text: "camera stops for \(fmtSeconds(gap)) s at out \(fmtTime(Double(r.b) / fps)) and moves again: a stutter. Join the two moves (one zoom to the final framing) or hold a second or more between them"))
      }
      // A reversal: the pan swings back the way it came while both are real moves, not a spring settling.
      for g in stride(from: r.a + 1, through: r.b, by: 1) {
        let v0 = speeds[g - 1], v1 = speeds[g]
        if v0.dx * v1.dx + v0.dy * v1.dy < 0, v0.pan > 0.3 * peakPan, v1.pan > 0.3 * peakPan, peakPan > 0.5 {
          out.append(
            PolishNote(
              kind: "camera", outSeconds: Double(g) / fps,
              text: "camera reverses direction mid-move at out \(fmtTime(Double(g) / fps)): a new zoom interrupts the last one going the other way. Space the zooms out or drop one"))
          break
        }
      }
    }
    return out
  }

  // MARK: Items

  /// Titles and annotation labels on screen too briefly to read.
  static func reading(_ scene: Scene, _ plan: Plan) -> [PolishNote] {
    let fps = Double(scene.fps)
    func need(_ text: String) -> Double {
      let words = text.split(whereSeparator: \.isWhitespace).count
      return max(minReadSeconds, Double(words) * 0.33 + 0.5)
    }
    var out: [PolishNote] = []
    for c in scene.callouts {
      let text = [c.c.text, c.c.subtitle ?? ""].joined(separator: " ")
      let seconds = (c.e - c.s) / fps, needed = need(text)
      if seconds < needed {
        out.append(
          PolishNote(
            kind: "reading", outSeconds: c.s / fps,
            text: "title \"\(c.c.text)\" at out \(fmtTime(c.s / fps)) is up \(fmtSeconds(seconds)) s; its words need \(fmtSeconds(needed)) s to read"))
      }
    }
    for a in scene.annotations {
      guard let text = a.a.text, !text.isEmpty else { continue }
      let seconds = (a.e - a.s) / fps, needed = need(text)
      if seconds < needed {
        out.append(
          PolishNote(
            kind: "reading", outSeconds: a.s / fps,
            text: "\(a.a.kind) label \"\(text)\" at out \(fmtTime(a.s / fps)) is up \(fmtSeconds(seconds)) s; it needs \(fmtSeconds(needed)) s to read"))
      }
    }
    return out
  }

  /// Styled transitions on too many cuts, or the same one twice in a row.
  static func transitions(_ scene: Scene, _ plan: Plan) -> [PolishNote] {
    let fps = Double(scene.fps)
    // Cuts: every clip after the first that doesn't continue straight from the one before.
    let cuts = scene.mapped.indices.dropFirst().filter { i in abs(scene.mapped[i - 1].end - scene.mapped[i].start) > 0.001 || scene.mapped[i].transition != nil }
    let styled = cuts.filter { scene.mapped[$0].transition != nil }
    var out: [PolishNote] = []
    if styled.count >= 2, Double(styled.count) > maxTransitionShare * Double(cuts.count) {
      out.append(
        PolishNote(
          kind: "transitions", outSeconds: Double(scene.mapped[styled[0]].outStart) / fps,
          text: "\(styled.count) of \(cuts.count) cuts have a styled transition; keep them for section changes and let the rest be hard cuts"))
    }
    for (a, b) in zip(styled, styled.dropFirst()) where cuts.firstIndex(of: b) == cuts.firstIndex(of: a).map({ $0 + 1 }) {
      let t = scene.mapped[b].transition ?? ""
      guard t == scene.mapped[a].transition else { continue }
      let at = Double(scene.mapped[b].outStart) / fps
      out.append(PolishNote(kind: "transitions", outSeconds: at, text: "two \(t) transitions in a row at out \(fmtTime(at)); make one of them a hard cut"))
    }
    return out
  }

  /// Stretches with more sounds than a viewer can take as meaningful. An animation's own beat
  /// sounds don't count: a diagram building on cue is one appearance after another.
  static func sounds(_ scene: Scene, _ plan: Plan) -> [PolishNote] {
    let fps = Double(scene.fps)
    var outside = plan
    outside.animations = nil
    let times = outside.soundEffects.compactMap { srcToOut(scene.mapped, $0.t, fps: scene.fps).map { $0 / fps } }.sorted()
    var out: [PolishNote] = []
    var i = 0
    while i < times.count {
      let window = times[i...].prefix { $0 < times[i] + 10 }
      if window.count > maxSoundsPer10s {
        out.append(
          PolishNote(
            kind: "sound", outSeconds: times[i],
            text: "\(window.count) sound effects in 10 s from out \(fmtTime(times[i])); keep the ones on the biggest appearances (about one per 10 s reads as produced)"))
        i += window.count
      } else {
        i += 1
      }
    }
    return out
  }

  /// Titles and annotations that enter on the same frame: one thing should draw the eye at a time.
  static func together(_ scene: Scene, _ plan: Plan) -> [PolishNote] {
    let fps = Double(scene.fps)
    let starts = (scene.callouts.map { ($0.s, "title \"\($0.c.text)\"") } + scene.annotations.map { ($0.s, "\($0.a.kind)\($0.a.text.map { " \"\($0)\"" } ?? "")") })
      .sorted { $0.0 < $1.0 }
    var out: [PolishNote] = []
    for (a, b) in zip(starts, starts.dropFirst()) where b.0 - a.0 < 3 {
      out.append(
        PolishNote(
          kind: "overlays", outSeconds: a.0 / fps,
          text: "\(a.1) and \(b.1) enter together at out \(fmtTime(a.0 / fps)); bring the second in on its own word, or at least 0.15 s later"))
    }
    return out
  }

  static func fmtSeconds(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }
}
