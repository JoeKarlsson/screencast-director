import CoreImage
import DirectorCore
import Foundation

// director: headless commands on a project folder. The app bundles it so Claude can run `describe`.
// `usage` below lists the commands.

let usage = """
  usage:
    director analyze  <dir>
    director plan     <dir> [--force]
    director describe <dir>
    director animate  <dir> [--force] [--preset id | --clip name]   render the plan's animations to .animations/ (render, still and gif do this first)
    director review   <dir>                         what each zoom shows, cut edges inside words, frames to check
    director render   <dir> [out.mp4] [--preset id | --clip name | --clips]   default: <dir>/<project name>.mp4
    director still    <dir> <frame> <out.png> [--preset id | --clip name]
    director profile  <dir> <profileDir>
    director pauses   <dir> gentle|normal|tight     re-cut silences (keeps cuts that removed words)
    director frame-camera <dir>                      center the camera on the speaker's face
    director sync-camera <dir>                       line the camera up with the voice by watching the lips
    director screentext <dir>                        read the text around each click (screentext.json)
    director cut      <dir> <start> <end>           cut a source-time range (seconds) from the edit
    director restore  <dir> <start> <end>           put a cut source-time range back at 1x
    director move     <dir> <start> <end> [--before <t>]   play a source-time range first (a cold open), or just before source time t
    director publish  <dir> [--title "..."] [--preset id] [--at s1,s2]   captions.srt, chapters, transcript, thumbnails (covers from those source seconds)
    director join     <out> <dir1> <dir2> ...       join takes into a new project with a fresh draft plan
    director upload   <file>                        S3-compatible PUT; prints the public URL (S3_* env vars)
    director gif      <dir> [out.gif] [--from s] [--to s] [--width 720] [--fps 12] [--preset id]   output seconds
    presets: \(ExportPreset.all.map(\.id).joined(separator: " "))
  """

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data((msg + "\n").utf8))
  exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail(usage) }
let dir = URL(fileURLWithPath: args[1]).standardizedFileURL

/// The --preset given, if any.
func presetArg() -> ExportPreset? {
  guard let i = args.firstIndex(of: "--preset") else { return nil }
  guard i + 1 < args.count, let preset = ExportPreset.all.first(where: { $0.id == args[i + 1] }) else { fail(usage) }
  return preset
}
/// The clip --clip names, if given.
func clipArg(_ plan: Plan) -> Clip? {
  guard let i = args.firstIndex(of: "--clip") else { return nil }
  guard i + 1 < args.count else { fail(usage) }
  guard let clip = plan.clipList.first(where: { $0.name == args[i + 1] }) else {
    fail("no clip named \"\(args[i + 1])\" (the plan has: \(plan.clipList.map(\.name).joined(separator: ", ")))")
  }
  return clip
}
/// A clip's plan: the edit cut to its range, in its format, its pauses re-cut from `words`.
func clipPlan(_ plan: Plan, _ clip: Clip, words: [Word], silences: [(Double, Double)]?) -> Plan {
  let p = plan.trimmed(to: clip, words: words, silences: silences)
  if p.segments.isEmpty { fail("the clip \"\(clip.name)\" is entirely cut from the edit") }
  return p
}
/// The plan for --clip, or reshaped by --preset, or as saved (the saved plan is untouched).
func planFor(_ project: Project) throws -> Plan {
  let plan = try Plan.load(project.planURL)
  if let clip = clipArg(plan) { return clipPlan(plan, clip, words: project.words, silences: project.silences) }
  return presetArg().map { $0.applied(to: plan) } ?? plan
}
let flags: Set<String> = ["--preset", "--clip", "--title", "--from", "--to", "--width", "--fps", "--before", "--at"]
func number(_ flag: String) -> Double? {
  args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
}
let positional = args.enumerated().filter { i, a in !flags.contains(a) && (i == 0 || !flags.contains(args[i - 1])) }.map(\.element)

/// The build's warnings, on stderr.
func printWarnings(_ built: BuiltComposition) {
  for w in built.warnings { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
}

func stillFrame(_ project: Project, _ plan: Plan, frame: Int, to out: URL) async throws {
  let built = try await buildComposition(project: project, plan: plan)
  printWarnings(built)
  try Publish.writePNG(try await stillImage(built, frame: frame), to: out)
}

do {
  switch args[0] {
  case "analyze":
    try await analyze(dir) { print($0) }
    print("Analysis done: transcript.json, motion.json")
  case "screentext":
    try await readScreenText(dir) { print($0) }
    let samples = ScreenText.load(dir)
    print("Read \(samples.count) clicks: " + samples.prefix(8).map { ScreenText.clicked(samples, at: $0.t) ?? "?" }.joined(separator: ", "))
  case "plan":
    let project = try Project.load(dir)
    if FileManager.default.fileExists(atPath: project.planURL.path), args.dropFirst(2).first != "--force" {
      fail("\(project.planURL.path) exists (it may hold edits). Pass --force to regenerate it.")
    }
    // With nothing to go on, every stretch reads as idle and the draft cuts the whole recording.
    if project.words.isEmpty && project.motion.isEmpty && project.events.isEmpty {
      fail("\(dir.path) has no transcript, screen motion or input events yet. Run `director analyze` (sd analyze) first.")
    }
    let plan = buildPlan(project)
    try plan.write(to: project.planURL)
    print("wrote \(project.planURL.path): \(plan.segments.count) segments, \(plan.zooms.count) zooms")
  case "debug":
    let project = try Project.load(dir)
    let built = try await buildComposition(project: project, plan: try Plan.load(project.planURL))
    printWarnings(built)
    print("asset duration", built.asset.duration.seconds, "frames", built.scene.frameCount)
    for t in built.asset.tracks { print(t.trackID, t.mediaType.rawValue, t.timeRange.start.seconds, t.timeRange.duration.seconds, t.segments.count) }
    for i in built.videoComposition.instructions { print("instr", i.timeRange.start.seconds, i.timeRange.duration.seconds) }
  case "describe":
    let project = try Project.load(dir)
    print(describe(project, try Plan.load(project.planURL)))
  case "review":
    let project = try Project.load(dir)
    print(editReview(project, try Plan.load(project.planURL)))
  case "animate":
    let project = try Project.load(dir)
    let plan = try planFor(project)
    let n = try await Animate.renderMissing(dir, plan, force: args.contains("--force")) { print($0) }
    print(n == 0 ? "Animations are up to date." : "Rendered \(n) animation(s).")
  case "render":
    let project = try Project.load(dir)
    // --clips renders every clip; otherwise the video or one --clip, at a preset's size if given.
    // Animations render at each output's size before its video is built.
    let saved = try Plan.load(project.planURL)
    let jobs: [(plan: Plan, out: URL, clip: Bool)] =
      args.contains("--clips")
      ? saved.clipList.map { (clipPlan(saved, $0, words: project.words, silences: project.silences), exportURL(dir: dir, clip: $0), true) }
      : [(try planFor(project), positional.count > 2 ? URL(fileURLWithPath: positional[2]) : exportURL(dir: dir, preset: presetArg(), clip: clipArg(saved)), clipArg(saved) != nil)]
    if jobs.isEmpty { fail("the plan has no clips") }
    for job in jobs {
      _ = try await Animate.renderMissing(dir, job.plan) { print($0) }
      let built = try await buildComposition(project: project, plan: job.plan)
      printWarnings(built)
      let started = Date()
      try await export(built, to: job.out) { p in
        FileHandle.standardError.write(Data("\(Int(p * 100))%\n".utf8))
      }
      print(String(format: "Rendered %@ in %.1fs", job.out.path, Date().timeIntervalSince(started)))
      // A clip goes out on its own, so its captions file goes beside it (for platforms that take one).
      if job.clip {
        let srt = job.out.deletingPathExtension().appendingPathExtension("srt")
        try Publish.srt(Scene(plan: job.plan, words: project.words, clicks: project.clicks, shortcuts: project.shortcuts)).write(to: srt, atomically: true, encoding: .utf8)
        print("wrote \(srt.path)")
      }
    }
  case "still":
    guard positional.count == 4, let frame = Int(positional[2]) else { fail(usage) }
    let project = try Project.load(dir)
    // Headless Claude may run this: write only into the project (e.g. .checks/) or a temp folder,
    // and never through a symlink.
    let out = URL(fileURLWithPath: positional[3])
    let roots = [dir, URL(fileURLWithPath: NSTemporaryDirectory()), URL(fileURLWithPath: "/tmp")]
    guard roots.contains(where: { PathSafety.url(out, isInside: $0) }) else {
      fail("refusing to write \(out.path): stills go in the project folder or a temp folder")
    }
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: out.path)) != nil { fail("refusing to overwrite the symlink \(out.path)") }
    if PathSafety.url(out, isInside: dir) {
      try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let plan = try planFor(project)
    _ = try await Animate.renderMissing(dir, plan) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    try await stillFrame(project, plan, frame: frame, to: out)
    print(positional[3])
  case "publish":
    let project = try Project.load(dir)
    let title = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? dir.lastPathComponent
    let at = args.firstIndex(of: "--at").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }?.split(separator: ",").compactMap { Double($0) }
    let files = try await Publish.run(project: project, plan: try planFor(project), title: title, coverAt: at) { print($0) }
    files.forEach { print("wrote \($0.path)") }
  case "pauses":
    guard positional.count == 3, let level = PauseLevel(rawValue: positional[2]) else { fail(usage) }
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    let before = planSeconds(plan)
    let levels = try await Analyzer.loudness(project, video: plan.source.video)
    plan.retrimPauses(words: project.words, level: level, silences: Analyzer.silences(levels, minLength: 0.2), paused: project.paused)
    plan.pauses = level
    try plan.write(to: project.planURL)
    let after = planSeconds(plan)
    print("pauses \(level.rawValue): \(fmtTime(before)) -> \(fmtTime(after))")
  case "frame-camera":
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    guard let face = try await Publish.faceCenter(project: project, plan: plan) else { fail("no face found in the camera video") }
    plan.camera?.x = face.x
    plan.camera?.y = face.y
    let zoom = Publish.centeringZoom(x: face.x, y: face.y)
    plan.camera?.zoom = zoom
    try plan.write(to: project.planURL)
    print(String(format: "camera centered on face at (%.2f, %.2f), zoom %.2f", face.x, face.y, plan.camera?.zoom ?? 1))
  case "sync-camera":
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    guard let camera = plan.camera else { fail("this recording has no camera") }
    guard let sync = try await LipSync.measure(project: project, camera: camera) else { fail("no face or voice to compare") }
    let summary = String(
      format: "lips match the voice at offset %.3f s (was %.3f; strength %.2f, %d of %d windows agree)",
      sync.offset, camera.offset, sync.strength, sync.agreeing, sync.windows)
    guard sync.confident else { fail("not sure enough to change it: " + summary) }
    plan.camera?.offset = sync.offset
    try plan.write(to: project.planURL)
    print(summary)
  case "cut", "restore":
    guard positional.count == 4, let a = Double(positional[2]), let b = Double(positional[3]), b > a else { fail(usage) }
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    let before = planSeconds(plan)
    if args[0] == "cut" { plan.cut(range: a..<b) } else { plan.restore(range: a..<b) }
    try plan.write(to: project.planURL)
    let after = planSeconds(plan)
    print("\(args[0]) \(fmtTime(a))-\(fmtTime(b)): \(fmtTime(before)) -> \(fmtTime(after))")
  case "move":
    guard positional.count == 4, let a = Double(positional[2]), let b = Double(positional[3]), b > a else { fail(usage) }
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    let before = number("--before")
    guard plan.move(range: a..<b, before: before) else {
      fail("nothing kept in \(fmtTime(a))-\(fmtTime(b)) to move\(before.map { ", or \(fmtTime($0)) is inside it" } ?? "")")
    }
    try plan.write(to: project.planURL)
    let at = srcRangeToOut(mapPlan(plan), a, b, fps: plan.output.fps).first.map { fmtTime($0.startF / Double(plan.output.fps)) } ?? "?"
    print("move \(fmtTime(a))-\(fmtTime(b)): now plays at \(at)")
  case "gif":
    let project = try Project.load(dir)
    let out = positional.count > 2 ? URL(fileURLWithPath: positional[2]) : dir.appendingPathComponent("out.gif")
    let plan = try planFor(project)
    _ = try await Animate.renderMissing(dir, plan) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    let built = try await buildComposition(project: project, plan: plan)
    printWarnings(built)
    let opts = GIF.Options(from: number("--from"), to: number("--to"), width: Int(number("--width") ?? 720), fps: Int(number("--fps") ?? 12))
    let started = Date()
    let frames = try await GIF.export(built, to: out, options: opts)
    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    print(String(format: "Wrote %@: %d frames, %.1f MB in %.1fs", out.path, frames, Double(size) / 1e6, Date().timeIntervalSince(started)))
  case "upload":
    // args[1] is the file here, not a project folder.
    let env = ProcessInfo.processInfo.environment
    guard let endpoint = env["S3_ENDPOINT"].flatMap(URL.init(string:)), let bucket = env["S3_BUCKET"],
      let access = env["S3_ACCESS_KEY"], let secret = env["S3_SECRET_KEY"]
    else { fail("upload needs S3_ENDPOINT, S3_BUCKET, S3_ACCESS_KEY and S3_SECRET_KEY (S3_REGION, S3_PUBLIC_BASE optional)") }
    let config = S3.Config(
      endpoint: endpoint, region: env["S3_REGION"] ?? "us-east-1", bucket: bucket, accessKey: access, secretKey: secret,
      publicBase: env["S3_PUBLIC_BASE"])
    let url = try await S3.upload(dir, key: S3.key(for: dir, name: dir.deletingPathExtension().lastPathComponent), config: config)
    print(url.absoluteString)
  case "join":
    guard positional.count >= 4 else { fail(usage) }
    let takes = positional.dropFirst(2).map { URL(fileURLWithPath: $0).standardizedFileURL }
    let result = try await Join.run(Array(takes), into: dir) { print($0) }
    let project = try Project.load(dir)
    let plan = buildPlan(project)
    try plan.write(to: project.planURL)
    let mapped = mapPlan(plan)
    print("joined \(takes.count) takes into \(dir.path): \(fmtTime(project.source.duration)), \(project.words.count) words, \(project.events.count) events")
    for (i, (t, start)) in zip(takes, result.starts).enumerated() {
      let f = Int(srcToOutClamped(mapped, start, fps: plan.output.fps))
      print("  take \(i + 1) \(t.lastPathComponent) starts at src \(fmtTime(start)), output frame \(f)")
    }
    print("wrote \(project.planURL.path): \(plan.segments.count) segments, \(plan.zooms.count) zooms")
  case "profile":
    guard positional.count == 3 else { fail(usage) }
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    let profile = try Profile.load(URL(fileURLWithPath: positional[2]))
    profile.apply(to: &plan, name: dir.lastPathComponent)
    try plan.write(to: project.planURL)
    print("applied profile \(profile.name)")
  default:
    fail(usage)
  }
} catch {
  fail("director: \(error.localizedDescription)\n\(error)")
}
