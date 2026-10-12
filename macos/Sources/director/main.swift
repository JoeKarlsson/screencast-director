import CoreImage
import DirectorCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// director: headless commands on a project folder. The app bundles it so Claude can run `describe`.
//
//   director analyze  <dir>                transcript.json + motion.json
//   director plan     <dir> [--force]      first-draft plan.json
//   director describe <dir>                the plan as a readable timeline
//   director render   <dir> [out.mp4]      export (default <dir>/out.mp4)
//   director still    <dir> <frame> <png> [--preset id]  one output frame, for checking an edit
//   director profile  <dir> <profileDir>   apply a profile (look + style) to the plan
//   director render   <dir> [out.mp4] [--preset id]   presets: youtube-4k youtube-1080 vertical square feed

let usage = """
  usage:
    director analyze  <dir>
    director plan     <dir> [--force]
    director describe <dir>
    director review   <dir>                         what each zoom shows, cut edges inside words, frames to check
    director render   <dir> [out.mp4]
    director still    <dir> <frame> <out.png> [--preset id]
    director profile  <dir> <profileDir>
    director pauses   <dir> gentle|normal|tight     re-cut silences (keeps cuts that removed words)
    director frame-camera <dir>                      center the camera on the speaker's face
    director screentext <dir>                        read the text around each click (screentext.json)
    director cut      <dir> <start> <end>           cut a source-time range (seconds) from the edit
    director restore  <dir> <start> <end>           put a cut source-time range back at 1x
    director publish  <dir> [--title "..."] [--preset id]   captions.srt, chapters, transcript, thumbnails
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

/// The plan, reshaped by --preset if given (the saved plan is untouched).
func planFor(_ project: Project) throws -> Plan {
  let plan = try Plan.load(project.planURL)
  guard let i = args.firstIndex(of: "--preset") else { return plan }
  guard i + 1 < args.count, let preset = ExportPreset.all.first(where: { $0.id == args[i + 1] }) else { fail(usage) }
  return preset.applied(to: plan)
}
let flags: Set<String> = ["--preset", "--title", "--from", "--to", "--width", "--fps"]
func number(_ flag: String) -> Double? {
  args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
}
let positional = args.enumerated().filter { i, a in !flags.contains(a) && (i == 0 || !flags.contains(args[i - 1])) }.map(\.element)

func stillFrame(_ project: Project, _ plan: Plan, frame: Int, to out: URL) async throws {
  let built = try await buildComposition(project: project, plan: plan)
  let image = try await stillImage(built, frame: frame)
  guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("can't write \(out.path)")
  }
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
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
    let plan = buildPlan(project)
    try plan.write(to: project.planURL)
    print("wrote \(project.planURL.path): \(plan.segments.count) segments, \(plan.zooms.count) zooms")
  case "debug":
    let project = try Project.load(dir)
    let built = try await buildComposition(project: project, plan: try Plan.load(project.planURL))
    print("asset duration", built.asset.duration.seconds, "frames", built.scene.frameCount)
    for t in built.asset.tracks { print(t.trackID, t.mediaType.rawValue, t.timeRange.start.seconds, t.timeRange.duration.seconds, t.segments.count) }
    for i in built.videoComposition.instructions { print("instr", i.timeRange.start.seconds, i.timeRange.duration.seconds) }
  case "describe":
    let project = try Project.load(dir)
    print(describe(project, try Plan.load(project.planURL)))
  case "review":
    let project = try Project.load(dir)
    print(editReview(project, try Plan.load(project.planURL)))
  case "render":
    let project = try Project.load(dir)
    let out = positional.count > 2 ? URL(fileURLWithPath: positional[2]) : dir.appendingPathComponent("out.mp4")
    let built = try await buildComposition(project: project, plan: try planFor(project))
    let started = Date()
    try await export(built, to: out) { p in
      FileHandle.standardError.write(Data("\(Int(p * 100))%\n".utf8))
    }
    print(String(format: "Rendered %@ in %.1fs", out.path, Date().timeIntervalSince(started)))
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
    try await stillFrame(project, try planFor(project), frame: frame, to: out)
    print(positional[3])
  case "publish":
    let project = try Project.load(dir)
    let title = args.firstIndex(of: "--title").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? dir.lastPathComponent
    let files = try await Publish.run(project: project, plan: try planFor(project), title: title) { print($0) }
    files.forEach { print("wrote \($0.path)") }
  case "pauses":
    guard positional.count == 3, let level = PauseLevel(rawValue: positional[2]) else { fail(usage) }
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    let before = Double(planFrames(plan)) / Double(plan.output.fps)
    let levels = try await Analyzer.loudness(project, video: plan.source.video)
    plan.retrimPauses(words: project.words, level: level, silences: Analyzer.silences(levels, minLength: 0.2), paused: project.paused)
    plan.pauses = level
    try plan.write(to: project.planURL)
    let after = Double(planFrames(plan)) / Double(plan.output.fps)
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
  case "cut", "restore":
    guard positional.count == 4, let a = Double(positional[2]), let b = Double(positional[3]), b > a else { fail(usage) }
    let project = try Project.load(dir)
    var plan = try Plan.load(project.planURL)
    let before = Double(planFrames(plan)) / Double(plan.output.fps)
    if args[0] == "cut" { plan.cut(range: a..<b) } else { plan.restore(range: a..<b) }
    try plan.write(to: project.planURL)
    let after = Double(planFrames(plan)) / Double(plan.output.fps)
    print("\(args[0]) \(fmtTime(a))-\(fmtTime(b)): \(fmtTime(before)) -> \(fmtTime(after))")
  case "gif":
    let project = try Project.load(dir)
    let out = positional.count > 2 ? URL(fileURLWithPath: positional[2]) : dir.appendingPathComponent("out.gif")
    let built = try await buildComposition(project: project, plan: try planFor(project))
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
