import Foundation

// `director review`'s retention notes: structure checks that depend on how long the video is.
// The ceilings come from measuring 31 hit videos (the engagement research, written up in
// .claude/skills/edit-screencast/references/engagement/by-length.md); each sits at or just past the
// worst seen in a hit, so a good edit stays quiet. Like the polish notes, none of these stops a build.

/// What a video of one length should stay inside, in output seconds.
public struct EngagementTargets: Equatable, Sendable {
  /// "60 s", "3 min", "5 min", "20 min" or "60 min".
  public var name: String
  /// The longest video this bucket covers.
  public var upTo: Double
  /// Before the first spoken word, intro card included.
  public var maxIntro: Double
  /// The longest stretch with nothing new on screen while the screen is what the viewer watches.
  public var maxStill: Double
  /// After the last spoken word, not counting the outro card (that's end-screen room).
  public var maxTail: Double
  /// The longest a chapter may run; nil when the bucket doesn't need chapters.
  public var maxChapterGap: Double?

  public static let all = [
    EngagementTargets(name: "60 s", upTo: 90, maxIntro: 0.5, maxStill: 6, maxTail: 3, maxChapterGap: nil),
    EngagementTargets(name: "3 min", upTo: 240, maxIntro: 1, maxStill: 20, maxTail: 15, maxChapterGap: nil),
    EngagementTargets(name: "5 min", upTo: 480, maxIntro: 3, maxStill: 36, maxTail: 20, maxChapterGap: 120),
    EngagementTargets(name: "20 min", upTo: 2100, maxIntro: 3, maxStill: 45, maxTail: 25, maxChapterGap: 300),
    EngagementTargets(name: "60 min", upTo: .infinity, maxIntro: 30, maxStill: 60, maxTail: 30, maxChapterGap: 600),
  ]

  /// The bucket for a plan's output length. Vertical video goes by the 60 s rules at any length.
  public static func of(_ plan: Plan) -> EngagementTargets {
    Aspect.of(plan.output) == .vertical ? all[0] : all.first { planSeconds(plan) <= $0.upTo }!
  }
}

public enum Retention {
  /// A cut away from the screen this soon after a click or the last keystroke hides the result
  /// before it can be read (viewers rewind for code that vanished).
  static let holdSeconds = 0.5
  /// Keystrokes closer than this are one typing run.
  static let typingGap = 1.0

  /// Every retention note for the edit, then for each social clip at its own length and format.
  public static func notes(_ project: Project, _ plan: Plan) -> [PolishNote] {
    let clipNotes = plan.clipList.flatMap { clip in
      check(project, plan.trimmed(to: clip, words: project.words, silences: project.silences))
        .map { PolishNote(kind: $0.kind, outSeconds: $0.outSeconds, text: "clip \"\(clip.name)\": \($0.text)") }
    }
    return check(project, plan) + clipNotes
  }

  static func check(_ project: Project, _ plan: Plan) -> [PolishNote] {
    let scene = Scene(plan: plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts)
    let target = EngagementTargets.of(plan)
    let spoken = spokenSpans(plan, words: project.words)
    return (intro(plan, spoken, target) + hook(scene, plan, spoken) + still(scene, plan, project, target) + hold(scene, plan, project)
      + tail(scene, plan, spoken, target) + chapters(scene, target)).sorted { $0.outSeconds < $1.outSeconds }
  }

  /// Kept spoken words as output-second spans, in play order. Sped-up clips play muted.
  static func spokenSpans(_ plan: Plan, words: [Word]) -> [(s: Double, e: Double)] {
    let fps = Double(plan.output.fps)
    var out: [(s: Double, e: Double)] = []
    for seg in mapPlan(plan) where seg.speed == 1 {
      let at = Double(seg.outStart) / fps
      for w in words where w.end > seg.start + 0.05 && w.start < seg.end - 0.05 && !w.text.trimmingCharacters(in: .whitespaces).isEmpty {
        out.append((at + max(0, w.start - seg.start), at + min(w.end, seg.end) - seg.start))
      }
    }
    return out.sorted { $0.s < $1.s }
  }

  static func intro(_ plan: Plan, _ spoken: [(s: Double, e: Double)], _ target: EngagementTargets) -> [PolishNote] {
    guard let first = spoken.first?.s, first > target.maxIntro else { return [] }
    let card = cardFrames(plan).intro > 0 ? " (the intro card is part of that; hits open on the first line, branding after the hook if anywhere)" : ""
    return [
      PolishNote(
        kind: "intro", outSeconds: 0,
        text: "the first word is at out \(fmtTime(first))\(card); a \(target.name) video should be talking by \(Polish.fmtSeconds(target.maxIntro)) s. Cut the warm-up or open on the strongest moment (`director repeat`)")
    ]
  }

  /// Vertical: the first frame has to say what this is, sound off. A title, an overlay or captions
  /// on a word that starts at once.
  static func hook(_ scene: Scene, _ plan: Plan, _ spoken: [(s: Double, e: Double)]) -> [PolishNote] {
    // An intro card has its own note (`intro`).
    guard Aspect.of(plan.output) == .vertical, cardFrames(plan).intro == 0 else { return [] }
    let soon = 0.5 * Double(scene.fps)
    let titled = scene.callouts.contains { $0.s <= soon } || scene.inserts.contains { $0.a.isOverlay && $0.s <= soon }
      || plan.animationList.contains { $0.isOverlay && (srcToOut(scene.mapped, $0.start, fps: scene.fps) ?? .infinity) <= soon }
    let captioned = plan.captions.enabled && (spoken.first?.s ?? .infinity) <= 0.5
    guard !titled && !captioned else { return [] }
    return [
      PolishNote(
        kind: "hook", outSeconds: 0,
        text: "nothing on screen at 0:00 says what this is (no title, and no caption until the first word): "
          + "give it a hook title (the clip's title, or a title on the first words) or start on the first word")
    ]
  }

  /// The longest stretches where the viewer watches the screen and nothing new happens on it: no cut,
  /// zoom, layout change, title, annotation, picture, punch-in, click, keystroke or screen motion.
  /// A face filling the frame, B-roll footage or an animation playing is something happening.
  static func still(_ scene: Scene, _ plan: Plan, _ project: Project, _ target: EngagementTargets) -> [PolishNote] {
    let fps = Double(scene.fps), m = scene.mapped
    let n = scene.outroStart
    guard n > scene.introFrames else { return [] }
    var busy = [Bool](repeating: false, count: n)
    func mark(_ f: Double) { if f >= 0 && Int(f) < n { busy[Int(f)] = true } }
    func span(_ a: Double, _ b: Double) {
      let lo = max(0, Int(a)), hi = min(n, Int(b.rounded(.up)))
      if lo < hi { for f in lo..<hi { busy[f] = true } }
    }
    span(0, Double(scene.introFrames))
    scene.cutFrames.forEach(mark)
    scene.zooms.forEach { mark($0.startF); mark($0.endF) }
    scene.callouts.forEach { mark($0.s) }
    scene.annotations.forEach { mark($0.s) }
    // B-roll footage moves the whole time it plays; a picture is new only as it lands.
    scene.inserts.forEach { $0.a.isImage ? mark($0.s) : span($0.s, $0.e) }
    plan.animationList.flatMap { srcRangeToOut(m, $0.start, $0.end, fps: scene.fps) }.forEach { span($0.startF, $0.endF) }
    (project.events.filter { $0.type == .click || $0.type == .key }.map(\.t)
      + project.motion.filter { $0.1 > Rules.motionThreshold }.map(\.0)).compactMap { srcToOut(m, $0, fps: scene.fps) }.forEach(mark)
    // Sped-up clips: the screen moves through them.
    m.filter { $0.speed > 1.5 }.forEach { span(Double($0.outStart), Double($0.outStart + $0.frames)) }
    if plan.camera != nil {
      let portrait = socialTop(plan) != nil
      func faceLed(_ mode: LayoutMode) -> Bool { mode == .camera || mode == .side || (portrait && mode != .screen) }
      for f in 0..<n where faceLed(scene.layouts.last { Double(f) >= $0.startF && Double(f) < $0.endF }?.mode ?? plan.defaultLayout) {
        busy[f] = true
      }
    }
    var out: [PolishNote] = []
    var f = 0
    while f < n {
      guard !busy[f] else { f += 1; continue }
      var e = f
      while e + 1 < n && !busy[e + 1] { e += 1 }
      let seconds = Double(e - f + 1) / fps
      if seconds > target.maxStill {
        out.append(
          PolishNote(
            kind: "still", outSeconds: Double(f) / fps,
            text: "nothing new on screen for \(Polish.fmtSeconds(seconds.rounded())) s from out \(fmtTime(Double(f) / fps)) to \(fmtTime(Double(e + 1) / fps)); hit \(target.name) videos stay under \(Polish.fmtSeconds(target.maxStill)) s. Add a zoom or punch-in on what's being said, a title, B-roll or a layout change, or speed it up"))
      }
      f = e + 1
    }
    return out
  }

  /// A click or the end of a typing run, then the screen goes away (to the face, B-roll or a
  /// full-frame animation) before the result can be seen.
  static func hold(_ scene: Scene, _ plan: Plan, _ project: Project) -> [PolishNote] {
    let fps = Double(scene.fps)
    let hidden = Polish.screenHidden(scene, plan)
    let keys = project.events.filter { $0.type == .key }.map(\.t).sorted()
    let typingEnds = zip(keys, Array(keys.dropFirst()) + [.infinity]).filter { $1 - $0 > typingGap }.map(\.0)
    var out: [PolishNote] = []
    var last = -Double.infinity
    for (t, what) in (project.clicks.map { ($0.t, "click") } + typingEnds.map { ($0, "typing") }).sorted(by: { $0.0 < $1.0 }) {
      guard let f = srcToOut(scene.mapped, t, fps: scene.fps), f - last > fps, !hidden(f) else { continue }
      let soon = Int((f + holdSeconds * fps).rounded())
      guard let away = (Int(f) + 1...max(Int(f) + 1, soon)).first(where: { hidden(Double($0)) }) else { continue }
      last = f
      out.append(
        PolishNote(
          kind: "hold", outSeconds: f / fps,
          text: "the screen cuts away \(Polish.fmtSeconds(Double(away) / fps - f / fps)) s after the \(what) at out \(fmtTime(f / fps)); hold the result about a second before leaving it (move the layout or B-roll start later)"))
    }
    return out
  }

  static func tail(_ scene: Scene, _ plan: Plan, _ spoken: [(s: Double, e: Double)], _ target: EngagementTargets) -> [PolishNote] {
    let fps = Double(scene.fps)
    guard let last = spoken.map(\.e).max() else { return [] }
    let tail = Double(scene.outroStart) / fps - last
    guard tail > target.maxTail else { return [] }
    return [
      PolishNote(
        kind: "tail", outSeconds: last,
        text: "the video runs \(Polish.fmtSeconds(tail.rounded())) s past the last word at out \(fmtTime(last)); end on the payoff (\(Polish.fmtSeconds(target.maxTail)) s or less for a \(target.name) video, end-screen room goes in the outro card)")
    ]
  }

  /// YouTube chapters (from the titles, as `publish` writes them) for 5 minutes and up: at least
  /// three, and none longer than the bucket's gap.
  static func chapters(_ scene: Scene, _ target: EngagementTargets) -> [PolishNote] {
    guard let maxGap = target.maxChapterGap else { return [] }
    let marks = Publish.chapterMarks(scene)
    guard marks.count >= 3 else {
      return [
        PolishNote(
          kind: "chapters", outSeconds: 0,
          text: "the titles make \(marks.count) YouTube chapter(s); a \(target.name) video needs at least 3 (YouTube's minimum, the first at 0:00). Add a chapter title at each section change")
      ]
    }
    let end = Double(scene.frameCount) / Double(scene.fps)
    return zip(marks, marks.dropFirst().map(\.0) + [end]).compactMap { mark, next in
      next - mark.0 > maxGap
        ? PolishNote(
          kind: "chapters", outSeconds: mark.0,
          text: "chapter \"\(mark.1)\" at out \(fmtTime(mark.0)) runs \(fmtTime(next - mark.0)); split it with a chapter title (a \(target.name) video's chapters stay under \(fmtTime(maxGap)))")
        : nil
    }
  }
}
